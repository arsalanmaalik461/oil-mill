import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Phase 4 (Daily Accounting) verification:
///  - a frozen daily closing is sealed: later backdated entries change
///    the LIVE sums but never the frozen record (mismatch detection)
///  - expense classification round-trips (operating vs owner/loan)
///  - batch yield analysis: recovery, accounted %, unexplained loss
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

  final day1 = DateTime(2026, 11, 3, 12);
  final day2 = DateTime(2026, 11, 4, 12);

  test('daily closing freezes and detects post-close edits', () async {
    await db.insertCashEntry(CashEntry(
        businessId: 1, type: 'in', amount: 100000, dateTime: DateTime(2026, 11, 2, 9)));
    await db.insertCashEntry(CashEntry(
        businessId: 1, type: 'in', amount: 30000, dateTime: day1));
    await db.insertCashEntry(CashEntry(
        businessId: 1, type: 'out', amount: 5000, dateTime: day1));
    await db.insertCashEntry(CashEntry(
        businessId: 1, type: 'in', amount: 9999, dateTime: day2));

    final frozen = await db.freezeDailyClosing(1, day1);
    expect(frozen.opening, 100000);
    expect(frozen.totalIn, 30000);
    expect(frozen.totalOut, 5000);
    expect(frozen.closing, 125000);

    // A backdated entry lands on the closed day afterwards:
    await db.insertCashEntry(CashEntry(
        businessId: 1, type: 'out', amount: 2000, dateTime: day1));
    final live = await db.liveDailyClosing(1, day1);
    expect(live.closing, 123000, reason: 'live sums moved');
    final sealed = await db.getDailyClosing(1, day1);
    expect(sealed!.closing, 125000, reason: 'frozen record is sealed');
    expect(sealed.totalOut, 5000);
  });

  test('expense kind classification round-trips', () async {
    await db.insertExpense(Expense(
        businessId: 1, category: 'Fuel', amount: 1000, dateTime: day1));
    await db.insertExpense(Expense(
        businessId: 1,
        category: 'Owner draw',
        amount: 50000,
        kind: 'owner',
        dateTime: day1));
    final all = await db.getExpenses(1);
    expect(all.firstWhere((e) => e.category == 'Fuel').kind, 'operating');
    expect(all.firstWhere((e) => e.category == 'Owner draw').kind, 'owner');
  });

  test('batch recovery: expected vs actual, unexplained loss', () async {
    final raw = await db.insertItem(
        StockItem(businessId: 1, name: 'Sarson Y', unit: 'kg', kind: 'raw'));
    final oil = await db.insertItem(
        StockItem(businessId: 1, name: 'Oil Y', unit: 'kg', kind: 'finished'));
    final khal = await db.insertItem(
        StockItem(businessId: 1, name: 'Khal Y', unit: 'kg', kind: 'finished'));
    await db.insertStockTransaction(StockTransaction(
        itemId: raw, type: 'in', qty: 1000, rate: 100, dateTime: day1));
    final batchId = await db.createProductionBatch(
      batch: ProductionBatch(
          businessId: 1,
          batchNo: 1,
          dateTime: day1,
          wastageQty: 30,
          expectedRecoveryPct: 97),
      inputs: [(itemId: raw, qty: 1000)],
      outputs: [
        (itemId: oil, qty: 350, saleRate: null),
        (itemId: khal, qty: 600, saleRate: null),
      ],
      expenses: const [],
    );
    final rec = await db.getBatchRecovery(batchId);
    expect(rec.inputKg, 1000);
    expect(rec.outputKg, 950);
    expect(rec.wastageKg, 30);
    expect(rec.recoveryPct, closeTo(95, 0.001));
    expect(rec.accountedPct, closeTo(98, 0.001));
    // unexplained = 1000 - 950 - 30 = 20 kg
    expect(rec.inputKg - rec.outputKg - rec.wastageKg, 20);
    final batches = await db.getProductionBatches(1);
    expect(batches.single.expectedRecoveryPct, 97);
  });
}
