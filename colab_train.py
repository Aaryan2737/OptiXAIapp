# Author: Aaryan Patil (Roll No. 26) - OptiXAI - SIH26038
"""
OptiXAI - Stage 1: EyePACS Pre-training (Google Colab GPU Environment)

=== COLAB SETUP (run these in separate cells BEFORE this script) ===

Cell 1 - Install Dependencies:
    !pip install timm scikit-learn opencv-python-headless

Cell 2 - Anti-Disconnect (paste into browser console F12 → Console):
    // Prevents Colab from disconnecting due to inactivity
    function KeepClicking() {
        console.log("Anti-disconnect: clicking connect button");
        document.querySelector("colab-connect-button")?.click();
    }
    setInterval(KeepClicking, 60000);

Cell 3 - Run this script:
    %run colab_train.py

=== GOOGLE DRIVE LAYOUT ===
Your Drive should have:
    MyDrive/
    ├── OptiXAI_Checkpoints/        ← checkpoints saved here (auto-created)
    └── OptiXAI_Data/
        └── eyepacs.zip             ← zipped EyePACS dataset (images + trainLabels.csv)
"""

# ==========================================
# 0. Colab Environment: Mount Drive & Extract Dataset
# ==========================================
import os
import time
import gc
import zipfile

# --- Google Drive Mount ---
from google.colab import drive
DRIVE_MOUNT = "/content/drive"
if not os.path.ismount(DRIVE_MOUNT):
    drive.mount(DRIVE_MOUNT)
    print("Google Drive mounted.")
else:
    print("Google Drive already mounted.")

# --- Persistent Paths (survive disconnects) ---
DRIVE_CKPT_DIR = "/content/drive/MyDrive/OptiXAI_Checkpoints"
DRIVE_DATA_DIR = "/content/drive/MyDrive/OptiXAI_Data"
os.makedirs(DRIVE_CKPT_DIR, exist_ok=True)

# Checkpoint paths on Drive
BEST_CKPT_PATH   = os.path.join(DRIVE_CKPT_DIR, "mobilenetv4_eyepacs.pth")
LATEST_CKPT_PATH = os.path.join(DRIVE_CKPT_DIR, "mobilenetv4_latest.pth")
WEIGHTS_ONLY_PATH = os.path.join(DRIVE_CKPT_DIR, "mobilenetv4_eyepacs_weights.pth")

# --- Dataset: Local SSD for fast I/O ---
LOCAL_DATA_DIR = "/content/eyepacs_data"
DRIVE_ZIP_PATH = os.path.join(DRIVE_DATA_DIR, "eyepacs.zip")
_EXTRACTION_MARKER = os.path.join(LOCAL_DATA_DIR, ".extraction_done")

def _count_files_recursive(path):
    """Count total files recursively."""
    count = 0
    for _, _, files in os.walk(path):
        count += len(files)
    return count

