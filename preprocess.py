# Author: Aaryan Patil (Roll No. 26) - OptiXAI Preprocessing Engine

import os
import cv2
import numpy as np
import torch
import random
from torch.utils.data import Dataset
from PIL import Image
import torchvision.transforms as transforms
import matplotlib.pyplot as plt

# ==============================================================================
# 1. CORE PREPROCESSING PIPELINE (Train-Serve Consistency)
# ==============================================================================

def auto_crop_fundus(img):
    """
    Automated Circular Contour Auto-Cropping.
    Isolates the retinal circle from the black background.
    """
    gray = cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)
    
    # Threshold to isolate the fundus (values > 10 are typically non-background)
    _, thresh = cv2.threshold(gray, 10, 255, cv2.THRESH_BINARY)
    
    # Find contours of the fundus area
    contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    
    if contours:
        # Find the largest contour which should correspond to the illuminated fundus
        c = max(contours, key=cv2.contourArea)
        x, y, w, h = cv2.boundingRect(c)
        
        # Defensive check to ensure we don't crop to a tiny artifact or glint
        if w > 50 and h > 50:
            return img[y:y+h, x:x+w]
            
    return img # Return original image if robust cropping fails

def clean_single_image(image_path_or_bytes, return_intermediate=False):
    """
    Standalone deterministic cleaning pipeline for Diabetic Retinopathy images.
    Used identically in PyTorch Dataset and Edge Deployment (Dart reference).
    """
    # 1. Load Image
    if isinstance(image_path_or_bytes, str):
        if not os.path.exists(image_path_or_bytes):
            raise FileNotFoundError(f"Image not found at: {image_path_or_bytes}")
        img = cv2.imread(image_path_or_bytes)
        if img is None:
            raise ValueError(f"Failed to read image at: {image_path_or_bytes}")
        # Convert BGR (OpenCV default) to RGB
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    elif isinstance(image_path_or_bytes, bytes):
        # Decode from raw bytes (e.g., streaming from mobile camera memory)
        nparr = np.frombuffer(image_path_or_bytes, np.uint8)
        img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    else:
        # Assume it's already a numpy array (RGB)
        img = image_path_or_bytes
        
    raw_img = img.copy()

    # 2. Automated Circular Contour Auto-Cropping
    cropped_img = auto_crop_fundus(img)
    
    # 3. Standardized Denoising
    # Light Gaussian filter (radius 1-2 equivalent to 3x3 kernel)
    # Suppresses digital sensor noise without blurring fine vessel edges
    denoised_img = cv2.GaussianBlur(cropped_img, (3, 3), 0)
    
    # 4. CLAHE (Contrast Limited Adaptive Histogram Equalization)
    lab = cv2.cvtColor(denoised_img, cv2.COLOR_RGB2LAB)
    l_channel, a_channel, b_channel = cv2.split(lab)
    
    # clipLimit=2.0 and tileGridSize=(8,8) configured for optimal retinal lesion visibility
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    cl = clahe.apply(l_channel)
    
    limg = cv2.merge((cl, a_channel, b_channel))
    clahe_img = cv2.cvtColor(limg, cv2.COLOR_LAB2RGB)
    
    # 5. Bicubic Resize to 224x224 cleanly
    final_img = cv2.resize(clahe_img, (224, 224), interpolation=cv2.INTER_CUBIC)
    
    if return_intermediate:
        return raw_img, cropped_img, final_img
        
    return final_img

# ==============================================================================
# 2. PYTORCH DATASET INTEGRATION
# ==============================================================================

# Standard ImageNet Normalization used for MobileNetV4 backbone
# Explicitly logged for Train-Serve Consistency matching in Flutter deployment
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]

