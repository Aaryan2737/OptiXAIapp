# OptiXAI: Agent Task Brief — Fix inaccurate DR grading

Follow this brief in order. Stop at every **STOP** gate, report, and wait for the human.

## 0. Rules (non-negotiable)

1. **Never invent, estimate, or "expect" model outputs.** If you cannot run something (no device, no Python deps, no images), say so and ask the human to run it and paste the output.
2. **Smallest change that does the job.** No refactors, renames, formatting sweeps, dependency upgrades, or UI changes.
3. **Do not tune thresholds, preprocessing constants, or IQA constants to make the specific test images pass.** Any such change needs evidence from a labelled set and the human's approval.
4. **Do not touch** `sync_service.dart`, `local_database.dart`, `providers.dart`, or any Supabase URL/key. Do not paste keys into your reports.
5. Mark all temporary code with `// TEMP-DIAG` so it can be found and removed. Patient-related logging must not remain in the final build.
6. After every code change run `flutter analyze` and include the result in your report.
7. Do not commit. Leave changes in the working tree so the human can review the diff.

## 1. Context (already established — do not re-investigate)

- Flutter app that grades fundus images (DR grades 0–4) on-device. Model: `assets/models/optixai_dr_model.tflite`, 224×224, 5 outputs, **softmax is already in the graph**.
- `image_ingestion_service.dart`: OpenCV pipeline in an isolate (contour crop → 3×3 Gaussian blur → CLAHE on LAB L channel → bicubic resize 224×224 → BGR→RGB). Returns 224×224×3 **raw uint8 RGB** bytes. It must not normalise.
- `edge_inference.dart`: `runInferenceFromPreprocessed()` applies ImageNet normalisation `(x/255 − mean)/std`, mean `[0.485, 0.456, 0.406]`, std `[0.229, 0.224, 0.225]` in RGB order, then runs the model. This matches the training contract.
- Camera and gallery images are meant to follow the same path: `processImage()` → `runInferenceFromPreprocessed()`. `runInference()` is believed to be unused by the UI (verify with grep, see Phase 1).
- **The threshold-escalation block in `_postProcess` is dead code.** It only fires if `P(next grade) ≥ threshold` while the current grade is the argmax. With any threshold ≥ 0.5 that is impossible (the two probabilities would sum past 1). All current thresholds for grades 1–4 are ≥ 0.55. So the app currently outputs plain argmax. Do not "fix" this by editing thresholds.

**Symptoms**
- Visibly severe fundus pair (uploaded from gallery) → app shows Grade 0 at 99.2% (left) and 85.9% (right), "NORMAL".
- Healthy pair → Grade 0 at 71.1% and Grade 1 at 54.7%.
- Earlier: a healthy gallery image showed Grade 4 at 31.5%. The root cause of that was never found.

**Unknowns (this is your job to resolve)**
1. Does the app's input tensor layout match the model? Code assumes NHWC `[1,224,224,3]`.
2. Does the app's preprocessing output match the Python/training pipeline for the same file?
3. If both match, is the model itself unreliable on these images?

**Goal:** grading that is accurate for gallery and camera images alike, established with evidence, not by guessing.

## 2. Phase 1 — Diagnose (no logic changes)

1. Grep to confirm `runInference(` has no callers outside `edge_inference.dart`. Also grep for any remaining `print(` / `debugPrint(` that logs probabilities or patient data. Report findings.
2. Add temporary logging (`// TEMP-DIAG`, wrapped in `kDebugMode`, import `package:flutter/foundation.dart`):
   - In `initializeModel()`, after the interpreter is created, log input tensor shape + type and output tensor shape + type.
   - At the top of `_postProcess`, log `rawProbs`.
3. Ask the human for: (a) the **exact original files** of the severe pair and the healthy pair (not screenshots; not WhatsApp-recompressed copies unless those are what will be used), (b) the model export method (e.g. PyTorch → TFLite), (c) the output of `calibrate_thresholds.py`. Do not proceed without (a).
4. Get the same file bytes onto the phone (e.g. `adb push`) so the app and Python read identical bytes.
5. Set up Python (`pip install numpy opencv-python tensorflow`, or `tflite-runtime`). Run:
   `python parity_eval.py --model assets/models/optixai_dr_model.tflite --images <severe_left> <severe_right> <healthy_left> <healthy_right> --dump-dir dumped`
   Capture the full output, especially the `model input shape` line and any `WARNING`.
