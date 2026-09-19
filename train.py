# Author: Aaryan Patil (Roll No. 26) - OptiXAI
import os
import time
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, WeightedRandomSampler
from sklearn.metrics import cohen_kappa_score
from sklearn.model_selection import train_test_split
import numpy as np
import matplotlib.pyplot as plt
import timm

# Import our custom clinically validated preprocessing and loss modules
from preprocess import APTOSDataset
from dataset import FocalLoss

def parse_dataset_directory(data_dir):
    """
    Parses a dataset directory by walking through segregated folder names.
    (e.g., '0_No_DR', '1_Mild')
    """
    valid_exts = ('.png', '.jpg', '.jpeg')
    image_paths = []
    labels = []
    
    if not os.path.exists(data_dir):
        raise FileNotFoundError(f"Dataset directory not found: {data_dir}")

    print(f"Parsing dataset based on segregated folder names in {data_dir}...")
    for root, _, files in os.walk(data_dir):
        folder_name = os.path.basename(root)
        grade = -1
        # Extract first digit from folder name
        for char in folder_name:
            if char.isdigit():
                grade = int(char)
                break
        
        if 0 <= grade <= 4:
            for f in files:
                if f.lower().endswith(valid_exts):
                    image_paths.append(os.path.join(root, f))
                    labels.append(grade)
                    
    return image_paths, labels

def get_dataloaders(data_dir, batch_size=32, val_split=0.2, test_split=0.0):
    """
    Creates train and validation DataLoaders with a WeightedRandomSampler 
    to handle class imbalance naturally present in EyePACS/APTOS.
    
    When test_split > 0, the original holdout (val_split fraction of total) is
    further split into val and test sets. This enables calibrating thresholds
    on val while reporting unbiased metrics on a completely unseen test set.
    
    Returns:
        (train_loader, val_loader) when test_split == 0
        (train_loader, val_loader, test_loader) when test_split > 0
    """
    print(f"\nInitializing DataLoaders for {data_dir}...")
    try:
        image_paths, labels = parse_dataset_directory(data_dir)
    except Exception as e:
        print(f"Error accessing dataset directory {data_dir}: {e}")
        return None, None
        
    if len(image_paths) == 0:
        print(f"No valid images with labels found in {data_dir}")
        return None, None
        
    print(f"Found {len(image_paths)} images across 5 clinical grades.")
    
    # 80/20 Train-Val Split (Stratified to maintain class distributions)
    train_paths, holdout_paths, train_labels, holdout_labels = train_test_split(
        image_paths, labels, test_size=val_split, stratify=labels, random_state=42
    )
    
    # Optionally split the holdout further into val and test
    test_paths, test_labels = None, None
    if test_split > 0:
        val_paths, test_paths, val_labels, test_labels = train_test_split(
            holdout_paths, holdout_labels, test_size=test_split,
            stratify=holdout_labels, random_state=42
        )
        print(f"Split: {len(train_paths)} train / {len(val_paths)} val / {len(test_paths)} test")
    else:
        val_paths, val_labels = holdout_paths, holdout_labels
        print(f"Split: {len(train_paths)} train / {len(val_paths)} val")
    
    # Calculate class weights for WeightedRandomSampler (addressing class imbalance)
    class_counts = np.bincount(train_labels, minlength=5)
    class_weights = 1.0 / (class_counts + 1e-6) # Add epsilon to avoid div by zero
    sample_weights = [class_weights[lbl] for lbl in train_labels]
    
    # Enforces a 1:1:1:1:1 class ratio within every batch.
    # num_samples=len(train_labels) ensures 1 epoch = 1 full pass over the dataset size
    sampler = WeightedRandomSampler(
        weights=sample_weights,
        num_samples=len(train_labels),
        replacement=True
    )
    
    # Create Datasets using our standardized preprocessing pipeline (CLAHE, Crop, Resize)
    train_dataset = APTOSDataset(train_paths, train_labels, augment=True)
    val_dataset = APTOSDataset(val_paths, val_labels, augment=False)
    
    # DataLoaders (Dynamic Hardware Support)
    use_cuda = torch.cuda.is_available()
    pin_memory = use_cuda
    num_workers = 4 if use_cuda else 0
    
    train_loader = DataLoader(train_dataset, batch_size=batch_size, sampler=sampler, num_workers=num_workers, pin_memory=pin_memory)
    val_loader = DataLoader(val_dataset, batch_size=batch_size, shuffle=False, num_workers=num_workers, pin_memory=pin_memory)
    
    if test_split > 0:
        test_dataset = APTOSDataset(test_paths, test_labels, augment=False)
        test_loader = DataLoader(test_dataset, batch_size=batch_size, shuffle=False, num_workers=num_workers, pin_memory=pin_memory)
        return train_loader, val_loader, test_loader
    
    return train_loader, val_loader

