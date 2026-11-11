import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Import crash-safety (Antigravity review, verified + fixed):
/// the UNIQUE indexes on cash_entries(source_table, source_id) and
/// daily_closings(business_id, date) must never abort an import —
/// colliding cash links are dropped (money row kept), duplicate
/// closing days are skipped.
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

  test('import into account B survives a cash-source clash with account A',
      () async {
    final day = DateTime(2026, 11, 6, 12);
    // Account A (business 1): a ledger entry creates a linked cash row.
    final partyId = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'A Customer'));
    await db.insertLedgerEntry(PartyTransaction(
        partyId: partyId, type: 'udhaar', amount: 900, dateTime: day));
    final raw = await db.db;
    final linked = await raw.query('cash_entries',
        where: 'source_table IS NOT NULL', limit: 1);
    expect(linked, isNotEmpty);
    final clashId = linked.first['source_id'];

    // Import a backup into business 2 whose cash row carries the
    // SAME (source_table, source_id) pair.
    await db.importBusinessData(2, {
      'app': 'namat_oil_mill',
      'businesses': [
        {'name': 'Imported B'}
      ],
      'cash_entries': [
        {
          'type': 'in',
          'amount': 777.0,
          'note': 'clashing import',
          'date_time': day.toIso8601String(),
          'source_table': 'party_transactions',
          'source_id': clashId,
        }
      ],
      'daily_closings': [
        {'date': '2026-11-06', 'opening': 100.0, 'closing': 250.0},
        {'date': '2026-11-06', 'opening': 100.0, 'closing': 999.0},
      ],
    });

    final bCash = await raw.query('cash_entries',
        where: 'business_id = 2 AND note = ?', whereArgs: ['clashing import']);
    expect(bCash, hasLength(1));
    expect(bCash.first['amount'], 777.0);
    expect(bCash.first['source_id'], isNull,
        reason: 'colliding link dropped, money kept');
    final bClosings =
        await raw.query('daily_closings', where: 'business_id = 2');
    expect(bClosings, hasLength(1),
        reason: 'duplicate closing day skipped, not crashed');
    expect(bClosings.first['closing'], 250.0);
  });

  test('full restore survives duplicate pairs inside the file', () async {
    final backup = jsonEncode({
      'app': 'namat_oil_mill',
      'businesses': [
        {'id': 1, 'name': 'Restored'}
      ],
      'cash_entries': [
        {
          'id': 1,
          'business_id': 1,
          'type': 'in',
          'amount': 100.0,
          'date_time': '2026-11-06T12:00:00',
          'source_table': 'party_transactions',
          'source_id': 42,
        },
        {
          'id': 2,
          'business_id': 1,
          'type': 'in',
          'amount': 200.0,
          'date_time': '2026-11-06T13:00:00',
          'source_table': 'party_transactions',
          'source_id': 42,
        },
      ],
      'daily_closings': [
        {'id': 1, 'business_id': 1, 'date': '2026-11-06', 'closing': 1.0},
        {'id': 2, 'business_id': 1, 'date': '2026-11-06', 'closing': 2.0},
      ],
    });
    await db.importJson(backup); // must not throw
    final raw = await db.db;
    final cash = await raw.query('cash_entries', orderBy: 'amount');
    expect(cash, hasLength(2));
    expect(cash[0]['source_id'], 42, reason: 'first link kept');
    expect(cash[1]['source_id'], isNull, reason: 'duplicate link dropped');
    final closings = await raw.query('daily_closings');
    expect(closings, hasLength(1));
  });
}
