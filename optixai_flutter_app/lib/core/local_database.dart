import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class LocalDatabase {
  static final LocalDatabase instance = LocalDatabase._init();
  static Database? _database;

  LocalDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('optixai_offline.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getApplicationDocumentsDirectory();
    final path = join(dbPath.path, filePath);

    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future<void> _createDB(Database db, int version) async {
    // 1. Patients Table
    await db.execute('''
    CREATE TABLE patients (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      local_id TEXT UNIQUE NOT NULL,
      asha_worker_id TEXT NOT NULL,
      full_name TEXT NOT NULL,
      age INTEGER,
      gender TEXT,
      contact_number TEXT,
      sync_status TEXT DEFAULT 'pending',
      created_at TEXT NOT NULL
    )
    ''');

    // 2. Screenings Table
    await db.execute('''
    CREATE TABLE screenings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      local_id TEXT UNIQUE NOT NULL,
      patient_local_id TEXT NOT NULL,
      left_eye_local_path TEXT,
      right_eye_local_path TEXT,
      left_eye_grade INTEGER,
      right_eye_grade INTEGER,
      is_urgent_refer INTEGER NOT NULL,
      thresholds_version TEXT NOT NULL,
      sync_status TEXT DEFAULT 'pending',
      screened_at TEXT NOT NULL,
      FOREIGN KEY (patient_local_id) REFERENCES patients (local_id) ON DELETE CASCADE
    )
    ''');
  }

  // --- CRUD Operations ---
  
  Future<void> insertPatient(Map<String, dynamic> patient) async {
    try {
      assert(patient['local_id'] != null, 'Patient local_id cannot be null');
      final db = await instance.database;
      await db.insert('patients', patient, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      print('DatabaseException in insertPatient: $e');
      rethrow;
    }
  }

  Future<void> insertScreening(Map<String, dynamic> screening) async {
    try {
      assert(screening['patient_local_id'] != null, 'patient_local_id cannot be null');
      assert(screening['left_eye_local_path'] != null, 'left_eye_local_path cannot be null');
      assert(screening['right_eye_local_path'] != null, 'right_eye_local_path cannot be null');
      
      final db = await instance.database;
      await db.insert('screenings', screening, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      print('DatabaseException in insertScreening: $e');
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getPendingPatients() async {
    final db = await instance.database;
    return await db.query('patients', where: 'sync_status = ?', whereArgs: ['pending']);
  }

  Future<List<Map<String, dynamic>>> getPendingScreenings() async {
    final db = await instance.database;
    return await db.query('screenings', where: 'sync_status = ?', whereArgs: ['pending']);
  }

  Future<void> markPatientSynced(String localId) async {
    final db = await instance.database;
    await db.update('patients', {'sync_status': 'synced'}, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> markScreeningSynced(String localId) async {
    final db = await instance.database;
    await db.update('screenings', {'sync_status': 'synced'}, where: 'local_id = ?', whereArgs: [localId]);
  }

  // --- UI Fetch Operations ---

  Future<List<Map<String, dynamic>>> getAllPatients() async {
    final db = await instance.database;
    return await db.query('patients', orderBy: 'created_at DESC');
  }

  Future<List<Map<String, dynamic>>> getAllScreenings() async {
    final db = await instance.database;
    return await db.query('screenings', orderBy: 'screened_at DESC');
  }

  Future<List<Map<String, dynamic>>> getRecentScreenings({int limit = 5}) async {
    final db = await instance.database;
    return await db.query('screenings', orderBy: 'screened_at DESC', limit: limit);
  }
}
