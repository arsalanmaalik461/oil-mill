import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

import '../db/database_helper.dart';
import '../utils/google_drive_service.dart';
import '../models/models.dart';

/// Central Firebase Integration Service for Namat Oil Mill.
///
/// Designed to be resilient: if Firebase has not yet been configured with
/// `google-services.json`, the app degrades gracefully to 100% offline SQLite
/// without crashing, and reports [isConfigured] as false.
class FirebaseService {
  /// The login-time decision, kept pure so it can be unit-tested:
  /// whichever side holds more rows wins. 'restore' = download the
  /// cloud copy, 'upload' = push this device's copy up, 'none' =
  /// both sides empty.
  static String loginSyncDecision(int localRows, int cloudRows) {
    if (cloudRows > localRows) return 'restore';
    if (localRows > 0) return 'upload';
    return 'none';
  }

  /// The one normalization every username goes through (createUser
  /// applies it too): trimmed + lowercased. The username becomes the
  /// Firestore document id, so it must be produced identically
  /// everywhere.
  static String normalizeUsername(String raw) => raw.trim().toLowerCase();

  /// Whether [newUsername] actually renames [currentUsername] after
  /// normalization — a rename is a data MOVE (doc id + subcollection
  /// root + sync-cache keys), not a field edit.
  static bool isUsernameRename(String currentUsername, String newUsername) =>
      normalizeUsername(currentUsername) != normalizeUsername(newUsername);

  /// Validates a proposed username from the admin edit form against
  /// the existing doc ids. Returns a StateError code or null:
  /// 'username-empty' | 'user-exists'. Keeping the SAME username is
  /// valid — that is an in-place field edit, not a rename.
  static String? validateUsernameChange(String currentUsername,
      String newUsername, Set<String> existingUsernames) {
    final next = normalizeUsername(newUsername);
    if (next.isEmpty) return 'username-empty';
    if (next != normalizeUsername(currentUsername) &&
        existingUsernames.contains(next)) {
      return 'user-exists';
    }
    return null;
  }

  /// Light contact validation for the owner self-edit form (Settings
  /// > Account): the email must be non-empty and contain '@'; the
  /// phone must carry at least 7 digits (spaces/dashes ignored).
  /// Returns 'invalid-email' | 'invalid-phone' | null.
  static String? validateContact(
      {required String email, required String phone}) {
    final e = email.trim();
    if (e.isEmpty || !e.contains('@')) return 'invalid-email';
    if (phone.replaceAll(RegExp(r'\D'), '').length < 7) {
      return 'invalid-phone';
    }
    return null;
  }

