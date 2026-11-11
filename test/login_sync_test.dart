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
}
