import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Per-user data isolation at the database level: a business-scoped export
/// must contain ONLY that business's rows, and a scoped import must replace
/// only that business's data — the other business stays untouched. This is
/// what keeps one app user's data invisible to another.
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

  test('business-scoped export/import keeps users isolated', () async {
    // Business A = seeded default (id 1), bound to user 'arsu'
    await db.updateBusiness(Business(
        id: 1, name: 'Arslan Oil', appUsername: 'arsu'));
    final aParty = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'A Customer'));
    await db.insertPartyTransaction(PartyTransaction(
        partyId: aParty,
        type: 'udhaar',
        amount: 7000,
        note: 'a-note',
        dateTime: DateTime(2026, 1, 1)));

    // Business B, bound to user 'bilal'
    final bizB = await db.insertBusiness(
        Business(name: 'Bilal Traders', appUsername: 'bilal'));
    final bParty = await db.insertParty(
        Party(businessId: bizB, type: 'customer', name: 'B Customer'));
    await db.insertPartyTransaction(PartyTransaction(
        partyId: bParty,
        type: 'udhaar',
        amount: 3000,
        note: 'b-note',
        dateTime: DateTime(2026, 1, 2)));

    // Username binding lookup works
    expect((await db.getBusinessByUsername('arsu'))?.id, 1);
    expect((await db.getBusinessByUsername('bilal'))?.id, bizB);
    expect(await db.getBusinessByUsername('nobody'), isNull);

    // Export A: only A's rows
    final exportA = await db.exportBusinessData(1);
    final aParties = exportA['parties'] as List;
    expect(aParties.length, 1);
    expect((aParties.first as Map)['name'], 'A Customer');
    final aTxns = exportA['party_transactions'] as List;
    expect(aTxns.length, 1);
    expect((aTxns.first as Map)['amount'], 7000.0);
    final aBiz = exportA['businesses'] as List;
    expect((aBiz.first as Map)['app_username'], 'arsu');

    // Change A's live data, then restore A from its own export:
    // A returns to exported state, B is untouched.
    await db.insertPartyTransaction(PartyTransaction(
        partyId: aParty,
        type: 'wasool',
        amount: 2000,
        note: 'later',
        dateTime: DateTime(2026, 1, 3)));
    expect(await db.getPartyBalance(aParty), 5000);
    await db.importBusinessData(1, exportA);
    expect(await db.getPartyBalance(aParty), 7000);
    expect(await db.getPartyBalance(bParty), 3000);
    // B's binding survived A's restore
    expect((await db.getBusinessByUsername('bilal'))?.id, bizB);
  });
}
