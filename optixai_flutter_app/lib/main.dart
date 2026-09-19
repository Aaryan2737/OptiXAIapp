import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/sync_service.dart';
import 'ui/image_review_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Supabase
  await Supabase.initialize(
    url: 'https://ceuvbmchntjytouatigz.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNldXZibWNobnRqeXRvdWF0aWd6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk4MDc1NTEsImV4cCI6MjEwNTM4MzU1MX0.dwnb4ZPvfHIjJS3zPIYhfISIUxpSHpmYJPFM-6vhhLM',
  );

  // 2. Initialize WorkManager for true background sync
  SyncService.initialize();

  runApp(const OptiXAIApp());
}

class OptiXAIApp extends StatelessWidget {
  const OptiXAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OptiXAI - DR Screening',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorSchemeSeed: const Color(0xFF00C5A1),
        useMaterial3: true,
        fontFamily: 'Inter',
      ),
      // For demo purposes, we route directly to the screening screen.
      // In production, this would go through an auth flow first.
      home: const ImageReviewScreen(patientId: 'demo-patient-001'),
      routes: {
        '/screening-result': (context) => const _ScreeningResultPlaceholder(),
      },
    );
  }
}

/// Placeholder for the screening result screen.
/// This will be replaced with the full clinical result UI in a later phase.
class _ScreeningResultPlaceholder extends StatelessWidget {
  const _ScreeningResultPlaceholder();

  @override
  Widget build(BuildContext context) {
    final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
    final result = args['result'] as Map<String, dynamic>;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Screening Result', style: TextStyle(color: Color(0xFFE6EDF3))),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DR Grade: ${result['dr_grade']}',
              style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              'Confidence: ${(result['confidence_score'] * 100).toStringAsFixed(1)}%',
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 18),
            ),
            const SizedBox(height: 12),
            Text(
              result['is_urgent_refer'] ? '🚨 URGENT REFER' : (result['is_referable'] ? '⚠️ ROUTINE REFER' : '✅ NO DR DETECTED'),
              style: TextStyle(
                color: result['is_urgent_refer'] ? const Color(0xFFEF5350) : (result['is_referable'] ? const Color(0xFFFFC107) : const Color(0xFF00C5A1)),
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
