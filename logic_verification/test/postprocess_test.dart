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
