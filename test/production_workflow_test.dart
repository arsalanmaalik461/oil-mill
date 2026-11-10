import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// End-to-end workflow verification on a real (ffi) SQLite database:
/// Supplier Purchase -> Raw Material Stock -> Production Batch ->
/// Finished Goods Stock -> Sales Invoice -> Profit from actual COGS.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = DatabaseHelper.instance;

  setUpAll(() async {
    // Start from a clean database file for deterministic numbers.
    final path = '${await getDatabasesPath()}/namat_oil_mill.db';
    await databaseFactoryFfi.deleteDatabase(path);
    await db.db; // opens + creates schema (business id 1 seeded)
  });

  tearDownAll(() async => db.close());

  test('full production workflow with weighted-average costing', () async {
    // --- Setup: supplier, raw material (Sarson), finished goods (Khal, Oil)
    final supplierId = await db.insertParty(Party(
        businessId: 1, type: 'supplier', name: 'Test Supplier'));
    final rawId = await db.insertItem(StockItem(
        businessId: 1, name: 'Sarson', unit: 'kg', kind: 'raw'));
    final khalId = await db.insertItem(StockItem(
        businessId: 1, name: 'Khal', unit: 'kg', kind: 'finished'));
    final oilId = await db.insertItem(StockItem(
        businessId: 1, name: 'Oil', unit: 'kg', kind: 'finished'));
    final customerId = await db.insertParty(Party(
        businessId: 1, type: 'customer', name: 'Test Customer'));

    // --- 1. Purchase 1000 kg @ Rs 100, then 500 kg @ Rs 130 (credit)
    await db.insertStockTransaction(StockTransaction(
        itemId: rawId, type: 'in', qty: 1000, rate: 100,
        supplierId: supplierId, dateTime: DateTime(2026, 11, 1)));
    await db.insertStockTransaction(StockTransaction(
        itemId: rawId, type: 'in', qty: 500, rate: 130,
        supplierId: supplierId, dateTime: DateTime(2026, 11, 2)));
    expect(await db.getItemQty(rawId), 1500);
    // Weighted average = (1000*100 + 500*130) / 1500 = 110
    expect(await db.getItemAvgCost(rawId), closeTo(110, 1e-9));

    // --- 2. Production batch: consume 1000 kg, expenses Rs 5000,
    //        outputs Khal 600 kg + Oil (by-product) 350 kg, wastage 50 kg
    final batchNo = await db.getNextBatchNo(1);
    final batchId = await db.createProductionBatch(
      batch: ProductionBatch(
          businessId: 1, batchNo: batchNo, dateTime: DateTime(2026, 11, 3),
          wastageQty: 50, wastageNote: 'pressing loss'),
      inputs: [(itemId: rawId, qty: 1000)],
      outputs: [(itemId: khalId, qty: 600, saleRate: null), (itemId: oilId, qty: 350, saleRate: null)],
      expenses: [
        ProductionExpense(
            batchId: 0, category: 'labour', amount: 5000,
            dateTime: DateTime(2026, 11, 3)),
      ],
    );
    // Raw stock deducted, finished goods added.
    expect(await db.getItemQty(rawId), 500);
    expect(await db.getItemQty(khalId), 600);
    expect(await db.getItemQty(oilId), 350);
    // Material cost snapshot = 1000 * 110 (WAC) = 110,000
    final inputs = await db.getBatchInputs(batchId);
    expect(inputs.single.cost, closeTo(110000, 1e-6));
    // Total cost = 115,000 allocated by output qty (950 kg total):
    // per-unit cost identical for both outputs = 115000/950
    final outputs = await db.getBatchOutputs(batchId);
    final khalOut = outputs.firstWhere((o) => o.itemId == khalId);
    expect(khalOut.costPerUnit, closeTo(115000 / 950, 1e-6));
    expect(khalOut.allocatedCost, closeTo(115000 * 600 / 950, 1e-6));
    // Finished unit cost for COGS = production average
    expect(await db.getItemUnitCost(khalId), closeTo(115000 / 950, 1e-6));

    // --- 3. Insufficient stock is rejected (no negative stock)
    expect(
      () => db.createProductionBatch(
        batch: ProductionBatch(
            businessId: 1, batchNo: 99, dateTime: DateTime(2026, 11, 3)),
        inputs: [(itemId: rawId, qty: 99999)],
        outputs: [(itemId: khalId, qty: 10, saleRate: null)],
        expenses: const [],
      ),
      throwsA(isA<StateError>()),
    );
    expect(await db.getItemQty(rawId), 500); // unchanged after rejection

    // --- 4. Sale: 100 kg Khal @ Rs 150 through the Bill Book
    await db.createBill(
      businessId: 1,
      bill: Bill(
          businessId: 1, billNo: 1, partyId: customerId,
          partyName: 'Test Customer', total: 15000, status: 'pending',
          dateTime: DateTime(2026, 11, 4)),
      items: [
        BillItem(
            billId: 0, itemId: khalId, name: 'Khal', qty: 100, rate: 150),
      ],
    );
    expect(await db.getItemQty(khalId), 500); // stock deducted by the bill
    expect(await db.getItemSoldQty(khalId), 100);
    // Profit on actual COGS: 15000 - 100 * (115000/950) = 2894.736...
    final cogs = 100 * await db.getItemUnitCost(khalId);
    expect(15000 - cogs, closeTo(15000 - 100 * 115000 / 950, 1e-6));
    // Customer owes the bill amount (udhaar posted by createBill)
    expect(await db.getPartyBalance(customerId), closeTo(15000, 1e-9));

    // --- 5. Cancel a second batch: all postings reverse exactly
    await db.insertStockTransaction(StockTransaction(
        itemId: rawId, type: 'in', qty: 200, rate: 110,
        supplierId: supplierId, dateTime: DateTime(2026, 11, 5)));
    final batch2 = await db.createProductionBatch(
      batch: ProductionBatch(
          businessId: 1, batchNo: await db.getNextBatchNo(1),
          dateTime: DateTime(2026, 11, 5)),
      inputs: [(itemId: rawId, qty: 200)],
      outputs: [(itemId: khalId, qty: 120, saleRate: null)],
      expenses: const [],
    );
    expect(await db.getItemQty(rawId), 500);
    expect(await db.getItemQty(khalId), 620);
    await db.cancelProductionBatch(batch2);
    expect(await db.getItemQty(rawId), 700);
    expect(await db.getItemQty(khalId), 500);
    final batches = await db.getProductionBatches(1);
    expect(
        batches.firstWhere((b) => b.id == batch2).status, 'cancelled');
  });
}
