import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Speed work (owner: "pehle sirf app tez kar do"): the list screens
/// now load balances/quantities with ONE aggregate query per list
/// instead of a balance query + full history fetch per row, and DB
/// v12 adds the indexes those queries need. These tests pin the
/// summaries to the exact figures the old per-row methods produce.
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

  test('party summaries match per-party balances and last dates', () async {
    final base = DateTime(2026, 11, 1, 12);
    for (var i = 0; i < 12; i++) {
      final pid = await db.insertParty(Party(
          businessId: 1,
          type: i.isEven ? 'customer' : 'supplier',
          name: 'Party $i',
          openingBalance: i * 100.0));
      for (var j = 0; j < 7; j++) {
        await db.insertLedgerEntry(PartyTransaction(
            partyId: pid,
            type: j.isEven ? 'udhaar' : 'wasool',
            amount: (i + 1) * 10.0 + j,
            dateTime: base.add(Duration(days: j, hours: i))));
      }
    }
    final summaries = await db.getPartySummaries(1);
    expect(summaries, hasLength(12));
    for (final s in summaries) {
      expect(s.balance, await db.getPartyBalance(s.party.id!),
          reason: 'balance of ${s.party.name}');
      final txns = await db.getPartyTransactions(s.party.id!);
      expect(s.lastDate, txns.first.dateTime);
    }
    // Type filter narrows exactly like the old getParties path.
    final customers = await db.getPartySummaries(1, type: 'customer');
    expect(customers, hasLength(6));
    expect(customers.every((s) => s.party.type == 'customer'), isTrue);
  });

  test('item summaries match qty, last date and latest-rate rules',
      () async {
    final base = DateTime(2026, 11, 2, 12);
    final oil = await db.insertItem(StockItem(
        businessId: 1, name: 'Oil', unit: 'kg', openingQty: 100));
    await db.insertStockTransaction(StockTransaction(
        itemId: oil, type: 'in', qty: 50, rate: 400, dateTime: base));
    await db.insertStockTransaction(StockTransaction(
        itemId: oil,
        type: 'out',
        qty: 20,
        rate: 500,
        dateTime: base.add(const Duration(days: 1))));
    await db.insertStockTransaction(StockTransaction(
        itemId: oil,
        type: 'in',
        qty: 10,
        rate: 450,
        dateTime: base.add(const Duration(days: 2))));
    // An item with only an 'out': latest rate falls back to that row.
    final khal = await db.insertItem(
        StockItem(businessId: 1, name: 'Khal', unit: 'kg', openingQty: 5));
    await db.insertStockTransaction(StockTransaction(
        itemId: khal,
        type: 'out',
        qty: 2,
        rate: 90,
        dateTime: base.add(const Duration(days: 3))));
    // An item with no movements at all.
    await db.insertItem(
        StockItem(businessId: 1, name: 'Empty', unit: 'kg', openingQty: 7));

    final sums = await db.getItemSummaries(1);
    expect(sums, hasLength(3));
    final byName = {for (final s in sums) s.item.name: s};
    expect(byName['Oil']!.qty, await db.getItemQty(oil));
    expect(byName['Oil']!.qty, 140);
    expect(byName['Oil']!.latestRate, 450,
        reason: 'newest IN rate wins over a newer OUT rate');
    expect(byName['Oil']!.lastDate, base.add(const Duration(days: 2)));
    expect(byName['Khal']!.qty, 3);
    expect(byName['Khal']!.latestRate, 90,
        reason: 'no IN rows: fall back to newest movement rate');
    expect(byName['Empty']!.qty, 7);
    expect(byName['Empty']!.latestRate, 0);
    expect(byName['Empty']!.lastDate, isNull);
  });

  test('bank balances map matches per-account balances', () async {
    final day = DateTime(2026, 11, 3, 12);
    final a1 = await db.insertBankAccount(BankAccount(
        businessId: 1, bankName: 'MCB', openingBalance: 1000));
    final a2 = await db.insertBankAccount(
        BankAccount(businessId: 1, bankName: 'HBL', openingBalance: 0));
    await db.insertBankTransaction(BankTransaction(
        bankId: a1, type: 'in', amount: 250, dateTime: day));
    await db.insertBankTransaction(BankTransaction(
        bankId: a1, type: 'out', amount: 100, dateTime: day));
    await db.insertBankTransaction(BankTransaction(
        bankId: a2, type: 'in', amount: 75, dateTime: day));
    final map = await db.getBankBalances(1);
    expect(map[a1], await db.getBankBalance(a1));
    expect(map[a1], 1150);
    expect(map[a2], 75);
  });
}
