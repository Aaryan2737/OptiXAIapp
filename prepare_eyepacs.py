# Author: Aaryan Patil (Roll No. 26) - OptiXAI
import os
import shutil
import pandas as pd
import kagglehub

def prepare_eyepacs_on_d_drive():
    """
    Downloads the massive EyePACS dataset onto the D: drive to prevent C: drive crashes.
    Reads the associated Kaggle CSV and strictly segregates images into their respective 
    0 to 4 grading folders.
    """
    # 1. Force kagglehub to download to the D drive cache
    cache_dir = r"D:\kagglehub_cache"
    os.environ["KAGGLEHUB_CACHE"] = cache_dir
    os.makedirs(cache_dir, exist_ok=True)
    
    print("Downloading EyePACS to D: drive...")
    print("Note: This is a ~35GB dataset. It may take a while depending on your network.")
    try:
        source_dir = kagglehub.dataset_download("dreamer07/eyepacs")
        print(f"Download complete! Stored temporarily in {source_dir}")
    except Exception as e:
        print(f"Failed to download from Kagglehub. Error: {e}")
        return
        
    # 2. Setup the Segregated Target Directory
    dest_dir = r"D:\EyePACS_Segregated"
    print(f"Segregating images by clinical grade into {dest_dir}...")
    
    folder_names = ["0_No_DR", "1_Mild", "2_Moderate", "3_Severe", "4_Proliferative_DR"]
    for folder in folder_names:
        os.makedirs(os.path.join(dest_dir, folder), exist_ok=True)
        
    # 3. Find the CSV file for labels provided by Kaggle
    csv_paths = [os.path.join(root, f) for root, dirs, files in os.walk(source_dir) for f in files if f.endswith('.csv')]
    if not csv_paths:
        print("Could not find the labels CSV in the downloaded dataset!")
        return
        
    df = pd.read_csv(csv_paths[0])
    img_col, lbl_col = df.columns[0], df.columns[1]
    
    # Map available images on disk to avoid O(N^2) searching
    valid_exts = ('.png', '.jpg', '.jpeg')
    available_images = {}
    for root, _, files in os.walk(source_dir):
        for f in files:
            if f.lower().endswith(valid_exts):
                basename = os.path.splitext(f)[0]
                available_images[basename] = os.path.join(root, f)
                
    moved_count = 0
    missing_count = 0
    
    # 4. Move files based on the grade mapped in the CSV
    for idx, row in df.iterrows():
        basename = str(row[img_col])
        grade = int(row[lbl_col])
        
        if basename in available_images:
            src = available_images[basename]
            dst_folder = os.path.join(dest_dir, folder_names[grade])
            dst = os.path.join(dst_folder, os.path.basename(src))
            
            # Use shutil.move to save space (removes it from the cache as it goes)
            if not os.path.exists(dst):
                try:
                    shutil.move(src, dst)
                    moved_count += 1
                except Exception as e:
                    print(f"Warning: Failed to move {src}. {e}")
            
            if moved_count > 0 and moved_count % 5000 == 0:
                print(f"Moved {moved_count} images so far...")
        else:
            missing_count += 1
            
    print(f"Successfully segregated {moved_count} images to {dest_dir}")
    if missing_count > 0:
        print(f"Note: {missing_count} images listed in CSV were not found in the folders (this is normal for Kaggle partial sets).")

if __name__ == "__main__":
    prepare_eyepacs_on_d_drive()
