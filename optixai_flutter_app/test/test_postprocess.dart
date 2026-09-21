import 'package:flutter_test/flutter_test.dart';

void main() {
  final List<double> _calibratedThresholds = [0.45, 0.35, 0.40, 0.55, 0.50];

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

  const _mean = [0.485, 0.456, 0.406];
  const _std  = [0.229, 0.224, 0.225];

  double _normalizePixel(int raw0to255, int channelIndex) =>
      (raw0to255 / 255.0 - _mean[channelIndex]) / _std[channelIndex];


  test('Test case 1: No escalation needed', () {
    final probs = [0.10, 0.05, 0.80, 0.03, 0.02];
    final result = _postProcess(probs);
    expect(result['dr_grade'], equals(2));
  });

  test('Test case 2: Overriding argmax should not happen (was broken before)', () {
    final probs = [0.10, 0.40, 0.45, 0.03, 0.02];
    final result = _postProcess(probs);
    expect(result['dr_grade'], equals(2));
  });

  test('Test case 3: Does not clear threshold', () {
    final probs = [0.60, 0.05, 0.05, 0.15, 0.15];
    final result = _postProcess(probs);
    expect(result['dr_grade'], equals(0));
  });

  test('Test case 4: Escalates by exactly one level', () {
    // Argmax is grade 0. Grade 1 clears 0.35 threshold.
    // Ensure it escalates to 1 and not 2, even if Grade 2 was high but it doesn't check it directly.
    // We make rawProbs[1] = 0.36 >= 0.35, so it escalates to 1.
    final probs = [0.60, 0.36, 0.41, 0.02, 0.01];
    final result = _postProcess(probs);
    expect(result['dr_grade'], equals(1));
  });
  
  test('Test case 6: Normalize pixels', () {
    print("Normalize 0 for R: \${_normalizePixel(0, 0)}");
    print("Normalize 255 for R: \${_normalizePixel(255, 0)}");
    expect(_normalizePixel(0, 0) < 0, true);
    expect(_normalizePixel(255, 0) > 0, true);
  });
}