def calculate_qwk(preds, labels):
    """Quadratic Weighted Kappa (QWK) metric calculation."""
    return cohen_kappa_score(labels, preds, weights='quadratic')

def train_one_stage(model, train_loader, val_loader, optimizer, scheduler, criterion, epochs, device, stage_name):
    """Executes the training loop for a given stage, tracking QWK and Accuracy."""
    print(f"\n{'='*50}\nStarting {stage_name}\n{'='*50}")
    
    best_qwk = -1.0
    history = {'epoch': [], 'val_qwk': [], 'val_acc': []}
    
    use_cuda = torch.cuda.is_available()
    scaler = torch.amp.GradScaler('cuda') if use_cuda else None
    
    for epoch in range(epochs):
        model.train()
        running_loss = 0.0
        
        start_time = time.time()
        for batch_idx, (inputs, targets) in enumerate(train_loader):
            inputs, targets = inputs.to(device), targets.to(device)
            
            optimizer.zero_grad(set_to_none=True)
            
            if use_cuda:
                with torch.amp.autocast('cuda'):
                    outputs = model(inputs)
                    loss = criterion(outputs, targets)
                
                if not torch.isfinite(loss):
                    print(f"  [!] NaN/Inf loss at batch {batch_idx}, skipping...")
                    continue
                    
                scaler.scale(loss).backward()
                scaler.unscale_(optimizer)
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
                scaler.step(optimizer)
                scaler.update()
            else:
                outputs = model(inputs)
                loss = criterion(outputs, targets)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
                optimizer.step()
            
            running_loss += loss.item()
            
            if batch_idx % 50 == 0:
                print(f"[{stage_name}] Epoch {epoch+1}/{epochs} | Batch {batch_idx}/{len(train_loader)} | Loss: {loss.item():.4f} | LR: {scheduler.get_last_lr()[0]:.6f}")
                
        scheduler.step()
                
        # Validation Phase
        model.eval()
        val_loss = 0.0
        all_preds = []
        all_labels = []
        
        with torch.no_grad():
            for inputs, targets in val_loader:
                inputs, targets = inputs.to(device), targets.to(device)
                
                if use_cuda:
                    with torch.amp.autocast('cuda'):
                        outputs = model(inputs)
                        loss = criterion(outputs, targets)
                else:
                    outputs = model(inputs)
                    loss = criterion(outputs, targets)
                    
                val_loss += loss.item()
                
                all_preds.append(outputs)
                all_labels.append(targets)
                
        # Calculate Epoch Metrics
        all_preds = torch.cat(all_preds)
        all_labels = torch.cat(all_labels)
        
        preds_cls = torch.argmax(all_preds, dim=1).cpu().numpy()
        labels_np = all_labels.cpu().numpy()
        
        # OVERALL ACCURACY CALCULATION
        correct = (preds_cls == labels_np).sum()
        epoch_acc = (correct / len(labels_np)) * 100.0
        
        # QWK
        epoch_qwk = calculate_qwk(preds_cls, labels_np)
        
        avg_train_loss = running_loss / len(train_loader)
        epoch_time = time.time() - start_time
        
        # Track history for plotting
        history['epoch'].append(epoch + 1)
        history['val_qwk'].append(epoch_qwk)
        history['val_acc'].append(epoch_acc)
        
        print(f"--- Epoch {epoch+1} Summary ---")
        print(f"Time: {epoch_time:.1f}s | Train Loss: {avg_train_loss:.4f} | Val QWK: {epoch_qwk:.4f} | Val Accuracy: {epoch_acc:.2f}%")
        
        # Per-class accuracy
        class_names = ['No DR', 'Mild', 'Moderate', 'Severe', 'PDR']
        for cls_idx in range(5):
            mask = labels_np == cls_idx
            if mask.sum() > 0:
                cls_acc = (preds_cls[mask] == cls_idx).mean() * 100
                print(f"  Class {cls_idx} ({class_names[cls_idx]:>8s}): {cls_acc:5.1f}% acc ({mask.sum()} samples)")
        
        # Save Best Checkpoint based on QWK
        if epoch_qwk > best_qwk:
            best_qwk = epoch_qwk
            ckpt_path = f"optixai_final_aptos.pth"
            # Save full checkpoint dict for consistency with colab_train.py / kaggle_train.py
            torch.save({
                'model_state_dict': model.state_dict(),
                'epoch': epoch + 1,
                'best_qwk': epoch_qwk,
            }, ckpt_path)
            print(f"[*] New Best QWK! Model checkpoint saved to {ckpt_path}")
            
    # Generate Accuracy Graph at the end of the stage using Matplotlib
    plt.figure(figsize=(10, 6))
    plt.plot(history['epoch'], history['val_acc'], marker='o', linestyle='-', color='b', linewidth=2)
    plt.title(f"{stage_name} - Validation Accuracy across {epochs} Epochs", fontsize=14)
    plt.xlabel("Epoch", fontsize=12)
    plt.ylabel("Overall Accuracy (%)", fontsize=12)
    plt.ylim(0, 100)
    plt.xticks(range(1, epochs + 1))
    plt.grid(True, linestyle='--', alpha=0.7)
    
    # Annotate points with exact percentages
    for i, acc in enumerate(history['val_acc']):
        plt.annotate(f"{acc:.1f}%", (history['epoch'][i], acc), textcoords="offset points", xytext=(0,10), ha='center')
        
    plot_filename = f"{stage_name.lower().replace(' ', '_')}_accuracy_graph.png"
    plt.savefig(plot_filename, dpi=300, bbox_inches='tight')
    plt.close()
    
    print(f"\nFinished {stage_name}. Best Val QWK: {best_qwk:.4f}")
    print(f"Saved Accuracy Graph to: {plot_filename}")
    return best_qwk

