# OptiXAI — Fix Instructions: `sync_service.dart`

Follow these steps in order. Each one is independent and can be verified separately — do not
combine or reorder them.

---

## STEP 1 — Fix the swallowed error messages (do this first, it's one character twice)

Find these two lines:
```dart
print("Failed to sync patient: \$e");
```
```dart
print("Failed to sync screening: \$e");
```

In a double-quoted Dart string, `\$` is an escaped literal dollar sign, not interpolation. These
lines currently print the literal text `Failed to sync patient: $e` every time, regardless of what
`e` actually is — the real exception object is never shown. This means every sync failure in the
app today is unloggable.

Change both to remove the backslash so `$e` actually interpolates:
```dart
print("Failed to sync patient: $e");
```
```dart
print("Failed to sync screening: $e");
```

**Verification for this step:** after the fix, temporarily change one line inside the patient
try-block to force a failure — e.g. `throw Exception('test forced failure');` right after
`final payload = {...};` — run `performSync()` once, and confirm the printed line shows
`Failed to sync patient: Exception: test forced failure`, not `Failed to sync patient: $e`. Then
remove the forced throw. Do not leave the forced throw in the shipped code.

---

## STEP 2 — Don't crash the sync run on a stale/expired background token

Find this in `callbackDispatcher`:
```dart
final refreshToken = inputData?['refresh_token'] as String?;
if (refreshToken != null) {
  await Supabase.instance.client.auth.recoverSession(refreshToken);
}

await SyncService.performSync();
```

`recoverSession` can throw if the token is expired, already rotated, or otherwise invalid. Right
now that throw is unhandled inside `callbackDispatcher`, which means `performSync()` never runs at
all for that background execution — the whole sync attempt is lost, silently, with no record of
why.

Wrap it and make the failure visible, and skip straight to `performSync()`'s own per-row error
handling instead of aborting the whole run:

```dart
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
```

Do not add a `return` inside the catch block. The point is that a stale token shouldn't kill the
entire background task before any attempt is made — let the per-row Supabase calls inside
`performSync()` fail and log naturally (this now works correctly because of Step 1).

**Verification for this step:** call `recoverSession` with a syntactically-plausible but garbage
token string (e.g. `'not.a.real.token'`) in a scratch test, confirm the `catch` block runs and
prints the message, and confirm execution continues to `performSync()` afterward rather than
throwing out of `callbackDispatcher`.

---

## STEP 3 — Fix the orphaned-screening failure mode

Currently, patients and screenings sync in two separate loops, each row's failure caught and
logged independently. If a specific patient's upsert fails, its screening will later fail on:
```dart
final patientRes = await supabase.from('patients').select('id').eq('local_id', s['patient_local_id'] as String).single();
```
`.single()` throws if zero rows match. That's caught by the screening's own try/catch and logged
(now correctly, after Step 1) — but the screening stays `pending` forever, retried every cycle,
with no way for anyone to know it's permanently stuck behind a different failing row.

Add an explicit, named check before the `.single()` call so the failure reason is unambiguous
rather than being an incidental side effect of a Postgrest error:

```dart
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
```

This replaces the `.single()` call and the line that assigned `payload['patient_id']` from it —
remove those two lines and put this block in their place. Note `continue` here refers to the
`for (var s in pendingScreenings)` loop — confirm this block is placed inside that loop, not
extracted into a separate function, or `continue` will not compile.

**Verification for this step:** in a scratch test against a local/test Supabase project (or by
temporarily inserting a screening row with a `patient_local_id` that has no matching patient row),
confirm the printed message names the skipped screening and its missing patient, and confirm the
screening's `sync_status` remains `pending` (not marked synced, not crashed) after the run.

---

## STEP 4 — Add a retry ceiling so a permanently-broken row doesn't retry forever silently

Right now a row that can never succeed (deleted image file, malformed data) retries every 15
minutes indefinitely with no visibility to a human. This step adds a bounded retry count without
changing the sync logic itself.

1. In `local_database.dart`, add a `sync_attempts` column to both tables. Since `onCreate` only
   runs for a fresh install, add a migration instead of editing `_createDB` directly:

   ```dart
   Future<Database> _initDB(String filePath) async {
     final dbPath = await getApplicationDocumentsDirectory();
     final path = join(dbPath.path, filePath);
     return await openDatabase(
       path,
       version: 2, // was 1
       onCreate: _createDB,
       onUpgrade: _onUpgrade,
     );
   }

   Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
     if (oldVersion < 2) {
       await db.execute('ALTER TABLE patients ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0');
       await db.execute('ALTER TABLE screenings ADD COLUMN sync_attempts INTEGER NOT NULL DEFAULT 0');
     }
   }
   ```

   Also add `sync_attempts INTEGER NOT NULL DEFAULT 0` to both `CREATE TABLE` statements in
   `_createDB`, so a fresh install has the column from the start too (both places need it — the
   migration only helps existing installs).

2. In `local_database.dart`, add a way to increment the counter and a way to fetch rows below a
   ceiling:
   ```dart
   Future<void> incrementPatientSyncAttempts(String localId) async {
     final db = await instance.database;
     await db.rawUpdate(
       'UPDATE patients SET sync_attempts = sync_attempts + 1 WHERE local_id = ?',
       [localId],
     );
   }

   Future<void> incrementScreeningSyncAttempts(String localId) async {
     final db = await instance.database;
     await db.rawUpdate(
       'UPDATE screenings SET sync_attempts = sync_attempts + 1 WHERE local_id = ?',
       [localId],
     );
   }
   ```

3. In `sync_service.dart`, in both catch blocks in `performSync()`, call the relevant increment
   function alongside the (now-fixed) print statement:
   ```dart
   } catch (e) {
     print("Failed to sync patient: $e");
     await db.incrementPatientSyncAttempts(p['local_id'] as String);
   }
   ```
   and the equivalent for screenings.

4. At the top of each loop body, skip rows that have exceeded a ceiling (use `5` as the starting
   value — this is a number to revisit with whoever owns field operations, not a hard requirement):
   ```dart
   if ((p['sync_attempts'] as int? ?? 0) >= 5) {
     print("Patient ${p['local_id']} exceeded sync retry limit — needs manual attention.");
     continue;
   }
   ```
   Do the same for screenings using `s['sync_attempts']`.

Do not build a UI for surfacing these stuck rows as part of this task — that's a separate,
larger piece of work. The goal here is only that a broken row stops retrying silently forever and
prints something identifiable in the logs.

**Verification for this step:** insert a patient row directly via SQL with `sync_attempts = 5`,
run `performSync()`, and confirm it's skipped with the printed message and that its
`sync_attempts` value doesn't change (since it never entered the try block).

---

## What NOT to do in this pass

- Do not touch `edge_inference.dart`, `image_ingestion_service.dart`, `providers.dart`, or the
  Supabase URL/key duplication between `main.dart` and `callbackDispatcher` — those are separate,
  already-tracked issues, not part of this fix.
- Do not change the 15-minute WorkManager frequency or the `NetworkType.connected` constraint.
- Do not add any UI changes. This is a backend/service-layer fix only.

## What "done" looks like

- Both `\$e` typos are fixed and verified with a forced-failure test.
- `callbackDispatcher` no longer aborts the entire sync task on a bad `recoverSession` call.
- A screening whose patient hasn't synced yet is explicitly skipped and logged, not silently
  retried via a generic `.single()` failure.
- Both tables have a working `sync_attempts` column (verified on both a fresh install and via the
  `onUpgrade` migration path), rows are skipped and logged once they hit the ceiling, and the
  four verification checks above all pass with real, pasted (not summarized) output.
