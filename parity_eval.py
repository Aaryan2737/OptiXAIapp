#!/usr/bin/env python3
"""
OptiXAI parity + accuracy check (Python side).

Replicates image_ingestion_service.dart (crop -> blur -> CLAHE -> resize -> RGB)
and edge_inference.dart (ImageNet normalisation), then runs the SAME .tflite
file the app ships.

--pipeline chooses the preprocessing:
  app         crop + 3x3 blur + CLAHE + bicubic resize   (what the app does now)
  no_clahe    crop + 3x3 blur + bicubic resize
  resize_only plain bilinear resize                      (the unused runInference() path)
  all         run every pipeline and print each result

Use it on a LABELLED validation set with --pipeline all: the pipeline that
matches how the model was trained will score clearly best. Decide from that
evidence, not from a handful of hand-picked images.

If your training repo has its own preprocess function, add it as another mode
so this tests your real training path.

Usage:
  python parity_eval.py --model optixai_dr_model.tflite --images a.jpg b.jpg
  python parity_eval.py --model optixai_dr_model.tflite --pipeline all \
      --image-dir val_images --labels labels.csv --dump-dir dumped

labels.csv: one "filename,grade" per line (grade 0-4). A header row is fine.
Works with float32 and int8 (full_integer_quant) exports. For int8 it applies the
same input quantisation as edge_inference.dart and dequantises the output.
Requires: numpy, opencv-python, and tensorflow or tflite-runtime.
"""
import argparse
import csv
import os
import sys

import cv2
import numpy as np

try:
    from tflite_runtime.interpreter import Interpreter
except ImportError:
    import tensorflow as tf
    Interpreter = tf.lite.Interpreter

MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)  # R, G, B
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
SIZE = 224
MODES = ["app", "no_clahe", "resize_only"]


def preprocess(path, mode="app", crop_thresh=20):
    """Returns a 224x224x3 uint8 RGB array. 'app' mirrors _runPreprocessPipeline."""
    raw = np.fromfile(path, dtype=np.uint8)
    img = cv2.imdecode(raw, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("cannot decode image")

    if mode == "resize_only":
        img = cv2.resize(img, (SIZE, SIZE), interpolation=cv2.INTER_LINEAR)
        return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

    # A. contour auto-crop
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    _, thresh = cv2.threshold(gray, crop_thresh, 255, cv2.THRESH_BINARY)
    contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if contours:
        x, y, w, h = cv2.boundingRect(max(contours, key=cv2.contourArea))
        if w > 50 and h > 50:
            img = img[y:y + h, x:x + w]

    # B. Gaussian denoise
    img = cv2.GaussianBlur(img, (3, 3), 0)

    # C. CLAHE on the L channel (skipped for no_clahe)
    if mode == "app":
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
        l, a, b = cv2.split(lab)
        l = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(l)
        img = cv2.cvtColor(cv2.merge([l, a, b]), cv2.COLOR_LAB2BGR)

    # D. bicubic resize, E. BGR -> RGB
    img = cv2.resize(img, (SIZE, SIZE), interpolation=cv2.INTER_CUBIC)
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


def predict(interp, x):
    """x is the float, ImageNet-normalised input. Quantised models get the same
    quantisation the app applies: q = round(x / scale) + zero_point."""
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]
    dt = np.dtype(inp["dtype"])
    if dt != np.float32:
        scale, zp = inp["quantization"]
        info = np.iinfo(dt)
        x = np.clip(np.round(x / scale) + zp, info.min, info.max)
    interp.set_tensor(inp["index"], x.astype(dt))
    interp.invoke()
    y = interp.get_tensor(out["index"])[0]
    if np.dtype(out["dtype"]) != np.float32:
        scale, zp = out["quantization"]
        y = (y.astype(np.float32) - zp) * scale
    return y


def read_labels(path):
    labels = {}
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if len(row) >= 2 and row[1].strip().isdigit():
                labels[row[0].strip()] = int(row[1])
    return labels