def _download_from_kaggle():
    """Download EyePACS dataset using Kaggle API.
    
    SETUP (one-time, takes 2 minutes):
    1. Go to https://www.kaggle.com/settings -> API -> Create New Token
    2. Copy the token string (starts with KGAT_)
    3. Paste it when prompted.
    """
    print("\n" + "=" * 50)
    print("KAGGLE API DATASET DOWNLOAD")
    print("=" * 50)
    
    # Install kaggle package
    import subprocess
    subprocess.check_call(['pip', 'install', '-q', 'kaggle'])
    
    kaggle_dir = os.path.expanduser("~/.kaggle")
    kaggle_json = os.path.join(kaggle_dir, "kaggle.json")
    access_token_path = os.path.join(kaggle_dir, "access_token")
    
    os.makedirs(kaggle_dir, exist_ok=True)
    
    if not os.path.exists(kaggle_json) and not os.path.exists(access_token_path):
        # Try Google Drive first
        drive_token = "/content/drive/MyDrive/kaggle_access_token"
        drive_json = "/content/drive/MyDrive/kaggle.json"
        
        if os.path.exists(drive_token):
            import shutil
            shutil.copy(drive_token, access_token_path)
            os.chmod(access_token_path, 0o600)
            print("Found kaggle token on Google Drive!")
        elif os.path.exists(drive_json):
            import shutil
            shutil.copy(drive_json, kaggle_json)
            os.chmod(kaggle_json, 0o600)
            print("Found kaggle.json on Google Drive!")
        else:
            # Prompt for new Kaggle Token
            import getpass
            print("\nYou need a Kaggle API Token to download the dataset.")
            print("Steps:")
            print("  1. Go to: https://www.kaggle.com/settings")
            print("  2. Scroll to 'API' section -> click 'Create New Token'")
            print("  3. Copy the token string (e.g., KGAT_...) and paste it below:\n")
            
            token = getpass.getpass("Enter Kaggle API Token: ").strip()
            
            if not token:
                print("ERROR: No token provided. Aborting.")
                return False
                
            with open(access_token_path, 'w') as f:
                f.write(token)
            os.chmod(access_token_path, 0o600)
            print("Token saved successfully!")
            
            # Save to Drive for future sessions
            try:
                import shutil
                shutil.copy(access_token_path, drive_token)
                print(f"Saved copy to Drive (won't need to enter again)")
            except Exception:
                pass
    
    print("\nDownloading EyePACS dataset from Kaggle...")
    print("This may take 15-30 minutes. Go get a coffee!\n")
    
    os.makedirs(LOCAL_DATA_DIR, exist_ok=True)
    
    try:
        # Try competition dataset first
        result = subprocess.run(
            ['kaggle', 'competitions', 'download', '-c',
             'diabetic-retinopathy-detection', '-p', LOCAL_DATA_DIR],
            capture_output=True, text=True, timeout=7200
        )
        if result.returncode != 0:
            print(f"Competition download note: {result.stderr.strip()}")
            print("Trying resized version (smaller, faster)...")
            result = subprocess.run(
                ['kaggle', 'datasets', 'download', '-d',
                 'tanlikesmath/diabetic-retinopathy-resized', '-p', LOCAL_DATA_DIR],
                capture_output=True, text=True, timeout=3600
            )
            if result.returncode != 0:
                print(f"Download failed: {result.stderr}")
                return False
        
        print("Download complete! Extracting...")
        for f in os.listdir(LOCAL_DATA_DIR):
            if f.endswith('.zip'):
                zip_path = os.path.join(LOCAL_DATA_DIR, f)
                print(f"  Extracting {f}...")
                with zipfile.ZipFile(zip_path, 'r') as zf:
                    zf.extractall(LOCAL_DATA_DIR)
                os.remove(zip_path)  # Free disk space
        
        open(_EXTRACTION_MARKER, 'w').close()
        print("Dataset ready!")
        return True
    except subprocess.TimeoutExpired:
        print("ERROR: Download timed out.")
        return False
    except Exception as e:
        print(f"ERROR: {e}")
        return False

def setup_dataset():
    """3-tier dataset setup: Local cache -> Drive zip -> Kaggle API."""
    
    # Tier 1: Already extracted locally (instant)
    if os.path.exists(_EXTRACTION_MARKER):
        print(f"Dataset ready at {LOCAL_DATA_DIR} (cached)")
        return True
    
    if os.path.exists(LOCAL_DATA_DIR):
        file_count = _count_files_recursive(LOCAL_DATA_DIR)
        if file_count > 100:
            open(_EXTRACTION_MARKER, 'w').close()
            print(f"Dataset at {LOCAL_DATA_DIR} ({file_count} files)")
            return True
    
    # Tier 2: Zip file on Google Drive
    if os.path.exists(DRIVE_ZIP_PATH):
        print(f"Extracting from Drive: {DRIVE_ZIP_PATH}")
        os.makedirs(LOCAL_DATA_DIR, exist_ok=True)
        start = time.time()
        with zipfile.ZipFile(DRIVE_ZIP_PATH, 'r') as zf:
            zf.extractall(LOCAL_DATA_DIR)
        open(_EXTRACTION_MARKER, 'w').close()
        print(f"Extracted in {time.time() - start:.0f}s")
        return True
    
    # Tier 2b: Unzipped data on Drive
    if os.path.exists(DRIVE_DATA_DIR):
        try:
            entries = os.listdir(DRIVE_DATA_DIR)
            has_data = any(e.lower().endswith(('.csv', '.jpeg', '.jpg', '.png')) or
                          os.path.isdir(os.path.join(DRIVE_DATA_DIR, e))
                          for e in entries[:20])
            if has_data:
                print(f"Using data from Drive: {DRIVE_DATA_DIR} (slower I/O)")
                return True
        except OSError:
            pass
    
    # Tier 3: Download from Kaggle API
    print("Dataset not found locally or on Drive.")
    print("Will download from Kaggle (one-time setup)...\n")
    return _download_from_kaggle()

