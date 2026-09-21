# OptiXAI — Follow-Up Instructions: Calibration Logic & Verified Testing

Read this fully before making any changes. It responds to two things you reported: the contents
of `apply_calibrated_thresholds` in `calibrate_thresholds.py`, and a test transcript for
`_postProcess`. Neither is being accepted as-is — here is exactly what to do about each, and why.

---

## PART A — Do NOT port the Python threshold logic into Dart. Here is why, precisely.

You found that `calibrate_thresholds.py` does this:

```python
adjusted_probs = y_probs / (thresholds + 1e-7)
predictions = np.argmax(adjusted_probs, axis=1)
```

and that `thresholds` comes from per-class one-vs-rest (OVR) ROC curves, each independently
optimized via Youden's J statistic.

**This is a bug in the Python script, not a spec to copy.** Do not change `_postProcess` in
`edge_inference.dart` to match it. Here is the reasoning, so you can explain it if anyone asks:

- Youden's J for class `i` answers one question in isolation: *"if I only had to decide
  class-`i`-vs-everything-else, what probability cutoff best balances true and false positive
  rates for that one binary decision?"* It says nothing about how class `i`'s probability compares
  to class `j`'s probability. The five thresholds were never computed to be comparable to each
  other.
- Dividing five unrelated probabilities by five unrelated, independently-derived cutoffs and
  taking `argmax` of the ratios does not produce a valid multiclass decision rule. It reintroduces
  exactly the failure mode already identified in this project: a class with a low threshold can
  win against a class with a much higher raw probability, with no relationship to which class the
  model actually believes is most likely.
- Concrete proof, reuse this exact check: `y_probs = [0.10, 0.40, 0.45, 0.03, 0.02]`,
  `thresholds = [0.45, 0.35, 0.40, 0.55, 0.50]`. Argmax of raw probs is class 2 (0.45, clearly the
  model's top belief). Argmax of `probs/thresholds` is class 1 (`0.40/0.35 ≈ 1.143` beats
  `0.45/0.40 = 1.125`). The proportional-division rule silently overturns the model's own most
  confident prediction. That is the bug, demonstrated numerically, not a matter of opinion.

**What to actually do:**

1. **Leave `_postProcess` in `edge_inference.dart` exactly as it currently is** — plain argmax,
   then single-level escalation gated on the next-highest class clearing its own threshold. Do not
   revert it, do not add the proportional-division version anywhere in the Dart codebase, even
   behind a flag or as a commented-out alternative.
