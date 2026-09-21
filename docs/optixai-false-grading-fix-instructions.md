# OptiXAI — Fix Instructions: False Grading Bug

Follow these steps in order. Each is independent and verifiable separately.
Do not combine or reorder them.

---

## Root cause summary (read before touching any code)

The screenshot shows Left Eye: Grade 4 at 31.5% confidence. That 31.5% tells
us the model is highly uncertain — probability is spread across all 5 classes,
with Grade 4 winning argmax at only 0.315. This is not a math error in
normalisation. The normalisation in both inference paths is mathematically
correct for ImageNet RGB order. The false grading is caused by two things:

1. Gallery images bypass the OpenCV preprocessing pipeline entirely and go
   through `runInference()` instead of `runInferenceFromPreprocessed()`. The
   model was trained on images that went through CLAHE, Gaussian denoising, and
   contour auto-crop. A raw gallery image looks completely different to the
   model — it outputs garbage probabilities as a result.

2. The calibrated escalation thresholds are too permissive, especially for
   Grade 1 (0.35) and Grade 2 (0.40). On an already-uncertain prediction,
   these cause over-escalation to higher severity grades.

Fix A is the primary cause of the bug you are seeing. Fix B reduces
over-escalation. Fix C corrects a misleading confidence display. Fix D removes
dead code left over from a deleted branch.

---

## FIX A — Route ALL image inputs through the OpenCV pipeline (critical)

### What to find

In whatever screen or provider calls inference after the user picks an image
from the gallery (likely your screening screen, an image picker callback, or
a provider method), find the call that looks like this:

```dart
final result = engine.runInference(imageBytes);
```

This is the wrong path for any image that will be shown to the model. It uses
only the `image` package's basic bilinear resize with no CLAHE, no denoising,
and no contour crop. The model has never seen images preprocessed this way —
its training pipeline always ran the full OpenCV stack.

### What to change

Replace every call to `engine.runInference(imageBytes)` in your screening or
inference flow with this two-step sequence:

```dart
// Step 1: run the full clinical preprocessing pipeline (CLAHE, denoise, crop)
final preprocessed = await ImageIngestionService().processImage(
  imageBytes,
  ImageSourceType.upload,   // use .upload for gallery picks
);

// Step 2: run inference on the preprocessed buffer
final result = engine.runInferenceFromPreprocessed(preprocessed);
```

`ImageIngestionService().processImage()` runs inside a Flutter Isolate
automatically — you do not need to wrap it in `compute()` yourself. It returns
a `Uint8List` of 224×224×3 raw uint8 pixels in RGB order, which is exactly
what `runInferenceFromPreprocessed` expects.

### What NOT to do

Do not delete `runInference`. It is still the correct path if you ever add a
live camera capture path that has already been preprocessed outside Dart. Just
make sure no gallery or file-pick code path reaches it.

### Verification

After the change, run the app and pick the same left-eye image that showed
Grade 4. The output should shift significantly — a visually healthy fundus
should score Grade 0 or 1. If it still scores Grade 4 with similar confidence,
add this temporary debug print inside `_postProcess` before the return
statement:

```dart
print('[rawProbs] $rawProbs');
print('[sum] ${rawProbs.reduce((a, b) => a + b)}');
```

Confirm the sum is between 0.98 and 1.02. If it is not, softmax is not baked
into the TFLite graph and you need to re-export the model — but fix the
routing first and re-check, because that is almost certainly the only issue.
Remove the debug prints before shipping.

---

## FIX B — Tighten the calibrated escalation thresholds

### File: `edge_inference.dart`

### What to find

```dart
final List<double> _calibratedThresholds = [0.45, 0.35, 0.40, 0.55, 0.50];
```

### The problem

These thresholds govern when the model escalates its argmax prediction by one
severity grade. The logic is: if the class one step above the argmax clears its
own threshold, escalate to it.

The current values are:
- Grade 0 → escalates to Grade 1 if rawProbs[1] >= 0.35
- Grade 1 → escalates to Grade 2 if rawProbs[2] >= 0.40
- Grade 2 → escalates to Grade 3 if rawProbs[3] >= 0.55
- Grade 3 → escalates to Grade 4 if rawProbs[4] >= 0.50
- Grade 4 → no escalation possible (ceiling)

