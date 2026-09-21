import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/providers.dart';

const _bgColor     = Color(0xFF0D1117);
const _cardColor   = Color(0xFF161B22);
const _teal        = Color(0xFF00C5A1);
const _amber       = Color(0xFFFFC107);
const _red         = Color(0xFFEF5350);
const _textPrimary = Color(0xFFE6EDF3);
const _textMuted   = Color(0xFF8B949E);

class ScreeningResultScreen extends StatelessWidget {
  final String patientId;
  final Map<String, dynamic> result;
  final Uint8List leftBytes;
  final Uint8List rightBytes;

  const ScreeningResultScreen({
    super.key, 
    required this.patientId, 
    required this.result, 
    required this.leftBytes,
    required this.rightBytes
  });

  @override
  Widget build(BuildContext context) {
    final leftResult = result['left'] as Map<String, dynamic>;
    final rightResult = result['right'] as Map<String, dynamic>;
    
    final leftGrade = leftResult['dr_grade'] as int;
    final rightGrade = rightResult['dr_grade'] as int;
    
    // User Constraint: Strict Triage Rule
    // is_urgent_refer = (left_eye_grade >= 3 || right_eye_grade >= 3)
    final isUrgent = (leftGrade >= 3 || rightGrade >= 3);
    final isReferable = (leftGrade >= 2 || rightGrade >= 2);

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _cardColor,
        elevation: 0,
        title: const Text('Capture Successful', style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w600)),
        iconTheme: const IconThemeData(color: _textPrimary),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),
              const Icon(Icons.check_circle_outline, color: _teal, size: 100),
              const SizedBox(height: 32),
              const Text(
                'Data Synced to Clinic',
                style: TextStyle(color: _textPrimary, fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'The fundus images have been successfully uploaded and are pending doctor review.',
                style: TextStyle(color: _textMuted, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () async {
                    await context.read<ConnectivityService>().refreshPendingCount();
                    if (!context.mounted) return;
                    await context.read<PatientRegistry>().refreshAll();
                    if (context.mounted) {
                      Navigator.of(context).pushNamedAndRemoveUntil('/', (Route<dynamic> route) => false);
                    }
                  },
                  child: const Text('Return to Dashboard', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
