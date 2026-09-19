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
    
    final riskColor = isUrgent ? _red : (isReferable ? _amber : _teal);
    final riskLabel = isUrgent ? 'URGENT REFERRAL' : (isReferable ? 'MODERATE RISK' : 'NORMAL');

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _cardColor,
        elevation: 0,
        title: const Text('Bilateral Analysis Complete', style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w600)),
        iconTheme: const IconThemeData(color: _textPrimary),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Left Eye (OS)', style: TextStyle(color: _textMuted, fontSize: 13, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(leftBytes, height: 140, width: double.infinity, fit: BoxFit.cover),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Right Eye (OD)', style: TextStyle(color: _textMuted, fontSize: 13, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(rightBytes, height: 140, width: double.infinity, fit: BoxFit.cover),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: riskColor.withValues(alpha: 0.15),
                  border: Border.all(color: riskColor.withValues(alpha: 0.5), width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Text(riskLabel, style: TextStyle(color: riskColor, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildGradeColumn('OS (Left)', leftGrade, leftResult['confidence_score'] as double),
                        Container(height: 40, width: 1, color: _textMuted.withValues(alpha: 0.3)),
                        _buildGradeColumn('OD (Right)', rightGrade, rightResult['confidence_score'] as double),
                      ],
                    )
                  ],
                ),
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

  Widget _buildGradeColumn(String label, int grade, double confidence) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: _textMuted, fontSize: 12)),
        const SizedBox(height: 4),
        Text('Grade $grade', style: const TextStyle(color: _textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text('${(confidence * 100).toStringAsFixed(1)}%', style: const TextStyle(color: _textMuted, fontSize: 12)),
      ],
    );
  }
}
