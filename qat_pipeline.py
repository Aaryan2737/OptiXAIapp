# Author: Aaryan Patil (Roll No. 26) - OptiXAI
import os
import torch
import torch.optim as optim
import numpy as np
import timm

from train import get_dataloaders
from dataset import FocalLoss

def get_mobilenetv4_model(num_classes=5):
    """
    Initializes a MobileNetV4 architecture shell.
    pretrained=False because we load our own Stage 2 weights immediately after.
    """
    print("Initializing MobileNetV4...")
    try:
        model = timm.create_model('mobilenetv4_conv_small.e2400_r224_in1k', pretrained=False, num_classes=num_classes)
    except Exception as e:
        print(f"Failed to load MobileNetV4 directly. Using fallback. Error: {e}")
        model = timm.create_model('mobilenetv3_large_100', pretrained=False, num_classes=num_classes)
    return model

def save_calibration_data(train_loader, num_samples=200, output_dir="calibration_data_sample_data_nchw"):
    """
    Saves representative input tensors from the training set for onnx2tf's
    INT8 post-training quantization calibration.
    
    onnx2tf's -oiqt flag auto-detects .npy files in this directory to compute
    real activation ranges (min/max) for each layer, producing true INT8 weights
    and activations instead of Float32.
    """
    os.makedirs(output_dir, exist_ok=True)
    
    collected = 0
    print(f"\nGenerating calibration dataset ({num_samples} samples) for INT8 quantization...")
    
    for inputs, _ in train_loader:
        for i in range(inputs.size(0)):
            if collected >= num_samples:
                break
            # Save each sample as a separate .npy file in NCHW format
            sample = inputs[i].unsqueeze(0).numpy()  # Shape: (1, 3, 224, 224)
            np.save(os.path.join(output_dir, f"sample_{collected:04d}.npy"), sample)
            collected += 1
        if collected >= num_samples:
            break
    
    print(f"Saved {collected} calibration samples to '{output_dir}/'")
    return output_dir


def export_to_tflite(model, train_loader=None, output_path="optixai_dr_model.tflite"):
    """
    Exports the trained model to ONNX. 
    (Modern TFLite pipelines use ONNX as the bridge to handle BatchNorm fusing automatically)
    
    When ai_edge_torch is unavailable, generates calibration data alongside the ONNX
    export so that onnx2tf can produce a real INT8 TFLite model (not Float32).
    """
    model.eval()
    # Wrap model with Softmax to guarantee TFLite outputs probabilities (required for Dart thresholds)
    class SoftmaxModel(torch.nn.Module):
        def __init__(self, base):
            super().__init__()
            self.base = base
        def forward(self, x):
            return torch.nn.functional.softmax(self.base(x), dim=1)
            
    export_model = SoftmaxModel(model).eval()
    dummy_input = torch.randn(1, 3, 224, 224).to(next(model.parameters()).device)
    
    # Modern approach using ai-edge-torch for direct TFLite conversion
    try:
        import ai_edge_torch
        print("Exporting model using ai_edge_torch...")
        edge_model = ai_edge_torch.convert(export_model, (dummy_input,))
        edge_model.export(output_path)
        print(f"Successfully exported TFLite model to {output_path}")
    except ImportError:
        print("ai_edge_torch not found! Falling back to robust ONNX export with INT8 calibration.")
        onnx_path = output_path.replace('.tflite', '.onnx')
        
        # ONNX export must happen on CPU to avoid device mismatch errors
        export_model_cpu = export_model.cpu()
        dummy_cpu = torch.randn(1, 3, 224, 224)
        
        # Export to ONNX (opset 18 is the minimum for PyTorch 2.14+)
        torch.onnx.export(
            export_model_cpu,
            dummy_cpu,
            onnx_path,
            opset_version=18,
            input_names=['input'],
            output_names=['output'],
            dynamic_axes={
                'input': {0: 'batch_size'},
                'output': {0: 'batch_size'}
            }
        )
        print(f"Successfully exported ONNX model to {onnx_path}.")
        
        # Generate calibration data for INT8 quantization
        # onnx2tf -oiqt auto-detects .npy files in calibration_data_sample_data_nchw/
        if train_loader is not None:
            calib_dir = save_calibration_data(train_loader, num_samples=200)
        else:
            print("WARNING: No train_loader provided — cannot generate calibration data.")
            print("INT8 quantization will fall back to random calibration (less accurate).")
            calib_dir = None
        
        print("\n" + "=" * 60)
        print(" FINAL EDGE DEPLOYMENT STEP (INT8 Quantization)")
        print("=" * 60)
        print("-> Use 'onnx2tf' with the -oiqt flag for full INT8 conversion.")
        print("-> onnx2tf automatically fuses MobileNetV4 BatchNorms.")
        print(f"-> Command: onnx2tf -i {onnx_path} -o optixai_tflite_model/ -oiqt")
        print("")
        print("-> VERIFICATION: After conversion, confirm INT8 dtype with:")
        print("   python -c \"import tensorflow as tf; m = tf.lite.Interpreter('optixai_tflite_model/optixai_dr_model_full_integer_quant.tflite'); m.allocate_tensors(); print([d['dtype'] for d in m.get_input_details()])\"")
        print("   Expected output: [<class 'numpy.int8'>]")
        print("")
        if calib_dir:
            print(f"-> Calibration data directory: {calib_dir}/")
        print("-> WARNING: Without -oiqt, onnx2tf produces Float32 which Android")
        print("   NNAPI/NPU delegates will REJECT, falling back to slow CPU inference.")
        print("=" * 60)