if __name__ == "__main__":
    print("=" * 50)
    print(f"PyTorch Version: {torch.__version__}")
    print(f"CUDA Available:  {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"Device Name:     {torch.cuda.get_device_name(0)}")
        print(f"CUDA Version:    {torch.version.cuda}")
    else:
        print("WARNING: Running on CPU! Pre-training on 35,000 images will be extremely slow.")
        print("Verify whether a CUDA-enabled PyTorch build is installed.")
    print("=" * 50)
    
    use_cuda = torch.cuda.is_available()
    device = torch.device('cuda' if use_cuda else 'cpu')
    
    # ---------------------------------------------------------
    # 0. Initialize Model & Loss
    # ---------------------------------------------------------
    print("Initializing MobileNetV4...")
    try:
        model = timm.create_model('mobilenetv4_conv_small.e2400_r224_in1k', pretrained=True, num_classes=5)
    except Exception as e:
        print(f"timm MobileNetV4 not found, falling back to v3. Error: {e}")
        model = timm.create_model('mobilenetv3_large_100', pretrained=True, num_classes=5)
    
    model = model.to(device)
    criterion = FocalLoss(gamma=2.0)
    
    # ---------------------------------------------------------
    # 0.5 Load Pre-Trained Weights from Colab (Stage 1)
    # ---------------------------------------------------------
    weights_path = "mobilenetv4_eyepacs_weights.pth"
    if not os.path.exists(weights_path):
        print(f"\n[!] CRITICAL ERROR: Could not find '{weights_path}'")
        print("Please place the weights file you downloaded from Colab into the same folder as train.py")
        exit(1)
        
    print(f"\nLoading Pre-Trained Stage 1 Weights from: {weights_path}")
    try:
        # Load with weights_only=True for security since it's from an external source
        state_dict = torch.load(weights_path, map_location=device, weights_only=True)
        # Handle case where checkpoint dict contains 'model_state_dict' vs raw state dict
        if 'model_state_dict' in state_dict:
            state_dict = state_dict['model_state_dict']
            
        model.load_state_dict(state_dict)
        print("Successfully loaded pre-trained MobileNetV4 weights!")
    except Exception as e:
        print(f"Failed to load weights: {e}")
        exit(1)
        
    # ---------------------------------------------------------
    # Stage 2: Fine-Tuning (Local APTOS Dataset)
    # ---------------------------------------------------------
    print("\n[STAGE 2] APTOS Fine-Tuning")
    aptos_path = r"D:\APTOS_MobileNetV4\APTOS_MobileNetV4\train"
    
    if not os.path.exists(aptos_path):
        print(f"ERROR: APTOS path {aptos_path} not found.")
    else:
        try:
            aptos_train_loader, aptos_val_loader = get_dataloaders(aptos_path, batch_size=32)
            
            if aptos_train_loader:
                # Stage 2 Optimizer: Lower LR to calibrate and lock in clinical grading
                optimizer_s2 = optim.AdamW(model.parameters(), lr=1e-4, weight_decay=1e-4)
                
                # Add Cosine Annealing Scheduler to smoothly reduce LR during fine-tuning
                scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer_s2, T_max=5, eta_min=1e-6)
                
                train_one_stage(model, aptos_train_loader, aptos_val_loader, 
                                optimizer_s2, scheduler, criterion, epochs=5, device=device, stage_name="Stage 2 APTOS")
        except Exception as e:
            print(f"Stage 2 APTOS fine-tuning failed. Error: {e}")
        
    print("\nOptiXAI Hybrid Training Pipeline Completed successfully.")
