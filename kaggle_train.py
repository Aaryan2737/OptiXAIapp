# Author: Aaryan Patil (Roll No. 26) - OptiXAI - SIH26038
"""
OptiXAI - Stage 1: EyePACS Pre-training (Kaggle GPU Environment)
Instructions:
1. Enable GPU (T4 x2 or P100) and mount the 'eyepacs' dataset.
2. Add this to your first cell: !pip install timm scikit-learn opencv-python-headless
3. Run this script.
"""

import os
import time
import gc
import cv2
import numpy as np
import random

# Prevent OpenCV Thread Thrashing
cv2.setNumThreads(0)
cv2.ocl.setUseOpenCL(False)

import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader, WeightedRandomSampler
from sklearn.metrics import cohen_kappa_score
from sklearn.model_selection import train_test_split
import timm

# Reproducibility: seed all RNGs so augmentations and sampling are deterministic
SEED = 42
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)
if torch.cuda.is_available():
    torch.cuda.manual_seed_all(SEED)

# ==========================================
# 1. Hardware Diagnostics & Multi-GPU Setup
# ==========================================
print("=" * 50)
print(f"PyTorch Version: {torch.__version__}")
use_cuda = torch.cuda.is_available()
print(f"CUDA Available:  {use_cuda}")
if use_cuda:
    gpu_count = torch.cuda.device_count()
    print(f"GPUs Detected:   {gpu_count}")
    print(f"Device Name:     {torch.cuda.get_device_name(0)}")
else:
    print("WARNING: Running on CPU!")
print("=" * 50)

device = torch.device("cuda" if use_cuda else "cpu")

# Fixed input size (224x224) → let cuDNN auto-tune conv algorithms for ~15% speedup
if use_cuda:
    torch.backends.cudnn.benchmark = True

# ==========================================
# 2. Custom Preprocessing & Dataset
# ==========================================
class FocalLoss(nn.Module):
    """Focal Loss with optional per-class alpha weighting.
    
    Args:
        alpha: Per-class weight tensor of shape (num_classes,), or scalar.
               Pass inverse class frequencies to up-weight rare classes.
        gamma: Focusing parameter. Higher = more focus on hard examples.
    """
    def __init__(self, alpha=None, gamma=2.0, reduction='mean'):
        super(FocalLoss, self).__init__()
        if alpha is not None:
            if isinstance(alpha, (list, np.ndarray)):
                alpha_t = torch.FloatTensor(alpha)
            elif isinstance(alpha, torch.Tensor):
                alpha_t = alpha.float()
            else:
                alpha_t = torch.tensor(float(alpha))
            # register_buffer: moves with .to(device), included in state_dict, no gradient
            self.register_buffer('alpha', alpha_t)
        else:
            self.alpha = None
        self.gamma = gamma
        self.reduction = reduction
        self.ce = nn.CrossEntropyLoss(reduction='none')

    def forward(self, inputs, targets):
        ce_loss = self.ce(inputs, targets)
        pt = torch.exp(-ce_loss)
        focal_loss = (1 - pt) ** self.gamma * ce_loss
        
        if self.alpha is not None:
            alpha_t = self.alpha.to(inputs.device)[targets]
            focal_loss = alpha_t * focal_loss
        
        if self.reduction == 'mean':
            return focal_loss.mean()
        return focal_loss.sum()