  /// Content fingerprint of one business's full export (the shape
  /// produced by exportBusinessData): a [tableSyncHash] over every
  /// table's combined hash. Two exports holding the same rows — in
  /// any order — fingerprint equal; ANY value change (e.g. a phone
  /// number filled in) changes it, even though the row COUNT does
  /// not move. Built on the delta-sync row hashes, so the cloud-only
  /// keys (`_sync_hash`, `attachment_drive_id`) never affect it.
  static String businessFingerprint(Map<String, dynamic> data) {
    final tables = <String, String>{};
    for (final e in data.entries) {
      if (e.key == 'app' || e.key == 'version') continue;
      final rows = (e.value as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      final hashes = <String, String>{};
      for (var i = 0; i < rows.length; i++) {
        hashes[rowDocId(rows[i], i)] = rowSyncHash(rows[i]);
      }
      tables[e.key] = tableSyncHash(hashes);
    }
    return tableSyncHash(tables);
  }

  /// The login decision when content fingerprints are known. Row
  /// counts cannot see value-only changes — filling in party phone
  /// numbers on one phone adds no rows — so without fingerprints the
  /// second phone kept its stale copy and its uploads overwrote the
  /// filled numbers in the cloud. Rule: if the cloud fingerprint has
  /// moved since this device's last sync (another device synced)
  /// AND this device's local content is exactly what it last synced
  /// (nothing unsynced to lose), restore the cloud copy. In every
  /// other case the richer-side-wins count rule decides, unchanged.
  static String loginSyncDecisionV2({
    required int localRows,
    required int cloudRows,
    required String? localFingerprint,
    required String? cloudFingerprint,
    required String? lastSyncedFingerprint,
  }) {
    if (cloudFingerprint != null &&
        lastSyncedFingerprint != null &&
        cloudFingerprint != lastSyncedFingerprint &&
        localFingerprint == lastSyncedFingerprint) {
      return 'restore';
    }
    return loginSyncDecision(localRows, cloudRows);
  }

  /// Whether the login path must pay for a local content fingerprint
  /// at all: only when the cloud fingerprint EXISTS and has MOVED
  /// since this device's last sync. When it has not moved (the
  /// everyday case — same phone, nothing synced from elsewhere), the
  /// count rule alone decides and login never scans the ledger.
  static bool fingerprintCheckNeeded({
    required String? cloudFingerprint,
    required String? lastSyncedFingerprint,
  }) =>
      cloudFingerprint != null &&
      lastSyncedFingerprint != null &&
      cloudFingerprint != lastSyncedFingerprint;

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

  /// FNV-1a 64-bit over the UTF-8 bytes of [input], as 16 lowercase
  /// hex chars. Computed on two 32-bit halves so every intermediate
  /// stays a small int: Dart hex literals wrap to signed 64-bit, so a
  /// plain `hash * prime & 0xFFFF...` would not actually truncate.
  /// Verified against the published FNV-1a test vectors.
  static String _fnv1a64Hex(String input) {
    var hi = 0xcbf29ce4; // offset basis, high 32 bits
    var lo = 0x84222325; // offset basis, low 32 bits
    const pHi = 0x100; // FNV prime 0x100000001b3, high part
    const pLo = 0x1b3; // FNV prime, low part
    for (final byte in utf8.encode(input)) {
      lo ^= byte;
      final lowProduct = lo * pLo;
      final mid = lo * pHi + hi * pLo + (lowProduct >> 32);
      lo = lowProduct & 0xFFFFFFFF;
      hi = mid & 0xFFFFFFFF;
    }
    return hi.toRadixString(16).padLeft(8, '0') +
        lo.toRadixString(16).padLeft(8, '0');
  }

  /// Canonical, type-tagged encoding of one synced value, so two
  /// values hash equal only when they are truly the same content
  /// (an integral double encodes like the matching int, because
  /// SQLite REAL and Firestore numbers round-trip between the two).
  static String _canonicalSyncValue(Object? v) {
    if (v == null) return 'n';
    if (v is bool) return v ? 'b:1' : 'b:0';
    if (v is int) return 'i:$v';
    if (v is double) {
      if (v.isFinite &&
          v == v.truncateToDouble() &&
          v.abs() < 9007199254740992) {
        return 'i:${v.toInt()}';
      }
      return 'd:$v';
    }
    if (v is String) return 's:${v.length}:$v';
    if (v is Timestamp) return 't:${v.millisecondsSinceEpoch}';
    if (v is List) return 'l:[${v.map(_canonicalSyncValue).join(',')}]';
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      final parts =
          keys.map((k) => 's:${k.length}:$k=${_canonicalSyncValue(v[k])}');
      return 'm:{${parts.join(',')}}';
    }
    final s = '$v';
    return 's:${s.length}:$s';
  }

  /// Content hash of one row for delta sync. The cloud-only keys
  /// `_sync_hash` (the hash itself) and `attachment_drive_id` (a Drive
  /// pointer compared separately) are excluded, so a row hashes the
  /// same before upload, in the cloud, and after a restore.
  static String rowSyncHash(Map<String, dynamic> row) {
    final keys = row.keys
        .where((k) => k != '_sync_hash' && k != 'attachment_drive_id')
        .toList()
      ..sort();
    final parts =
        keys.map((k) => 's:${k.length}:$k=${_canonicalSyncValue(row[k])}');
    return _fnv1a64Hex('m:{${parts.join(',')}}');
  }

