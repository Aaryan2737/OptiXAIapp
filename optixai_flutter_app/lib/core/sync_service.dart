import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';
import 'local_database.dart';

class SyncService {
  static const String syncTaskName = "syncOfflineData";

  static void initialize() {
    Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: true, // Set to false in production
    );
    
    // Register periodic background task
    Workmanager().registerPeriodicTask(
      "1",
      syncTaskName,
      frequency: const Duration(minutes: 15), // Android minimum is 15 minutes
      constraints: Constraints(
        networkType: NetworkType.connected, // Only run when internet is available
      ),
    );
  }

  static void registerOneOffSync() {
    Workmanager().registerOneOffTask(
      "oneOffSync",
      syncTaskName,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }

  // The actual sync logic that pushes SQLite data to Supabase
  static Future<void> performSync() async {
    final db = LocalDatabase.instance;
    final supabase = Supabase.instance.client;

    // 1. Sync Patients
    final pendingPatients = await db.getPendingPatients();
    for (var p in pendingPatients) {
      try {
        final payload = {
          'local_id': p['local_id'],
          'asha_worker_id': p['asha_worker_id'],
          'full_name': p['full_name'],
          'age': p['age'],
          'gender': p['gender'],
          'contact_number': p['contact_number'],
          'sync_status': 'synced',
        };
        // Upsert to Supabase
        await supabase.from('patients').upsert(payload, onConflict: 'local_id');
        // Mark locally synced
        await db.markPatientSynced(p['local_id']);
        print("Synced Patient: \${p['local_id']}");
      } catch (e) {
        print("Failed to sync patient: \$e");
      }
    }

    // 2. Sync Screenings and Upload Images
    final pendingScreenings = await db.getPendingScreenings();
    for (var s in pendingScreenings) {
      try {
        String? leftImageUrl;
        String? rightImageUrl;

        // Upload Left Eye Image
        if (s['left_eye_image_path'] != null) {
          final file = File(s['left_eye_image_path']);
          final fileName = "left_${s['local_id']}.jpg";
          await supabase.storage.from('fundus-images').upload(fileName, file);
          leftImageUrl = supabase.storage.from('fundus-images').getPublicUrl(fileName);
        }

        // Upload Right Eye Image
        if (s['right_eye_image_path'] != null) {
          final file = File(s['right_eye_image_path']);
          final fileName = "right_${s['local_id']}.jpg";
          await supabase.storage.from('fundus-images').upload(fileName, file);
          rightImageUrl = supabase.storage.from('fundus-images').getPublicUrl(fileName);
        }

        final payload = {
          'local_id': s['local_id'],
          // We will assign the cloud patient_id after fetching it below
          'left_eye_image_url': leftImageUrl,
          'right_eye_image_url': rightImageUrl,
          'left_eye_grade': s['left_eye_grade'],
          'right_eye_grade': s['right_eye_grade'],
          'is_urgent_refer': s['is_urgent_refer'] == 1,
          'thresholds_version': s['thresholds_version'],
          'sync_status': 'synced',
        };

        // We must map local_id -> actual patient UUID in Supabase
        final patientRes = await supabase.from('patients').select('id').eq('local_id', s['patient_local_id']).single();
        payload['patient_id'] = patientRes['id'];

        // Upsert Screening
        await supabase.from('screenings').upsert(payload, onConflict: 'local_id');
        // Mark locally synced
        await db.markScreeningSynced(s['local_id']);
        print("Synced Screening: \${s['local_id']}");
      } catch (e) {
        print("Failed to sync screening: \$e");
      }
    }
  }
}

// Top-level function required by WorkManager
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == SyncService.syncTaskName) {
      print("WorkManager triggered background sync...");
      
      // CRITICAL FIX: The background isolate has no access to main.dart's initialization.
      // Supabase MUST be initialized here before attempting to sync.
      // Replace with your actual URL and Anon Key via env or secure storage in production.
      await Supabase.initialize(
        url: 'https://ceuvbmchntjytouatigz.supabase.co',
        anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNldXZibWNobnRqeXRvdWF0aWd6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk4MDc1NTEsImV4cCI6MjEwNTM4MzU1MX0.dwnb4ZPvfHIjJS3zPIYhfISIUxpSHpmYJPFM-6vhhLM',
      );
      
      await SyncService.performSync();
    }
    return Future.value(true);
  });
}