class KaggleEyePACSDataset(Dataset):
    def __init__(self, image_paths, labels, augment=False):
        self.image_paths = image_paths
        self.labels = labels
        self.augment = augment
        # Create CLAHE once, reuse for all images (thread-safe with num_workers=0)
        self.clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))

    def __len__(self):
        return len(self.image_paths)

    def preprocess_fundus(self, img):
        # A. Contour Auto-Crop with Fallback
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        _, thresh = cv2.threshold(gray, 10, 255, cv2.THRESH_BINARY)
        contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        
        if contours:
            c = max(contours, key=cv2.contourArea)
            x, y, w, h = cv2.boundingRect(c)
            if w > img.shape[1] * 0.3 and h > img.shape[0] * 0.3:
                img = img[y:y+h, x:x+w]
        
        # Free contour intermediates immediately
        del gray, thresh, contours
                
        # B. CLAHE on L-channel of LAB color space
        # [FIX] Matches Stage 2 preprocess.py — previously used green channel of BGR
        # LAB CLAHE preserves color fidelity while enhancing luminance contrast
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2Lab)
        l_ch, a_ch, b_ch = cv2.split(lab)
        l_clahe = self.clahe.apply(l_ch)
        del l_ch  # Free original L channel
        img = cv2.merge((l_clahe, a_ch, b_ch))
        img = cv2.cvtColor(img, cv2.COLOR_Lab2BGR)
        del l_clahe, a_ch, b_ch, lab  # Free channel arrays
        
        # C. Bicubic Resize to 224x224
        img = cv2.resize(img, (224, 224), interpolation=cv2.INTER_CUBIC)
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        
        # D. Training augmentations (fundus-safe: no color jitter)
        if self.augment:
            if random.random() > 0.5:
                img = cv2.flip(img, 1)
            if random.random() > 0.5:
                img = cv2.flip(img, 0)
            k = random.randint(0, 3)
            if k > 0:
                img = np.rot90(img, k).copy()
        
        # E. Normalize to [0, 1] float32, apply ImageNet mean/std, convert to tensor
        # [FIX] Added ImageNet normalization to match Stage 2 preprocess.py
        # Previously only divided by 255.0, causing a distribution shift when
        # Stage 2 fine-tuning loaded these weights with ImageNet-normalized inputs.
        IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
        IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
        
        img = np.ascontiguousarray(img.transpose(2, 0, 1), dtype=np.float32) / 255.0
        # Apply per-channel normalization: (pixel - mean) / std
        for c in range(3):
            img[c] = (img[c] - IMAGENET_MEAN[c]) / IMAGENET_STD[c]
        return torch.from_numpy(img)

    def __getitem__(self, idx, _depth=0):
        path = self.image_paths[idx]
        label = self.labels[idx]
        
        # Load at HALF resolution: EyePACS images are 3000-5000px, we need 224px.
        # This cuts raw memory from ~45MB to ~11MB per image load.
        img = cv2.imread(path, cv2.IMREAD_REDUCED_COLOR_2)
        if img is None:
            # Fallback: try full resolution in case REDUCED isn't supported
            img = cv2.imread(path)
        if img is None:
            if _depth >= 5:
                return torch.zeros(3, 224, 224, dtype=torch.float32), 0
            fallback_idx = random.randint(0, len(self.image_paths) - 1)
            return self.__getitem__(fallback_idx, _depth=_depth + 1)
        
        tensor_img = self.preprocess_fundus(img)
        del img  # Free raw image array immediately
        return tensor_img, label

# ==========================================
# 3. CSV-Based Data Ingestion
# ==========================================
def find_dataset_files(base_path="/kaggle/input"):
    print("Searching for images and CSV labels...")
    csv_path = None
    img_dir = None
    all_csvs = []
    
    for root, dirs, files in os.walk(base_path):
        for f in files:
            if f.endswith('.csv'):
                all_csvs.append(os.path.join(root, f))
            # Grab the first directory containing any standard image format
            if f.lower().endswith(('.jpeg', '.jpg', '.png', '.tif')) and img_dir is None:
                img_dir = root
    
    # Prefer trainLabels.csv over any other CSV (e.g., testLabels.csv)
    if all_csvs:
        for c in all_csvs:
            if 'trainlabels' in os.path.basename(c).lower().replace('_', ''):
                csv_path = c
                break
        if csv_path is None:
            csv_path = all_csvs[0]  # Fallback to first CSV
                
    return csv_path, img_dir

