import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/sync_service.dart';
import 'core/providers.dart';
import 'theme/app_colors.dart';

import 'ui/dashboard_screen.dart';
import 'ui/new_patient_screen.dart';
import 'ui/patient_list_screen.dart';
import 'ui/capture_screen.dart';
import 'ui/screening_result_screen.dart';
import 'ui/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Supabase
  await Supabase.initialize(
    url: 'https://ceuvbmchntjytouatigz.supabase.co',
    publishableKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNldXZibWNobnRqeXRvdWF0aWd6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk4MDc1NTEsImV4cCI6MjEwNTM4MzU1MX0.dwnb4ZPvfHIjJS3zPIYhfISIUxpSHpmYJPFM-6vhhLM',
  );

  // 2. Initialize WorkManager for true background sync
  SyncService.initialize();

  // 3. Run with Providers
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ConnectivityService()),
        ChangeNotifierProvider(create: (_) => PatientRegistry()),
      ],
      child: const OptiXAIApp(),
    ),
  );
}

class OptiXAIApp extends StatelessWidget {
  const OptiXAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OptiXAI - DR Screening',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.background,
        colorSchemeSeed: AppColors.primary,
        useMaterial3: true,
        fontFamily: 'Roboto', // Default fallback
      ),
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(builder: (_) => const AuthWrapper());
          case '/new_patient':
            return MaterialPageRoute(builder: (_) => const NewPatientScreen());
          case '/patient_list':
            return MaterialPageRoute(builder: (_) => const PatientListScreen());
          case '/screening_flow':
            // Instead of a dedicated intermediate screen, we just go to PatientList to pick a patient.
            return MaterialPageRoute(builder: (_) => const PatientListScreen());
          case '/capture':
            final patientId = settings.arguments as String;
            return MaterialPageRoute(builder: (_) => CaptureScreen(patientId: patientId));
          case '/screening_result':
            final args = settings.arguments as Map<String, dynamic>;
            return MaterialPageRoute(
              builder: (_) => ScreeningResultScreen(
                patientId: args['patientId'] as String,
                result: args['result'] as Map<String, dynamic>,
                leftBytes: args['leftBytes'] as Uint8List,
                rightBytes: args['rightBytes'] as Uint8List,
              ),
            );
          default:
            return MaterialPageRoute(builder: (_) => const AuthWrapper());
        }
      },
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  @override
  void initState() {
    super.initState();
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      return const DashboardScreen();
    }
    return const LoginScreen();
  }
}
