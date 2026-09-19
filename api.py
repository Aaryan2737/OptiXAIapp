# Author: Aaryan Patil (Roll No. 26) - OptiXAI
import io
import cv2
import torch
import numpy as np
from PIL import Image
import torchvision.transforms as transforms
from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import Response
import timm

# Standard Grad-CAM utilities (pip install grad-cam)
from pytorch_grad_cam import GradCAMPlusPlus
from pytorch_grad_cam.utils.model_targets import ClassifierOutputTarget
from pytorch_grad_cam.utils.image import show_cam_on_image

# Import our exact preprocessing pipeline to maintain Zero Train-Serve Skew
from optixai.preprocess import clean_single_image, IMAGENET_MEAN, IMAGENET_STD

app = FastAPI(
    title="OptiXAI Grad-CAM++ Cloud Engine",
    description="Offloads heavy backpropagation heatmap generation from the edge device to save battery and compute."
)

# Global instances
device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
model = None
cam = None
calibrated_thresholds = [0.5, 0.5, 0.5, 0.5, 0.5]

@app.on_event("startup")
def load_model():
    """
    Initializes the PyTorch model and binds the Grad-CAM++ hooks to the 
    last convolutional layer upon server startup.
    """
    global model, cam
    print(f"Initializing OptiXAI Cloud Engine on {device}...")
    
    try:
        # Reconstruct the exact architecture used in training
        model = timm.create_model('mobilenetv4_conv_small.e2400_r224_in1k', pretrained=False, num_classes=5)
        
        # Attempt to load the fine-tuned APTOS weights (from Stage 2 of train.py)
        weights_path = "optixai_final_aptos.pth"
        import os
        if os.path.exists(weights_path):
            state_dict = torch.load(weights_path, map_location=device, weights_only=True)
            if 'model_state_dict' in state_dict:
                state_dict = state_dict['model_state_dict']
            model.load_state_dict(state_dict)
            print(f"Loaded fine-tuned weights from {weights_path}")
        else:
            print(f"Warning: {weights_path} not found. Running with uninitialized weights for testing.")
            
    except Exception as e:
        print(f"Error loading MobileNetV4 architecture: {e}")
        print("Falling back to MobileNetV3 for stability...")
        model = timm.create_model('mobilenetv3_large_100', pretrained=False, num_classes=5)
        
    model.to(device)
    model.eval() # CRITICAL: Ensure Dropout/BatchNorm are in inference mode
    
    # Target the last convolutional layer for Grad-CAM spatial heatmaps.
    # We dynamically find the typical MobileNet head layer naming in timm.
    if hasattr(model, 'conv_head'):
        target_layers = [model.conv_head]
    elif hasattr(model, 'features'):
        target_layers = [model.features[-1]]
    else:
        # Fallback to the second to last layer block
        target_layers = [list(model.children())[-2]]
        
    print(f"Binding Grad-CAM++ to target layer: {target_layers[0].__class__.__name__}")
    
    # Initialize the GradCAM++ engine
    # (Newer versions of pytorch-grad-cam auto-detect device from model)
    cam = GradCAMPlusPlus(model=model, target_layers=target_layers)
    print("Grad-CAM++ Engine Ready to accept mobile requests.")
    
    # Load calibrated thresholds for Edge-Cloud Parity
    try:
        import json
        with open("calibrated_thresholds.json", "r") as f:
            global calibrated_thresholds
            calibrated_thresholds = json.load(f)["thresholds"]
            print(f"Loaded calibrated thresholds: {calibrated_thresholds}")
    except Exception as e:
        print(f"Warning: Could not load calibrated_thresholds.json, defaulting to 0.5. Error: {e}")

@app.post("/generate_heatmap")
async def generate_heatmap(file: UploadFile = File(...)):
    """
    Receives a raw fundus image stream from the Flutter app.
    Runs it through the deterministic preprocessing pipeline, calculates the DR Grade,
    and performs a backward pass to generate a Grad-CAM++ heatmap indicating 
    lesion focal points (Microaneurysms, Hemorrhages).
    """
    if not model or not cam:
        raise HTTPException(status_code=500, detail="OptiXAI Model Engine is not initialized.")
        
    try:
        # 1. Read byte stream directly from the incoming HTTP request
        contents = await file.read()
        
        # 2. Deterministic Preprocessing (Guarantees consistency with train.py)
        # Parses bytes, crops fundus, applies CLAHE, and resizes to 224x224 RGB
        cleaned_np = clean_single_image(contents, return_intermediate=False)
        
        # 3. PyTorch Tensor Transformation
        img_pil = Image.fromarray(cleaned_np)
        transform = transforms.Compose([
            transforms.ToTensor(),
            transforms.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD)
        ])
        input_tensor = transform(img_pil).unsqueeze(0).to(device)
        
        # 4. Forward Pass Prediction
        with torch.no_grad():
            outputs = model(input_tensor)
            probs = torch.nn.functional.softmax(outputs, dim=1).cpu().numpy()[0]
            
            # Apply calibrated thresholds to match Edge inference logic
            adjusted_probs = probs / (np.array(calibrated_thresholds) + 1e-7)
            predicted_grade = int(np.argmax(adjusted_probs))
            
        # 5. Grad-CAM++ Heatmap Generation
        # Target the gradients specifically for the predicted grade
        targets = [ClassifierOutputTarget(predicted_grade)]
        
        # Generate the grayscale activation map
        grayscale_cam = cam(input_tensor=input_tensor, targets=targets)
        grayscale_cam = grayscale_cam[0, :]
        
        # 6. Overlay Heatmap onto the Cleaned Image
        # pytorch_grad_cam expects the base image normalized to [0, 1] float32
        rgb_img_float = cleaned_np.astype(np.float32) / 255.0
        
        # Creates a blended Jet colormap overlay (Red = High Importance, Blue = Low)
        cam_image = show_cam_on_image(rgb_img_float, grayscale_cam, use_rgb=True)
        
        # 7. Encode Image back to JPG bytes for HTTP Response
        # OpenCV requires BGR color space for encoding
        cam_image_bgr = cv2.cvtColor(cam_image, cv2.COLOR_RGB2BGR)
        success, encoded_image = cv2.imencode('.jpg', cam_image_bgr)
        
        if not success:
            raise ValueError("Failed to compress and encode the heatmap image.")
            
        # Return the raw image bytes to the mobile app. 
        # Inject the predicted grade into the custom HTTP headers so the app gets both!
        return Response(
            content=encoded_image.tobytes(), 
            media_type="image/jpeg", 
            headers={"X-OptiXAI-Predicted-Grade": str(predicted_grade)}
        )
                        
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to process image: {str(e)}")