if not setup_dataset():
    raise RuntimeError("Dataset setup failed. Cannot continue.")

# ==========================================
# 1. Imports & Reproducibility
# ==========================================
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

# Reproducibility
SEED = 42
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)
if torch.cuda.is_available():
    torch.cuda.manual_seed_all(SEED)

# ==========================================
# 2. Hardware Diagnostics
# ==========================================
print("=" * 50)
print(f"PyTorch Version: {torch.__version__}")
use_cuda = torch.cuda.is_available()
print(f"CUDA Available:  {use_cuda}")
if use_cuda:
    gpu_count = torch.cuda.device_count()
    print(f"GPUs Detected:   {gpu_count}")
    print(f"Device Name:     {torch.cuda.get_device_name(0)}")
    vram_gb = torch.cuda.get_device_properties(0).total_mem / 1e9
    print(f"VRAM:            {vram_gb:.1f} GB")
else:
    print("WARNING: Running on CPU! Enable GPU: Runtime → Change runtime type → T4 GPU")
print("=" * 50)

device = torch.device("cuda" if use_cuda else "cpu")

# Fixed input size (224x224) → let cuDNN auto-tune conv algorithms
if use_cuda:
    torch.backends.cudnn.benchmark = True

# ==========================================
# 3. Custom Preprocessing & Dataset
# ==========================================
class FocalLoss(nn.Module):
    """Focal Loss with optional per-class alpha weighting."""
    def __init__(self, alpha=None, gamma=2.0, reduction='mean'):
        super(FocalLoss, self).__init__()
        if alpha is not None:
            if isinstance(alpha, (list, np.ndarray)):
                alpha_t = torch.FloatTensor(alpha)
            elif isinstance(alpha, torch.Tensor):
                alpha_t = alpha.float()
            else:
                alpha_t = torch.tensor(float(alpha))
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

