import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

import '../db/database_helper.dart';
import '../models/models.dart';

/// Central Firebase Integration Service for Namat Oil Mill.
///
/// Designed to be resilient: if Firebase has not yet been configured with
/// `google-services.json`, the app degrades gracefully to 100% offline SQLite
/// without crashing, and reports [isConfigured] as false.
class FirebaseService {
  FirebaseService._();
  static final FirebaseService instance = FirebaseService._();

  bool _isConfigured = false;
  bool get isConfigured => _isConfigured;

  FirebaseAuth? _auth;
  FirebaseFirestore? _firestore;

  FirebaseAuth? get auth => _auth;
  FirebaseFirestore? get firestore => _firestore;

  User? get currentUser => _isConfigured ? _auth?.currentUser : null;
  Stream<User?> get authStateChanges => _isConfigured
      ? (_auth?.authStateChanges() ?? const Stream.empty())
      : const Stream.empty();

  /// Initializes Firebase safely. Returns true if Firebase is active.
  Future<bool> initialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      _auth = FirebaseAuth.instance;
      _firestore = FirebaseFirestore.instance;

      // Enable offline persistence for Cloud Firestore
      _firestore!.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );

      _isConfigured = true;
      debugPrint('Firebase successfully initialized for Namat Oil Mill');
      return true;
    } catch (e) {
      _isConfigured = false;
      debugPrint('Firebase not initialized (Offline mode active): $e');
      return false;
    }
  }

  // ---------------- Authentication ----------------

  /// Signs in using Email & Password.
  Future<UserCredential?> signInWithEmail(String email, String password) async {
    if (!_isConfigured || _auth == null) {
      throw StateError(
          'Firebase is not yet configured. Please add google-services.json.');
    }
    return _auth!.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  /// Registers a new account using Email & Password.
  Future<UserCredential?> registerWithEmail(
      String email, String password) async {
    if (!_isConfigured || _auth == null) {
      throw StateError(
          'Firebase is not yet configured. Please add google-services.json.');
    }
    return _auth!.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  /// Signs the user out.
  Future<void> signOut() async {
    if (_isConfigured && _auth != null) {
      await _auth!.signOut();
    }
  }

  // ---------------- Cloud Firestore Sync ----------------

  /// Syncs all local SQLite data for [businessId] up to Cloud Firestore.
  Future<int> syncAllLocalToCloud(int businessId) async {
    if (!_isConfigured || _firestore == null) {
      throw StateError('Firebase is not configured for cloud sync.');
    }

    final db = DatabaseHelper.instance;
    final batch = _firestore!.batch();
    int syncedCount = 0;

    final bizRef = _firestore!.collection('businesses').doc('$businessId');

    // 1. Business Info
    final businesses = await db.getBusinesses();
    Business? business;
    for (final b in businesses) {
      if (b.id == businessId) {
        business = b;
        break;
      }
    }
    if (business != null) {
      batch.set(
          bizRef,
          {
            'name': business.name,
            'owner': business.owner,
            'phone': business.phone,
            'address': business.address,
            'updated_at': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true));
      syncedCount++;
    }

    // 2. Parties
    final parties = await db.getParties(businessId);
    for (final p in parties) {
      if (p.id == null) continue;
      final docRef = bizRef.collection('parties').doc('${p.id}');
      batch.set(
          docRef,
          {
            ...p.toMap(),
            'updated_at': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true));
      syncedCount++;
    }

    // 3. Stock Items
    final items = await db.getItems(businessId);
    for (final item in items) {
      if (item.id == null) continue;
      final docRef = bizRef.collection('items').doc('${item.id}');
      batch.set(
          docRef,
          {
            ...item.toMap(),
            'updated_at': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true));
      syncedCount++;
    }

    // 4. Production Batches
    final batches = await db.getProductionBatches(businessId);
    for (final b in batches) {
      if (b.id == null) continue;
      final docRef = bizRef.collection('production_batches').doc('${b.id}');
      batch.set(
          docRef,
          {
            ...b.toMap(),
            'updated_at': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true));
      syncedCount++;
    }

    // Commit batch
    await batch.commit();
    return syncedCount;
  }

  /// Restores cloud data for [businessId] down to SQLite.
  Future<int> restoreCloudToLocal(int businessId) async {
    if (!_isConfigured || _firestore == null) {
      throw StateError('Firebase is not configured.');
    }

    final db = DatabaseHelper.instance;
    final bizRef = _firestore!.collection('businesses').doc('$businessId');
    int restored = 0;

    // Restore parties
    final partiesSnap = await bizRef.collection('parties').get();
    for (final doc in partiesSnap.docs) {
      final data = doc.data();
      final party = Party.fromMap(data);
      if (party.id != null) {
        final existing = await db.getParty(party.id!);
        if (existing == null) {
          await (await db.db).insert('parties', party.toMap());
        } else {
          await db.updateParty(party);
        }
        restored++;
      }
    }

    // Restore items
    final itemsSnap = await bizRef.collection('items').get();
    for (final doc in itemsSnap.docs) {
      final data = doc.data();
      final item = StockItem.fromMap(data);
      if (item.id != null) {
        final existing = await (await db.db)
            .query('items', where: 'id = ?', whereArgs: [item.id]);
        if (existing.isEmpty) {
          await (await db.db).insert('items', item.toMap());
        } else {
          await db.updateItem(item);
        }
        restored++;
      }
    }

    return restored;
  }
  /// Document id for one synced row in the v2 cloud layout: its local
  /// id, or a positional fallback for the rare row without one.
  static String rowDocId(Map<String, dynamic> row, int index) {
    final id = row['id'];
    return id != null ? '$id' : 'x$index';
  }

}

/// One app-user record (Firestore collection `app_users`, doc id = username).
/// Created ONLY by the app admin; the user signs in with username, email or
/// phone + password. Passwords are stored in plain text in the `password`
/// field (owner's explicit choice, 2026-11-08) so the owner can view or
/// change any user's password directly from the Firebase Console.
class AppUserRecord {
  final String username;
  final String businessName;
  final String email;
  final String phone;
  final bool active;
  const AppUserRecord({
    required this.username,
    required this.businessName,
    this.email = '',
    this.phone = '',
    this.active = true,
  });
}

extension FirebaseUsers on FirebaseService {
  /// Legacy records (created by older builds) stored only this salted
  /// hash; accepted once at sign-in and upgraded to plain text.
  static String _hashPw(String password, String salt) =>
      sha256.convert(utf8.encode('$salt:$password')).toString();

  CollectionReference<Map<String, dynamic>> get _users =>
      firestore!.collection('app_users');

  /// Finds a user by username, email, or phone. Null when not found.
  Future<Map<String, dynamic>?> _findUserDoc(String identifier) async {
    final id = identifier.trim();
    final byName = await _users.doc(id.toLowerCase()).get();
    if (byName.exists) return {'id': byName.id, ...byName.data()!};
    for (final field in ['email', 'phone']) {
      final q = await _users.where(field, isEqualTo: id).limit(1).get();
      if (q.docs.isNotEmpty) {
        return {'id': q.docs.first.id, ...q.docs.first.data()};
      }
    }
    return null;
  }

  /// Verifies sign-in credentials. Returns the user record on success.
  /// Throws a [StateError] with a user-facing code on failure:
  /// 'wrong' (no such user / bad password) or 'inactive'.
  Future<AppUserRecord> loginUser(String identifier, String password) async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    final doc = await _findUserDoc(identifier);
    if (doc == null) throw StateError('wrong');
    if (doc['active'] == false) throw StateError('inactive');
    final username = doc['id'] as String;
    if ((doc['password'] as String?) != password) {
      final legacy = doc['password_hash'] == _hashPw(password, username);
      if (!legacy) throw StateError('wrong');
      // Upgrade the legacy hashed record to plain text (owner's choice).
      await _users.doc(username).update({
        'password': password,
        'password_hash': FieldValue.delete(),
      });
    }
    final rec = AppUserRecord(
      username: username,
      businessName: (doc['business_name'] as String?) ?? '',
      email: (doc['email'] as String?) ?? '',
      phone: (doc['phone'] as String?) ?? '',
    );
    await cacheLogin(rec, password);
    return rec;
  }

  /// Smallest positive integer (as a string) not already used as a
  /// username — the admin no longer types user IDs by hand, every new
  /// user automatically gets a different one (existing IDs are numeric:
  /// '1', '2', ...). [createUser] still re-checks for a clash.
  Future<String> generateUserId() async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    final snap = await _users.get();
    final used = <int>{};
    for (final d in snap.docs) {
      final n = int.tryParse(d.id);
      if (n != null && n > 0) used.add(n);
    }
    var candidate = 1;
    while (used.contains(candidate)) {
      candidate++;
    }
    return '$candidate';
  }

  Future<void> createUser({
    required String username,
    required String businessName,
    required String email,
    required String phone,
    required String password,
  }) async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    final uname = username.trim().toLowerCase();
    final existing = await _users.doc(uname).get();
    if (existing.exists) throw StateError('user-exists');
    await _users.doc(uname).set({
      'business_name': businessName.trim(),
      'email': email.trim(),
      'phone': phone.trim(),
      'password': password,
      'active': true,
      'created_at': FieldValue.serverTimestamp(),
    });
  }

  Future<List<AppUserRecord>> listUsers() async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    final snap = await _users.get();
    final out = snap.docs
        .map((d) => AppUserRecord(
              username: d.id,
              businessName: (d.data()['business_name'] as String?) ?? '',
              email: (d.data()['email'] as String?) ?? '',
              phone: (d.data()['phone'] as String?) ?? '',
              active: d.data()['active'] != false,
            ))
        .toList()
      ..sort((a, b) => a.username.compareTo(b.username));
    return out;
  }

  Future<void> setUserPassword(String username, String newPassword) async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    await _users.doc(username).update({
      'password': newPassword,
      'password_hash': FieldValue.delete(),
    });
  }

  Future<void> setUserActive(String username, bool active) async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    await _users.doc(username).update({'active': active});
  }

  Future<void> deleteUser(String username) async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    await _users.doc(username).delete();
  }

  /// Changes the signed-in user's own password (verifies the old one).
  Future<void> changeOwnPassword(
      String username, String oldPassword, String newPassword) async {
    final doc = await _findUserDoc(username);
    if (doc == null) throw StateError('wrong');
    if ((doc['password'] as String?) != oldPassword &&
        doc['password_hash'] != _hashPw(oldPassword, username)) {
      throw StateError('wrong');
    }
    await setUserPassword(username, newPassword);
    final cached = await _cachedUsers();
    if (cached.containsKey(username)) {
      cached[username]['password'] = newPassword;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cached_users', jsonEncode(cached));
    }
  }

  // ---------- Offline sign-in cache (this device only) ----------
  Future<Map<String, dynamic>> _cachedUsers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('cached_users');
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> cacheLogin(AppUserRecord rec, String password) async {
    final cached = await _cachedUsers();
    cached[rec.username] = {
      'business_name': rec.businessName,
      'email': rec.email,
      'phone': rec.phone,
      'password': password,
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_users', jsonEncode(cached));
    await prefs.setString('last_login_username', rec.username);
  }

  /// The user who most recently signed in online on THIS device (used by
  /// the fingerprint sign-in on the login screen). Null when none.
  Future<AppUserRecord?> cachedPrimaryUser() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('last_login_username');
    if (last == null || last.isEmpty) return null;
    final cached = await _cachedUsers();
    final v = cached[last];
    if (v == null) return null;
    final m = Map<String, dynamic>.from(v as Map);
    return AppUserRecord(
      username: last,
      businessName: (m['business_name'] as String?) ?? '',
      email: (m['email'] as String?) ?? '',
      phone: (m['phone'] as String?) ?? '',
    );
  }

  /// Offline fallback: verifies against the record cached on THIS device
  /// from a previous successful online sign-in.
  Future<AppUserRecord?> loginUserCached(
      String identifier, String password) async {
    final cached = await _cachedUsers();
    final id = identifier.trim().toLowerCase();
    for (final e in cached.entries) {
      final v = Map<String, dynamic>.from(e.value as Map);
      if (e.key == id || v['email'] == identifier.trim() || v['phone'] == identifier.trim()) {
        if (v['password'] == password ||
            v['password_hash'] == _hashPw(password, e.key)) {
          return AppUserRecord(
            username: e.key,
            businessName: (v['business_name'] as String?) ?? '',
            email: (v['email'] as String?) ?? '',
            phone: (v['phone'] as String?) ?? '',
          );
        }
        return null;
      }
    }
    return null;
  }

  // ---------- Per-user full data sync ----------
  /// Cloud layout v2 (one document per row, so every entry is visible in
  /// the Firebase Console and no table can hit the 1 MiB single-document
  /// limit): app_users/{username}/tables/{table}/rows/{rowId}, with the
  /// row's own fields as the document. The table document itself only
  /// holds a summary (row_count, updated_at). Restore still understands
  /// the legacy layout (a `rows` array on the table document).
  ///
  /// Entry photos (attachment_path) are uploaded to Firebase Storage
  /// under users/{username}/... and the row document carries their cloud
  /// path as `attachment_storage`; restore downloads them back.

  /// How many data rows this user's cloud backup currently holds
  /// (0 = no backup yet). Reads the v2 row_count summaries, falling back
  /// to the legacy rows arrays.
  Future<int> cloudRowCount(String username) async {
    if (!isConfigured) return 0;
    final snap = await _users.doc(username).collection('tables').get();
    var count = 0;
    for (final doc in snap.docs) {
      final summary = doc.data()['row_count'];
      if (summary is num) {
        count += summary.toInt();
      } else {
        count += ((doc.data()['rows'] as List?) ?? const []).length;
      }
    }
    return count;
  }

  /// Uploads one row's attachment photo to Firebase Storage (skipped
  /// when the same file was already uploaded from this device) and
  /// records its cloud path on the row as `attachment_storage`.
  Future<void> _attachCloudImage(String username, int businessId,
      String table, Map<String, dynamic> row) async {
    final local = row['attachment_path'];
    if (local is! String || local.isEmpty) return;
    final storagePath =
        'users/$username/biz$businessId/$table/${row['id'] ?? 'x'}/${p.basename(local)}';
    try {
      final file = File(local);
      if (!await file.exists()) return;
      final prefs = await SharedPreferences.getInstance();
      final key = 'img_uploaded:$storagePath';
      final size = await file.length();
      if (prefs.getInt(key) != size) {
        await FirebaseStorage.instance.ref(storagePath).putFile(file);
        await prefs.setInt(key, size);
      }
      row['attachment_storage'] = storagePath;
    } catch (_) {
      // Best effort: the row still syncs, and the next sync retries.
    }
  }

  /// Inverse of [_attachCloudImage] during restore: downloads the cloud
  /// photo into the local attachments folder and points the row's
  /// attachment_path at it. Always strips `attachment_storage` (it is
  /// not a database column).
  Future<void> _resolveCloudImage(Map<String, dynamic> row) async {
    final storagePath = row.remove('attachment_storage');
    if (storagePath is! String || storagePath.isEmpty) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final attDir = Directory(p.join(dir.path, 'attachments'));
      if (!await attDir.exists()) await attDir.create(recursive: true);
      final segments = storagePath.split('/');
      final rowPart = segments.length >= 2 ? segments[segments.length - 2] : 'x';
      final file =
          File(p.join(attDir.path, '${rowPart}_${p.basename(storagePath)}'));
      if (!await file.exists()) {
        final bytes = await FirebaseStorage.instance.ref(storagePath).getData();
        if (bytes == null) return;
        await file.writeAsBytes(bytes);
      }
      row['attachment_path'] = file.path;
    } catch (_) {
      row.remove('attachment_path');
    }
  }

  /// Stable per-device id (persisted), used to detect when a DIFFERENT
  /// device synced this user's cloud data since this device last did.
  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null || id.isEmpty) {
      id = 'd${DateTime.now().millisecondsSinceEpoch}'
          '-${DateTime.now().microsecondsSinceEpoch % 100000}';
      await prefs.setString('device_id', id);
    }
    return id;
  }

  /// Conflict safety net: copies the CURRENT cloud data into
  /// app_users/{username}/snapshots/{timestamp} before this device
  /// overwrites it, so entries synced from another device are never
  /// silently lost. Only the newest 3 snapshots are kept.
  Future<void> _snapshotCloudBeforeOverwrite(String username) async {
    final root = _users.doc(username);
    final tablesSnap = await root.collection('tables').get();
    if (tablesSnap.docs.isEmpty) return;
    final snapRef = root
        .collection('snapshots')
        .doc('${DateTime.now().millisecondsSinceEpoch}');
    final counts = <String, int>{};
    for (final doc in tablesSnap.docs) {
      final rowsSnap = await doc.reference.collection('rows').get();
      final List<dynamic> rows;
      if (rowsSnap.docs.isNotEmpty) {
        rows = rowsSnap.docs.map((d) => d.data()).toList();
      } else {
        rows = (doc.data()['rows'] as List?) ?? const [];
      }
      if (rows.isEmpty) continue;
      counts[doc.id] = rows.length;
      await snapRef.collection('tables').doc(doc.id).set({'rows': rows});
    }
    if (counts.isEmpty) return;
    await snapRef.set({
      'created_at': FieldValue.serverTimestamp(),
      'reason': 'another device synced since this device last did',
      'tables': counts,
    });
    final snaps = await root.collection('snapshots').get();
    final ids = snaps.docs.map((d) => d.id).toList()..sort();
    while (ids.length > 3) {
      final oldRef = root.collection('snapshots').doc(ids.removeAt(0));
      final oldTables = await oldRef.collection('tables').get();
      for (final t in oldTables.docs) {
        await t.reference.delete();
      }
      await oldRef.delete();
    }
  }

  Future<int> syncUserData(String username, int businessId) async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    final data = await DatabaseHelper.instance.exportBusinessData(businessId);
    // Safety: an EMPTY local business must never wipe a cloud backup
    // that still holds data (e.g. signing in on a fresh phone before
    // the restore runs). Skip the upload in that case.
    var localRows = 0;
    for (final e in data.entries) {
      if (e.key == 'app' || e.key == 'version') continue;
      localRows += (e.value as List).length;
    }
    if (localRows == 0) {
      try {
        final cloud = await cloudRowCount(username);
        if (cloud > 0) return cloud;
      } catch (_) {
        return 0; // cannot verify the cloud copy — write nothing
      }
    }
    // Conflict guard: if a DIFFERENT device synced this user's data
    // after this device's last sync, preserve that cloud state as a
    // snapshot first — this device's upload then wins, but nothing is
    // silently lost and no duplicates are created (the upload below is
    // keyed by row id and removes stale rows).
    final myDevice = await _deviceId();
    final prefs = await SharedPreferences.getInstance();
    try {
      final userDoc = await _users.doc(username).get();
      final cloudDevice = userDoc.data()?['last_sync_device'] as String?;
      final cloudAt =
          (userDoc.data()?['last_sync_at'] as Timestamp?)?.toDate();
      final myLastIso = prefs.getString('last_sync_at_$username');
      final myLast = myLastIso == null ? null : DateTime.tryParse(myLastIso);
      if (cloudDevice != null &&
          cloudDevice != myDevice &&
          cloudAt != null &&
          (myLast == null || cloudAt.isAfter(myLast))) {
        await _snapshotCloudBeforeOverwrite(username);
      }
    } catch (_) {
      // The snapshot is a safety net, never a blocker for the sync.
    }
    final root = _users.doc(username).collection('tables');
    var count = 0;
    for (final entry in data.entries) {
      if (entry.key == 'app' || entry.key == 'version') continue;
      final table = entry.key;
      final rows = (entry.value as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      for (final row in rows) {
        await _attachCloudImage(username, businessId, table, row);
      }
      final tableRef = root.doc(table);
      final rowsRef = tableRef.collection('rows');
      final existing = await rowsRef.get();
      final staleIds =
          existing.docs.map((d) => d.id).toSet();
      var batch = _firestore!.batch();
      var ops = 0;
      Future<void> flush() async {
        if (ops == 0) return;
        await batch.commit();
        batch = _firestore!.batch();
        ops = 0;
      }

      for (var i = 0; i < rows.length; i++) {
        final id = FirebaseService.rowDocId(rows[i], i);
        staleIds.remove(id);
        batch.set(rowsRef.doc(id), rows[i]);
        if (++ops >= 400) await flush();
      }
      for (final oldId in staleIds) {
        batch.delete(rowsRef.doc(oldId));
        if (++ops >= 400) await flush();
      }
      await flush();
      // Replaces the table document, dropping any legacy `rows` array.
      await tableRef.set({
        'row_count': rows.length,
        'updated_at': FieldValue.serverTimestamp(),
      });
      count += rows.length;
    }
    await _users.doc(username).set({
      'last_sync_at': FieldValue.serverTimestamp(),
      'last_sync_count': count,
      'last_sync_device': myDevice,
    }, SetOptions(merge: true));
    await prefs.setString(
        'last_sync_at_$username', DateTime.now().toIso8601String());
    return count;
  }

  /// Downloads this user's cloud data and replaces the local data of
  /// [businessId]. Returns the number of rows restored (0 = nothing in
  /// cloud). Reads the v2 per-row documents, falling back to the legacy
  /// rows-array layout per table.
  Future<int> restoreUserData(String username, int businessId) async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    final root = _users.doc(username).collection('tables');
    final snap = await root.get();
    if (snap.docs.isEmpty) return 0;
    final data = <String, dynamic>{'app': 'namat_oil_mill', 'version': 1};
    var count = 0;
    for (final doc in snap.docs) {
      final rowsSnap = await doc.reference.collection('rows').get();
      final List<Map<String, dynamic>> rows;
      if (rowsSnap.docs.isNotEmpty) {
        rows = rowsSnap.docs
            .map((d) => Map<String, dynamic>.from(d.data()))
            .toList()
          ..sort((a, b) =>
              ((a['id'] as num?) ?? 0).compareTo((b['id'] as num?) ?? 0));
      } else {
        final legacy = (doc.data()['rows'] as List?) ?? const [];
        rows = legacy
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
      }
      for (final row in rows) {
        await _resolveCloudImage(row);
      }
      data[doc.id] = rows;
      count += rows.length;
    }
    if (count == 0) return 0;
    await DatabaseHelper.instance.importBusinessData(businessId, data);
    return count;
  }
}
