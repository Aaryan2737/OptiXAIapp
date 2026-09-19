// Author: Aaryan Patil (Roll No. 26) - OptiXAI - SIH26038
// image_ingestion_service.dart
//
// Pure-Dart IQA Gatekeeper + Clinical Preprocessing using opencv_dart.
// No custom C++ / CMake / NDK required.
// All heavy operations execute inside a Flutter Isolate to avoid UI jank.

import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Defines the source of the fundus image to determine preprocessing routing
enum ImageSourceType {
  UPLOAD,
  LIVE_HARDWARE,
}

// -----------------------------------------------------------------------------
// IMAGE QUALITY ASSESSMENT RESULT
// -----------------------------------------------------------------------------

/// The result of the IQA gatekeeper.
enum IqaResult {
  pass,       //  Image is gradeable. Pipeline may proceed.
  errDecode,  //  Not a valid image file (corrupted bytes).
  errFov,     //  No circular fundus boundary found. Not a retinal photo.
  errBlur,    //  Laplacian variance below threshold. Image is too blurry.
  errDark,    //  Mean luminance too low. Underexposed / lens cap on.
  errGlare,   //  Mean luminance too high. Corneal glare / overexposed.
}

/// Human-readable title + remediation instruction for each IQA result.
/// Displayed verbatim in the Flutter rejection modal.
extension IqaResultUX on IqaResult {
  /// Short title shown in the amber/red status banner.
  String get title => switch (this) {
    IqaResult.pass      => 'Quality: Excellent',
    IqaResult.errDecode => 'Image Unreadable',
    IqaResult.errFov    => 'Ungradeable Image: No Fundus Detected',
    IqaResult.errBlur   => 'Ungradeable Image: Excessive Blur Detected',
    IqaResult.errDark   => 'Ungradeable Image: Poor Illumination (Too Dark)',
    IqaResult.errGlare  => 'Ungradeable Image: Poor Illumination (Glare)',
  };

  /// Detailed remediation instruction shown below the title.
  String get instruction => switch (this) {
    IqaResult.pass      => 'Image is sharp, well-lit, and correctly framed.',
    IqaResult.errDecode => 'The image file is corrupted. Please retake the photo.',
    IqaResult.errFov    => 'Ensure the fundus lens is correctly attached and centred on the patient\'s eye.',
    IqaResult.errBlur   => 'Please stabilise the smartphone and hold it steady against the fundus lens.',
    IqaResult.errDark   => 'The image is too dark. Check that the flashlight is enabled and aligned.',
    IqaResult.errGlare  => 'Corneal glare detected. Slightly adjust the angle of the lens against the eye.',
  };

  bool get isPassed => this == IqaResult.pass;
}

// =============================================================================
// TUNABLE IQA THRESHOLDS (Calibrated on APTOS 2019 gradeable set)
// =============================================================================
const double _blurThreshold = 85.0;
const double _illuminationMin = 30.0;
const double _illuminationMax = 220.0;
const double _minCircleRadiusFraction = 0.30;

// =============================================================================
// ISOLATE PAYLOADS
// =============================================================================

class _IqaTaskParams {
  final Uint8List imageBytes;
  _IqaTaskParams(this.imageBytes);
}

class _PreprocessTaskParams {
  final Uint8List imageBytes;
  final bool isLiveHardware;
  _PreprocessTaskParams({required this.imageBytes, required this.isLiveHardware});
}

// =============================================================================
// IMAGE INGESTION SERVICE (IQA Gatekeeper + Clinical Pipeline)
// =============================================================================
class ImageIngestionService {
  static const int targetSize = 224;
  static const int channels = 3;

  // ---------------------------------------------------------------------------
  // PUBLIC API: IQA GATEKEEPER
  // ---------------------------------------------------------------------------

  /// Runs all three mathematical image quality checks on a background isolate.
  ///
  /// Call this immediately after capture, BEFORE calling [processImage].
  /// Only proceed to [processImage] if [IqaResult.pass] is returned.
  ///
  /// Checks performed (in order, early-exit on first failure):
  ///   1. FOV     — Is a circular fundus boundary present?
  ///   2. Blur    — Is Laplacian variance above BLUR_THRESHOLD (85.0)?
  ///   3. Illumination — Is mean luminance in [30, 220]?
  Future<IqaResult> assessImageQuality(Uint8List rawBytes) async {
    final int code = await compute(_runIqaCheck, _IqaTaskParams(rawBytes));
    return _codeToResult(code);
  }