2. **Create a new file** `docs/calibration_script_bug_report.md` in the project root (create the
   `docs/` folder if it doesn't exist) containing:
   - The exact Python snippet you found, verbatim, with file name and line numbers.
   - The explanation above (OVR thresholds are not mutually comparable; division does not fix
     that).
   - The worked numeric counterexample above.
   - One sentence stating that the Dart app does NOT implement this logic and instead uses
     argmax + single-level escalation, and why (link back to this file if useful).
   - A closing line: "This needs a decision from whoever owns calibrate_thresholds.py: either
     retire the proportional-division selection rule and keep the OVR thresholds only as
     single-class gates (matching the Dart app's current behavior), or redesign the multiclass
     decision rule with a method that's actually valid for combining per-class thresholds (for
     example: pick the highest class whose own threshold is cleared, ties broken by probability
     — not a cross-class ratio)."
3. Do not close this out or mark it resolved yourself. This is a flag for a human model-owner
   decision, not something you should silently choose a side on beyond what step 1 already fixed
   in the Dart code.

---

## PART B — Get one real, verifiable test run. Follow this exactly, no summarizing.

The previous test transcript is not being accepted because the test file as reported contains a
syntax error (`static` used on a local variable inside `main()`, which is illegal in Dart — it
only works on class members) and the transcript claims both a crash and a final passing tally in
the same run, which cannot both be true. Do not attempt to explain or patch around this — just
redo it correctly, following these exact steps, and show the true output.

1. In the project root, confirm there is a `test/` directory at the same level as `lib/`. If not,
   create one: `mkdir -p test`.
2. Create `test/postprocess_test.dart` with the content below. Copy it exactly — do not
   restructure it, do not move any declaration outside of `main()`, do not use `static` anywhere
   in this file.

```dart
import 'package:flutter_test/flutter_test.dart';

// --- Inlined copies for isolated testing. Keep these in sync with edge_inference.dart. ---

const List<double> calibratedThresholds = [0.45, 0.35, 0.40, 0.55, 0.50];

const List<double> imagenetMean = [0.485, 0.456, 0.406];
const List<double> imagenetStd = [0.229, 0.224, 0.225];

double normalizePixel(int raw0to255, int channelIndex) =>
    (raw0to255 / 255.0 - imagenetMean[channelIndex]) / imagenetStd[channelIndex];

Map<String, dynamic> postProcess(List<double> rawProbs) {
  int predictedGrade = 0;
  double maxConfidence = rawProbs[0];
  for (int i = 1; i < 5; i++) {
    if (rawProbs[i] > maxConfidence) {
      maxConfidence = rawProbs[i];
      predictedGrade = i;
    }
  }

  final nextGrade = predictedGrade + 1;
  if (nextGrade <= 4 && rawProbs[nextGrade] >= calibratedThresholds[nextGrade]) {
    predictedGrade = nextGrade;
  }

  return {
    'dr_grade': predictedGrade,
    'is_referable': predictedGrade >= 2,
    'is_urgent_refer': predictedGrade >= 3,
    'urgent_refer_confidence': rawProbs[3] + rawProbs[4],
    'confidence_score': rawProbs[predictedGrade],
    'raw_probabilities': rawProbs,
  };
}

void main() {
  group('postProcess', () {
    test('case 1: clean argmax winner, no escalation', () {
      final result = postProcess([0.10, 0.05, 0.80, 0.03, 0.02]);
      expect(result['dr_grade'], 2);
    });

    test('case 2: argmax must not be hijacked by a lower-threshold class', () {
      final result = postProcess([0.10, 0.40, 0.45, 0.03, 0.02]);
      expect(result['dr_grade'], 2);
    });

    test('case 3: next class does not clear its threshold, no escalation', () {
      final result = postProcess([0.60, 0.05, 0.05, 0.15, 0.15]);
      expect(result['dr_grade'], 0);
    });

    test('case 4: escalates by exactly one level when next class clears threshold', () {
      final result = postProcess([0.60, 0.36, 0.41, 0.02, 0.01]);
      expect(result['dr_grade'], 1);
    });

    test('case 5: probabilities sum to ~1.0 (softmax contract check)', () {
      final probs = [0.10, 0.05, 0.80, 0.03, 0.02];
      final sum = probs.reduce((a, b) => a + b);
      expect(sum, closeTo(1.0, 0.001));
    });
  });

  group('normalizePixel', () {
    test('case 6: red channel at 0 and 255 map into the expected ImageNet range', () {
      final low = normalizePixel(0, 0);
      final high = normalizePixel(255, 0);
      expect(low, lessThan(0));
      expect(high, greaterThan(0));
      expect(low, closeTo(-2.118, 0.01));
      expect(high, closeTo(2.249, 0.01));
    });
  });
}
```

3. Run it from the project root with:
   ```
   flutter test test/postprocess_test.dart
   ```
   (If this is a pure-Dart package with no Flutter dependency, use `dart test` instead and swap
   the import to `package:test/test.dart` — but keep everything else identical.)
4. **Paste the complete, unedited terminal output** — every line, from the command invocation to
   the final summary — into the next message. Do not summarize it, do not say "all tests passed"
   in your own words instead of showing the output, and do not omit anything even if part of it
   looks like unrelated build/toolchain noise. If the command fails or errors before producing
   test results, paste that failure output too, in full — a failure is a valid and useful answer
   here, silence or a rewritten summary is not.
5. If any test fails, do not edit the test file to make it pass. Report the failure as-is and stop
   — a failing test here means either `edge_inference.dart`'s actual `_postProcess` has drifted
   from this inlined copy, or one of the expected values above needs to be revisited together, not
   silently patched.

---

## What "done" looks like for this follow-up

- `docs/calibration_script_bug_report.md` exists with the four required parts from Part A, step 2.
- `edge_inference.dart`'s `_postProcess` is unchanged from its current argmax + single-escalation
  form.
- `test/postprocess_test.dart` exists exactly as specified above.
- The next message contains the full, real, copy-pasted terminal output of running it — not a
  reconstruction, not a summary, not a table of results typed out by hand.
