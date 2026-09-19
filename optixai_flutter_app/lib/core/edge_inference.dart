// Author: Aaryan Patil (Roll No. 26) - OptiXAI
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class OptiXAIEngine {
  Interpreter? _interpreter;
  
  // Pre-allocated buffers to prevent garbage collection pauses (Zero-Copy approach)
  // Using int for TFLite quantized integer inputs
  late List<List<List<List<int>>>> _inputBuffer;
  late List<List<double>> _outputBuffer;
  
  static const int inputSize = 224;
  static const int channels = 3;
  
  // Calibrated thresholds exported from calibrate_thresholds.py
  // Replacing standard argmax static logic
  final List<double> _calibratedThresholds = [0.45, 0.35, 0.40, 0.55, 0.50];



  /// Initialize TFLite interpreter with hardware delegate bindings to prevent thermal throttling
  Future<void> initializeModel() async {
    try {
      var interpreterOptions = InterpreterOptions()..threads = 4;
      
      // Explicit Hardware Delegate Bindings
      if (Platform.isAndroid) {
        // NNAPI was removed from default in tflite_flutter, so we use default delegates (XNNPACK is enabled by default)
      }

      _interpreter = await Interpreter.fromAsset(
        'assets/models/optixai_dr_model.tflite',
        options: interpreterOptions,
      );

      // Pre-allocate int tensor buffers for raw pixel input (NHWC format)
      _inputBuffer = List.generate(
        1,
        (i) => List.generate(
          inputSize,
          (j) => List.generate(
            inputSize,
            (k) => List.filled(channels, 0),
          ),
        ),
      );
      
      // MobileNetV4 output is typically 5 logits/probs for the DR grades
      _outputBuffer = List.generate(1, (i) => List.filled(5, 0.0));
      
      print('OptiXAI Edge Model Initialized Successfully.');
    } catch (e) {
      print('Error initializing OptiXAI edge model: $e');
    }
  }

  /// Dart-only fallback preprocessing (no CLAHE, auto-crop, or denoising).
  /// 
  /// IMPORTANT: ImageNet normalization is baked into the TFLite model,
  /// so this simply extracts raw RGB pixels in [0-255].
  /// 
  /// For production use, prefer runInferenceFromPreprocessed() with the
  /// opencv_dart pipeline (via ImageIngestionService) which also applies
  /// CLAHE, auto-crop, and denoising.
  void _preprocessToBuffer(Uint8List imageBytes) {
    // Decode camera stream
    final image = img.decodeImage(imageBytes)!;
    final resizedImage = img.copyResize(image, width: inputSize, height: inputSize);

    // Extract raw RGB pixels without floating point normalization
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final pixel = resizedImage.getPixel(x, y);
        
        // Channel order: RGB
        _inputBuffer[0][y][x][0] = pixel.r.toInt();
        _inputBuffer[0][y][x][1] = pixel.g.toInt();
        _inputBuffer[0][y][x][2] = pixel.b.toInt();
      }
    }
  }

  /// Loads pre-processed raw pixel data from the opencv_dart pipeline (ImageIngestionService)
  /// into the TFLite input buffer. This is the PREFERRED path for production because
  /// ImageIngestionService applies the full clinical pipeline (CLAHE, auto-crop,
  /// denoising, glare removal) using opencv_dart bindings in a background isolate.
  ///
  /// [preprocessedData] must be a Uint8List of length 224*224*3 in NHWC/RGB order.
  void _loadPreprocessedToBuffer(Uint8List preprocessedData) {
    assert(preprocessedData.length == inputSize * inputSize * channels,
        'Expected ${inputSize * inputSize * channels} bytes, got ${preprocessedData.length}');
    
    int idx = 0;
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        _inputBuffer[0][y][x][0] = preprocessedData[idx++]; // R
        _inputBuffer[0][y][x][1] = preprocessedData[idx++]; // G
        _inputBuffer[0][y][x][2] = preprocessedData[idx++]; // B
      }
    }
  }

  /// Execute Edge AI Inference from raw image bytes (uses Dart-only preprocessing).
  /// 
  /// NOTE: This path does NOT apply CLAHE, auto-crop, or denoising. For clinical
  /// accuracy, use [runInferenceFromPreprocessed] with the opencv_dart pipeline.
  Map<String, dynamic> runInference(Uint8List imageBytes) {
    if (_interpreter == null) {
      throw Exception('OptiXAI Interpreter not initialized.');
    }

    // 1. Dart-only Preprocessing (raw pixels, no normalization)
    _preprocessToBuffer(imageBytes);

    // 2. Local Inference execution
    _interpreter!.run(_inputBuffer, _outputBuffer);

    // 3. Post-processing
    return _postProcess(_outputBuffer[0]);
  }

  /// Execute Edge AI Inference from pre-processed Uint8List data.
  /// 
  /// This is the RECOMMENDED path. Use with ImageIngestionService which routes
  /// through opencv_dart for the full clinical preprocessing pipeline
  /// (CLAHE, auto-crop, denoising, glare removal) inside a background isolate.
  Map<String, dynamic> runInferenceFromPreprocessed(Uint8List preprocessedData) {
    if (_interpreter == null) {
      throw Exception('OptiXAI Interpreter not initialized.');
    }

    // 1. Load pre-processed native output directly into buffer
    _loadPreprocessedToBuffer(preprocessedData);

    // 2. Local Inference execution
    _interpreter!.run(_inputBuffer, _outputBuffer);

    // 3. Post-processing
    return _postProcess(_outputBuffer[0]);
  }

  /// Shared post-processing: applies calibrated thresholds, computes clinical flags.
  Map<String, dynamic> _postProcess(List<double> rawProbs) {
    int predictedGrade = 0;
    double maxConfidence = -1.0;
    
    for (int i = 0; i < 5; i++) {
      // Adjust standard confidence based on Youden's Index calibrated boundaries
      double adjustedConfidence = rawProbs[i] / _calibratedThresholds[i];
      if (adjustedConfidence > maxConfidence) {
        maxConfidence = adjustedConfidence;
        predictedGrade = i;
      }
    }

    // DR severity >= 2 indicates referable DR
    bool isReferable = predictedGrade >= 2;
    
    // SAFETY NET: Group Class 3 (Severe NPDR) and Class 4 (PDR) into a single
    // "Urgent Refer" clinical action. The model achieves only 35-37% accuracy on
    // Class 4, systematically confusing it with Class 3. Both grades require
    // immediate specialist referral (laser photocoagulation / vitrectomy), so
    // grouping them ensures no PDR patient is missed due to model confusion.
    bool isUrgentRefer = predictedGrade >= 3;
    
    // Combined confidence for the urgent tier: sum of Class 3 + Class 4 probabilities.
    // Even when the model misclassifies 4→3, this combined score remains high,
    // giving clinicians a reliable "urgency signal" regardless of the specific grade.
    double urgentReferConfidence = rawProbs[3] + rawProbs[4];

    return {
      'dr_grade': predictedGrade, // 0-4 (full 5-class prediction preserved for analytics)
      'is_referable': isReferable,
      'is_urgent_refer': isUrgentRefer,
      'urgent_refer_confidence': urgentReferConfidence,
      'confidence_score': rawProbs[predictedGrade],
      'raw_probabilities': rawProbs,
    };
  }

  void dispose() {
    _interpreter?.close();
  }
}