6. Run the same files through the app (debug build) and capture the `rawProbs` lines from logcat (`adb logcat | grep -i rawProbs`).

**STOP.** Report: tensor shapes/types, Python probabilities per image, app `rawProbs` per image, and which decision-table row below applies. Do not continue until the human confirms.

## 3. Phase 2 — Act on the diagnosis

| Finding | Action |
|---|---|
| Input tensor type is not float32 | STOP. Tell the human. Do not modify anything. |
| Input shape is `[1,3,224,224]` (NCHW) | Apply the NCHW fix below to `runInferenceFromPreprocessed`. Re-run the app on the same files and compare with the script's *correct* (non-"as-app") probabilities. |
| Shape is NHWC, but app `rawProbs` differ from Python by more than ~0.02 per class on the same file | Preprocessing mismatch. Dump the app's 224×224 output for one image (debug only, `// TEMP-DIAG`; e.g. encode with the `image` package and write a PNG, then `adb pull`) and pixel-diff it against the script's `dumped/*.png`. Find the first stage that differs and change **only that stage** so it matches Python. Small differences from JPEG decoding are normal; large ones are bugs. |
| App ≈ Python, and Python gives sensible grades on the severe images, but the app UI showed Grade 0 | The app fed a different image than expected. In `capture_screen.dart`, log length + a hash of the bytes given to `processImage()` for each eye and check left/right are not swapped or stale. |
| App ≈ Python, and both say Grade 0 / low grades on the severe images | **This is a model/data problem, not a code bug. Make no code changes.** Do not adjust preprocessing or thresholds to compensate. Report to the human. |

**NCHW fix** (apply only if the shape is NCHW; do not apply to NHWC). Add to `OptiXAIEngine` and use it in the float32 branch of `runInferenceFromPreprocessed`, replacing the manual loop:

```dart
List<double> _toFloatInput(Uint8List rgb, List<int> shape) {
  final bool nchw = shape.length == 4 && shape[1] == 3 && shape[3] != 3;
  final int n = rgb.length ~/ 3;
  final out = List<double>.filled(rgb.length, 0.0);
  for (int p = 0; p < n; p++) {
    for (int c = 0; c < 3; c++) {
      final v = _normalizePixel(rgb[p * 3 + c], c);
      out[nchw ? c * n + p : p * 3 + c] = v;
    }
  }
  return out;
}
// float32 branch:
reshapedInput = _toFloatInput(preprocessedData, inputShape).reshape<double>(inputShape);
```

Leave the unused `runInference()` alone (add a comment that it is unused and lacks the OpenCV pipeline).

**Thresholds:** only change `_calibratedThresholds` if the human supplies the output of `calibrate_thresholds.py`. Use those exact values. Never pick values yourself.

**STOP.** Report the diff, `flutter analyze` result, and before/after `rawProbs` for the four test files. Wait for the human.

## 4. Phase 3 — Validate (needed before anyone calls grading "accurate")

Ask the human for a labelled set (≥ 20–30 images across grades 0–4, including several grade 3–4, from more than one source or camera). Run:
`python parity_eval.py --model ... --image-dir <dir> --labels labels.csv`
Report the confusion matrix and referable-DR (grade ≥ 2) sensitivity/specificity. Do not claim accuracy beyond what this shows.

Do **not** implement a new referral rule or a "low confidence / needs review" state yet. If you think one is needed, describe it in your report and let the human decide.

## 5. Phase 4 — Cleanup (after the human approves the fix)

1. In `capture_screen.dart` (~line 374, "Upload from Gallery" `onPressed`): change `_onPhotoTaken(bytes, ImageSourceType.upload);` to `await _onPhotoTaken(bytes, ImageSourceType.upload);`.
2. Remove every `// TEMP-DIAG` line. Grep to confirm none remain, and that no `print(` logs `rawProbs`, `predictedGrade`, or patient data.
3. `flutter analyze` must report no issues.

## 6. Report format (every STOP)

- What you ran (exact commands) and the raw output, pasted, not summarised.
- Files changed, with the diff.
- What you did **not** do or could not verify.
- The decision you need from the human.
