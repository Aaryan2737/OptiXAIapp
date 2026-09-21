# Calibration Script Bug Report

## Location
File: `calibrate_thresholds.py`
Lines: 49-58

## Verbatim Snippet
```python
def apply_calibrated_thresholds(y_probs, thresholds):
    """
    Replaces default static (0.5) / argmax logic with calibrated thresholds 
    to mitigate high false positives caused by class imbalance.
    """
    # Adjust probabilities proportionally to the calibrated thresholds
    # Added 1e-7 epsilon to prevent DivisionByZero if a threshold calibrates to exactly 0.0
    adjusted_probs = y_probs / (thresholds + 1e-7)
    predictions = np.argmax(adjusted_probs, axis=1)
    return predictions
```

## Explanation
The thresholds are generated using binary One-Vs-Rest (OVR) ROC curves, each independently optimized via Youden's J statistic. Youden's J for class `i` answers one question in isolation: "if I only had to decide class-`i`-vs-everything-else, what probability cutoff best balances true and false positive rates for that one binary decision?" It says nothing about how class `i`'s probability compares to class `j`'s probability. The five thresholds were never computed to be comparable to each other.

Dividing five unrelated probabilities by five unrelated, independently-derived cutoffs and taking `argmax` of the ratios does not produce a valid multiclass decision rule. It allows a class with a low threshold to hijack the final prediction from a class with a much higher raw probability, with no relationship to which class the model actually believes is most likely.

## Numeric Counterexample
Consider:
- `y_probs = [0.10, 0.40, 0.45, 0.03, 0.02]`
- `thresholds = [0.45, 0.35, 0.40, 0.55, 0.50]`

Argmax of raw probabilities is **Class 2** (0.45, clearly the model's top belief). 

Argmax of `probs/thresholds` is **Class 1** (`0.40/0.35 ≈ 1.143` beats `0.45/0.40 = 1.125`). 

The proportional-division rule silently overturns the model's own most confident prediction.

## Edge Deployment Divergence
The Dart edge application does **NOT** implement this logic. Instead, `edge_inference.dart` uses plain argmax followed by single-level escalation (picking the class one step above the argmax winner if and only if it clears its own threshold) to safely boost sensitivity without allowing low-probability classes to globally hijack predictions.

## Conclusion
This needs a decision from whoever owns calibrate_thresholds.py: either retire the proportional-division selection rule and keep the OVR thresholds only as single-class gates (matching the Dart app's current behavior), or redesign the multiclass decision rule with a method that's actually valid for combining per-class thresholds (for example: pick the highest class whose own threshold is cleared, ties broken by probability — not a cross-class ratio).
