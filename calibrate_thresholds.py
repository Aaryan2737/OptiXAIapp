# Author: Aaryan Patil (Roll No. 26) - OptiXAI
import os
import torch
import torch.nn.functional as F
import numpy as np
import timm
from sklearn.metrics import roc_curve
from train import get_dataloaders

def calculate_optimal_thresholds(y_true, y_probs):
    """
    Iterates over a validation holdout set to mathematically calculate optimal 
    decision boundaries (thresholds) for the 5 severity grades (0-4) using Youden's Index.
    
    y_true: Array of true labels (0 to 4) of shape (N,)
    y_probs: Array of predicted probabilities of shape (N, 5)
    """
    num_classes = y_probs.shape[1]
    optimal_thresholds = np.zeros(num_classes)
    
    print("Calibrating decision boundaries using Youden's Index (J = Sensitivity + Specificity - 1)...")
    
    for i in range(num_classes):
        # Create binary OVR (One-Vs-Rest) labels for the current class
        binary_true = (y_true == i).astype(int)
        
        # Defensive check: If validation set happens to have 0 images of this class
        if binary_true.sum() == 0:
            print(f"  [ Grade {i} ] WARNING: No positive samples in validation set. Defaulting to 0.5")
            optimal_thresholds[i] = 0.5
            continue
            
        class_probs = y_probs[:, i]
        
        # Compute ROC curve metrics
        fpr, tpr, thresholds = roc_curve(binary_true, class_probs)
        
        # Calculate Youden's J statistic
        youden_j = tpr + (1 - fpr) - 1
        
        # Find the threshold that maximizes Youden's J
        optimal_idx = np.argmax(youden_j)
        optimal_thresholds[i] = thresholds[optimal_idx]
        
        print(f"  [ Grade {i} ] Optimal Threshold: {optimal_thresholds[i]:.4f} | Max J: {youden_j[optimal_idx]:.4f}")
        
    return optimal_thresholds

def apply_calibrated_thresholds(y_probs, thresholds):
    """
    Replaces default static (0.5) / argmax logic with calibrated thresholds 
    to mitigate high false positives caused by class imbalance.
    """
    # Adjust probabilities proportionally to the calibrated thresholds
    # Added 1e-7 epsilon to prevent DivisionByZero if a threshold calibrates to exactly 0.0
    adjusted_probs = y_probs / (thresholds + 1e-7)
    predictions = np.argmax(adjusted_probs, axis=1)
    return predictions

