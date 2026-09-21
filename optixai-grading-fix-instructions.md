# OptiXAI — Fix Instructions for the DR Grading Pipeline

Follow these steps **in order**. Step 0 must be done first — everything else depends on its answer. Do not skip it or guess.

---

## STEP 0 — Confirm two facts before touching any code

Open the Python script that trained/exported `optixai_dr_model.tflite` (likely `calibrate_thresholds.py` or a `train.py` / `export.py` next to it). Find the answers to these two questions and write them down before proceeding:

**Fact A — Input normalization.** In the training/calibration data pipeline, right before an image is fed to the model, what is done to pixel values? Look for one of these patterns and note which one it is:
- `pixel / 255.0` only → **convention = RAW_0_1** (values 0.0–1.0)
- `(pixel / 255.0 - 0.5) * 2.0` or `pixel/127.5 - 1` → **convention = SCALED_NEG1_1** (values -1.0–1.0)
- `(pixel/255.0 - mean) / std` with `mean=[0.485,0.456,0.406]`, `std=[0.229,0.224,0.225]` → **convention = IMAGENET**
- Nothing at all, raw `uint8` 0–255 passed straight into the model → **convention = RAW_0_255**

**Fact B — Output activation.** Find where the model is defined (Keras model summary, or the last layer of the `.h5`/`.pb`/`.onnx` before conversion). Is the final layer `softmax`, or is it a plain `Dense`/`Linear` layer with no activation?
- Final layer has softmax → **has_softmax = true**
- Final layer has no activation (raw logits) → **has_softmax = false**

