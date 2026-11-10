import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Phase 5 (Reports & Dashboard) verification:
///  - getProfitSummary: the single profit calculation — sales from bill
///    totals, COGS from sale-time snapshots, only 'operating' expenses
///    count against profit, owner withdrawals are reported apart, and
///    salaries paid are deducted.
///  - getBatchProfits: FIFO lot replay attributes bill sales (revenue
///    and COGS) to the production batch that supplied the stock.
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

  group('getProfitSummary', () {
    test('hand-computed November: snapshot COGS, kinds, salary', () async {
      const biz = 1;
      final start = DateTime(2026, 11, 1);
      final end = DateTime(2026, 12, 1);

      // Stock in 100 kg @ 200 -> unit cost 200.
      final item = await db.insertItem(StockItem(
          businessId: biz, name: 'Mustard Oil PS', unit: 'kg', kind: 'finished'));
      await db.insertStockTransaction(StockTransaction(
          itemId: item,
          type: 'in',
          qty: 100,
          rate: 200,
          dateTime: DateTime(2026, 11, 5)));

      // Sell 40 kg @ 500 -> sales 20,000; snapshot COGS 40 x 200 = 8,000.
      await db.createBill(
        businessId: biz,
        bill: Bill(
            businessId: biz,
            billNo: 1,
            partyName: 'Counter',
            total: 20000,
            status: 'paid',
            dateTime: DateTime(2026, 11, 10)),
        items: [
          BillItem(billId: 0, itemId: item, name: 'Mustard Oil PS', qty: 40, rate: 500),
        ],
      );

      // Operating expense 3,000 (counts against profit).
      await db.insertExpense(Expense(
          businessId: biz,
          category: 'Fuel',
          amount: 3000,
          dateTime: DateTime(2026, 11, 12)));
      // Owner withdrawal 7,000 (reported apart, never touches net).
      await db.insertExpense(Expense(
          businessId: biz,
          category: 'Owner draw',
          amount: 7000,
          kind: 'owner',
          dateTime: DateTime(2026, 11, 13)));
      // Salary paid 10,000 (operating cost via salary_payments).
      final staffId = await db.insertStaff(
          Staff(businessId: biz, name: 'Worker PS', monthlySalary: 30000));
      await db.insertSalaryPayment(SalaryPayment(
          staffId: staffId,
          type: 'salary',
          amount: 10000,
          dateTime: DateTime(2026, 11, 15)));

      final s = await db.getProfitSummary(biz, start, end);
      expect(s.sales, closeTo(20000, 0.001));
      expect(s.cogs, closeTo(8000, 0.001), reason: 'snapshot 40 x 200');
      expect(s.gross, closeTo(12000, 0.001));
      expect(s.operatingExpenses, closeTo(3000, 0.001));
      expect(s.salaries, closeTo(10000, 0.001));
      expect(s.nonOperating, closeTo(7000, 0.001));
      expect(s.net, closeTo(-1000, 0.001),
          reason: '12000 gross - 3000 expenses - 10000 salaries');
      expect(s.unknownCostLines, 0);
      expect(s.unknownCostSales, closeTo(0, 0.001));
    });
  });

  group('getBatchProfits', () {
    test('FIFO: batch output sold through a bill', () async {
      const biz = 2;

      // Raw material 1,000 kg @ 100 -> batch material cost 100,000.
      final raw = await db.insertItem(StockItem(
          businessId: biz, name: 'Sarson BP', unit: 'kg', kind: 'raw'));
      final oil = await db.insertItem(StockItem(
          businessId: biz, name: 'Oil BP', unit: 'kg', kind: 'finished'));
      await db.insertStockTransaction(StockTransaction(
          itemId: raw,
          type: 'in',
          qty: 1000,
          rate: 100,
          dateTime: DateTime(2026, 11, 1)));

      // Batch #1: 1,000 kg raw -> 400 kg oil. Single output takes the
      // whole cost: allocated 100,000 / 400 = 250 per kg.
      final batchId = await db.createProductionBatch(
        batch: ProductionBatch(
            businessId: biz, batchNo: 1, dateTime: DateTime(2026, 11, 2)),
        inputs: [(itemId: raw, qty: 1000)],
        outputs: [(itemId: oil, qty: 400, saleRate: null)],
        expenses: const [],
      );

      // Sell 150 kg @ 600 through a bill.
      await db.createBill(
        businessId: biz,
        bill: Bill(
            businessId: biz,
            billNo: 1,
            partyName: 'Counter',
            total: 90000,
            status: 'paid',
            dateTime: DateTime(2026, 11, 5)),
        items: [
          BillItem(billId: 0, itemId: oil, name: 'Oil BP', qty: 150, rate: 600),
        ],
      );

      final profits = await db.getBatchProfits(biz);
      final bp = profits.singleWhere((e) => e.batchId == batchId);
      expect(bp.batchNo, 1);
      expect(bp.producedQty, closeTo(400, 0.001));
      expect(bp.soldQty, closeTo(150, 0.001));
      expect(bp.revenue, closeTo(90000, 0.001), reason: '150 x 600');
      expect(bp.cogs, closeTo(37500, 0.001), reason: '150 x 250 lot cost');
      expect(bp.profit, closeTo(52500, 0.001));
      expect(bp.unsoldQty, closeTo(250, 0.001), reason: '400 - 150');
    });
  });
}
