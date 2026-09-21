# OptiXAI — Follow-Up: Isolate the Logic Test from the Native Build

## Why the last run failed

`flutter test test/postprocess_test.dart` failed before running a single test, with:

```
Exception: Failed to find cmake version: latest
...
Building native assets failed.
```

This is a real, legitimate failure — not something to patch around or explain away. Here's what
it means: `flutter test` resolves and builds native assets for the whole project's dependency
graph before running anything, and `opencv_dart` (via its `dartcv4` native build hook) is a
dependency of this project because `image_ingestion_service.dart` uses it elsewhere. The Windows
machine doesn't have a Visual Studio toolchain or a `cmake` matching the version the hook wants, so
the native build step fails — before `flutter test` ever gets to `postprocess_test.dart`.

**Important: `postprocess_test.dart` does not import `opencv_dart` or anything native.** It only
tests `postProcess` and `normalizePixel`, two pure Dart functions with no dependency on the camera
pipeline. We are blocked by a build requirement that has nothing to do with the code being tested.
Do not try to install Visual Studio Build Tools or fix the cmake toolchain to solve this — that's
solving a much bigger problem (getting the full app to build on this machine) than the one in
front of us (verifying two functions). Instead, isolate the test.

## What to do: create a standalone Dart package for this test

1. Outside the Flutter app's directory (a sibling folder, not nested inside `lib/` or the existing
   `optixai_flutter_app/`), create a new plain Dart package:
   ```
   mkdir logic_verification
   cd logic_verification
   dart create -t package .
   ```
   If `dart create` prompts or scaffolds extra files you don't need, that's fine — leave them.

2. Open the generated `pubspec.yaml` in `logic_verification/` and make sure `dev_dependencies`
   includes only:
   ```yaml
   dev_dependencies:
     test: ^1.24.0
   ```
   Do **not** add `flutter_test`, `opencv_dart`, or any Flutter/Android/native dependency to this
   package. That's the entire point — it must not be able to trigger a native build.

3. Delete anything under `logic_verification/lib/` and `logic_verification/test/` that
   `dart create` scaffolded by default (the sample "calculator" style files), so the package
   starts clean.

4. Create `logic_verification/test/postprocess_test.dart` with this content — same logic as
   before, but the import changed from `flutter_test` to plain `test` since this package has no
   Flutter dependency at all:

```dart
import 'package:test/test.dart';

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

5. From inside `logic_verification/`, run:
   ```
   dart pub get
   dart test
   ```
   This package has no native dependencies at all, so there is nothing for a build hook to fail
   on. If this still fails, the failure is worth reporting in full, in the same way as before —
   but it should not be a cmake/native-asset error, since nothing here depends on native code.

6. Paste the complete, unedited terminal output of both commands into the next message — same
   rule as last time: no summarizing, no "all tests passed" in your own words, every line as
   printed, including if something unexpected happens.

## One thing to flag, not fix, in the same message

Note in your reply (don't act on it) that the app's real toolchain — the one needed to eventually
run the *actual* app and its full test suite on this Windows machine — is still missing a working
`cmake`/Visual Studio setup for `dartcv4`. That's a separate, real piece of setup work for later.
It is not blocking what we need right now, which is just confirming `postProcess` and
`normalizePixel` behave correctly, and this isolated package gets us there without it.

## What "done" looks like

- A new, separate `logic_verification/` Dart package exists, with no Flutter or native
  dependencies.
- `dart test` runs inside it successfully (or fails — either way, report it in full).
- The next message contains the complete raw output of `dart pub get` and `dart test`.
- No changes are made to the existing Flutter app, `pubspec.yaml`, or any cmake/Visual Studio
  configuration as part of this task.