def get_kaggle_dataloaders(batch_size=32):
    import pandas as pd
    
    csv_path, img_dir = find_dataset_files()
    if not csv_path or not img_dir:
        print("CRITICAL ERROR: Could not find trainLabels.csv or the image directory.")
        return None, None
        
    print(f"Found CSV: {csv_path}")
    print(f"Found Images at: {img_dir}")
    
    # Read the CSV mappings
    df = pd.read_csv(csv_path)
    
    print("Mapping images to CSV labels...")
    # EyePACS CSVs usually have 'image' and 'level' columns
    img_col = 'image' if 'image' in df.columns else df.columns[0]
    lbl_col = 'level' if 'level' in df.columns else df.columns[1]
    
    # Pre-index all files on disk: lowercase key → actual filename (preserves case for path construction)
    available_files = {}
    try:
        for f in os.listdir(img_dir):
            available_files[f.lower()] = f  # Map lowercase → real filename
    except OSError as e:
        print(f"ERROR: Cannot list image directory: {e}")
        return None, None
    
    image_paths = []
    labels = []
    skipped = 0
    
    for _, row in df.iterrows():
        img_name = str(row[img_col])
        # Append extension if the CSV omitted it
        if not img_name.lower().endswith(('.jpeg', '.jpg', '.png')):
            img_name += '.jpeg'
        
        # O(1) dict lookup; use the REAL filename from disk to avoid case mismatch on Linux
        real_name = available_files.get(img_name.lower())
        if real_name is not None:
            image_paths.append(os.path.join(img_dir, real_name))
            labels.append(int(row[lbl_col]))
        else:
            skipped += 1

    if not image_paths:
        print("CRITICAL ERROR: CSV mapping failed. No matching images found.")
        print(f"  CSV has {len(df)} rows, image dir has {len(available_files)} files")
        print(f"  Sample CSV name: {df[img_col].iloc[0]}")
        print(f"  Sample dir file: {next(iter(available_files)) if available_files else 'EMPTY'}")
        return None, None

    if skipped > 0:
        print(f"Note: {skipped} CSV entries had no matching file on disk (normal for partial sets).")
    print(f"Successfully mapped {len(image_paths)} images.")

    # Train/Val Split (80/20 Stratified)
    train_paths, val_paths, train_labels, val_labels = train_test_split(
        image_paths, labels, test_size=0.2, stratify=labels, random_state=42
    )
    
    # Free originals immediately — data is now in train_*/val_* lists
    del image_paths, labels, df, available_files
    gc.collect()
    
    # Target Extraction & Weight Calculation for Long-Tail Imbalance
    train_labels_arr = np.array(train_labels)
    class_counts = np.bincount(train_labels_arr, minlength=5)
    print(f"Class distribution (train): {dict(enumerate(class_counts))}")
    class_weights = 1.0 / (class_counts + 1e-6)
    sample_weights = class_weights[train_labels_arr]  # Vectorized, no Python loop
    sample_weights = torch.DoubleTensor(sample_weights)
    del train_labels_arr, class_weights  # Free temp arrays
    
    # 10,000 samples per epoch, perfectly balanced
    sampler = WeightedRandomSampler(weights=sample_weights, num_samples=10000, replacement=True)
    
    train_dataset = KaggleEyePACSDataset(train_paths, train_labels, augment=True)
    val_dataset = KaggleEyePACSDataset(val_paths, val_labels, augment=False)
    
    # num_workers=0 and pin_memory=False eliminate host RAM leaks
    train_loader = DataLoader(
        train_dataset, batch_size=batch_size, sampler=sampler, 
        num_workers=0, pin_memory=False
    )
    val_loader = DataLoader(
        val_dataset, batch_size=batch_size, shuffle=False, 
        num_workers=0, pin_memory=False
    )
    return train_loader, val_loader

