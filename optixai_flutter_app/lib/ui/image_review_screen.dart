// Author: Aaryan Patil (Roll No. 26) - OptiXAI - SIH26038
// image_review_screen.dart
//
// The Camera Capture + IQA Lockout screen.
//
// STATE MACHINE:
//   idle      -> user has returned to this screen, no photo yet
//   checking  -> photo captured; IQA running on background isolate (~200ms)
//   rejected  -> IQA returned a non-pass code; inference button hidden
//   passed    -> IQA returned pass; inference button unlocked and glowing teal
//   inferring -> TFLite running; all buttons disabled

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../core/image_ingestion_service.dart';
import '../core/edge_inference.dart';
import '../core/local_database.dart';
import '../core/sync_service.dart';
import 'package:uuid/uuid.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
const _bgColor     = Color(0xFF0D1117);
const _cardColor   = Color(0xFF161B22);
const _teal        = Color(0xFF00C5A1);
const _amber       = Color(0xFFFFC107);
const _red         = Color(0xFFEF5350);
const _textPrimary = Color(0xFFE6EDF3);
const _textMuted   = Color(0xFF8B949E);

enum _ScreenState { idle, checking, rejected, passed, inferring }

class ImageReviewScreen extends StatefulWidget {
  final String patientId;
  const ImageReviewScreen({super.key, required this.patientId});
  @override
  State<ImageReviewScreen> createState() => _ImageReviewScreenState();
}

