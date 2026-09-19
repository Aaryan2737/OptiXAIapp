import os
import shutil
import random

def curate_golden_dataset(source_dir, dest_dir, samples_per_class=1):
    """
    Curates a 'Golden Dataset' for the offline pitch demo.
    Selects 1 representative image from each of the 5 DR grades.
    """
    if not os.path.exists(source_dir):
        print(f"Error: Source directory {source_dir} not found.")
        return

    os.makedirs(dest_dir, exist_ok=True)
    
    classes = ['0_No_DR', '1_Mild', '2_Moderate', '3_Severe', '4_Proliferative_DR']
    
    for cls in classes:
        cls_dir = os.path.join(source_dir, cls)
        if not os.path.exists(cls_dir):
            print(f"Warning: Class directory {cls_dir} not found. Skipping.")
            continue
            
        images = [f for f in os.listdir(cls_dir) if f.lower().endswith(('.png', '.jpg', '.jpeg'))]
        if not images:
            print(f"Warning: No images found in {cls_dir}. Skipping.")
            continue
            
        # Select random images
        selected = random.sample(images, min(samples_per_class, len(images)))
        
        for img_name in selected:
            src = os.path.join(cls_dir, img_name)
            # Prefix with class name for easy identification during demo
            dest_name = f"grade{cls[0]}_{img_name}"
            dest = os.path.join(dest_dir, dest_name)
            
            shutil.copy2(src, dest)
            print(f"Copied {img_name} -> {dest_name}")
            
    print(f"\nGolden dataset curated successfully at: {dest_dir}")

if __name__ == "__main__":
    # Update this path to where the actual APTOS dataset is stored on your machine
    APTOS_TRAIN_DIR = r"D:\APTOS_MobileNetV4\APTOS_MobileNetV4\train"
    GOLDEN_DIR = "./golden_dataset_demo"
    
    print("Curating OptiXAI Golden Dataset for SIH Pitch Demo...")
    curate_golden_dataset(APTOS_TRAIN_DIR, GOLDEN_DIR)
