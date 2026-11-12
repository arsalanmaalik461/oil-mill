import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

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

  test('supplier rates: grouped, cheapest last-rate first', () async {
    final d1 = DateTime(2026, 10, 1, 12);
    final d2 = DateTime(2026, 11, 1, 12);
    final cheap = await db.insertParty(Party(
        businessId: 1, type: 'supplier', name: 'Cheap Supplier'));
    final dear = await db.insertParty(Party(
        businessId: 1, type: 'supplier', name: 'Dear Supplier'));
    final seed = await db.insertItem(
        StockItem(businessId: 1, name: 'Sarson', unit: 'kg', kind: 'raw'));
    // Cheap: 300 then 280 (last = 280). Dear: 350 once.
    await db.saveRawPurchase(
        businessId: 1, itemId: seed, supplierId: cheap,
        qty: 100, rate: 300, dateTime: d1, paid: false);
    await db.saveRawPurchase(
        businessId: 1, itemId: seed, supplierId: cheap,
        qty: 50, rate: 280, dateTime: d2, paid: false);
    await db.saveRawPurchase(
        businessId: 1, itemId: seed, supplierId: dear,
        qty: 80, rate: 350, dateTime: d2, paid: false);

    final items = await db.getPurchasedItems(1);
    expect(items.map((i) => i.name), contains('Sarson'));
    final rates = await db.getSupplierRates(seed);
    expect(rates, hasLength(2));
    expect(rates.first.supplier.name, 'Cheap Supplier');
    expect(rates.first.lastRate, 280);
    expect(rates.first.purchases, 2);
    expect(rates.first.totalQty, 150);
    expect(rates.first.minRate, 280);
    expect(rates.first.maxRate, 300);
    expect(rates.last.supplier.name, 'Dear Supplier');
    expect(rates.last.lastRate, 350);
  });
}