  /// Combined hash of a whole table's doc-id → row-hash map. If this
  /// matches what the last successful sync stored, the table is
  /// unchanged and sync skips it without any Firestore traffic.
  static String tableSyncHash(Map<String, String> idToHash) {
    final ids = idToHash.keys.toList()..sort();
    return _fnv1a64Hex(ids.map((id) => '$id:${idToHash[id]}').join('\n'));
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
    final uname = FirebaseService.normalizeUsername(username);
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
    await _deleteUserTree(FirebaseService.normalizeUsername(username));
    await _clearSyncCaches(FirebaseService.normalizeUsername(username));
  }

  /// Full user edit (admin panel): email / phone / password, and —
  /// when [newUsername] differs after normalization — a username
  /// MOVE. The username is the Firestore doc id, the root of the
  /// user's tables/snapshots subcollections and of this device's
  /// delta-sync cache keys, so a rename creates the new doc with the
  /// edited fields, copies the whole data tree across in chunked
  /// batches, then deletes the old tree and clears the old name's
  /// cached sync hashes — the user's cloud data is never left behind
  /// or duplicated under both names. [newPassword] null/empty keeps
  /// the current password. Throws StateError('username-empty') or
  /// StateError('user-exists') on an invalid new username.
  Future<void> updateUser({
    required String currentUsername,
    required String newUsername,
    required String email,
    required String phone,
    String? newPassword,
  }) async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    final cur = FirebaseService.normalizeUsername(currentUsername);
    final next = FirebaseService.normalizeUsername(newUsername);
    final snap = await _users.get();
    final ids = snap.docs.map((d) => d.id).toSet();
    final err = FirebaseService.validateUsernameChange(cur, next, ids);
    if (err != null) throw StateError(err);
    final trimmedEmail = email.trim();
    final trimmedPhone = phone.trim();
    final hasNewPassword = newPassword != null && newPassword.isNotEmpty;
    if (!FirebaseService.isUsernameRename(cur, next)) {
      final fields = <String, dynamic>{
        'email': trimmedEmail,
        'phone': trimmedPhone,
      };
      if (hasNewPassword) {
        fields['password'] = newPassword;
        fields['password_hash'] = FieldValue.delete();
      }
      await _users.doc(cur).update(fields);
      return;
    }
    // MOVE — new doc first: until the copy completes the old tree is
    // untouched, so an interruption can never lose the user (at
    // worst both exist briefly and the admin retries).
    final oldSnap = await _users.doc(cur).get();
    if (!oldSnap.exists) throw StateError('wrong');
    final data = Map<String, dynamic>.from(oldSnap.data()!);
    data['email'] = trimmedEmail;
    data['phone'] = trimmedPhone;
    if (hasNewPassword) data['password'] = newPassword;
    data.remove('password_hash');
    await _users.doc(next).set(data);
    await _moveUserSubcollections(cur, next);
    await _deleteUserTree(cur);
    await _clearSyncCaches(cur);
    await rekeyCachedLogin(cur, next,
        email: trimmedEmail,
        phone: trimmedPhone,
        password: hasNewPassword ? newPassword : null);
  }

  /// Copies every document of one collection into another, in
  /// chunked batches (Firestore's 500-op batch limit).
  Future<void> _copyCollection(
      CollectionReference<Map<String, dynamic>> from,
      CollectionReference<Map<String, dynamic>> to) async {
    final snap = await from.get();
    var batch = _firestore!.batch();
    var ops = 0;
    for (final d in snap.docs) {
      batch.set(to.doc(d.id), d.data());
      if (++ops >= 400) {
        await batch.commit();
        batch = _firestore!.batch();
        ops = 0;
      }
    }
    if (ops > 0) await batch.commit();
  }

  /// Deletes every document of one collection, in chunked batches.
  Future<void> _deleteCollection(
      CollectionReference<Map<String, dynamic>> c) async {
    final snap = await c.get();
    var batch = _firestore!.batch();
    var ops = 0;
    for (final d in snap.docs) {
      batch.delete(d.reference);
      if (++ops >= 400) {
        await batch.commit();
        batch = _firestore!.batch();
        ops = 0;
      }
    }
    if (ops > 0) await batch.commit();
  }

  /// Copies a user's whole data tree — tables with their rows, and
  /// the conflict snapshots with their table docs — from [from] to
  /// [to] (both already-normalized usernames).
  Future<void> _moveUserSubcollections(String from, String to) async {
    final oldRoot = _users.doc(from);
    final newRoot = _users.doc(to);
    final tables = await oldRoot.collection('tables').get();
    for (final t in tables.docs) {
      final target = newRoot.collection('tables').doc(t.id);
      await target.set(t.data());
      await _copyCollection(
          t.reference.collection('rows'), target.collection('rows'));
    }
    final snaps = await oldRoot.collection('snapshots').get();
    for (final s in snaps.docs) {
      final target = newRoot.collection('snapshots').doc(s.id);
      await target.set(s.data());
      await _copyCollection(
          s.reference.collection('tables'), target.collection('tables'));
    }
  }

  /// Deletes a user doc AND its whole data tree — a bare doc delete
  /// does not cascade into subcollections and would orphan the data.
  Future<void> _deleteUserTree(String username) async {
    final root = _users.doc(username);
    final tables = await root.collection('tables').get();
    for (final t in tables.docs) {
      await _deleteCollection(t.reference.collection('rows'));
      await t.reference.delete();
    }
    final snaps = await root.collection('snapshots').get();
    for (final s in snaps.docs) {
      await _deleteCollection(s.reference.collection('tables'));
      await s.reference.delete();
    }
    await root.delete();
  }

  /// Drops this device's delta-sync bookkeeping for [username]: the
  /// cached per-table hashes and last-sync markers are keyed by
  /// username, so after a rename or delete they describe an identity
  /// that no longer exists.
  Future<void> _clearSyncCaches(String username) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = 'sync_tbl_hash_${username}_';
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      await prefs.remove(key);
    }
    await prefs.remove('last_sync_fp_$username');
    await prefs.remove('last_sync_at_$username');
  }

  /// Moves this device's offline login cache entry from [oldName] to
  /// [newName] after an admin rename, so the renamed user can still
  /// sign in offline (and via fingerprint) on this device. No-op when
  /// they were never cached here.
  Future<void> rekeyCachedLogin(String oldName, String newName,
      {String? email, String? phone, String? password}) async {
    final cached = await _cachedUsers();
    final entry = cached.remove(oldName);
    if (entry == null) return;
    final m = Map<String, dynamic>.from(entry as Map);
    if (email != null) m['email'] = email;
    if (phone != null) m['phone'] = phone;
    if (password != null) m['password'] = password;
    cached[newName] = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_users', jsonEncode(cached));
    if (prefs.getString('last_login_username') == oldName) {
      await prefs.setString('last_login_username', newName);
    }
  }

  /// Updates the signed-in user's OWN email/phone on their app_users
  /// doc — sign-in by email/phone reads these fields, so the new
  /// values work at the next login — and refreshes this device's
  /// cached copy of the record (offline login, Settings account row).
  Future<void> updateOwnContact(String username,
      {required String email, required String phone}) async {
    if (!isConfigured) throw StateError('firebase-not-configured');
    final uname = FirebaseService.normalizeUsername(username);
    await _users.doc(uname).update({
      'email': email.trim(),
      'phone': phone.trim(),
    });
    final cached = await _cachedUsers();
    if (cached.containsKey(uname)) {
      final m = Map<String, dynamic>.from(cached[uname] as Map);
      m['email'] = email.trim();
      m['phone'] = phone.trim();
      cached[uname] = m;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cached_users', jsonEncode(cached));
    }
  }

  /// This device's cached record for [username] from their last
  /// online sign-in here (email/phone for display and prefill), or
  /// null when they were never cached on this device.
  Future<AppUserRecord?> cachedUser(String username) async {
    final uname = FirebaseService.normalizeUsername(username);
    final cached = await _cachedUsers();
    final v = cached[uname];
    if (v == null) return null;
    final m = Map<String, dynamic>.from(v as Map);
    return AppUserRecord(
      username: uname,
      businessName: (m['business_name'] as String?) ?? '',
      email: (m['email'] as String?) ?? '',
      phone: (m['phone'] as String?) ?? '',
    );
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
  /// Entry photos (attachment_path) are uploaded to Google Drive
  /// into the app's Drive folder and the row document carries the
  /// Drive file id as `attachment_drive_id`; restore downloads them back.

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

  /// Uploads one row's attachment photo to the app's Google Drive
  /// folder (skipped when the same file was already uploaded from this
  /// device) and records its Drive file id on the row as
  /// `attachment_drive_id`. Drive uses silent sign-in only — if Google
  /// is not connected, the photo is retried on the next sync.
  Future<void> _attachCloudImage(String username, int businessId,
      String table, Map<String, dynamic> row) async {
    final local = row['attachment_path'];
    if (local is! String || local.isEmpty) return;
    final remoteName = 'img_${username}_biz${businessId}_${table}_'
        '${row['id'] ?? 'x'}_${p.basename(local)}';
    try {
      final file = File(local);
      if (!await file.exists()) return;
      final prefs = await SharedPreferences.getInstance();
      final key = 'img_drive:$remoteName';
      final size = await file.length();
      final cached = prefs.getString(key);
      if (cached != null && cached.startsWith('$size:')) {
        row['attachment_drive_id'] = cached.substring('$size:'.length);
        return;
      }
      final id =
          await GoogleDriveService.instance.uploadAttachment(file, remoteName);
      if (id == null) return;
      await prefs.setString(key, '$size:$id');
      row['attachment_drive_id'] = id;
    } catch (_) {
      // Best effort: the row still syncs, and the next sync retries.
    }
  }

  /// Inverse of [_attachCloudImage] during restore: downloads the photo
  /// from Google Drive into the local attachments folder and points the
  /// row's attachment_path at it. Always strips the cloud-only keys
  /// (they are not database columns).
  Future<void> _resolveCloudImage(Map<String, dynamic> row) async {
    row.remove('attachment_storage'); // legacy key, no longer used
    row.remove('_sync_hash'); // delta-sync bookkeeping, not a column
    final driveId = row.remove('attachment_drive_id');
    if (driveId is! String || driveId.isEmpty) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final attDir = Directory(p.join(dir.path, 'attachments'));
      if (!await attDir.exists()) await attDir.create(recursive: true);
      final oldPath = row['attachment_path'];
      final base = (oldPath is String && oldPath.isNotEmpty)
          ? p.basename(oldPath)
          : 'drive_$driveId';
      final file = File(p.join(attDir.path, base));
      if (!await file.exists()) {
        final bytes = await GoogleDriveService.instance.downloadBytes(driveId);
        if (bytes == null) {
          row.remove('attachment_path');
          return;
        }
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
    // A local copy that holds FEWER rows than the cloud must never
    // overwrite it — the cloud is richer (another device, or this
    // device before a reinstall) and the login flow restores it down
    // instead. This extends the original empty-local guard, which
    // let a nearly-empty business (e.g. 1 stray row) wipe a full
    // cloud backup.
    try {
      final cloud = await cloudRowCount(username);
      if (cloud > localRows) return cloud;
    } catch (_) {
      if (localRows == 0) {
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
      // Delta sync: hash every local row and combine into one table
      // hash. If it matches what this device's last successful sync
      // stored, the table is unchanged — skip it entirely, with no
      // Firestore read or write (re-uploading every row on every sync
      // burned through the free plan's daily write quota).
      final localHashes = <String, String>{};
      for (var i = 0; i < rows.length; i++) {
        localHashes[FirebaseService.rowDocId(rows[i], i)] =
            FirebaseService.rowSyncHash(rows[i]);
      }
      final combined = FirebaseService.tableSyncHash(localHashes);
      final hashKey = 'sync_tbl_hash_${username}_${businessId}_$table';
      if (prefs.getString(hashKey) == combined) {
        count += rows.length;
        continue;
      }
      final tableRef = root.doc(table);
      final rowsRef = tableRef.collection('rows');
      final existing = await rowsRef.get();
      final hadCloudDocs = existing.docs.isNotEmpty;
      final cloudDocs = {for (final d in existing.docs) d.id: d};
      final staleIds =
          existing.docs.map((d) => d.id).toSet();
      var batch = _firestore!.batch();
      var ops = 0;
      var totalOps = 0;
      Future<void> flush() async {
        if (ops == 0) return;
        await batch.commit();
        batch = _firestore!.batch();
        ops = 0;
      }

      for (var i = 0; i < rows.length; i++) {
        final id = FirebaseService.rowDocId(rows[i], i);
        staleIds.remove(id);
        final localHash = localHashes[id]!;
        final cloudDoc = cloudDocs[id];
        if (cloudDoc != null) {
          final cloudData = cloudDoc.data();
          final storedHash = cloudData['_sync_hash'];
          // Legacy docs written before delta sync carry no hash:
          // hash the cloud content itself. Any mismatch uploads —
          // the safe direction.
          final cloudHash = storedHash is String
              ? storedHash
              : FirebaseService.rowSyncHash(cloudData);
          final cloudDriveId = cloudData['attachment_drive_id'];
          if (cloudHash == localHash &&
              cloudDriveId == rows[i]['attachment_drive_id']) {
            continue; // unchanged — no write
          }
          // Keep a Drive id uploaded from another device; a plain
          // set would wipe it from the document.
          if (rows[i]['attachment_drive_id'] == null && cloudDriveId != null) {
            rows[i]['attachment_drive_id'] = cloudDriveId;
          }
        }
        batch.set(rowsRef.doc(id), {...rows[i], '_sync_hash': localHash});
        totalOps++;
        if (++ops >= 400) await flush();
      }
      for (final oldId in staleIds) {
        batch.delete(rowsRef.doc(oldId));
        totalOps++;
        if (++ops >= 400) await flush();
      }
      await flush();
      if (totalOps > 0 || !hadCloudDocs) {
        // Replaces the table document, dropping any legacy `rows` array.
        await tableRef.set({
          'row_count': rows.length,
          'updated_at': FieldValue.serverTimestamp(),
        });
      }
      await prefs.setString(hashKey, combined);
      count += rows.length;
    }
    // Record WHAT was synced, not just how much: the content
    // fingerprint lets other devices detect value-only changes
    // (filled-in phone numbers move no row counts) at login time.
    final fingerprint = FirebaseService.businessFingerprint(data);
    await _users.doc(username).set({
      'last_sync_at': FieldValue.serverTimestamp(),
      'last_sync_count': count,
      'last_sync_device': myDevice,
      'last_sync_fingerprint': fingerprint,
    }, SetOptions(merge: true));
    await prefs.setString(
        'last_sync_at_$username', DateTime.now().toIso8601String());
    await prefs.setString('last_sync_fp_$username', fingerprint);
    return count;
  }

  /// Makes the account's data simply BE in the app after sign-in —
  /// no manual sync, no file import (owner's requirement). A richer
  /// cloud restores down to this device before sign-in completes; a
  /// richer (or equal) local copy uploads in the background. Content
  /// fingerprints (see [loginSyncDecisionV2]) additionally catch
  /// value-only changes another device synced — e.g. party phone
  /// numbers filled in there — which row counts cannot see. Returns
  /// what happened: 'restored' | 'uploading' | 'none'.
  ///
  /// STAGED for login speed (the decision logic is exactly
  /// [loginSyncDecisionV2]'s): stage 1 compares COUNT(*) locally
  /// against the cloud's summary docs — no row is materialized, so
  /// the everyday login (this phone, already in sync) decides in
  /// milliseconds. Only when the cloud fingerprint has actually
  /// MOVED since this device's last sync does stage 2 pay for one
  /// local export + fingerprint. [onRestoring] fires right before a
  /// restore begins, so the login screen can show progress instead
  /// of a frozen spinner.
  Future<String> syncOnLogin(String username, int businessId,
      {void Function()? onRestoring}) async {
    if (!isConfigured) return 'none';
    final local = await DatabaseHelper.instance.countBusinessRows(businessId);
    final cloud = await cloudRowCount(username);
    if (cloud > local) {
      onRestoring?.call();
      await restoreUserData(username, businessId);
      return 'restored';
    }
    String? cloudFp;
    String? lastFp;
    try {
      final doc = await _users.doc(username).get();
      cloudFp = doc.data()?['last_sync_fingerprint'] as String?;
    } catch (_) {
      // No fingerprint recorded (older build / read failure): the
      // count rule below still applies.
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      lastFp = prefs.getString('last_sync_fp_$username');
    } catch (_) {}
    if (FirebaseService.fingerprintCheckNeeded(
        cloudFingerprint: cloudFp, lastSyncedFingerprint: lastFp)) {
      String? localFp;
      try {
        final data =
            await DatabaseHelper.instance.exportBusinessData(businessId);
        localFp = FirebaseService.businessFingerprint(data);
      } catch (_) {}
      if (localFp != null && localFp == lastFp) {
        onRestoring?.call();
        await restoreUserData(username, businessId);
        return 'restored';
      }
    }
    switch (FirebaseService.loginSyncDecision(local, cloud)) {
      case 'upload':
        unawaited(() async {
          try {
            await syncUserData(username, businessId);
          } catch (_) {}
        }());
        return 'uploading';
      default:
        return 'none';
    }
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
    // Fetch every table's rows CONCURRENTLY (one wave instead of 21
    // sequential round-trips) and resolve attachment photos
    // concurrently within each table: a full-ledger restore is
    // network-bound, and doing it table-by-table, row-by-row made
    // login crawl.
    final perTable = await Future.wait(snap.docs.map((doc) async {
      final rowsSnap = await doc.reference.collection('rows').get();
      final v2Rows = rowsSnap.docs
          .map((d) => Map<String, dynamic>.from(d.data()))
          .toList()
        ..sort((a, b) =>
            ((a['id'] as num?) ?? 0).compareTo((b['id'] as num?) ?? 0));
      final legacyRows = ((doc.data()['rows'] as List?) ?? const [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList()
        ..sort((a, b) =>
            ((a['id'] as num?) ?? 0).compareTo((b['id'] as num?) ?? 0));
      // Completeness: take the FULLER source. A first v2 sync that
      // was interrupted mid-table can leave a partial rows
      // subcollection next to the complete legacy rows array — the
      // old "any v2 rows win" rule would have restored only the
      // partial set and silently dropped the rest of the table.
      final rows = v2Rows.length >= legacyRows.length ? v2Rows : legacyRows;
      await Future.wait(rows.map(_resolveCloudImage));
      return MapEntry(doc.id, rows);
    }));
    for (final e in perTable) {
      data[e.key] = e.value;
      count += e.value.length;
    }
    if (count == 0) return 0;
    await DatabaseHelper.instance.importBusinessData(businessId, data);
    // Local rows now mirror the cloud, so this device's stored
    // per-table sync hashes no longer describe a known upload state:
    // clear them and let the next sync revalidate against the cloud
    // (per-row hashes still keep that pass write-cheap).
    final prefs = await SharedPreferences.getInstance();
    final prefix = 'sync_tbl_hash_${username}_${businessId}_';
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      await prefs.remove(key);
    }
    // This device now holds exactly the cloud content just
    // downloaded: record its fingerprint as the last-synced state,
    // so a later login can tell "cloud moved on another device"
    // apart from "I have unsynced changes of my own".
    await prefs.setString(
        'last_sync_fp_$username', FirebaseService.businessFingerprint(data));
    return count;
  }
}
