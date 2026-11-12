import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Party Payment Settlement (backlog plan #4): 100,000 outstanding,
/// 92,000 actually paid, 8,000 forgiven as an adjustment — balance
/// must land on exactly zero, and only the 92,000 may touch cash
/// (the old workaround of booking the discount as a wasool lied to
/// the cash book and the Roznamcha).
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = DatabaseHelper.instance;
  final day = DateTime(2026, 11, 6, 12);

  setUpAll(() async {
    final path = '${await getDatabasesPath()}/namat_oil_mill.db';
    await databaseFactoryFfi.deleteDatabase(path);
    await db.db;
  });
  tearDownAll(() async => db.close());

  test('settle 100k = 92k cash + 8k adjustment', () async {
    final cust = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Settle Cust'));
    await db.insertPartyTransaction(PartyTransaction(
        partyId: cust, type: 'udhaar', amount: 100000, dateTime: day));
    expect(await db.getPartyBalance(cust), 100000);
    final cashBefore = await db.getCashBalance(1);

    await db.settlePartyPayment(
        partyId: cust,
        paidAmount: 92000,
        adjustmentAmount: 8000,
        method: 'cash',
        dateTime: day.add(const Duration(days: 1)),
        reason: 'full and final');

    expect(await db.getPartyBalance(cust), 0);
    expect(await db.getCashBalance(1), cashBefore + 92000,
        reason: 'only the real payment reached the drawer');
    final txns = await db.getPartyTransactions(cust);
    final adj = txns.where((t) => t.type == 'adjustment').toList();
    expect(adj, hasLength(1));
    expect(adj.single.amount, 8000);
    expect(adj.single.note, contains('full and final'));
  });

  test('a direct adjustment entry never posts cash', () async {
    final cust = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Adj Cust'));
    await db.insertPartyTransaction(PartyTransaction(
        partyId: cust, type: 'udhaar', amount: 5000, dateTime: day));
    final cashBefore = await db.getCashBalance(1);
    await db.insertLedgerEntry(PartyTransaction(
        partyId: cust,
        type: 'adjustment',
        amount: 5000,
        method: 'cash',
        note: 'write-off',
        dateTime: day));
    expect(await db.getPartyBalance(cust), 0,
        reason: 'adjustment reduces the balance like a wasool');
    expect(await db.getCashBalance(1), cashBefore,
        reason: 'but it is not money — the drawer must not move');
  });

  test('full payment settlement writes no adjustment row', () async {
    final cust = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Full Cust'));
    await db.insertPartyTransaction(PartyTransaction(
        partyId: cust, type: 'udhaar', amount: 7000, dateTime: day));
    await db.settlePartyPayment(
        partyId: cust,
        paidAmount: 7000,
        adjustmentAmount: 0,
        method: 'bank',
        dateTime: day);
    expect(await db.getPartyBalance(cust), 0);
    final txns = await db.getPartyTransactions(cust);
    expect(txns.where((t) => t.type == 'adjustment'), isEmpty);
  });
}