class ColabEyePACSDataset(Dataset):
    def __init__(self, image_paths, labels, augment=False):
        self.image_paths = image_paths
        self.labels = labels
        self.augment = augment
        self.clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))

    def __len__(self):
        return len(self.image_paths)

    def preprocess_fundus(self, img):
        # A. Contour Auto-Crop
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        _, thresh = cv2.threshold(gray, 10, 255, cv2.THRESH_BINARY)
        contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        
        if contours:
            c = max(contours, key=cv2.contourArea)
            x, y, w, h = cv2.boundingRect(c)
            if w > img.shape[1] * 0.3 and h > img.shape[0] * 0.3:
                img = img[y:y+h, x:x+w]
        
        del gray, thresh, contours
                
        # B. CLAHE on L-channel of LAB color space
        # [FIX] Matches Stage 2 preprocess.py — previously used green channel of BGR
        # LAB CLAHE preserves color fidelity while enhancing luminance contrast
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2Lab)
        l_ch, a_ch, b_ch = cv2.split(lab)
        l_clahe = self.clahe.apply(l_ch)
        del l_ch
        img = cv2.merge((l_clahe, a_ch, b_ch))
        img = cv2.cvtColor(img, cv2.COLOR_Lab2BGR)
        del l_clahe, a_ch, b_ch, lab
        
        # C. Bicubic Resize to 224x224
        img = cv2.resize(img, (224, 224), interpolation=cv2.INTER_CUBIC)
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        
        # D. Augmentations (fundus-safe: no color jitter)
        if self.augment:
            if random.random() > 0.5:
                img = cv2.flip(img, 1)
            if random.random() > 0.5:
                img = cv2.flip(img, 0)
            k = random.randint(0, 3)
            if k > 0:
                img = np.rot90(img, k).copy()
        
        # E. Normalize + tensor
        # [FIX] Apply ImageNet mean/std normalization to match Stage 2 preprocess.py
        # Previously only divided by 255.0, causing a distribution shift when
        # Stage 2 fine-tuning loaded these weights with ImageNet-normalized inputs.
        IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
        IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
        
        img = np.ascontiguousarray(img.transpose(2, 0, 1), dtype=np.float32)
        np.divide(img, 255.0, out=img)  # Scale to [0, 1]
        # Apply per-channel normalization: (pixel - mean) / std
        for c in range(3):
            img[c] = (img[c] - IMAGENET_MEAN[c]) / IMAGENET_STD[c]
        return torch.from_numpy(img.copy())  # .copy() gives tensor its own memory

    def __getitem__(self, idx, _depth=0):
        path = self.image_paths[idx]
        label = self.labels[idx]
        
        # Load at HALF resolution to cut RAM usage by 4x
        img = cv2.imread(path, cv2.IMREAD_REDUCED_COLOR_2)
        if img is None:
            img = cv2.imread(path)
        if img is None:
            if _depth >= 5:
                return torch.zeros(3, 224, 224, dtype=torch.float32), 0
            fallback_idx = random.randint(0, len(self.image_paths) - 1)
            return self.__getitem__(fallback_idx, _depth=_depth + 1)
        
        tensor_img = self.preprocess_fundus(img)
        del img
        return tensor_img, label

# ==========================================
# 4. CSV-Based Data Ingestion (Local SSD → Fast I/O)
# ==========================================
def find_dataset_files():
    """Search for CSV and images, preferring local SSD, falling back to Drive."""
    search_paths = [LOCAL_DATA_DIR, DRIVE_DATA_DIR]
    
    for base_path in search_paths:
        if not os.path.exists(base_path):
            continue
            
        csv_path = None
        img_dir = None
        all_csvs = []
        
        print(f"Searching in: {base_path}")
        for root, dirs, files in os.walk(base_path):
            for f in files:
                if f.endswith('.csv'):
                    all_csvs.append(os.path.join(root, f))
                if f.lower().endswith(('.jpeg', '.jpg', '.png', '.tif')) and img_dir is None:
                    img_dir = root
        
        # Prefer trainLabels.csv
        if all_csvs:
            for c in all_csvs:
                if 'trainlabels' in os.path.basename(c).lower().replace('_', ''):
                    csv_path = c
                    break
            if csv_path is None:
                csv_path = all_csvs[0]
        
        if csv_path and img_dir:
            return csv_path, img_dir
    
    return None, None