A threshold of 0.35 for Grade 1 means any image where the model assigns 35%+
probability to Grade 1 gets escalated there from Grade 0, even when the model
is highly uncertain. On a confused, unpreprocessed input this fires constantly.

After Fix A is in place, the model will be far more confident on well-
preprocessed inputs, but the thresholds still need to be tighter to avoid
clinical false positives, especially for the urgent-referral tier.

### What to change

```dart
final List<double> _calibratedThresholds = [0.45, 0.55, 0.55, 0.65, 0.70];
```

Explanation of each value:
- `0.45` for grade 0 is unused (there is no grade -1 to escalate from), keep
  as-is.
- `0.55` for Grade 1: a grade-0 image escalates to Grade 1 only if the model
  assigns 55%+ to Grade 1. This is a meaningful signal.
- `0.55` for Grade 2: same reasoning for grade-1 → grade-2 escalation.
- `0.65` for Grade 3: escalation into the urgent referral tier requires a
  strong signal.
- `0.70` for Grade 4: the model has only 35–37% accuracy on Grade 4 and
  confuses it heavily with Grade 3. The comment in the code acknowledges this.
  A 70% threshold means escalation to PDR only fires when the model is highly
  confident, which is rare and appropriate.

These are starting values. They should be re-calibrated against your validation
set once Fix A is in place and you have stable, preprocessed outputs to work
with.

### Verification

With the same left-eye gallery image from the screenshot (after Fix A is also
applied), confirm that the output does not escalate a borderline Grade 0 or
Grade 1 prediction to Grade 4. If you have labelled test images, run them
through and confirm no Grade 0 ground truth is returned as Grade 3 or Grade 4.

---

## FIX C — Fix the confidence score returned after escalation

### File: `edge_inference.dart`

### What to find

In `_postProcess`, the escalation block and the return statement:

```dart
final nextGrade = predictedGrade + 1;
if (nextGrade <= 4 && rawProbs[nextGrade] >= _calibratedThresholds[nextGrade]) {
  predictedGrade = nextGrade;
}

// DR severity >= 2 indicates referable DR
bool isReferable = predictedGrade >= 2;
bool isUrgentRefer = predictedGrade >= 3;
double urgentReferConfidence = rawProbs[3] + rawProbs[4];

// ...

return {
  'dr_grade': predictedGrade,
  'is_referable': isReferable,
  'is_urgent_refer': isUrgentRefer,
  'urgent_refer_confidence': urgentReferConfidence,
  'confidence_score': rawProbs[predictedGrade],   // ← this line
  'raw_probabilities': rawProbs,
};
```

### The problem

After escalation, `predictedGrade` has been mutated to the escalated grade.
`rawProbs[predictedGrade]` therefore returns the escalated grade's raw
probability — which is the threshold that triggered escalation, not the
model's primary confidence signal. In the screenshot, Grade 4 at 31.5% is
already the argmax (escalation did not fire there), but once escalation does
fire in other cases, you will display the escalation-trigger probability as
the confidence, which is always lower than the argmax probability. This makes
the UI show "Grade 3, 38% confidence" when the model actually scored Grade 2
at 60% — the clinician sees a lower-confidence higher-grade result and cannot
understand why.

The fix is to capture the argmax confidence before mutation and return that
alongside the final grade.

### What to change

Replace the entire `_postProcess` method with this:

