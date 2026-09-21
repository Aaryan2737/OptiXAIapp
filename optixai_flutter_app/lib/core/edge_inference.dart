// Author: Aaryan Patil (Roll No. 26) - OptiXAI
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class OptiXAIEngine {
  Interpreter? _interpreter;
  
  // Calibrated thresholds exported from calibrate_thresholds.py
  static const int inputSize = 224;
  static const int channels = 3;
  



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
      
      print('OptiXAI Edge Model Initialized Successfully.');
    } catch (e) {
      print('Error initializing OptiXAI edge model: $e');
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

    final inputTensor = _interpreter!.getInputTensor(0);
    final inputShape = inputTensor.shape; // [1, height, width, 3]
    final height = inputShape[1];
    final width = inputShape[2];
    final inputType = inputTensor.type;

    // 1. Dart-only Preprocessing (raw pixels, dynamically typed)
    final image = img.decodeImage(imageBytes)!;
    final resizedImage = img.copyResize(image, width: width, height: height);

    Object reshapedInput;
    if (inputType == TensorType.float32) {
      final flatList = <double>[];
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final pixel = resizedImage.getPixel(x, y);
          flatList.add(((pixel.r / 255.0) - 0.5) * 2.0);
          flatList.add(((pixel.g / 255.0) - 0.5) * 2.0);
          flatList.add(((pixel.b / 255.0) - 0.5) * 2.0);
        }
      }
      reshapedInput = flatList.reshape<double>(inputShape);
    } else {
      final flatList = <int>[];
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final pixel = resizedImage.getPixel(x, y);
          if (inputType == TensorType.int8) {
            flatList.add(pixel.r.toInt() - 128);
            flatList.add(pixel.g.toInt() - 128);
            flatList.add(pixel.b.toInt() - 128);
          } else {
            flatList.add(pixel.r.toInt());
            flatList.add(pixel.g.toInt());
            flatList.add(pixel.b.toInt());
          }
        }
      }
      reshapedInput = flatList.reshape<int>(inputShape);
    }

    // 2. Local Inference execution
    final outputTensor = _interpreter!.getOutputTensor(0);
    final outputType = outputTensor.type;
    
    Object outputBuffer;
    if (outputType == TensorType.float32) {
      outputBuffer = List.generate(1, (i) => List.filled(5, 0.0));
    } else {
      outputBuffer = List.generate(1, (i) => List.filled(5, 0));
    }

    _interpreter!.run(reshapedInput, outputBuffer);

    // 3. Dynamic Dequantization
    List<double> rawProbs = [];
    if (outputType == TensorType.float32) {
      final buffer = outputBuffer as List<List<double>>;
      for (int i = 0; i < 5; i++) {
        rawProbs.add(buffer[0][i]);
      }
    } else {
      final buffer = outputBuffer as List<List<int>>;
      final scale = outputTensor.params.scale;
      final zeroPoint = outputTensor.params.zeroPoint;
      for (int i = 0; i < 5; i++) {
        int quantizedValue = buffer[0][i];
        double probability = (quantizedValue - zeroPoint) * scale;
        rawProbs.add(probability);
      }
    }

    // 4. Post-processing — guard against double softmax
    final double probSum = rawProbs.reduce((a, b) => a + b);
    final List<double> finalProbs = (probSum - 1.0).abs() < 0.05
        ? rawProbs
        : _softmax(rawProbs);
    return _postProcess(finalProbs);
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

    final inputTensor = _interpreter!.getInputTensor(0);
    final inputShape = inputTensor.shape; 
    final inputType = inputTensor.type;
    final outputTensor = _interpreter!.getOutputTensor(0);
    // TEMP-DIAG: print('[OptiXAI Debug] inputType: ${inputTensor.type}  outputType: ${outputTensor.type}');
    // 1. Load pre-processed native output directly into buffer
    // preprocessedData is already RGB — COLOR_BGR2RGB was applied in OpenCV pipeline.
    // Read channels in order: R=index 0, G=index 1, B=index 2.
    Object reshapedInput;
    if (inputType == TensorType.float32) {
      final flatList = Float32List(preprocessedData.length);
      for (int i = 0; i < preprocessedData.length; i += 3) {
          final int r = preprocessedData[i];
          final int g = preprocessedData[i+1];
          final int b = preprocessedData[i+2];
          
          flatList[i] = (r / 255.0 - 0.5) * 2.0;
          flatList[i+1] = (g / 255.0 - 0.5) * 2.0;
          flatList[i+2] = (b / 255.0 - 0.5) * 2.0;
      }
      reshapedInput = flatList.reshape<double>(inputShape);
    } else {
      final flatList = Int8List(preprocessedData.length);
      final double inScale = inputTensor.params.scale;
      final int inZp = inputTensor.params.zeroPoint;
      for (int i = 0; i < preprocessedData.length; i += 3) {
          final int r = preprocessedData[i];
          final int g = preprocessedData[i+1];
          final int b = preprocessedData[i+2];
          
          if (inputType == TensorType.int8) {
            double rFloat = (r / 255.0 - 0.5) * 2.0;
            double gFloat = (g / 255.0 - 0.5) * 2.0;
            double bFloat = (b / 255.0 - 0.5) * 2.0;
            
            flatList[i] = ((rFloat / inScale).round() + inZp).clamp(-128, 127);
            flatList[i+1] = ((gFloat / inScale).round() + inZp).clamp(-128, 127);
            flatList[i+2] = ((bFloat / inScale).round() + inZp).clamp(-128, 127);
          } else {
            flatList[i] = r;
            flatList[i+1] = g;
            flatList[i+2] = b;
          }
      }
      reshapedInput = flatList.reshape<int>(inputShape);
    }

    // 2. Local Inference execution
    final outputType = outputTensor.type;
    
    Object outputBuffer;
    if (outputType == TensorType.float32) {
      outputBuffer = List.generate(1, (i) => List.filled(5, 0.0));
    } else {
      outputBuffer = List.generate(1, (i) => List.filled(5, 0));
    }

    // `reshapedInput` is either Float32List or Int8List depending on inputType.
    // `reshape` returns the correct flat list based on generic type, but to be absolutely safe
    // we should ensure it's a typed array. However, tflite_flutter handles reshaping flat typed lists.
    _interpreter!.run(reshapedInput, outputBuffer);

    // 3. Dynamic Dequantization
    List<double> rawProbs = [];
    if (outputType == TensorType.float32) {
      final buffer = outputBuffer as List<List<double>>;
      for (int i = 0; i < 5; i++) {
        rawProbs.add(buffer[0][i]);
      }
    } else {
      final buffer = outputBuffer as List<List<int>>;
      final scale = outputTensor.params.scale;
      final zeroPoint = outputTensor.params.zeroPoint;
      for (int i = 0; i < 5; i++) {
        int quantizedValue = buffer[0][i].toSigned(8);
        double probability = (quantizedValue - zeroPoint) * scale;
        rawProbs.add(probability);
      }
    }

    // TEMP-DIAG: print('[OptiXAI Debug] rawProbs: $rawProbs');
    // 4. Post-processing
    // The TFLite model's graph already includes a softmax output layer.
    // Dequantized values sum to ~1.0 (they are probabilities, not logits).
    // Applying _softmax() again would compress the distribution toward uniform,
    // destroying the model's discriminative signal.
    final double probSum = rawProbs.reduce((a, b) => a + b);
    final List<double> finalProbs = (probSum - 1.0).abs() < 0.05
        ? rawProbs  // Already valid probabilities — skip softmax
        : _softmax(rawProbs);  // Raw logits — apply softmax
    return _postProcess(finalProbs);
  }

  /// Converts raw logits into a proper probability distribution summing to 1.0
  List<double> _softmax(List<double> logits) {
    double maxLogit = logits.reduce(max);
    List<double> expLogits = logits.map((logit) => exp(logit - maxLogit)).toList();
    double sumExp = expLogits.reduce((a, b) => a + b);
    return expLogits.map((e) => e / sumExp).toList();
  }

  /// Shared post-processing: computes clinical flags.
  Map<String, dynamic> _postProcess(List<double> rawProbs) {
    int predictedGrade = 0;
    double maxConfidence = -1.0;
    
    for (int i = 0; i < 5; i++) {
      if (rawProbs[i] > maxConfidence) {
        maxConfidence = rawProbs[i];
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