def get_colab_dataloaders(batch_size=32):
    import pandas as pd
    
    csv_path, img_dir = find_dataset_files()
    if not csv_path or not img_dir:
        print("CRITICAL ERROR: Could not find trainLabels.csv or image directory.")
        print(f"  Searched: {LOCAL_DATA_DIR}, {DRIVE_DATA_DIR}")
        return None, None
        
    print(f"Found CSV: {csv_path}")
    print(f"Found Images at: {img_dir}")
    
    df = pd.read_csv(csv_path)
    
    print("Mapping images to CSV labels...")
    img_col = 'image' if 'image' in df.columns else df.columns[0]
    lbl_col = 'level' if 'level' in df.columns else df.columns[1]
    
    # Pre-index files: lowercase → real filename (case-safe on Linux)
    available_files = {}
    try:
        for f in os.listdir(img_dir):
            available_files[f.lower()] = f
    except OSError as e:
        print(f"ERROR: Cannot list image directory: {e}")
        return None, None
    
    image_paths = []
    labels = []
    skipped = 0
    
    for _, row in df.iterrows():
        img_name = str(row[img_col])
        if not img_name.lower().endswith(('.jpeg', '.jpg', '.png')):
            img_name += '.jpeg'
        
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
        print(f"Note: {skipped} CSV entries had no matching file on disk.")
    print(f"Successfully mapped {len(image_paths)} images.")

    # Train/Val Split (80/20 Stratified)
    train_paths, val_paths, train_labels, val_labels = train_test_split(
        image_paths, labels, test_size=0.2, stratify=labels, random_state=42
    )
    
    # Free originals immediately
    del image_paths, labels, df, available_files
    gc.collect()
    
    # Weight Calculation for Long-Tail Imbalance
    train_labels_arr = np.array(train_labels)
    class_counts = np.bincount(train_labels_arr, minlength=5)
    print(f"Class distribution (train): {dict(enumerate(class_counts))}")
    class_weights = 1.0 / (class_counts + 1e-6)
    sample_weights = class_weights[train_labels_arr]
    sample_weights = torch.DoubleTensor(sample_weights)
    del train_labels_arr, class_weights
    
    sampler = WeightedRandomSampler(weights=sample_weights, num_samples=10000, replacement=True)
    
    train_dataset = ColabEyePACSDataset(train_paths, train_labels, augment=True)
    val_dataset = ColabEyePACSDataset(val_paths, val_labels, augment=False)
    
    # num_workers=0 and pin_memory=False: critical for Colab's 12GB RAM limit
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
# 5. Safe Drive I/O & Training Loop
# ==========================================
LOCAL_CKPT_DIR = "/content/checkpoints_local"
os.makedirs(LOCAL_CKPT_DIR, exist_ok=True)

def _safe_save_to_drive(obj, drive_path, max_retries=3):
    """Save to local SSD first, then copy to Drive with retry.
    
    Prevents data loss if Drive FUSE is flaky or disconnected.
    """
    local_path = os.path.join(LOCAL_CKPT_DIR, os.path.basename(drive_path))
    
    # Step 1: Always save to fast local disk (instant, reliable)
    torch.save(obj, local_path)
    
    # Step 2: Copy to Drive with retries
    for attempt in range(max_retries):
        try:
            import shutil
            shutil.copy2(local_path, drive_path)
            return True
        except (OSError, IOError) as e:
            if attempt < max_retries - 1:
                print(f"  [!] Drive save failed (attempt {attempt+1}/{max_retries}): {e}")
                time.sleep(2 ** attempt)  # Exponential backoff: 1s, 2s, 4s
            else:
                print(f"  [WARNING] Could not save to Drive after {max_retries} attempts.")
                print(f"  [WARNING] Checkpoint safe at LOCAL: {local_path}")
                return False