If you cannot find the training script at all, run this instead: load the `.tflite` file with Netron (https://netron.app) or in Python:
```python
import tensorflow as tf
interp = tf.lite.Interpreter(model_path="optixai_dr_model.tflite")
interp.allocate_tensors()
print(interp.get_input_details())
print(interp.get_output_details())
```
Look at the **last op in the graph visualization**. If it's `SOFTMAX`, `has_softmax = true`. The input details won't tell you the normalization convention directly — you need the training script for Fact A. If you truly cannot find Fact A anywhere, default to **RAW_0_255** (do nothing to the pixel values beyond dtype conversion) and flag this to a human — do not guess ImageNet normalization, it's the least likely to be correct for a custom medical model.

Write both answers at the top of `edge_inference.dart` as a comment before continuing:
```dart
// CONFIRMED MODEL CONTRACT (verified against training script on <date>):
// Input normalization: <RAW_0_255 | RAW_0_1 | SCALED_NEG1_1 | IMAGENET>
// Output softmax baked into graph: <true | false>
```

---

## STEP 1 — Fix `edge_inference.dart`: one normalization function, used everywhere

Right now `runInference` and `runInferenceFromPreprocessed` each duplicate their own pixel-normalization math, and it's drifted out of sync with what `image_ingestion_service.dart` promises to hand over. Fix this by writing **one function** and calling it from both places.

Add this method to `OptiXAIEngine`, choosing the ONE branch that matches Fact A from Step 0 — **delete the other three branches**, don't leave them as dead code:

```dart
/// Converts a raw 0-255 pixel value into the float the model was trained on.
/// Must match Fact A from the training script exactly — see contract comment above.
double _normalizePixel(int raw0to255) {
  // RAW_0_255:
  return raw0to255.toDouble();

  // RAW_0_1:
  // return raw0to255 / 255.0;

  // SCALED_NEG1_1:
  // return (raw0to255 / 255.0 - 0.5) * 2.0;

  // IMAGENET (mean/std must match the channel you're calling this for — see note below):
  // return (raw0to255 / 255.0 - mean) / std;
}
```

> If Fact A is IMAGENET, `_normalizePixel` needs a `channelIndex` parameter (0=R, 1=G, 2=B) because mean/std differ per channel. Use:
> ```dart
> static const _mean = [0.485, 0.456, 0.406];
> static const _std  = [0.229, 0.224, 0.225];
> double _normalizePixel(int raw0to255, int channelIndex) =>
>     (raw0to255 / 255.0 - _mean[channelIndex]) / _std[channelIndex];
> ```

Then in **both** `runInference` and `runInferenceFromPreprocessed`, replace every inline normalization expression (the `(pixel.r / 255.0 - 0.485) / 0.229` type lines, for every channel, in every `if (inputType == ...)` branch) with a call to `_normalizePixel(...)`. Do not write the formula out by hand anywhere else in the file. If you find yourself typing `/255.0` or `-0.5` or `0.229` a second time anywhere in this file, stop — you should be calling the shared function instead.

For the int8 quantization step that follows normalization, keep the existing pattern (this part is already correct — it reads the tensor's real `scale`/`zeroPoint` instead of hardcoding them):
```dart
flatList.add((_normalizePixel(r) / inScale).round() + inZeroPoint);
```

## STEP 2 — Fix `image_ingestion_service.dart`: comment must match Step 0's answer

Find this comment in `_runPreprocessPipeline`:
```dart
// F. Extract raw uint8 pixels in NHWC format
// No normalization needed — TFLite model expects raw pixels [0-255]
```

Replace it with a comment stating the actual agreed convention from Step 0, e.g.:
```dart
// F. Extract raw uint8 pixels in NHWC format.
// NOTE: these are RAW 0-255 bytes. Normalization happens later, in
// OptiXAIEngine._normalizePixel() in edge_inference.dart — see the
// CONFIRMED MODEL CONTRACT comment at the top of that file.
// Do not normalize here — do not change this function to output floats.
```
Do not change the actual pixel extraction code in this file — it should keep outputting raw 0–255 `uint8` RGB bytes regardless of which convention Step 0 found. All normalization happens in one place: `edge_inference.dart`, in `_normalizePixel`. This file's only job is decode → clean → resize → hand off raw bytes.

## STEP 3 — Fix the softmax question in `edge_inference.dart`

Look at `_postProcess(List<double> rawProbs)`. Based on Fact B from Step 0:

- **If `has_softmax = true`:** do nothing here, `rawProbs` are already valid probabilities that sum to ~1.0.
- **If `has_softmax = false`:** `rawProbs` are raw logits and must be converted before any threshold comparison. Add this method back to the class:
  ```dart
  List<double> _softmax(List<double> logits) {
    final maxLogit = logits.reduce((a, b) => a > b ? a : b);
    final expLogits = logits.map((l) => exp(l - maxLogit)).toList();
    final sumExp = expLogits.reduce((a, b) => a + b);
    return expLogits.map((e) => e / sumExp).toList();
  }
  ```
  and change both call sites from:
  ```dart
  return _postProcess(rawProbs);
  ```
  to:
  ```dart
  return _postProcess(_softmax(rawProbs));
  ```
  (`import 'dart:math'` is already present in the file for `exp`/`max`, keep it.)

## STEP 4 — Replace the broken class-selection logic in `_postProcess`

Delete this block entirely — it is mathematically wrong and must not be used in any form:
```dart
for (int i = 0; i < 5; i++) {
  double adjustedConfidence = rawProbs[i] / _calibratedThresholds[i];
  if (adjustedConfidence > maxConfidence) {
    maxConfidence = adjustedConfidence;
    predictedGrade = i;
  }
}
```

Replace it with this exact two-step rule: plain argmax first, then allow the calibrated thresholds to escalate the grade by **at most one level**, and only when there's real evidence for the escalation. Do not implement any version that lets a threshold pick a class ranked below the argmax winner, and do not implement any version that compares two different classes' probabilities against each other's thresholds.

```dart
Map<String, dynamic> _postProcess(List<double> rawProbs) {
  // Step A: plain argmax — the model's single most likely class.
  int predictedGrade = 0;
  double maxConfidence = rawProbs[0];
  for (int i = 1; i < 5; i++) {
    if (rawProbs[i] > maxConfidence) {
      maxConfidence = rawProbs[i];
      predictedGrade = i;
    }
  }

  // Step B: calibrated-threshold escalation.
  // If the class ONE SEVERITY LEVEL ABOVE the argmax winner clears its own
  // calibrated threshold, escalate to it. This exists because the model
  // under-calls certain severe classes — see _calibratedThresholds comment.
  // It never escalates by more than one level and never overrides argmax
  // in favor of a LOWER severity class.
  final nextGrade = predictedGrade + 1;
  if (nextGrade <= 4 && rawProbs[nextGrade] >= _calibratedThresholds[nextGrade]) {
    predictedGrade = nextGrade;
  }

  bool isReferable = predictedGrade >= 2;
  bool isUrgentRefer = predictedGrade >= 3;
  double urgentReferConfidence = rawProbs[3] + rawProbs[4];

  return {
    'dr_grade': predictedGrade,
    'is_referable': isReferable,
    'is_urgent_refer': isUrgentRefer,
    'urgent_refer_confidence': urgentReferConfidence,
    'confidence_score': rawProbs[predictedGrade],
    'raw_probabilities': rawProbs,
  };
}
```

**Do not deviate from this shape.** In particular:
- Do not divide any `rawProbs[i]` by any `_calibratedThresholds[i]` anywhere in this file.
- Do not loop over all 5 classes picking whichever clears its threshold with no relationship to the argmax winner.
- `confidence_score` must always be `rawProbs[predictedGrade]` — the actual probability of the grade you're reporting, computed *after* Step B, not before it.

> If a human later hands you the real Python `apply_calibrated_thresholds` function and it does something different from Step B above, implement that instead of this — this is a safe placeholder, not a substitute for the real calibration logic. Flag the discrepancy rather than silently picking one.

## STEP 5 — Verification checklist (do this after the code changes, before saying you're done)

Write a small standalone Dart test (or a scratch `main()`) that does NOT touch the interpreter, and just calls `_postProcess` directly with hand-picked `rawProbs` lists, to confirm the logic behaves as intended. `_postProcess` and `_calibratedThresholds` are private — either temporarily make them `@visibleForTesting` or copy the function body into a test file. Check these cases:

1. `[0.10, 0.05, 0.80, 0.03, 0.02]` → expect `dr_grade = 2` (clear argmax winner, no escalation needed).
2. `[0.10, 0.40, 0.45, 0.03, 0.02]` → expect `dr_grade = 2` (argmax is already 2; this is the exact case that was broken before — confirm it no longer drops to grade 1).
3. `[0.60, 0.05, 0.05, 0.15, 0.15]` → argmax is grade 0. Check whether grade 1 clears `_calibratedThresholds[1] = 0.35` — it doesn't (0.05 < 0.35) — expect `dr_grade = 0`, unescalated.
4. Construct one case where the argmax winner is grade `i` and `rawProbs[i+1] >= _calibratedThresholds[i+1]` — confirm it escalates by exactly one level and no more, even if `rawProbs[i+2]` is also high.
5. Confirm `sum(rawProbs)` is close to `1.0` for every test input if `has_softmax = true` was confirmed in Step 0 — if it isn't, something upstream (Step 3) is wrong.
6. In `_normalizePixel`, feed `raw0to255 = 0` and `raw0to255 = 255` and print the output — sanity-check the numbers are in the range the convention from Step 0 implies (e.g. RAW_0_1 should print `0.0` and `1.0`; SCALED_NEG1_1 should print `-1.0` and `1.0`).

Do not mark this work complete until all six checks pass and the contract comment from Step 0 is in place in both files.
