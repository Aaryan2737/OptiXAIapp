import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';
import 'local_database.dart';

class SyncService {
  static const String syncTaskName = "syncOfflineData";

  static void initialize() {
    Workmanager().initialize(
      callbackDispatcher,
    );
    
    final token = Supabase.instance.client.auth.currentSession?.refreshToken;

    // Register periodic background task
    Workmanager().registerPeriodicTask(
      "1",
      syncTaskName,
      frequency: const Duration(minutes: 15), // Android minimum is 15 minutes
      constraints: Constraints(
        networkType: NetworkType.connected, // Only run when internet is available
      ),
      inputData: token != null ? {'refresh_token': token} : null,
    );
  }

  static void registerOneOffSync() {
    final token = Supabase.instance.client.auth.currentSession?.refreshToken;
    Workmanager().registerOneOffTask(
      "oneOffSync",
      syncTaskName,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      inputData: token != null ? {'refresh_token': token} : null,
    );
  }

  // The actual sync logic that pushes SQLite data to Supabase
  static Future<void> performSync() async {
    final db = LocalDatabase.instance;
    final supabase = Supabase.instance.client;

    final ashaUser = supabase.auth.currentUser;
    if (ashaUser == null) {
      print("Cannot sync: User not logged in.");
      return;
    }

    // Lookup public ASHA worker ID to satisfy RLS
    final workerRes = await supabase
        .from('asha_workers')
        .select('id')
        .eq('auth_uid', ashaUser.id)
        .maybeSingle();

    if (workerRes == null) {
      print("Cannot sync: ASHA worker profile not found for current user.");
      return;
    }
    
    final ashaWorkerId = workerRes['id'] as String;

    // 1. Sync Patients
    final pendingPatients = await db.getPendingPatients();
    for (var p in pendingPatients) {
      if ((p['sync_attempts'] as int? ?? 0) >= 50) {
        print("Patient ${p['local_id']} exceeded sync retry limit — needs manual attention.");
        continue;
      }
      try {
        final payload = {
          'local_id': p['local_id'],
          'asha_worker_id': ashaWorkerId,
          'full_name': p['full_name'],
          'age': p['age'],
          'gender': p['gender'],
          'contact_number': p['contact_number'],
          'sync_status': 'synced',
        };
        // Upsert to Supabase
        await supabase.from('patients').upsert(payload, onConflict: 'local_id');
        // Mark locally synced
        await db.markPatientSynced(p['local_id'] as String);
        print("Synced Patient: ${p['local_id']}");
      } catch (e) {
        print("Failed to sync patient: $e");
        await db.incrementPatientSyncAttempts(p['local_id'] as String);
      }
    }

    // 2. Sync Screenings and Upload Images
    final pendingScreenings = await db.getPendingScreenings();
    for (var s in pendingScreenings) {
      if ((s['sync_attempts'] as int? ?? 0) >= 50) {
        print("Screening ${s['local_id']} exceeded sync retry limit — needs manual attention.");
        continue;
      }
      try {
        // Upload Left Eye Image
        if (s['left_eye_local_path'] != null) {
          final file = File(s['left_eye_local_path'] as String);
          final fileName = "left_${s['local_id']}.jpg";
          await supabase.storage.from('fundus-images').upload(fileName, file, fileOptions: const FileOptions(upsert: true));
        }

        // Upload Right Eye Image
        if (s['right_eye_local_path'] != null) {
          final file = File(s['right_eye_local_path'] as String);
          final fileName = "right_${s['local_id']}.jpg";
          await supabase.storage.from('fundus-images').upload(fileName, file, fileOptions: const FileOptions(upsert: true));
        }

        final payload = {
          'screening_id': s['local_id'],
          'asha_worker_id': ashaWorkerId,
          'left_eye_image_path': 'fundus-images/left_${s['local_id']}.jpg',
          'right_eye_image_path': 'fundus-images/right_${s['local_id']}.jpg',
          'ai_triage_grade_left': s['left_eye_grade'],
          'ai_triage_grade_right': s['right_eye_grade'],
          'ai_confidence_score': s['ai_confidence_score'] ?? 0.0,
          'is_urgent_referral': s['is_urgent_refer'] == 1 || s['is_urgent_refer'] == true,
          'clinical_status': 'pending_doctor_review',
          'thresholds_version': s['thresholds_version'] ?? 'v1.0',
        };

        // We must map local_id -> actual patient UUID in Supabase.
        // If the patient hasn't synced yet (e.g. failed in the loop above), skip this
        // screening for now rather than letting a generic .single() error mask the
        // real cause. It will be retried next cycle once the patient syncs.
        final patientRows = await supabase
            .from('patients')
            .select('id')
            .eq('local_id', s['patient_local_id'] as String)
            .limit(1);

        if (patientRows.isEmpty) {
          print("Skipping screening ${s['local_id']}: patient ${s['patient_local_id']} not yet synced.");
          continue;
        }
        payload['patient_id'] = patientRows.first['id'];

        // Upsert Screening
        await supabase.from('screenings').upsert(payload, onConflict: 'screening_id');
        // Mark locally synced
        await db.markScreeningSynced(s['local_id'] as String);
        print("Synced Screening: ${s['local_id']}");
      } catch (e) {
        print("Failed to sync screening: $e");
        await db.incrementScreeningSyncAttempts(s['local_id'] as String);
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
        publishableKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNldXZibWNobnRqeXRvdWF0aWd6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk4MDc1NTEsImV4cCI6MjEwNTM4MzU1MX0.dwnb4ZPvfHIjJS3zPIYhfISIUxpSHpmYJPFM-6vhhLM',
      );
      
      final refreshToken = inputData?['refresh_token'] as String?;
      if (refreshToken != null) {
        try {
          await Supabase.instance.client.auth.recoverSession(refreshToken);
        } catch (e) {
          print("Background sync: failed to recover session — $e");
          // Do not return early. If there's no valid session, performSync's own
          // Supabase calls will fail per-row and log individually below, which is
          // more informative than aborting the whole task silently here.
        }
      }
      
      await SyncService.performSync();
    }
    return Future.value(true);
  });
}
