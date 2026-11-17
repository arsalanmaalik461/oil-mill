import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Login-restore completeness (owner's demand: logging in on another
/// phone must show ALL entries, never some). This is the exact chain
/// a login restore runs — exportBusinessData on the source phone,
/// importBusinessData on the new phone (restoreUserData feeds the
/// cloud copy through it) — exercised with one row in EVERY synced
/// table, so a table silently dropped from either side fails here.
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

  test('export -> import round-trip keeps every table complete',
      () async {
    final d = await db.db;
    final bizA = await db.insertBusiness(Business(name: 'Source Mill'));
    final bizB = await db.insertBusiness(Business(name: 'Target Mill'));

    // One row in every parent table of business A (raw inserts —
    // only the scoping columns matter for a completeness check).
    final partyId = await d.insert('parties',
        {'business_id': bizA, 'type': 'customer', 'name': 'P1'});
    await d.insert('cash_entries',
        {'business_id': bizA, 'type': 'in', 'amount': 50});
    final itemId =
        await d.insert('items', {'business_id': bizA, 'name': 'I1'});
    final billId =
        await d.insert('bills', {'business_id': bizA, 'bill_no': 1});
    final staffId =
        await d.insert('staff', {'business_id': bizA, 'name': 'S1'});
    final bankId = await d
        .insert('bank_accounts', {'business_id': bizA, 'bank_name': 'B1'});
    await d.insert('expenses',
        {'business_id': bizA, 'category': 'fuel', 'amount': 10});
    await d.insert('wallet_transactions',
        {'business_id': bizA, 'channel': 'jazzcash', 'type': 'in', 'amount': 5});
    await d.insert('qr_payments',
        {'business_id': bizA, 'party_id': partyId, 'amount': 5});
    final batchId = await d.insert(
        'production_batches', {'business_id': bizA, 'batch_no': 1});
    await d.insert('daily_closings',
        {'business_id': bizA, 'date': '2026-11-06', 'closing': 100});

    // One row in every child table.
    await d.insert('party_transactions',
        {'party_id': partyId, 'type': 'udhaar', 'amount': 100});
    await d.insert('stock_transactions',
        {'item_id': itemId, 'type': 'in', 'qty': 3, 'rate': 10});
    await d.insert('bill_items',
        {'bill_id': billId, 'item_id': itemId, 'qty': 1, 'rate': 10, 'amount': 10});
    await d.insert('attendance',
        {'staff_id': staffId, 'date': '2026-11-06', 'status': 'present'});
    await d.insert('salary_payments',
        {'staff_id': staffId, 'type': 'salary', 'amount': 1000});
    await d.insert('bank_transactions',
        {'bank_id': bankId, 'type': 'in', 'amount': 200});
    await d.insert('production_inputs',
        {'batch_id': batchId, 'item_id': itemId, 'qty': 10, 'rate': 5, 'cost': 50});
    await d.insert('production_outputs',
        {'batch_id': batchId, 'item_id': itemId, 'qty': 8, 'allocated_cost': 50, 'cost_per_unit': 6.25});
    await d.insert('production_expenses',
        {'batch_id': batchId, 'category': 'labour', 'amount': 20});

    final exportA = await db.exportBusinessData(bizA);
    final tables = exportA.keys
        .where((k) => k != 'app' && k != 'version')
        .toList();
    // Fixture sanity: the export really does carry every table, each
    // with the row just inserted (businesses carries A's profile).
    expect(tables.length, 21,
        reason: 'businesses + 11 parents + 9 children in the sync set');
    for (final t in tables) {
      expect((exportA[t] as List).length, 1,
          reason: 'fixture/export missing a row in $t');
    }

    // The restore on the "other phone": import A's export into the
    // fresh business B, then compare per-table counts.
    await db.importBusinessData(bizB, exportA);
    final exportB = await db.exportBusinessData(bizB);
    for (final t in tables) {
      expect((exportB[t] as List).length, (exportA[t] as List).length,
          reason: 'table $t lost rows in the round-trip');
    }
    expect(await db.totalBusinessRows(bizB),
        await db.totalBusinessRows(bizA));

    // Restoring the SAME cloud copy a second time (re-login) must
    // neither duplicate nor drop rows.
    await db.importBusinessData(bizB, exportA);
    final exportB2 = await db.exportBusinessData(bizB);
    for (final t in tables) {
      expect((exportB2[t] as List).length, (exportA[t] as List).length,
          reason: 'table $t changed on a repeat restore');
    }
  });
}
