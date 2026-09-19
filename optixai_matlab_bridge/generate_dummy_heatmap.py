import cv2
import numpy as np
import argparse
import os

def generate_heatmap(input_path, output_path):
    # Read the original image
    img = cv2.imread(input_path)
    if img is None:
        raise ValueError(f"Could not read input image: {input_path}")
        
    h, w = img.shape[:2]
    
    # Generate a dummy heatmap (a Gaussian blob in the center)
    x = np.linspace(-1, 1, w)
    y = np.linspace(-1, 1, h)
    X, Y = np.meshgrid(x, y)
    
    # Create two "hotspots" to look somewhat realistic
    d1 = np.sqrt(X**2 + Y**2)
    d2 = np.sqrt((X-0.3)**2 + (Y+0.2)**2)
    
    blob1 = np.exp(- (d1**2) / 0.1)
    blob2 = np.exp(- (d2**2) / 0.05)
    
    heatmap_gray = np.maximum(blob1, blob2)
    heatmap_gray = np.uint8(255 * heatmap_gray)
    
    # Apply JET colormap
    heatmap_color = cv2.applyColorMap(heatmap_gray, cv2.COLORMAP_JET)
    
    # Blend with original image
    # For a real Grad-CAM, we usually overlay with some alpha
    alpha = 0.5
    overlaid = cv2.addWeighted(heatmap_color, alpha, img, 1 - alpha, 0)
    
    # Save the result
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    cv2.imwrite(output_path, overlaid)
    print(f"Successfully generated dummy heatmap at {output_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate Dummy Grad-CAM Heatmap")
    parser.add_argument("--input", required=True, help="Path to input image")
    parser.add_argument("--output", required=True, help="Path to save output heatmap")
    args = parser.parse_args()
    
    generate_heatmap(args.input, args.output)