def evaluate(interp, paths, labels, mode, shape, nchw, dump_dir, crop_thresh=20):
    print(f"\n=== pipeline: {mode} (crop threshold {crop_thresh}) ===")
    truths, preds = [], []
    for path in paths:
        name = os.path.basename(path)
        try:
            rgb = preprocess(path, mode, crop_thresh)
        except Exception as e:  # noqa: BLE001
            print(f"{name:32s} SKIPPED: {e}")
            continue

        if dump_dir:
            out_name = f"{os.path.splitext(name)[0]}_{mode}.png"
            cv2.imwrite(os.path.join(dump_dir, out_name), cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))

        hwc = (rgb.astype(np.float32) / 255.0 - MEAN) / STD
        x = hwc.transpose(2, 0, 1)[None] if nchw else hwc[None]
        probs = predict(interp, x)
        pred = int(np.argmax(probs))

        truth = labels.get(name)
        m = rgb.reshape(-1, 3).mean(axis=0)
        line = (f"{name:32s} [{' '.join(f'{v:6.3f}' for v in probs)}] "
                f"argmax={pred} P(>=2)={probs[2:].sum():.3f} "
                f"mean_RGB=({m[0]:.1f},{m[1]:.1f},{m[2]:.1f})")
        if truth is not None:
            line += f" true={truth}"
            truths.append(truth)
            preds.append(pred)
        print(line)
        if abs(float(probs.sum()) - 1.0) > 0.01:
            print(f"    note: probabilities sum to {probs.sum():.3f}; softmax may not be in the graph")

        if nchw:
            app_probs = predict(interp, hwc.reshape(shape))
            print(f"{'  as-app (scrambled)':32s} [{' '.join(f'{v:6.3f}' for v in app_probs)}] "
                  f"argmax={int(np.argmax(app_probs))}")

    if truths:
        cm = np.zeros((5, 5), dtype=int)
        for t, p in zip(truths, preds):
            cm[t, p] += 1
        print("\nconfusion matrix (rows = true grade, cols = predicted):")
        print(cm)
        ref_t = np.array(truths) >= 2
        ref_p = np.array(preds) >= 2
        sens = (ref_t & ref_p).sum() / max(ref_t.sum(), 1)
        spec = (~ref_t & ~ref_p).sum() / max((~ref_t).sum(), 1)
        acc = (np.array(truths) == np.array(preds)).mean()
        print(f"[{mode}] referable (grade >= 2): sensitivity {sens:.2f}, "
              f"specificity {spec:.2f}; exact-grade accuracy {acc:.2f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--images", nargs="*", default=[])
    ap.add_argument("--image-dir")
    ap.add_argument("--labels", help="CSV: filename,grade")
    ap.add_argument("--dump-dir", help="save the 224x224 preprocessed images here")
    ap.add_argument("--pipeline", default="app", choices=MODES + ["all"])
    ap.add_argument("--crop-threshold", type=int, default=20,
                    help="gray threshold for the auto-crop: the app uses 20, preprocess.py uses 10")
    args = ap.parse_args()

    labels = read_labels(args.labels) if args.labels else {}
    paths = list(args.images)
    if args.image_dir:
        names = sorted(labels) if labels else sorted(os.listdir(args.image_dir))
        paths += [os.path.join(args.image_dir, n) for n in names]
    if not paths:
        sys.exit("no images given")
    if args.dump_dir:
        os.makedirs(args.dump_dir, exist_ok=True)

    interp = Interpreter(model_path=args.model)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    shape = [int(v) for v in inp["shape"]]
    dt = np.dtype(inp["dtype"])
    print(f"model input shape: {shape}, dtype: {dt.name}"
          + (f", quantization (scale, zero_point): {inp['quantization']}" if dt != np.float32 else ""))
    if dt not in (np.float32, np.int8, np.uint8):
        sys.exit(f"unsupported input dtype {dt.name}; edge_inference.dart only handles "
                 "float32 and int8 inputs, so use one of those exports")

    nchw = shape[1] == 3 and shape[-1] != 3
    if nchw:
        print("WARNING: model expects NCHW. edge_inference.dart reshapes HWC data "
              "into this shape without transposing, so the app feeds it scrambled "
              "pixels. 'as-app' below reproduces that.")

    for mode in (MODES if args.pipeline == "all" else [args.pipeline]):
        evaluate(interp, paths, labels, mode, shape, nchw, args.dump_dir, args.crop_threshold)


if __name__ == "__main__":
    main()