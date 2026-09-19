import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'local_database.dart';

class ConnectivityService extends ChangeNotifier {
  bool _isOnline = false;
  bool _isChecking = true;
  int _pendingSyncCount = 0;
  
  late StreamSubscription<List<ConnectivityResult>> _subscription;

  bool get isOnline => _isOnline;
  bool get isChecking => _isChecking;
  int get pendingSyncCount => _pendingSyncCount;

  ConnectivityService() {
    _init();
  }

  Future<void> _init() async {
    final results = await Connectivity().checkConnectivity();
    _updateStatus(results);
    
    _subscription = Connectivity().onConnectivityChanged.listen(_updateStatus);
    await refreshPendingCount();
  }

  void _updateStatus(List<ConnectivityResult> results) {
    _isChecking = false;
    _isOnline = results.contains(ConnectivityResult.mobile) || 
                results.contains(ConnectivityResult.wifi) ||
                results.contains(ConnectivityResult.ethernet);
    notifyListeners();
  }

  Future<void> refreshPendingCount() async {
    final pendingScreenings = await LocalDatabase.instance.getPendingScreenings();
    final pendingPatients = await LocalDatabase.instance.getPendingPatients();
    _pendingSyncCount = pendingScreenings.length + pendingPatients.length;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

class PatientRegistry extends ChangeNotifier {
  List<Map<String, dynamic>> _patients = [];
  List<Map<String, dynamic>> _recentScreenings = [];
  
  int _totalPatients = 0;
  int _completedScreenings = 0;
  int _highRisk = 0;
  int _moderateRisk = 0;

  List<Map<String, dynamic>> get patients => _patients;
  List<Map<String, dynamic>> get recentScreenings => _recentScreenings;
  
  int get totalPatients => _totalPatients;
  int get completedScreenings => _completedScreenings;
  int get highRisk => _highRisk;
  int get moderateRisk => _moderateRisk;

  PatientRegistry() {
    refreshAll();
  }

  Future<void> refreshAll() async {
    final db = LocalDatabase.instance;
    
    _patients = await db.getAllPatients();
    final allScreenings = await db.getAllScreenings();
    
    _recentScreenings = allScreenings.take(5).toList();
    
    _totalPatients = _patients.length;
    _completedScreenings = allScreenings.length;
    
    _highRisk = allScreenings.where((s) => s['is_urgent_refer'] == 1).length;
    _moderateRisk = allScreenings.where((s) => s['left_eye_grade'] == 2 || s['right_eye_grade'] == 2).length;

    notifyListeners();
  }
}
