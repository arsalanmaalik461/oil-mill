import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
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
}