if __name__ == "__main__":
    print("=" * 50)
    print(" OptiXAI Threshold Calibration (Youden's Index)")
    print("=" * 50)
    
    use_cuda = torch.cuda.is_available()
    device = torch.device('cuda' if use_cuda else 'cpu')
    print(f"Using device: {device}")
    
    # 1. Load Model
    print("Initializing MobileNetV4...")
    try:
        model = timm.create_model('mobilenetv4_conv_small.e2400_r224_in1k', pretrained=False, num_classes=5)
    except Exception as e:
        print(f"timm MobileNetV4 not found, falling back to v3. Error: {e}")
        model = timm.create_model('mobilenetv3_large_100', pretrained=False, num_classes=5)
        
    model = model.to(device)
    
    # Load Stage 2 final weights
    weights_path = "optixai_final_aptos.pth"
    if not os.path.exists(weights_path):
        print(f"CRITICAL ERROR: Stage 2 weights '{weights_path}' not found.")
        print("Please ensure you have run 'python train.py' successfully.")
        exit(1)
        
    print(f"Loading weights from {weights_path}...")
    state_dict = torch.load(weights_path, map_location=device, weights_only=True)
    if 'model_state_dict' in state_dict:
        state_dict = state_dict['model_state_dict']
    model.load_state_dict(state_dict)
    
    # 2. Load Dataset with 3-WAY SPLIT to prevent validation leakage
    # test_split=0.5 splits the 20% holdout into 10% val + 10% test
    aptos_path = r"D:\APTOS_MobileNetV4\APTOS_MobileNetV4\train"
    if not os.path.exists(aptos_path):
        print(f"CRITICAL ERROR: APTOS dataset not found at {aptos_path}")
        exit(1)
        
    _, val_loader, test_loader = get_dataloaders(aptos_path, batch_size=32, test_split=0.5)
    if val_loader is None:
        print("Failed to initialize validation loader.")
        exit(1)
        
    # 3. Inference on VALIDATION set to calibrate thresholds
    print("\nRunning inference on VALIDATION set to calibrate thresholds...")
    model.eval()
    all_probs = []
    all_true = []
    
    with torch.no_grad():
        for inputs, targets in val_loader:
            inputs = inputs.to(device)
            # Mixed precision is safe for inference too
            if use_cuda:
                with torch.amp.autocast('cuda'):
                    logits = model(inputs)
            else:
                logits = model(inputs)
                
            # Apply Softmax to get probabilities (0.0 to 1.0)
            probs = F.softmax(logits, dim=1)
            
            all_probs.append(probs.cpu())
            all_true.append(targets.cpu())
            
    val_probs = torch.cat(all_probs).numpy()
    val_true = torch.cat(all_true).numpy()
    
    print(f"Collected predictions for {len(val_true)} validation images.")
    
    # 4. Calculate Thresholds on VALIDATION set
    optimal_thresh = calculate_optimal_thresholds(val_true, val_probs)
    
    # Val-set calibration accuracy (for reference only — NOT the final metric)
    baseline_preds_val = np.argmax(val_probs, axis=1)
    baseline_acc_val = (baseline_preds_val == val_true).mean() * 100
    
    adjusted_preds_val = apply_calibrated_thresholds(val_probs, optimal_thresh)
    adjusted_acc_val = (adjusted_preds_val == val_true).mean() * 100
    
    print("\n--- Calibration Results (Validation Set — used for tuning) ---")
    print(f"Baseline Accuracy (Static argmax):  {baseline_acc_val:.2f}%")
    print(f"Adjusted Accuracy (Youden Bounds):  {adjusted_acc_val:.2f}%")
    print("NOTE: These numbers are optimistically biased because thresholds were tuned on this data.")
    
    # 5. EVALUATE on completely UNSEEN TEST set (the honest metric)
    print("\nRunning inference on held-out TEST set for unbiased evaluation...")
    test_probs_list = []
    test_true_list = []
    
    with torch.no_grad():
        for inputs, targets in test_loader:
            inputs = inputs.to(device)
            if use_cuda:
                with torch.amp.autocast('cuda'):
                    logits = model(inputs)
            else:
                logits = model(inputs)
                
            probs = F.softmax(logits, dim=1)
            test_probs_list.append(probs.cpu())
            test_true_list.append(targets.cpu())
            
    test_probs = torch.cat(test_probs_list).numpy()
    test_true = torch.cat(test_true_list).numpy()
    
    print(f"Collected predictions for {len(test_true)} test images.")
    
    # Apply calibrated thresholds to test set
    baseline_preds_test = np.argmax(test_probs, axis=1)
    baseline_acc_test = (baseline_preds_test == test_true).mean() * 100
    
    adjusted_preds_test = apply_calibrated_thresholds(test_probs, optimal_thresh)
    adjusted_acc_test = (adjusted_preds_test == test_true).mean() * 100
    
    # Calculate QWK on test set
    from sklearn.metrics import cohen_kappa_score
    baseline_qwk_test = cohen_kappa_score(test_true, baseline_preds_test, weights='quadratic')
    adjusted_qwk_test = cohen_kappa_score(test_true, adjusted_preds_test, weights='quadratic')
    
    print("\n" + "=" * 60)
    print(" FINAL EVALUATION (Held-Out Test Set — Unbiased Metrics)")
    print("=" * 60)
    print(f"Test Baseline Accuracy (Static argmax):  {baseline_acc_test:.2f}%")
    print(f"Test Adjusted Accuracy (Youden Bounds):  {adjusted_acc_test:.2f}%")
    print(f"Test Baseline QWK:  {baseline_qwk_test:.4f}")
    print(f"Test Adjusted QWK:  {adjusted_qwk_test:.4f}")
    
    # Per-class accuracy on test set (critical for clinical validation)
    class_names = ['No DR', 'Mild', 'Moderate', 'Severe', 'PDR']
    print("\n  Per-Class Sensitivity (Adjusted Thresholds, Test Set):")
    for cls_idx in range(5):
        mask = test_true == cls_idx
        if mask.sum() > 0:
            cls_acc = (adjusted_preds_test[mask] == cls_idx).mean() * 100
            print(f"    Class {cls_idx} ({class_names[cls_idx]:>8s}): {cls_acc:5.1f}% ({mask.sum()} samples)")
        else:
            print(f"    Class {cls_idx} ({class_names[cls_idx]:>8s}): N/A (0 samples)")
    
    # Urgent Refer combined sensitivity (Class 3+4 → either 3 or 4)
    urgent_mask = (test_true >= 3)
    if urgent_mask.sum() > 0:
        urgent_correct = (adjusted_preds_test[urgent_mask] >= 3).mean() * 100
        print(f"\n    Urgent Refer (3+4 combined): {urgent_correct:5.1f}% ({urgent_mask.sum()} samples)")
        print(f"    → This is the clinically actionable metric. Even when 3↔4 are confused,")
        print(f"      the patient is still routed to urgent specialist referral.")
    
    print("=" * 60)
    
    print("\nFinal Calibrated Threshold Array for Edge Deployment (Dart):")
    print(f"final List<double> optimalThresholds = [{', '.join([f'{t:.4f}' for t in optimal_thresh])}];")
    
    # Save thresholds to JSON for the Cloud API (api.py) to maintain Edge-Cloud parity
    import json
    try:
        with open("calibrated_thresholds.json", "w") as f:
            json.dump({"thresholds": optimal_thresh.tolist()}, f)
        print("Saved thresholds to calibrated_thresholds.json for Cloud API.")
    except Exception as e:
        print(f"Failed to save thresholds to JSON: {e}")