# ==========================================
# 4. Training Loop
# ==========================================
def train_kaggle_model(resume_path=None):
    train_loader, val_loader = get_kaggle_dataloaders(batch_size=32)
    if not train_loader:
        return
        
    print("\nInitializing MobileNetV4...")
    model = timm.create_model('mobilenetv4_conv_small.e2400_r224_in1k', pretrained=True, num_classes=5)
    
    model = model.to(device)
    
    # [CRITICAL FIX: DOUBLE-WEIGHTING BUG]
    # You MUST NOT use `alpha_weights` here because we are already using `WeightedRandomSampler` in the DataLoader.
    # The Sampler perfectly balances the batches (50% rare classes, 50% common classes).
    # If you also apply FocalLoss alpha weights, you multiply the rare classes by 28x AGAIN,
    # causing the model to completely ignore Class 0 and Class 2 (0% accuracy).
    print("Focal Loss alpha: None (Relying on WeightedRandomSampler for balance)")
    
    criterion = FocalLoss(alpha=None, gamma=2.0)
    criterion = criterion.to(device)  # Moves alpha buffer to GPU
    optimizer = optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)
    
    # Mixed Precision (FP16) GradScaler — only when CUDA is available
    scaler = torch.amp.GradScaler('cuda') if use_cuda else None
    
    epochs = 10
    best_qwk = -1.0
    start_epoch = 0
    patience = 3        # Stop if QWK doesn't improve for this many consecutive epochs
    patience_counter = 0
    
    # Linear warmup (2 epochs) + Cosine decay for remaining epochs
    # Warmup prevents destructive early gradients on pretrained weights
    warmup_epochs = 2
    def lr_lambda(epoch):
        if epoch < warmup_epochs:
            # Epoch 0 → 0.5x, Epoch 1 → 1.0x (actual ramp)
            return (epoch + 1) / (warmup_epochs + 1)
        # Cosine decay for remaining epochs
        progress = (epoch - warmup_epochs) / max(1, epochs - warmup_epochs)
        return max(1e-6 / 1e-3, 0.5 * (1.0 + np.cos(np.pi * progress)))
    
    scheduler = optim.lr_scheduler.LambdaLR(optimizer, lr_lambda=lr_lambda)
    
    # Resume from checkpoint if session was interrupted
    ckpt_path = "mobilenetv4_eyepacs.pth"
    if resume_path and os.path.exists(resume_path):
        print(f"Resuming from checkpoint: {resume_path}")
        checkpoint = torch.load(resume_path, map_location=device, weights_only=False)
        
        # Load weights BEFORE wrapping with DataParallel to avoid key mismatch
        model.load_state_dict(checkpoint['model_state_dict'])
        optimizer.load_state_dict(checkpoint['optimizer_state_dict'])
        scheduler.load_state_dict(checkpoint['scheduler_state_dict'])
        if scaler and 'scaler_state_dict' in checkpoint:
            scaler.load_state_dict(checkpoint['scaler_state_dict'])
        start_epoch = checkpoint['epoch'] + 1
        best_qwk = checkpoint.get('best_qwk', -1.0)
        print(f"Resumed at epoch {start_epoch + 1}, best QWK so far: {best_qwk:.4f}")
    
    # Enable Multi-GPU Training AFTER loading checkpoint
    if torch.cuda.device_count() > 1:
        print(f"Activating DataParallel for {torch.cuda.device_count()} GPUs...")
        model = nn.DataParallel(model)
    
    for epoch in range(start_epoch, epochs):
        model.train()
        start_time = time.time()
        running_loss = 0.0
        valid_batches = 0  # Track actual (non-skipped) batches for correct avg loss
        
        for batch_idx, (inputs, targets) in enumerate(train_loader):
            inputs, targets = inputs.to(device, non_blocking=True), targets.to(device, non_blocking=True)
            
            # set_to_none=True frees gradient memory instead of zeroing it (~15% VRAM saved)
            optimizer.zero_grad(set_to_none=True)
            
            if use_cuda:
                # AMP: Forward pass in FP16
                with torch.amp.autocast('cuda'):
                    outputs = model(inputs)
                    loss = criterion(outputs, targets)
                
                # NaN/Inf guard: skip corrupted batches instead of poisoning weights
                if not torch.isfinite(loss):
                    print(f"  [!] NaN/Inf loss at batch {batch_idx}, skipping...")
                    optimizer.zero_grad(set_to_none=True)
                    continue
                
                # AMP: Backward pass with gradient scaling
                scaler.scale(loss).backward()
                # Gradient clipping prevents NaN from Focal Loss spikes on rare classes
                scaler.unscale_(optimizer)
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
                scaler.step(optimizer)
                scaler.update()
            else:
                outputs = model(inputs)
                loss = criterion(outputs, targets)
                
                if not torch.isfinite(loss):
                    print(f"  [!] NaN/Inf loss at batch {batch_idx}, skipping...")
                    optimizer.zero_grad(set_to_none=True)
                    continue
                
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
                optimizer.step()
            
            # Detach loss for logging — avoids GPU sync overhead
            running_loss += loss.detach().item()
            valid_batches += 1
            
            if batch_idx % 50 == 0:
                print(f"Epoch {epoch+1}/{epochs} | Batch {batch_idx}/{len(train_loader)} | "
                      f"Focal Loss: {loss.detach().item():.4f} | LR: {scheduler.get_last_lr()[0]:.6f}")
            
            # Periodic RAM cleanup: force Python to release accumulated garbage
            if batch_idx % 100 == 0 and batch_idx > 0:
                gc.collect()
        
        # Step the LR scheduler after each epoch
        scheduler.step()
        
        # Reclaim training batch memory before validation
        gc.collect()
        if use_cuda:
            torch.cuda.empty_cache()
        
        # Validation Phase
        model.eval()
        all_preds = []
        all_labels = []
        
        with torch.no_grad():
            for inputs, targets in val_loader:
                inputs = inputs.to(device, non_blocking=True)
                targets = targets.to(device, non_blocking=True)
                
                if use_cuda:
                    with torch.amp.autocast('cuda'):
                        outputs = model(inputs)
                else:
                    outputs = model(inputs)
                
                preds_cls = torch.argmax(outputs, dim=1).cpu().numpy()
                labels_np = targets.cpu().numpy()
                
                all_preds.extend(preds_cls)
                all_labels.extend(labels_np)
        
        # Compute metric while validation lists exist in memory
        epoch_qwk = cohen_kappa_score(all_labels, all_preds, weights='quadratic')
        avg_loss = running_loss / max(1, valid_batches)  # Only count non-skipped batches
        epoch_time = time.time() - start_time
        
        # Clear validation lists and reclaim RAM immediately
        del all_preds, all_labels
        gc.collect()
        if use_cuda:
            torch.cuda.empty_cache()
        
        print(f"--- Epoch {epoch+1} Summary ---")
        print(f"Time: {epoch_time:.1f}s | Avg Loss: {avg_loss:.4f} | Val QWK: {epoch_qwk:.4f} | LR: {scheduler.get_last_lr()[0]:.6f}")
        
        # Save full checkpoint every epoch for crash recovery
        model_to_save = model.module if isinstance(model, nn.DataParallel) else model
        checkpoint_state = {
            'epoch': epoch,
            'model_state_dict': model_to_save.state_dict(),
            'optimizer_state_dict': optimizer.state_dict(),
            'scheduler_state_dict': scheduler.state_dict(),
            'best_qwk': best_qwk,
        }
        if scaler:
            checkpoint_state['scaler_state_dict'] = scaler.state_dict()
        
        if epoch_qwk > best_qwk:
            best_qwk = epoch_qwk
            patience_counter = 0  # Reset patience on improvement
            checkpoint_state['best_qwk'] = best_qwk
            torch.save(checkpoint_state, ckpt_path)
            # Also save weights-only copy for Stage 2 compatibility with train.py
            torch.save(model_to_save.state_dict(), "mobilenetv4_eyepacs_weights.pth")
            print(f"[*] New Best QWK! Full checkpoint saved to {ckpt_path}")
            print(f"    Weights-only copy: mobilenetv4_eyepacs_weights.pth (for Stage 2)")
        else:
            # Always save latest state for crash recovery (overwrites previous)
            torch.save(checkpoint_state, "mobilenetv4_latest.pth")
            print(f"    Checkpoint saved to mobilenetv4_latest.pth (for resume)")
            patience_counter += 1
            if patience_counter >= patience:
                print(f"\n[Early Stop] QWK has not improved for {patience} epochs. Stopping.")
                break
    
    print(f"\nTraining complete. Best QWK: {best_qwk:.4f}")

if __name__ == "__main__":
    # To resume after a crash: train_kaggle_model(resume_path="mobilenetv4_latest.pth")
    train_kaggle_model()