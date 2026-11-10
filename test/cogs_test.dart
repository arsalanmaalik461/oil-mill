import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';
import 'package:oilmill/utils/helpers.dart';

/// Phase 2 (Inventory & COGS) verification:
///  - perpetual moving-average pool (consumption leaves the pool)
///  - sale-time COGS snapshot: a later purchase cannot rewrite a
///    past sale's cost (the audit's Scenario B2)
///  - relative-sales-value allocation for joint products (oil/khal)
///  - kg-normalised quantity allocation across mixed units
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

  test('perpetual pool: 100@100, consume 90, 100@200 -> 190.91', () async {
    final item = await db.insertItem(
        StockItem(businessId: 1, name: 'Pool Item', unit: 'kg'));
    await db.insertStockTransaction(StockTransaction(
        itemId: item, type: 'in', qty: 100, rate: 100, dateTime: DateTime(2026, 11, 1)));
    await db.insertStockTransaction(StockTransaction(
        itemId: item, type: 'out', qty: 90, rate: 0, dateTime: DateTime(2026, 11, 2)));
    await db.insertStockTransaction(StockTransaction(
        itemId: item, type: 'in', qty: 100, rate: 200, dateTime: DateTime(2026, 11, 3)));
    // Remaining pool: 10 @ 100 + 100 @ 200 = 21,000 / 110 = 190.909
    // (the old lifetime formula answered 150.)
    expect(await db.getItemUnitCost(item), closeTo(190.909, 0.01));
  });

  test('Scenario B2: later purchase cannot change a past sale\'s COGS',
      () async {
    final khal = await db.insertItem(
        StockItem(businessId: 1, name: 'Khal B2', unit: 'kg', kind: 'finished'));
    await db.insertStockTransaction(StockTransaction(
        itemId: khal, type: 'in', qty: 200, rate: 700, dateTime: DateTime(2026, 11, 1)));
    final billId = await db.createBill(
      businessId: 1,
      bill: Bill(
          businessId: 1, billNo: 1, partyName: 'Counter',
          total: 150000, status: 'paid', dateTime: DateTime(2026, 11, 2)),
      items: [BillItem(billId: 0, itemId: khal, name: 'Khal B2', qty: 100, rate: 1500)],
    );
    var lines = await db.getBillItems(billId);
    expect(lines.single.costRate, 700);
    expect(lines.single.costAmount, 70000);

    // The expensive later purchase that used to rewrite history:
    await db.insertStockTransaction(StockTransaction(
        itemId: khal, type: 'in', qty: 100, rate: 1300, dateTime: DateTime(2026, 11, 3)));
    lines = await db.getBillItems(billId);
    expect(lines.single.costAmount, 70000, reason: 'snapshot is frozen');
    // Current pool cost DID move: (100x700 + 100x1300) / 200 = 1000
    expect(await db.getItemUnitCost(khal), closeTo(1000, 0.001));
  });

  test('relative sales value: oil carries its value share of the cost',
      () async {
    final raw = await db.insertItem(
        StockItem(businessId: 1, name: 'Sarson RSV', unit: 'kg', kind: 'raw'));
    final oil = await db.insertItem(
        StockItem(businessId: 1, name: 'Oil RSV', unit: 'kg', kind: 'finished'));
    final khal = await db.insertItem(
        StockItem(businessId: 1, name: 'Khal RSV', unit: 'kg', kind: 'finished'));
    await db.insertStockTransaction(StockTransaction(
        itemId: raw, type: 'in', qty: 1000, rate: 100, dateTime: DateTime(2026, 11, 1)));
    final batchId = await db.createProductionBatch(
      batch: ProductionBatch(
          businessId: 1, batchNo: 1, dateTime: DateTime(2026, 11, 2),
          allocationMethod: 'value'),
      inputs: [(itemId: raw, qty: 1000)],
      outputs: [
        (itemId: oil, qty: 100, saleRate: 4000),
        (itemId: khal, qty: 100, saleRate: 500),
      ],
      expenses: const [],
    );
    final outs = await db.getBatchOutputs(batchId);
    final oilOut = outs.firstWhere((o) => o.itemId == oil);
    final khalOut = outs.firstWhere((o) => o.itemId == khal);
    // Total cost 100,000; value weights 400,000 vs 50,000
    expect(oilOut.allocatedCost, closeTo(88888.89, 0.5));
    expect(khalOut.allocatedCost, closeTo(11111.11, 0.5));
    expect(oilOut.costPerUnit, closeTo(888.89, 0.01));
    expect(khalOut.costPerUnit, closeTo(111.11, 0.01));
  });

  test('quantity allocation converts litres through density', () async {
    final raw = await db.insertItem(
        StockItem(businessId: 1, name: 'Sarson Mix', unit: 'kg', kind: 'raw'));
    final oil = await db.insertItem(StockItem(
        businessId: 1, name: 'Oil Ltr', unit: 'Litre', kind: 'finished',
        density: 0.92));
    final khal = await db.insertItem(
        StockItem(businessId: 1, name: 'Khal Mix', unit: 'kg', kind: 'finished'));
    await db.insertStockTransaction(StockTransaction(
        itemId: raw, type: 'in', qty: 200, rate: 500, dateTime: DateTime(2026, 11, 1)));
    final batchId = await db.createProductionBatch(
      batch: ProductionBatch(
          businessId: 1, batchNo: 2, dateTime: DateTime(2026, 11, 2)),
      inputs: [(itemId: raw, qty: 200)],
      outputs: [
        (itemId: oil, qty: 100, saleRate: null), // 100 L x 0.92 = 92 kg
        (itemId: khal, qty: 92, saleRate: null), // 92 kg
      ],
      expenses: const [],
    );
    final outs = await db.getBatchOutputs(batchId);
    // Equal kg weights -> the 100,000 total splits 50,000 / 50,000
    expect(outs.firstWhere((o) => o.itemId == oil).allocatedCost,
        closeTo(50000, 0.5));
    expect(outs.firstWhere((o) => o.itemId == khal).allocatedCost,
        closeTo(50000, 0.5));
    expect(outs.firstWhere((o) => o.itemId == oil).costPerUnit,
        closeTo(500, 0.01)); // per litre
  });

  test('unit factors: mann is 40 kg, litre uses density', () {
    expect(unitToKgFactor('Mann'), 40);
    expect(unitToKgFactor('Maund'), 40);
    expect(unitToKgFactor('Litre', densityKgPerLitre: 0.92), 0.92);
    expect(unitToKgFactor('Kilogram'), 1);
    expect(unitToKgFactor('Ton'), 1000);
  });
}