if __name__ == "__main__":
    print("=" * 50)
    print(" OptiXAI Quantization-Aware Training (QAT)")
    print("=" * 50)
    
    use_cuda = torch.cuda.is_available()
    device = torch.device('cuda' if use_cuda else 'cpu')
    print(f"Using device: {device}")
    
    # 1. Initialize Base Model
    model = get_mobilenetv4_model()
    model = model.to(device)
    
    # 2. Load Stage 2 Final Weights
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
    
    # 3. Load Dataset
    aptos_path = r"D:\APTOS_MobileNetV4\APTOS_MobileNetV4\train"
    if not os.path.exists(aptos_path):
        print(f"CRITICAL ERROR: APTOS dataset not found at {aptos_path}")
        exit(1)
        
    train_loader, _ = get_dataloaders(aptos_path, batch_size=32)
    if train_loader is None:
        print("Failed to initialize dataloaders.")
        exit(1)
    
    # Keep a reference to train_loader for calibration data generation during export
    calib_train_loader = train_loader
        
    # 4. Fine-Tuning Loop (1 Epoch)
    # Lock in the final weights for Edge export
    optimizer = optim.AdamW(model.parameters(), lr=1e-5, weight_decay=1e-4)
    criterion = FocalLoss(gamma=2.0)
    
    print("\nStarting final stabilization epoch for export...")
    model.train()
    
    for batch_idx, (inputs, targets) in enumerate(train_loader):
        inputs, targets = inputs.to(device), targets.to(device)
        
        optimizer.zero_grad(set_to_none=True)
        
        outputs = model(inputs)
        loss = criterion(outputs, targets)
        loss.backward()
        
        torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
        optimizer.step()
        
        if batch_idx % 25 == 0:
            print(f"[Export Stabilizer] Batch {batch_idx}/{len(train_loader)} | Loss: {loss.item():.4f}")
            
    print("Stabilization complete.")
    
    # Free training memory before export (keep calib_train_loader for calibration)
    del train_loader, optimizer, criterion
    import gc
    gc.collect()
    
    # 5. Export to ONNX / TFLite Bridge (with INT8 calibration data)
    print("\nExporting model for Edge deployment...")
    export_to_tflite(model, train_loader=calib_train_loader)
    
    print("\n" + "=" * 50)
    print(" OptiXAI Edge Export Pipeline Complete!")
    print("=" * 50)
