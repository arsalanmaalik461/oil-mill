import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Phase 3 (Transaction Integrity) verification:
///  - deleting a bill reverses stock + ledger + cash exactly
///  - restoring re-posts them, COGS snapshot preserved
///  - legacy bills (no bill_id) are detected by Book Check and repaired
///  - bill editing is atomic (reverse + re-post, same number)
///  - raw purchases / returns post completely in one transaction
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

  final when = DateTime(2026, 11, 6, 10);
  late int itemId;
  late int customerId;
  late int supplierId;

  Future<int> makeBill({
    required int billNo,
    required String status,
    required double qty,
    required double rate,
  }) {
    return db.createBill(
      businessId: 1,
      bill: Bill(
          businessId: 1,
          billNo: billNo,
          partyId: customerId,
          partyName: 'Cust',
          total: qty * rate,
          status: status,
          dateTime: when),
      items: [
        BillItem(
            billId: 0, itemId: itemId, name: 'Oil', qty: qty, rate: rate),
      ],
    );
  }

  test('setup stock', () async {
    itemId = await db.insertItem(
        StockItem(businessId: 1, name: 'Oil', unit: 'kg', kind: 'finished'));
    customerId = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Cust'));
    supplierId = await db.insertParty(
        Party(businessId: 1, type: 'supplier', name: 'Supp'));
    await db.insertStockTransaction(StockTransaction(
        itemId: itemId, type: 'in', qty: 100, rate: 500, dateTime: when));
    expect(await db.getItemQty(itemId), 100);
  });

  test('delete reverses everything; restore re-posts identically',
      () async {
    final cash0 = await db.getCashBalance(1);
    final billId = await makeBill(billNo: 1, status: 'paid', qty: 10, rate: 900);
    expect(await db.getItemQty(itemId), 90);
    expect(await db.getPartyBalance(customerId), 0); // udhaar + wasool
    expect(await db.getCashBalance(1), cash0 + 9000);
    final itemsBefore = await db.getBillItems(billId);
    expect(itemsBefore.single.costAmount, 5000); // snapshot 10 x 500

    await db.setBillDeleted(billId, true);
    expect(await db.getItemQty(itemId), 100, reason: 'stock restored');
    expect(await db.getPartyBalance(customerId), 0,
        reason: 'udhaar/wasool both reversed');
    expect(await db.getCashBalance(1), cash0, reason: 'cash reversed');
    expect(await db.countDeletedBillsWithPostings(1), 0);

    await db.setBillDeleted(billId, false);
    expect(await db.getItemQty(itemId), 90);
    expect(await db.getCashBalance(1), cash0 + 9000);
    final itemsAfter = await db.getBillItems(billId);
    expect(itemsAfter.single.costAmount, 5000,
        reason: 'original COGS snapshot survives delete + restore');

    await db.deleteBillForever(billId);
    expect(await db.getItemQty(itemId), 100);
    expect(await db.getCashBalance(1), cash0);
    expect((await db.getBills(1)).where((b) => b.id == billId), isEmpty);
  });

  test('legacy deleted bill is detected and repaired', () async {
    final billId = await makeBill(billNo: 2, status: 'paid', qty: 5, rate: 900);
    final raw = await db.db;
    // Simulate a pre-Phase-3 delete: strip the links, flip the flag,
    // leave every posting behind.
    await raw.update('stock_transactions', {'bill_id': null},
        where: 'bill_id = ?', whereArgs: [billId]);
    await raw.update('party_transactions', {'bill_id': null},
        where: 'bill_id = ?', whereArgs: [billId]);
    await raw.update('cash_entries', {'source_table': null, 'source_id': null},
        where: 'source_table = ? AND source_id = ?',
        whereArgs: ['bills', billId]);
    await raw.update('bills', {'deleted': 1}, where: 'id = ?', whereArgs: [billId]);

    expect(await db.getItemQty(itemId), 95, reason: 'posting still there');
    expect(await db.countDeletedBillsWithPostings(1), 1);
    final cashBefore = await db.getCashBalance(1);
    await db.repairDeletedBills(1);
    expect(await db.getItemQty(itemId), 100);
    expect(await db.getCashBalance(1), cashBefore - 4500);
    expect(await db.getPartyBalance(customerId), 0);
    expect(await db.countDeletedBillsWithPostings(1), 0);
  });

  test('bill edit: reverse + re-post atomically, number kept', () async {
    final billId = await makeBill(billNo: 3, status: 'pending', qty: 10, rate: 900);
    expect(await db.getItemQty(itemId), 90);
    expect(await db.getPartyBalance(customerId), 9000); // owes us

    final edited = Bill(
      id: billId,
      businessId: 1,
      billNo: 3,
      partyId: customerId,
      partyName: 'Cust',
      total: 4 * 900,
      status: 'paid',
      dateTime: when,
    );
    final oldItems = await db.getBillItems(billId);
    await db.updateBill(
      bill: edited,
      items: [
        BillItem(
            billId: billId,
            itemId: itemId,
            name: 'Oil',
            qty: 4,
            rate: 900,
            costRate: oldItems.single.costRate),
      ],
    );
    expect(await db.getItemQty(itemId), 96, reason: 'only 4 out now');
    expect(await db.getPartyBalance(customerId), 0,
        reason: 'paid edit posts wasool against the new udhaar');
    final cash = await db.getCashBalance(1);
    expect(cash, 3600);
    final bills = await db.getBills(1);
    expect(bills.single.billNo, 3);
    expect(bills.single.total, 3600);
  });

  test('raw purchase is atomic and complete; return adjusts', () async {
    final cash0 = await db.getCashBalance(1);
    await db.saveRawPurchase(
      businessId: 1,
      itemId: itemId,
      qty: 50,
      rate: 400,
      supplierId: supplierId,
      paid: true,
      dateTime: when,
    );
    expect(await db.getItemQty(itemId), 146);
    expect(await db.getPartyBalance(supplierId), 0); // wasool + udhaar
    expect(await db.getCashBalance(1), cash0 - 20000);

    await db.saveRawPurchase(
      businessId: 1,
      itemId: itemId,
      qty: 10,
      rate: 400,
      supplierId: supplierId,
      paid: false,
      dateTime: when,
    );
    expect(await db.getPartyBalance(supplierId), -4000); // we owe

    await db.savePurchaseReturn(
      itemId: itemId,
      qty: 4,
      rate: 400,
      supplierId: supplierId,
      dateTime: when,
    );
    expect(await db.getItemQty(itemId), 152);
    expect(await db.getPartyBalance(supplierId), -2400);
  });
}
