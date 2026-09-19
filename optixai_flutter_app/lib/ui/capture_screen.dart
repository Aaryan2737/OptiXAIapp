// Author: Aaryan Patil (Roll No. 26) - OptiXAI - SIH26038
// capture_screen.dart
//
// The Camera Capture + IQA Lockout screen, now with Bilateral (OS/OD) Support.

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

enum _EyeState { idle, checking, rejected, passed }

class CaptureScreen extends StatefulWidget {
  final String patientId;
  const CaptureScreen({super.key, required this.patientId});
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> with TickerProviderStateMixin {
  final _ingestion = ImageIngestionService();
  final _engine    = OptiXAIEngine();

  bool _isLeftEyeSelected = true;
  bool _isInferring = false;

  _EyeState _leftState = _EyeState.idle;
  _EyeState _rightState = _EyeState.idle;
  
  Uint8List? _leftBytes;
  Uint8List? _rightBytes;
  
  IqaResult? _leftIqa;
  IqaResult? _rightIqa;
  
  ImageSourceType _leftSource = ImageSourceType.liveHardware;
  ImageSourceType _rightSource = ImageSourceType.liveHardware;

  late final AnimationController _glowCtrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);
  late final Animation<double> _glowAnim = Tween<double>(begin: 4.0, end: 16.0).animate(
    CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
  );

  @override
  void initState() { super.initState(); _engine.initializeModel(); }

  @override
  void dispose() { _glowCtrl.dispose(); _engine.dispose(); super.dispose(); }

  Future<void> _onPhotoTaken(Uint8List bytes, ImageSourceType source) async {
    if (_isLeftEyeSelected) {
      setState(() { _leftBytes = bytes; _leftIqa = null; _leftSource = source; _leftState = _EyeState.checking; });
      final result = await _ingestion.assessImageQuality(bytes);
      setState(() { _leftIqa = result; _leftState = result.isPassed ? _EyeState.passed : _EyeState.rejected; });
    } else {
      setState(() { _rightBytes = bytes; _rightIqa = null; _rightSource = source; _rightState = _EyeState.checking; });
      final result = await _ingestion.assessImageQuality(bytes);
      setState(() { _rightIqa = result; _rightState = result.isPassed ? _EyeState.passed : _EyeState.rejected; });
    }
  }

  void _retake() {
    setState(() {
      if (_isLeftEyeSelected) {
        _leftState = _EyeState.idle; _leftBytes = null; _leftIqa = null;
      } else {
        _rightState = _EyeState.idle; _rightBytes = null; _rightIqa = null;
      }
    });
  }

