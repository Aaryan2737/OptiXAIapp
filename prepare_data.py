import os
import shutil
import csv

src = r"D:\APTOS_MobileNetV4\APTOS_MobileNetV4\test"
dst = r"D:\APTOS_MobileNetV4\APTOS_MobileNetV4\test_flat"
os.makedirs(dst, exist_ok=True)

with open("labels.csv", "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["filename", "grade"])
    for d in os.listdir(src):
        d_path = os.path.join(src, d)
        if os.path.isdir(d_path) and "_" in d and d.split("_")[0].isdigit():
            grade = int(d.split("_")[0])
            for img in os.listdir(d_path):
                if img.lower().endswith((".jpg", ".png", ".jpeg")):
                    shutil.copy(os.path.join(d_path, img), os.path.join(dst, img))
                    writer.writerow([img, grade])