```dart
Map<String, dynamic> _postProcess(List<double> rawProbs) {
  // Step A: argmax — the model's single most likely class.
  int predictedGrade = 0;
  double maxConfidence = rawProbs[0];
  for (int i = 1; i < 5; i++) {
    if (rawProbs[i] > maxConfidence) {
      maxConfidence = rawProbs[i];
      predictedGrade = i;
    }
  }

  // Capture the argmax confidence before any escalation mutates predictedGrade.
  // This is the model's raw best-guess confidence and is what we display to
  // the clinician. It is always the highest single-class probability.
  final double argmaxConfidence = maxConfidence;

  // Step B: calibrated-threshold escalation.
  // Only escalates by one level, and only upward.
  final nextGrade = predictedGrade + 1;
  if (nextGrade <= 4 && rawProbs[nextGrade] >= _calibratedThresholds[nextGrade]) {
    predictedGrade = nextGrade;
  }

  bool isReferable = predictedGrade >= 2;

  // Grade 3 (Severe NPDR) and Grade 4 (PDR) both require immediate referral.
  // The model confuses these two at 35–37% accuracy so they are grouped.
  bool isUrgentRefer = predictedGrade >= 3;

  // Combined urgency signal: sum of Grade 3 + Grade 4 probabilities.
  // Remains high even when the model misclassifies 4→3.
  double urgentReferConfidence = rawProbs[3] + rawProbs[4];

  print('[OptiXAI Debug] rawProbs: $rawProbs');
  print('[OptiXAI Debug] predictedGrade: $predictedGrade');
  print('[OptiXAI Debug] argmaxConfidence: $argmaxConfidence');

  return {
    'dr_grade': predictedGrade,
    'is_referable': isReferable,
    'is_urgent_refer': isUrgentRefer,
    'urgent_refer_confidence': urgentReferConfidence,
    'confidence_score': argmaxConfidence,  // always the model's top-class confidence
    'raw_probabilities': rawProbs,
  };
}
```

The only structural change is the `argmaxConfidence` capture before the
escalation block, and using it in the return map instead of
`rawProbs[predictedGrade]`. Everything else is identical to the original.

### Verification

Test a case where escalation fires (a borderline image where the next grade's
probability clears the threshold). Confirm the displayed confidence matches
the argmax probability, not the escalated grade's probability.

---

## FIX D — Remove dead glare-removal variables

### File: `image_ingestion_service.dart`

### What to find

At the top of `_runPreprocessPipeline`, these four variables are declared:

```dart
cv.Mat? maskedImg;
cv.Mat? glareGray;
cv.Mat? glareMask;
cv.Mat? glareKernel;
```

They are never assigned after the glare-removal branch was deleted. They only
appear again in the `finally` block:

```dart
} finally {
  img?.dispose();
  gray?.dispose();
  thresh?.dispose();
  mask?.dispose();
  glareGray?.dispose();
  glareMask?.dispose();
  glareKernel?.dispose();
  lab?.dispose();
  resized?.dispose();
}
```

Calling `dispose()` on a null `cv.Mat?` is safe and does not crash, so this
causes no functional bug. But it is dead code that will confuse future readers
into thinking glare removal is happening.

### What to change

Remove the four variable declarations at the top of `_runPreprocessPipeline`:

```dart
// DELETE these four lines:
cv.Mat? maskedImg;
cv.Mat? glareGray;
cv.Mat? glareMask;
cv.Mat? glareKernel;
```

And remove the three corresponding dispose calls in the `finally` block:

```dart
// DELETE these three lines from the finally block:
glareGray?.dispose();
glareMask?.dispose();
glareKernel?.dispose();
```

Note: `mask?.dispose()` in the finally block refers to `cv.Mat? mask` which
IS a live variable declared and used in the method. Do not remove that line.
Only remove the three glare-specific ones listed above.

`maskedImg` is also declared but has no corresponding dispose call — simply
remove its declaration.

### Verification

The method should compile and behave identically after this change. Run the
same inference test from Fix A to confirm output is unchanged.

---

## What NOT to do in this pass

- Do not touch `sync_service.dart` or `local_database.dart` — those fixes are
  already applied and verified separately.
- Do not touch `providers.dart`.
- Do not change the IQA thresholds (`_blurThreshold`, `_illuminationMin`,
  `_illuminationMax`, `_minCircleRadiusFraction`) in `image_ingestion_service.dart`.
- Do not change the TFLite model file or interpreter options.
- Do not add any UI changes. This is inference logic only.
- Do not delete `runInference` from `edge_inference.dart`. Only stop calling it
  from gallery/file-pick code paths.

---

## What "done" looks like

- The same left-eye gallery image that previously returned Grade 4 / Urgent
  Referral at 31.5% now returns a grade consistent with its visual appearance
  after going through the full OpenCV pipeline.
- The debug print added in Fix A verification confirms rawProbs sum is between
  0.98 and 1.02 (softmax is baked in, output is valid probability distribution).
- No healthy fundus image returns Grade 3 or Grade 4.
- The confidence percentage displayed in the UI reflects the model's argmax
  probability, not the escalation-trigger probability.
- The four dead glare-removal variables are gone and the code compiles cleanly.