def train_colab_model():
    train_loader, val_loader = get_colab_dataloaders(batch_size=32)
    if not train_loader:
        return
    
    # --- Bulletproof Auto-Resume ---
    # Check Drive first, then local fallback (in case Drive was disconnected)
    resume_path = None
    local_latest = os.path.join(LOCAL_CKPT_DIR, "mobilenetv4_latest.pth")
    
    if os.path.exists(LATEST_CKPT_PATH):
        resume_path = LATEST_CKPT_PATH
        print(f"\n[Auto-Resume] Found Drive checkpoint: {LATEST_CKPT_PATH}")
    elif os.path.exists(BEST_CKPT_PATH):
        resume_path = BEST_CKPT_PATH
        print(f"\n[Auto-Resume] Found Drive best checkpoint: {BEST_CKPT_PATH}")
    elif os.path.exists(local_latest):
        resume_path = local_latest
        print(f"\n[Auto-Resume] Found LOCAL checkpoint (Drive was down): {local_latest}")
    else:
        print("\n[Fresh Start] No checkpoint found. Training from scratch.")
        
    print("Initializing MobileNetV4...")
    model = timm.create_model('mobilenetv4_conv_small.e2400_r224_in1k', pretrained=True, num_classes=5)
    model = model.to(device)
    
    # [CRITICAL FIX: DOUBLE-WEIGHTING BUG]
    # You MUST NOT use `alpha_weights` here because we are already using `WeightedRandomSampler` in the DataLoader.
    # The Sampler perfectly balances the batches (50% rare classes, 50% common classes).
    # If you also apply FocalLoss alpha weights, you multiply the rare classes by 28x AGAIN,
    # causing the model to completely ignore Class 0 and Class 2 (0% accuracy).
    print("Focal Loss alpha: None (Relying on WeightedRandomSampler for balance)")
    criterion = FocalLoss(alpha=None, gamma=2.0)
    criterion = criterion.to(device)
    
    # Lower LR from 1e-3 to 5e-4. 1e-3 is too violent for a pretrained MobileNet and can cause loss plateaus.
    optimizer = optim.AdamW(model.parameters(), lr=5e-4, weight_decay=1e-4)
    
    scaler = torch.amp.GradScaler('cuda') if use_cuda else None
    
    epochs = 10
    best_qwk = -1.0
    start_epoch = 0
    patience = 3
    patience_counter = 0
    
    # Warmup (2 epochs) + Cosine decay
    warmup_epochs = 2
    def lr_lambda(epoch):
        if epoch < warmup_epochs:
            return (epoch + 1) / (warmup_epochs + 1)
        progress = (epoch - warmup_epochs) / max(1, epochs - warmup_epochs)
        return max(1e-6 / 1e-3, 0.5 * (1.0 + np.cos(np.pi * progress)))
    
    scheduler = optim.lr_scheduler.LambdaLR(optimizer, lr_lambda=lr_lambda)
    
    # Load checkpoint (BEFORE DataParallel wrapping)
    if resume_path:
        print(f"Loading checkpoint: {resume_path}")
        checkpoint = torch.load(resume_path, map_location=device, weights_only=False)
        model.load_state_dict(checkpoint['model_state_dict'])
        optimizer.load_state_dict(checkpoint['optimizer_state_dict'])
        scheduler.load_state_dict(checkpoint['scheduler_state_dict'])
        if scaler and 'scaler_state_dict' in checkpoint:
            scaler.load_state_dict(checkpoint['scaler_state_dict'])
        start_epoch = checkpoint['epoch'] + 1
        best_qwk = checkpoint.get('best_qwk', -1.0)
        patience_counter = checkpoint.get('patience_counter', 0)
        print(f"Resumed at epoch {start_epoch}/{epochs}, best QWK: {best_qwk:.4f}")
        del checkpoint
        gc.collect()
    
    # DataParallel AFTER checkpoint loading
    if torch.cuda.device_count() > 1:
        print(f"Activating DataParallel for {torch.cuda.device_count()} GPUs...")
        model = nn.DataParallel(model)
    
    if start_epoch >= epochs:
        print(f"Training already complete ({epochs}/{epochs} epochs). Best QWK: {best_qwk:.4f}")
        return
    
    for epoch in range(start_epoch, epochs):
        model.train()
        start_time = time.time()
        running_loss = 0.0
        valid_batches = 0
        
        for batch_idx, (inputs, targets) in enumerate(train_loader):
            inputs, targets = inputs.to(device, non_blocking=True), targets.to(device, non_blocking=True)
            
            optimizer.zero_grad(set_to_none=True)
            
            if use_cuda:
                with torch.amp.autocast('cuda'):
                    outputs = model(inputs)
                    loss = criterion(outputs, targets)
                
                if not torch.isfinite(loss):
                    print(f"  [!] NaN/Inf loss at batch {batch_idx}, skipping...")
                    optimizer.zero_grad(set_to_none=True)
                    continue
                
                scaler.scale(loss).backward()
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
            
            running_loss += loss.detach().item()
            valid_batches += 1
            
            if batch_idx % 50 == 0:
                print(f"Epoch {epoch+1}/{epochs} | Batch {batch_idx}/{len(train_loader)} | "
                      f"Focal Loss: {loss.detach().item():.4f} | LR: {scheduler.get_last_lr()[0]:.6f}")
            
            # Aggressive RAM cleanup for Colab's tight 12GB limit
            if batch_idx % 50 == 0 and batch_idx > 0:
                gc.collect()
        
        scheduler.step()
        
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
        
        all_preds_np = np.array(all_preds)
        all_labels_np = np.array(all_labels)
        
        epoch_qwk = cohen_kappa_score(all_labels_np, all_preds_np, weights='quadratic')
        avg_loss = running_loss / max(1, valid_batches)
        epoch_time = time.time() - start_time
        
        # Per-class accuracy: reveals if model ignores rare classes (3=Severe, 4=PDR)
        print(f"--- Epoch {epoch+1} Summary ---")
        print(f"Time: {epoch_time:.1f}s | Train Loss: {avg_loss:.4f} | Val QWK: {epoch_qwk:.4f} | LR: {scheduler.get_last_lr()[0]:.6f}")
        class_names = ['No DR', 'Mild', 'Moderate', 'Severe', 'PDR']
        for cls_idx in range(5):
            mask = all_labels_np == cls_idx
            if mask.sum() > 0:
                cls_acc = (all_preds_np[mask] == cls_idx).mean() * 100
                print(f"  Class {cls_idx} ({class_names[cls_idx]:>8s}): {cls_acc:5.1f}% acc ({mask.sum()} samples)")
        
        del all_preds, all_labels, all_preds_np, all_labels_np
        gc.collect()
        if use_cuda:
            torch.cuda.empty_cache()
        
        # Save checkpoint: local first, then copy to Drive (safe against Drive flakes)
        model_to_save = model.module if isinstance(model, nn.DataParallel) else model
        
        # Move state_dict to CPU to avoid doubling GPU memory (model + checkpoint both on VRAM)
        cpu_state_dict = {k: v.cpu() for k, v in model_to_save.state_dict().items()}
        
        checkpoint_state = {
            'epoch': epoch,
            'model_state_dict': cpu_state_dict,
            'optimizer_state_dict': optimizer.state_dict(),
            'scheduler_state_dict': scheduler.state_dict(),
            'best_qwk': best_qwk,
            'patience_counter': patience_counter,
        }
        if scaler:
            checkpoint_state['scaler_state_dict'] = scaler.state_dict()
        
        if epoch_qwk > best_qwk:
            best_qwk = epoch_qwk
            patience_counter = 0
            checkpoint_state['best_qwk'] = best_qwk
            checkpoint_state['patience_counter'] = patience_counter
            
            _safe_save_to_drive(checkpoint_state, BEST_CKPT_PATH)
            _safe_save_to_drive(cpu_state_dict, WEIGHTS_ONLY_PATH)  # Reuse, no extra copy
            _safe_save_to_drive(checkpoint_state, LATEST_CKPT_PATH)
            print(f"[*] New Best QWK! Saved to Drive: {BEST_CKPT_PATH}")
            print(f"    Weights-only: {WEIGHTS_ONLY_PATH} (for Stage 2)")
        else:
            patience_counter += 1
            checkpoint_state['patience_counter'] = patience_counter
            _safe_save_to_drive(checkpoint_state, LATEST_CKPT_PATH)
            print(f"    Checkpoint saved to Drive: {LATEST_CKPT_PATH}")
            if patience_counter >= patience:
                print(f"\n[Early Stop] QWK has not improved for {patience} epochs. Stopping.")
                break
    
    print(f"\nTraining complete. Best QWK: {best_qwk:.4f}")
    print(f"Best weights: {WEIGHTS_ONLY_PATH}")
    print(f"Download for Stage 2: from google.colab import files; files.download('{WEIGHTS_ONLY_PATH}')")

if __name__ == "__main__":
    train_colab_model()