  Future<void> _analyzeRetinaBilateral() async {
    if (_leftBytes == null || _rightBytes == null) return;
    setState(() => _isInferring = true);
    
    try {
      // 1. Process Left Eye
      final leftFloatBuffer = await _ingestion.processImage(_leftBytes!, _leftSource);
      final leftResult = _engine.runInferenceFromPreprocessed(leftFloatBuffer);
      
      // 2. Process Right Eye
      final rightFloatBuffer = await _ingestion.processImage(_rightBytes!, _rightSource);
      final rightResult = _engine.runInferenceFromPreprocessed(rightFloatBuffer);
      
      // 3. Save Both to Local Database
      final localId = const Uuid().v4();
      final dir = await getApplicationDocumentsDirectory();
      
      final leftImagePath = p.join(dir.path, 'left_$localId.jpg');
      await File(leftImagePath).writeAsBytes(_leftBytes!);
      
      final rightImagePath = p.join(dir.path, 'right_$localId.jpg');
      await File(rightImagePath).writeAsBytes(_rightBytes!);
      
      final isUrgent = (leftResult['is_urgent_refer'] as bool) || (rightResult['is_urgent_refer'] as bool);
      
      try {
        await LocalDatabase.instance.insertScreening({
          'local_id': localId,
          'patient_local_id': widget.patientId,
          'left_eye_local_path': leftImagePath,
          'right_eye_local_path': rightImagePath,
          'left_eye_grade': leftResult['dr_grade'],
          'right_eye_grade': rightResult['dr_grade'],
          'is_urgent_refer': isUrgent ? 1 : 0,
          'thresholds_version': 'v1.0.0',
          'sync_status': 'pending',
          'screened_at': DateTime.now().toIso8601String(),
        });
      } on Exception catch (dbError) {
        print('DatabaseException during capture insert: $dbError');
        throw Exception('Failed to save screening to local database: $dbError');
      }
      
      // WAKE UP BACKGROUND SYNC
      SyncService.registerOneOffSync();
      
      if (!context.mounted) return;
      Navigator.pushNamed(context, '/screening_result', arguments: {
        'patientId': widget.patientId,
        'result': {
            'left': leftResult,
            'right': rightResult,
            'is_urgent_refer': isUrgent
          },
          'leftBytes': _leftBytes,
          'rightBytes': _rightBytes,
        });
    } catch (e) {
      setState(() => _isInferring = false);
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
            _buildEyeToggle(),
            const SizedBox(height: 20),
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

  Widget _buildEyeToggle() {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _isInferring ? null : () => setState(() => _isLeftEyeSelected = true),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: _isLeftEyeSelected ? _teal.withValues(alpha: 0.15) : _cardColor,
                border: Border.all(color: _isLeftEyeSelected ? _teal : Colors.transparent, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Left Eye (OS)', style: TextStyle(color: _isLeftEyeSelected ? _teal : _textMuted, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  if (_leftState == _EyeState.passed) const Icon(Icons.check_circle, color: _teal, size: 16)
                  else if (_leftState == _EyeState.checking) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: _textMuted))
                  else if (_leftState == _EyeState.rejected) const Icon(Icons.warning_amber, color: _amber, size: 16)
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: GestureDetector(
            onTap: _isInferring ? null : () => setState(() => _isLeftEyeSelected = false),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: !_isLeftEyeSelected ? _teal.withValues(alpha: 0.15) : _cardColor,
                border: Border.all(color: !_isLeftEyeSelected ? _teal : Colors.transparent, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Right Eye (OD)', style: TextStyle(color: !_isLeftEyeSelected ? _teal : _textMuted, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  if (_rightState == _EyeState.passed) const Icon(Icons.check_circle, color: _teal, size: 16)
                  else if (_rightState == _EyeState.checking) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: _textMuted))
                  else if (_rightState == _EyeState.rejected) const Icon(Icons.warning_amber, color: _amber, size: 16)
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImagePreview() {
    final currentBytes = _isLeftEyeSelected ? _leftBytes : _rightBytes;
    return Container(
      height: 280, width: double.infinity,
      decoration: BoxDecoration(
        color: _cardColor, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _borderColorForState(), width: 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: currentBytes != null
            ? Image.memory(currentBytes, fit: BoxFit.cover)
            : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.camera_enhance_outlined, size: 60, color: _textMuted),
                const SizedBox(height: 12),
                Text('Tap the camera button to capture ${_isLeftEyeSelected ? "Left" : "Right"} Eye', style: const TextStyle(color: _textMuted, fontSize: 14)),
              ])),
      ),
    );
  }

  Color _borderColorForState() {
    if (_isInferring) return _teal;
    final currentState = _isLeftEyeSelected ? _leftState : _rightState;
    return switch (currentState) {
      _EyeState.passed    => _teal,
      _EyeState.rejected  => _amber,
      _EyeState.checking  => _textMuted,
      _EyeState.idle      => _cardColor,
    };
  }

  Widget _buildStatusBanner() {
    if (_isInferring) return _banner(key:'inferring', title:'Analysing Retina (Bilateral)...', sub:'Running INT8 neural network on both eyes', color:_teal, spin:true);
    
    final currentState = _isLeftEyeSelected ? _leftState : _rightState;
    final currentIqa = _isLeftEyeSelected ? _leftIqa : _rightIqa;

    if (currentState == _EyeState.idle) return const SizedBox.shrink(key: ValueKey('idle'));
    if (currentState == _EyeState.checking) return _banner(key:'checking', title:'Running Quality Check...', sub:'Analysing sharpness, illumination and field of view', color:_textMuted, spin:true);
    if (currentState == _EyeState.passed) return _banner(key:'passed', icon:Icons.check_circle_outline_rounded, title:currentIqa?.title ?? 'Quality: Excellent', sub:currentIqa?.instruction ?? 'Proceed to analysis.', color:_teal);
    
    final iqa = currentIqa!;
    return _banner(key:'rejected', icon:Icons.warning_amber_rounded, title:iqa.title, sub:iqa.instruction, color:iqa == IqaResult.errFov ? _red : _amber);
  }

  Widget _banner({required String key, required String title, required String sub, required Color color, IconData? icon, bool spin = false}) {
    return AnimatedContainer(
      key: ValueKey(key), duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.4))),
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
    if (_isInferring) {
      return SizedBox(width: double.infinity,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor:_textMuted.withValues(alpha: 0.2), foregroundColor:_textMuted, padding:const EdgeInsets.symmetric(vertical:16), shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
          onPressed: null,
          child: const Text('Please wait...', style: TextStyle(fontWeight:FontWeight.w600, fontSize:15)),
        ),
      );
    }

    final currentState = _isLeftEyeSelected ? _leftState : _rightState;

    // Both passed? Unlock big bilateral analyze button
    if (_leftState == _EyeState.passed && _rightState == _EyeState.passed) {
      return Column(children: [
        AnimatedBuilder(
          animation: _glowAnim,
          builder: (_, child) => Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color:_teal.withValues(alpha: 0.45), blurRadius:_glowAnim.value, spreadRadius:_glowAnim.value/4)]),
            child: child,
          ),
          child: SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor:_teal, foregroundColor:Colors.black, padding:const EdgeInsets.symmetric(vertical:16), shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
              icon: const Icon(Icons.biotech_outlined),
              label: const Text('Analyse Retina (Bilateral)', style: TextStyle(fontWeight:FontWeight.w800, fontSize:16)),
              onPressed: _analyzeRetinaBilateral,
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextButton.icon(onPressed: _retake, icon:const Icon(Icons.camera_alt_outlined, color:_textMuted, size:18), label:Text('Retake ${_isLeftEyeSelected ? "Left" : "Right"} Eye', style:const TextStyle(color:_textMuted, fontSize:13))),
      ]);
    }

    if (currentState == _EyeState.rejected || currentState == _EyeState.passed) {
      return SizedBox(width: double.infinity,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor:_amber, foregroundColor:Colors.black87, padding:const EdgeInsets.symmetric(vertical:16), shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
          icon: const Icon(Icons.camera_alt_outlined),
          label: const Text('Retake Image', style: TextStyle(fontWeight:FontWeight.w700, fontSize:15)),
          onPressed: _retake,
        ),
      );
    }

    if (currentState == _EyeState.idle) {
      return Column(
        children: [
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor:_cardColor, foregroundColor:_textPrimary, padding:const EdgeInsets.symmetric(vertical:16), side:const BorderSide(color:_textMuted, width:1), shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12))),
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text('Capture ${_isLeftEyeSelected ? "Left" : "Right"} Fundus', style: const TextStyle(fontWeight:FontWeight.w600, fontSize:15)),
              onPressed: () async {
                final picker = ImagePicker();
                final pickedFile = await picker.pickImage(source: ImageSource.camera);
                if (pickedFile != null) {
                  final bytes = await pickedFile.readAsBytes();
                  await _onPhotoTaken(bytes, ImageSourceType.liveHardware);
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
                  _onPhotoTaken(bytes, ImageSourceType.upload);
                }
              },
            ),
          ),
        ],
      );
    }

    return const SizedBox();
  }
}
