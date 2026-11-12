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

  test('expense category totals: operating only, period-bound, grouped',
      () async {
    final nov = DateTime(2026, 11, 10, 12);
    final oct = DateTime(2026, 10, 10, 12);
    Future<void> exp(String cat, double amt, DateTime when,
            {String kind = 'operating'}) =>
        db.insertExpense(Expense(
            businessId: 1,
            category: cat,
            amount: amt,
            dateTime: when,
            kind: kind));
    await exp('Diesel', 5000, nov);
    await exp(' Diesel ', 3000, nov); // trims into the same group
    await exp('Bills', 2000, nov);
    await exp('', 700, nov); // Other
    await exp('Diesel', 9999, oct); // outside the period
    await exp('Diesel', 8888, nov, kind: 'owner'); // not operating

    final start = DateTime(2026, 11, 1);
    final end = DateTime(2026, 12, 1);
    final cats = await db.getExpenseCategoryTotals(1, start, end);
    final byCat = {for (final c in cats) c.category: c.total};
    expect(byCat['Diesel'], 8000);
    expect(byCat['Bills'], 2000);
    expect(byCat['Other'], 700);
    expect(byCat.length, 3);
    expect(cats.first.category, 'Diesel', reason: 'sorted high to low');
  });
}