  /// Maps the raw integer return code to a typed [IqaResult].
  static IqaResult _codeToResult(int code) => switch (code) {
    0  => IqaResult.pass,
    -2 => IqaResult.errFov,
    -3 => IqaResult.errBlur,
    -4 => IqaResult.errDark,
    -5 => IqaResult.errGlare,
    _  => IqaResult.errDecode,
  };

  /// Isolate body for the IQA check. Runs entirely off the UI thread.
  /// Uses opencv_dart bindings — no custom C++ or FFI needed.
  static int _runIqaCheck(_IqaTaskParams params) {
    cv.Mat? img;
    cv.Mat? gray;
    cv.Mat? fovThresh;
    cv.Mat? kernel;
    cv.Mat? roiMask;
    cv.Mat? laplacian;

    try {
      // --- Decode ---
      img = cv.imdecode(params.imageBytes, cv.IMREAD_COLOR);
      if (img.isEmpty) return -1; // IQA_ERR_DECODE

      gray = cv.cvtColor(img, cv.COLOR_BGR2GRAY);

      // -----------------------------------------------------------
      // CHECK 1: FIELD OF VIEW — Is there a circular fundus boundary?
      // -----------------------------------------------------------
      fovThresh = cv.threshold(gray, 20, 255, cv.THRESH_BINARY).$2;
      kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (7, 7));
      fovThresh = cv.morphologyEx(fovThresh, cv.MORPH_CLOSE, kernel);

      final contours = cv.findContours(fovThresh, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE).$1;

      if (contours.isEmpty) return -2; // IQA_ERR_FOV

      // Find the largest contour by area (should be the fundus boundary)
      double maxArea = 0;
      int maxIdx = 0;
      for (int i = 0; i < contours.length; i++) {
        final a = cv.contourArea(contours[i]);
        if (a > maxArea) {
          maxArea = a;
          maxIdx = i;
        }
      }

      final (center, radius) = cv.minEnclosingCircle(contours[maxIdx]);
      final minDim = img.cols < img.rows ? img.cols : img.rows;
      if (radius < minDim * _minCircleRadiusFraction) return -2; // IQA_ERR_FOV

      // Build the fundus ROI mask for the next two checks.
      roiMask = cv.Mat.zeros(img.rows, img.cols, cv.MatType.CV_8UC1);
      cv.circle(roiMask, cv.Point(center.x.toInt(), center.y.toInt()), radius.toInt(), cv.Scalar.all(255), thickness: -1);

      // -----------------------------------------------------------
      // CHECK 2: BLUR DETECTION — Laplacian Variance
      // -----------------------------------------------------------
      laplacian = cv.laplacian(gray, 6); // 6 = CV_64F

      final (lapMean, lapStdDev) = cv.meanStdDev(laplacian, mask: roiMask);
      final laplacianVariance = lapStdDev.val1 * lapStdDev.val1;

      if (laplacianVariance < _blurThreshold) return -3; // IQA_ERR_BLUR

      // -----------------------------------------------------------
      // CHECK 3: ILLUMINATION — Mean Luminance inside fundus circle
      // -----------------------------------------------------------
      final (meanVal, _) = cv.meanStdDev(gray, mask: roiMask);
      final meanLuminance = meanVal.val1;

      if (meanLuminance < _illuminationMin) return -4; // IQA_ERR_DARK
      if (meanLuminance > _illuminationMax) return -5; // IQA_ERR_GLARE

      return 0; // IQA_PASS
    } catch (_) {
      return -1; // Never crash the app
    } finally {
      // CRITICAL: Dispose all native Mat objects to prevent memory leaks
      img?.dispose();
      gray?.dispose();
      fovThresh?.dispose();
      kernel?.dispose();
      roiMask?.dispose();
      laplacian?.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // PUBLIC API: FULL CLINICAL PREPROCESSING
  // ---------------------------------------------------------------------------

  /// Main entry point for inference preprocessing.
  ///
  /// Routes image through the full opencv_dart pipeline (auto-crop, denoising,
  /// CLAHE, optional glare removal). No ImageNet normalization — TFLite model
  /// expects raw [0-255] uint8 pixels.
  ///
  /// IMPORTANT: Only call this AFTER [assessImageQuality] returns [IqaResult.pass].
  Future<Uint8List> processImage(Uint8List rawBytes, ImageSourceType source) async {
    return await compute(
      _runPreprocessPipeline,
      _PreprocessTaskParams(
        imageBytes: rawBytes,
        isLiveHardware: source == ImageSourceType.LIVE_HARDWARE,
      ),
    );
  }

  /// The heavy function executed entirely inside a Background Isolate.
  static Uint8List _runPreprocessPipeline(_PreprocessTaskParams params) {
    cv.Mat? img;
    cv.Mat? gray;
    cv.Mat? thresh;
    cv.Mat? mask;
    cv.Mat? maskedImg;
    cv.Mat? glareGray;
    cv.Mat? glareMask;
    cv.Mat? glareKernel;
    cv.Mat? lab;
    cv.Mat? resized;

    try {
      // 1. Decode Image from byte array
      img = cv.imdecode(params.imageBytes, cv.IMREAD_COLOR);
      if (img.isEmpty) throw Exception('Failed to decode image bytes.');

      // ==========================================================
      // 2. Y-SHAPED PIPELINE: Branch-Specific Preprocessing
      // ==========================================================
      if (params.isLiveHardware) {
        // A. Mask adapter ring (Hardware condensation lens artifact)
        mask = cv.Mat.zeros(img.rows, img.cols, cv.MatType.CV_8UC1);
        final center = cv.Point(img.cols ~/ 2, img.rows ~/ 2);
        final radius = (img.cols < img.rows ? img.cols : img.rows) ~/ 2;
        cv.circle(mask, center, radius, cv.Scalar.all(255), thickness: -1);
        maskedImg = cv.bitwiseAND(img, img, mask: mask);
        img.dispose();
        img = maskedImg;
        maskedImg = null; // Prevent double-dispose

        // B. Fast Glare Mitigation (Corneal Reflection)
        glareGray = cv.cvtColor(img, cv.COLOR_BGR2GRAY);
        glareMask = cv.threshold(glareGray, 240, 255, cv.THRESH_BINARY).$2;
        glareKernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (5, 5));
        glareMask = cv.dilate(glareMask, glareKernel);
        final inpainted = cv.inpaint(img, glareMask, 3.0, cv.INPAINT_TELEA);
        img.dispose();
        img = inpainted;
      }
      // UPLOAD branch explicitly bypasses the above hardware artifact logic

      // ==========================================================
      // 3. COMMON CONVERGENCE PIPELINE (Crucial for AI Accuracy)
      // ==========================================================

      // A. Contour Auto-Crop
      gray = cv.cvtColor(img, cv.COLOR_BGR2GRAY);
      thresh = cv.threshold(gray, 10, 255, cv.THRESH_BINARY).$2;
      final contours = cv.findContours(thresh, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE).$1;

      if (contours.isNotEmpty) {
        double maxArea = 0;
        int maxIdx = 0;
        for (int i = 0; i < contours.length; i++) {
          final area = cv.contourArea(contours[i]);
          if (area > maxArea) {
            maxArea = area;
            maxIdx = i;
          }
        }
        final bbox = cv.boundingRect(contours[maxIdx]);
        if (bbox.width > 50 && bbox.height > 50) {
          final cropped = img.region(bbox);
          img.dispose();
          img = cropped;
        }
      }

      // B. Gaussian Denoising (matches preprocess.py)
      final denoised = cv.gaussianBlur(img, (3, 3), 0);
      img.dispose();
      img = denoised;

      // C. CLAHE on Luminance channel (LAB color space)
      lab = cv.cvtColor(img, cv.COLOR_BGR2Lab);
      final labChannels = cv.split(lab);
      final clahe = cv.CLAHE(2.0, (8, 8));
      final enhanced = clahe.apply(labChannels[0]);
      labChannels[0].dispose();
      labChannels[0] = enhanced;
      final merged = cv.merge(labChannels);
      final labBack = cv.cvtColor(merged, cv.COLOR_Lab2BGR);
      img.dispose();
      img = labBack;
      merged.dispose();
      for (final ch in labChannels) { ch.dispose(); }
      clahe.dispose();

      // D. Bicubic Resize to 224x224
      resized = cv.resize(img, (targetSize, targetSize), interpolation: cv.INTER_CUBIC);

      // E. Convert BGR to RGB (TFLite requirement)
      final rgb = cv.cvtColor(resized, cv.COLOR_BGR2RGB);

      // F. Extract raw uint8 pixels in NHWC format
      // No normalization needed — TFLite model expects raw pixels [0-255]
      final Uint8List result = Uint8List.fromList(rgb.data);
      rgb.dispose();

      return result;
    } finally {
      // CRITICAL: Dispose ALL native Mat objects to prevent memory leaks
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
  }
}