class _ImageReviewScreenState extends State<ImageReviewScreen>
    with TickerProviderStateMixin {
  final _ingestion = ImageIngestionService();
  final _engine    = OptiXAIEngine();

  _ScreenState _state  = _ScreenState.idle;
  Uint8List?   _imageBytes;
  IqaResult?   _iqaResult;
  ImageSourceType _currentSource = ImageSourceType.LIVE_HARDWARE;

  late final AnimationController _glowCtrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);
  late final Animation<double> _glowAnim =
      Tween<double>(begin: 4.0, end: 16.0).animate(
    CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
  );

  @override
  void initState() { super.initState(); _engine.initializeModel(); }

  @override
  void dispose() { _glowCtrl.dispose(); _engine.dispose(); super.dispose(); }

  Future<void> _onPhotoTaken(Uint8List bytes, ImageSourceType source) async {
    setState(() { _imageBytes = bytes; _iqaResult = null; _currentSource = source; _state = _ScreenState.checking; });
    final result = await _ingestion.assessImageQuality(bytes);
    setState(() { _iqaResult = result; _state = result.isPassed ? _ScreenState.passed : _ScreenState.rejected; });
  }

  void _retake() => setState(() { _state = _ScreenState.idle; _imageBytes = null; _iqaResult = null; });

  Future<void> _analyzeRetina() async {
    if (_imageBytes == null) return;
    setState(() => _state = _ScreenState.inferring);
    try {
      final floatBuffer = await _ingestion.processImage(_imageBytes!, _currentSource);
      final result = _engine.runInferenceFromPreprocessed(floatBuffer);
      
      // SAVE TO LOCAL DATABASE FOR OFFLINE SYNC
      final localId = const Uuid().v4();
      final dir = await getApplicationDocumentsDirectory();
      final imagePath = p.join(dir.path, '$localId.jpg');
      await File(imagePath).writeAsBytes(_imageBytes!);
      
      await LocalDatabase.instance.insertScreening({
        'local_id': localId,
        'patient_local_id': widget.patientId, // In production, this would be the actual patient's local UUID
        'left_eye_image_path': imagePath, // Assume left eye for this demo
        'right_eye_image_path': null,
        'left_eye_grade': result['dr_grade'],
        'right_eye_grade': null,
        'is_urgent_refer': result['is_urgent_refer'] ? 1 : 0,
        'thresholds_version': 'v1.0.0',
        'sync_status': 'pending',
        'screened_at': DateTime.now().toIso8601String(),
      });
      
      // WAKE UP BACKGROUND SYNC
      SyncService.registerOneOffSync();
      
      if (mounted) {
        Navigator.pushNamed(context, '/screening-result', arguments: {
          'patientId': widget.patientId, 'result': result, 'imageBytes': _imageBytes,
        });
      }
    } catch (e) {
      setState(() => _state = _ScreenState.passed);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Inference failed: $e'), backgroundColor: _red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _cardColor, elevation: 0,
        title: const Text('Fundus Capture', style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w600)),
        iconTheme: const IconThemeData(color: _textMuted),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            _buildImagePreview(),
            const SizedBox(height: 20),
            AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: _buildStatusBanner()),
            const Spacer(),
            _buildActionButtons(context),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );
  }

  Widget _buildImagePreview() {
    return Container(
      height: 280, width: double.infinity,
      decoration: BoxDecoration(
        color: _cardColor, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _borderColorForState(), width: 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: _imageBytes != null
            ? Image.memory(_imageBytes!, fit: BoxFit.cover)
            : const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.camera_enhance_outlined, size: 60, color: _textMuted),
                SizedBox(height: 12),
                Text('Tap the camera button below to begin', style: TextStyle(color: _textMuted, fontSize: 14)),
              ])),
      ),
    );
  }

  Color _borderColorForState() => switch (_state) {
    _ScreenState.passed    => _teal,
    _ScreenState.rejected  => _amber,
    _ScreenState.inferring => _teal,
    _ScreenState.checking  => _textMuted,
    _ScreenState.idle      => _cardColor,
  };

  Widget _buildStatusBanner() {
    if (_state == _ScreenState.idle) return const SizedBox.shrink(key: ValueKey('idle'));
    if (_state == _ScreenState.checking) return _banner(key:'checking', title:'Running Quality Check...', sub:'Analysing sharpness, illumination and field of view', color:_textMuted, spin:true);
    if (_state == _ScreenState.inferring) return _banner(key:'inferring', title:'Analysing Retina...', sub:'Running INT8 neural network on-device', color:_teal, spin:true);
    if (_state == _ScreenState.passed) return _banner(key:'passed', icon:Icons.check_circle_outline_rounded, title:_iqaResult?.title ?? 'Quality: Excellent', sub:_iqaResult?.instruction ?? 'Proceed to analysis.', color:_teal);
    final iqa = _iqaResult!;
    return _banner(key:'rejected', icon:Icons.warning_amber_rounded, title:iqa.title, sub:iqa.instruction, color:iqa == IqaResult.errFov ? _red : _amber);
  }

  Widget _banner({required String key, required String title, required String sub, required Color color, IconData? icon, bool spin = false}) {
    return AnimatedContainer(
      key: ValueKey(key), duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withOpacity(0.4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (spin) SizedBox(width:22, height:22, child: CircularProgressIndicator(strokeWidth:2.5, color:color))
        else if (icon != null) Icon(icon, color:color, size:22),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(color:color, fontSize:14, fontWeight:FontWeight.w700)),
          const SizedBox(height: 4),
          Text(sub, style: const TextStyle(color:_textMuted, fontSize:12.5)),
        ])),
      ]),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    // REJECTED: Only Retake. Analyze button is completely absent.
    if (_state == _ScreenState.rejected) {
      return SizedBox(width: double.infinity,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor:_amber, foregroundColor:Colors.black87, padding:const EdgeInsets.symmetric(vertical:16), shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
          icon: const Icon(Icons.camera_alt_outlined),
          label: const Text('Retake Image', style: TextStyle(fontWeight:FontWeight.w700, fontSize:15)),
          onPressed: _retake,
        ),
      );
    }

    // IDLE: camera and gallery buttons
    if (_state == _ScreenState.idle) {
      return Column(
        children: [
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor:_cardColor, foregroundColor:_textPrimary, padding:const EdgeInsets.symmetric(vertical:16), side:const BorderSide(color:_textMuted, width:1), shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Capture Fundus Image', style: TextStyle(fontWeight:FontWeight.w600, fontSize:15)),
              onPressed: () async {
                final picker = ImagePicker();
                final pickedFile = await picker.pickImage(source: ImageSource.camera);
                if (pickedFile != null) {
                  final bytes = await pickedFile.readAsBytes();
                  _onPhotoTaken(bytes, ImageSourceType.LIVE_HARDWARE);
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor:_textPrimary, padding:const EdgeInsets.symmetric(vertical:16), side:const BorderSide(color:_textMuted, width:1), shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Upload from Gallery', style: TextStyle(fontWeight:FontWeight.w600, fontSize:15)),
              onPressed: () async {
                final picker = ImagePicker();
                final pickedFile = await picker.pickImage(source: ImageSource.gallery);
                if (pickedFile != null) {
                  final bytes = await pickedFile.readAsBytes();
                  _onPhotoTaken(bytes, ImageSourceType.UPLOAD); // IQA gatekeeper automatically applied here
                }
              },
            ),
          ),
        ],
      );
    }

    // PASSED: glowing Analyze button + quiet Retake link
    if (_state == _ScreenState.passed) {
      return Column(children: [
        AnimatedBuilder(
          animation: _glowAnim,
          builder: (_, child) => Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color:_teal.withOpacity(0.45), blurRadius:_glowAnim.value, spreadRadius:_glowAnim.value/4)]),
            child: child,
          ),
          child: SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor:_teal, foregroundColor:Colors.black, padding:const EdgeInsets.symmetric(vertical:16), shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
              icon: const Icon(Icons.biotech_outlined),
              label: const Text('Analyse Retina', style: TextStyle(fontWeight:FontWeight.w800, fontSize:16)),
              onPressed: _analyzeRetina,
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextButton.icon(onPressed: _retake, icon:const Icon(Icons.camera_alt_outlined, color:_textMuted, size:18), label:const Text('Retake', style:TextStyle(color:_textMuted, fontSize:13))),
      ]);
    }

    // CHECKING / INFERRING: All buttons greyed out and disabled
    return SizedBox(width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor:_textMuted.withOpacity(0.2), foregroundColor:_textMuted, padding:const EdgeInsets.symmetric(vertical:16), shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
        onPressed: null,
        child: const Text('Please wait...', style: TextStyle(fontWeight:FontWeight.w600, fontSize:15)),
      ),
    );
  }
}
