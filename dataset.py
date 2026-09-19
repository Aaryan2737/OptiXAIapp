# Author: Aaryan Patil (Roll No. 26) - OptiXAI
import cv2
import torch
import numpy as np
from torch.utils.data import Dataset
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image

class DRDataset(Dataset):
    def __init__(self, image_paths, labels, transform=None):
        """
        Diabetic Retinopathy Dataset with local on-the-fly CLAHE preprocessing 
        and normalized cropping to handle variable rural capture conditions.
        """
        self.image_paths = image_paths
        self.labels = labels
        self.transform = transform
        
        # Initialize CLAHE with clip limit for retina contrast enhancement
        self.clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))

    def preprocess_image(self, img_path):
        # Read image
        img = cv2.imread(img_path)
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        
        # 1. Illumination Normalization using CLAHE (L-channel of LAB color space)
        lab = cv2.cvtColor(img, cv2.COLOR_RGB2LAB)
        l_channel, a, b = cv2.split(lab)
        
        cl = self.clahe.apply(l_channel)
        
        limg = cv2.merge((cl, a, b))
        img = cv2.cvtColor(limg, cv2.COLOR_LAB2RGB)
        
        # 2. Crop & Resize (Removing standard black borders around fundus)
        # Using a center crop based on the minimum dimension
        h, w = img.shape[:2]
        center = (w // 2, h // 2)
        radius = min(center[0], center[1])
        
        # Create circular mask
        mask = np.zeros((h, w), dtype=np.uint8)
        cv2.circle(mask, center, radius, (255, 255, 255), -1, 8, 0)
        img = cv2.bitwise_and(img, img, mask=mask)
        
        # Tight bounding box crop around the fundus
        img = img[center[1]-radius:center[1]+radius, center[0]-radius:center[0]+radius]
        
        return Image.fromarray(img)

    def __len__(self):
        return len(self.image_paths)

    def __getitem__(self, idx):
        img_path = self.image_paths[idx]
        label = self.labels[idx]
        
        # Apply local processing pipeline
        img = self.preprocess_image(img_path)
        
        if self.transform:
            img = self.transform(img)
            
        return img, torch.tensor(label, dtype=torch.long)


class FocalLoss(nn.Module):
    """
    Focal Loss to handle severe class imbalance in DR datasets,
    prioritizing hard-to-classify early-stage microaneurysms (e.g., Grade 1).
    """
    def __init__(self, alpha=None, gamma=2.0, reduction='mean'):
        super(FocalLoss, self).__init__()
        self.gamma = gamma
        self.reduction = reduction
        # Alpha: tensor of weights for each class to balance majority class (Grade 0)
        self.alpha = alpha

    def forward(self, inputs, targets):
        ce_loss = F.cross_entropy(inputs, targets, reduction='none', weight=self.alpha)
        pt = torch.exp(-ce_loss)
        focal_loss = ((1 - pt) ** self.gamma) * ce_loss
        
        if self.reduction == 'mean':
            return focal_loss.mean()
        elif self.reduction == 'sum':
            return focal_loss.sum()
        return focal_loss
