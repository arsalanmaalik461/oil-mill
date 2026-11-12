import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Sales Return fix (backlog plan #1): the old flow restocked at the
/// SALE rate (inflating the cost pool), posted party-credit AND a
/// cash refund for the same goods, and was not atomic. saveSalesReturn
/// restocks at cost and posts exactly one money side.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = DatabaseHelper.instance;
  final day = DateTime(2026, 11, 5, 12);

  setUpAll(() async {
    final path = '${await getDatabasesPath()}/namat_oil_mill.db';
    await databaseFactoryFfi.deleteDatabase(path);
    await db.db;
  });
  tearDownAll(() async => db.close());

  test('credit-bill return: wasool only, restock at cost, no cash moves',
      () async {
    final cust = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Return Cust'));
    final oil = await db.insertItem(StockItem(
        businessId: 1, name: 'Oil SR', unit: 'kg', kind: 'finished'));
    // Stock in at cost 200, then a credit sale of 10 @ 500.
    await db.insertStockTransaction(StockTransaction(
        itemId: oil, type: 'in', qty: 100, rate: 200, dateTime: day));
    final billId = await db.createBill(
      businessId: 1,
      bill: Bill(
          businessId: 1,
          billNo: 501,
          partyId: cust,
          partyName: 'Return Cust',
          total: 5000,
          status: 'pending',
          dateTime: day),
      items: [BillItem(billId: 0, itemId: oil, name: 'Oil SR', qty: 10, rate: 500)],
    );
    expect(await db.getPartyBalance(cust), 5000);
    expect(await db.getItemQty(oil), 90);
    final cashBefore = await db.getCashBalance(1);

    await db.saveSalesReturn(
        businessId: 1,
        itemId: oil,
        qty: 4,
        saleRate: 500,
        partyId: cust,
        refund: false,
        billId: billId,
        dateTime: day.add(const Duration(days: 1)));

    expect(await db.getPartyBalance(cust), 3000,
        reason: 'udhaar drops by 4 x 500, exactly once');
    expect(await db.getItemQty(oil), 94, reason: 'goods are back');
    expect(await db.getItemUnitCost(oil), 200,
        reason: 'restocked at the bill cost snapshot, NOT the 500 sale rate');
    final cashAfter = await db.getCashBalance(1);
    expect(cashAfter, cashBefore, reason: 'credit return moves no cash');
  });

  test('paid return with refund: cash out only, no party entry', () async {
    final oil2 = await db.insertItem(StockItem(
        businessId: 1, name: 'Oil SR2', unit: 'kg', kind: 'finished'));
    await db.insertStockTransaction(StockTransaction(
        itemId: oil2, type: 'in', qty: 50, rate: 300, dateTime: day));
    final cashBefore = await db.getCashBalance(1);
    // Refund requested AND a party id passed: still only the refund.
    final cust2 = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Refund Cust'));
    await db.saveSalesReturn(
        businessId: 1,
        itemId: oil2,
        qty: 2,
        saleRate: 600,
        partyId: cust2,
        refund: true,
        method: 'cash',
        dateTime: day.add(const Duration(days: 2)));
    final cashAfter = await db.getCashBalance(1);
    expect(cashAfter, cashBefore - 1200, reason: 'drawer pays the refund once');
    expect(await db.getPartyBalance(cust2), 0,
        reason: 'no wasool posted alongside a refund (the old double-post)');
    expect(await db.getItemQty(oil2), 52);
    expect(await db.getItemUnitCost(oil2), 300,
        reason: 'restocked at current unit cost, not the 600 sale rate');
  });

  test('non-cash refund leaves the drawer alone', () async {
    final oil3 = await db.insertItem(StockItem(
        businessId: 1, name: 'Oil SR3', unit: 'kg', kind: 'finished'));
    await db.insertStockTransaction(StockTransaction(
        itemId: oil3, type: 'in', qty: 10, rate: 100, dateTime: day));
    final cashBefore = await db.getCashBalance(1);
    await db.saveSalesReturn(
        businessId: 1,
        itemId: oil3,
        qty: 1,
        saleRate: 900,
        refund: true,
        method: 'jazzcash',
        dateTime: day.add(const Duration(days: 3)));
    final cashAfter = await db.getCashBalance(1);
    expect(cashAfter, cashBefore,
        reason: 'a JazzCash refund never touched the cash drawer');
    expect(await db.getItemQty(oil3), 11);
  });
}