class APTOSDataset(Dataset):
    """
    Custom PyTorch Dataset embedding the deterministic cleaning pipeline.
    Guarantees zero train-serve skew by enforcing the exact same logic.
    """
    def __init__(self, image_paths, labels, augment=False):
        self.image_paths = image_paths
        self.labels = labels
        self.augment = augment
        
        # Base transforms required for all images
        self.base_transforms = transforms.Compose([
            # ToTensor automatically scales uint8 [0, 255] to float32 [0.0, 1.0]
            transforms.ToTensor(), 
            # Apply standard ImageNet Normalization
            transforms.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD)
        ])
        
        # Optional spatial augmentations AFTER deterministic cleaning
        if self.augment:
            self.aug_transforms = transforms.Compose([
                transforms.RandomHorizontalFlip(p=0.5),
                transforms.RandomVerticalFlip(p=0.5),
                transforms.RandomRotation(degrees=15),
            ])
        else:
            self.aug_transforms = None

    def __len__(self):
        return len(self.image_paths)

    def __getitem__(self, idx):
        img_path = self.image_paths[idx]
        label = self.labels[idx]
        
        # 1. Apply deterministic cleaning (returns 224x224 RGB numpy array)
        try:
            cleaned_img_np = clean_single_image(img_path)
        except Exception as e:
            print(f"Warning: Corrupt or missing image at {img_path}. Error: {e}")
            # Defensive fallback to a zero tensor if image is fully corrupted to prevent training crash
            cleaned_img_np = np.zeros((224, 224, 3), dtype=np.uint8)
            
        # Convert NumPy to PIL for Torchvision augmentations compatibility
        img_pil = Image.fromarray(cleaned_img_np)
        
        # 2. Apply standard Spatial Augmentations (if any)
        if self.aug_transforms:
            img_pil = self.aug_transforms(img_pil)
            
        # 3. Convert to Float Tensor [0-1] and Normalize
        img_tensor = self.base_transforms(img_pil)
        
        return img_tensor, torch.tensor(label, dtype=torch.long)

# ==============================================================================
# 3. VISUAL VERIFICATION BLOCK (Local Testing)
# ==============================================================================

if __name__ == '__main__':
    dataset_dir = r"D:\APTOS_MobileNetV4\APTOS_MobileNetV4\train"
    
    print(f"[{'='*40}]")
    print(" OptiXAI Preprocessing Pipeline Check")
    print(f" Normalization Mean: {IMAGENET_MEAN}")
    print(f" Normalization Std:  {IMAGENET_STD}")
    print(f"[{'='*40}]")
    
    if not os.path.exists(dataset_dir):
        print(f"Error: Dataset directory not found at: {dataset_dir}")
        print("Please ensure your dataset is extracted and the path is correct.")
    else:
        # Load valid image paths by walking through subdirectories (0_No_DR, etc.)
        valid_exts = ('.png', '.jpg', '.jpeg')
        all_image_paths = []
        for root, _, files in os.walk(dataset_dir):
            for f in files:
                if f.lower().endswith(valid_exts):
                    all_image_paths.append(os.path.join(root, f))
        
        if len(all_image_paths) < 3:
            print("Not enough images found in the directory for verification.")
        else:
            # Select 3 random sample images for verification
            random.seed(42) # Ensure reproducible verification
            sample_paths = random.sample(all_image_paths, 3)
            
            fig, axes = plt.subplots(3, 3, figsize=(15, 15))
            fig.suptitle("OptiXAI Train-Serve Preprocessing Validation", fontsize=16, y=0.95)
            
            for i, img_path in enumerate(sample_paths):
                # Extract filename and its immediate parent folder for a cleaner title
                img_name = os.path.basename(img_path)
                folder_name = os.path.basename(os.path.dirname(img_path))
                display_name = f"{folder_name}/{img_name}"
                
                try:
                    # Execute deterministic cleaning pipeline capturing intermediate states
                    raw, cropped, final = clean_single_image(img_path, return_intermediate=True)
                    
                    # Col 1: Raw Input
                    axes[i, 0].imshow(raw)
                    axes[i, 0].set_title(f"Raw: {display_name}", fontsize=10)
                    axes[i, 0].axis('off')
                    
                    # Col 2: Cropped
                    axes[i, 1].imshow(cropped)
                    axes[i, 1].set_title(f"Auto-Cropped Fundus")
                    axes[i, 1].axis('off')
                    
                    # Col 3: Final Enhanced
                    axes[i, 2].imshow(final)
                    axes[i, 2].set_title(f"Final 224x224 (CLAHE + Denoised)")
                    axes[i, 2].axis('off')
                    
                except Exception as e:
                    print(f"Failed to process {img_name}: {e}")
            
            plt.tight_layout()
            
            # Save the verification plot in the current working directory
            output_plot_path = "raw_vs_cleaned.png"
            plt.savefig(output_plot_path, dpi=300, bbox_inches='tight')
            print(f"\nVerification complete! Saved side-by-side comparison plot to: {output_plot_path}")
            plt.close()
