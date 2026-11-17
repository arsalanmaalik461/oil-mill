import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';
import 'package:oilmill/services/firebase_service.dart';

/// Login-time cloud behaviour (owner's rule: data must simply BE in
/// the app after sign-in — no manual sync, no file import). The pure
/// decision is unit-tested here; the Firestore side is exercised on
/// device. Also covers totalBusinessRows, the local counter the
/// decision compares against cloudRowCount.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = DatabaseHelper.instance;

  setUpAll(() async {
    final path = '${await getDatabasesPath()}/namat_oil_mill.db';
    await databaseFactoryFfi.deleteDatabase(path);
    await db.db;
  });
  tearDownAll(() async => db.close());

  group('loginSyncDecision — richer side wins', () {
    test('cloud richer -> restore down', () {
      expect(FirebaseService.loginSyncDecision(0, 3083), 'restore');
      expect(FirebaseService.loginSyncDecision(3, 3083), 'restore');
      expect(FirebaseService.loginSyncDecision(58, 3084), 'restore');
    });
    test('local richer or equal -> upload', () {
      expect(FirebaseService.loginSyncDecision(3083, 0), 'upload');
      expect(FirebaseService.loginSyncDecision(3083, 3083), 'upload');
      expect(FirebaseService.loginSyncDecision(10, 3), 'upload');
    });
    test('both empty -> none', () {
      expect(FirebaseService.loginSyncDecision(0, 0), 'none');
    });
  });

  test('totalBusinessRows counts parents AND children', () async {
    final day = DateTime(2026, 11, 6, 12);
    // Baseline includes the business's own profile row (the cloud
    // count includes it too, so the comparison stays exact).
    final base = await db.totalBusinessRows(1);
    expect(base, greaterThanOrEqualTo(0));
    final partyId = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Count Customer'));
    await db.insertLedgerEntry(PartyTransaction(
        partyId: partyId,
        type: 'udhaar',
        amount: 500,
        note: 'count probe',
        dateTime: day));
    // 1 party (parent) + 1 party_transaction (child) + 1 linked
    // cash entry (parent) = exactly 3 more rows than the baseline.
    expect(await db.totalBusinessRows(1), base + 3);
    // Another business stays untouched.
    expect(await db.totalBusinessRows(2), 0);
  });

  test('countBusinessRows (COUNT(*) only) equals totalBusinessRows',
      () async {
    final day = DateTime(2026, 11, 6, 12);
    final biz = await db
        .insertBusiness(Business(name: 'Count Equivalence Mill'));
    // An untouched business counts just its own profile row, both ways.
    expect(await db.countBusinessRows(biz), 1);
    expect(await db.countBusinessRows(biz),
        await db.totalBusinessRows(biz));
    final partyId = await db.insertParty(
        Party(businessId: biz, type: 'customer', name: 'Eq Customer'));
    await db.insertLedgerEntry(PartyTransaction(
        partyId: partyId,
        type: 'udhaar',
        amount: 250,
        note: 'equivalence probe',
        dateTime: day));
    // profile + party + transaction + linked cash entry = 4.
    expect(await db.totalBusinessRows(biz), 4);
    expect(await db.countBusinessRows(biz), 4,
        reason: 'the fast login count must never disagree with the '
            'export-based count it replaces');
    expect(await db.countBusinessRows(99999), 0);
  });

  group('fingerprintCheckNeeded — when login pays for a fingerprint',
      () {
    test('cloud fingerprint moved since last sync -> check', () {
      expect(
          FirebaseService.fingerprintCheckNeeded(
              cloudFingerprint: 'fp-new', lastSyncedFingerprint: 'fp-old'),
          isTrue);
    });
    test('cloud fingerprint unchanged -> no check (the fast path)', () {
      expect(
          FirebaseService.fingerprintCheckNeeded(
              cloudFingerprint: 'fp-same', lastSyncedFingerprint: 'fp-same'),
          isFalse);
    });
    test('missing fingerprints -> no check (count rule decides)', () {
      expect(
          FirebaseService.fingerprintCheckNeeded(
              cloudFingerprint: null, lastSyncedFingerprint: 'fp-old'),
          isFalse);
      expect(
          FirebaseService.fingerprintCheckNeeded(
              cloudFingerprint: 'fp-new', lastSyncedFingerprint: null),
          isFalse);
      expect(
          FirebaseService.fingerprintCheckNeeded(
              cloudFingerprint: null, lastSyncedFingerprint: null),
          isFalse);
    });
  });
}
