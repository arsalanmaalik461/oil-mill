import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';
import 'package:oilmill/utils/export_service.dart';

/// Data Export (backlog plan #9): every book as CSV/Excel and a
/// full-database workbook — the accountant-facing export the JSON
/// backup never was.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = DatabaseHelper.instance;
  final day = DateTime(2026, 11, 8, 12);

  setUpAll(() async {
    final path = '${await getDatabasesPath()}/namat_oil_mill.db';
    await databaseFactoryFfi.deleteDatabase(path);
    await db.db;
    final cust = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Export, "Cust"'));
    await db.insertPartyTransaction(PartyTransaction(
        partyId: cust, type: 'udhaar', amount: 42000, dateTime: day));
    await db.insertItem(
        StockItem(businessId: 1, name: 'Sarson', unit: 'kg', kind: 'raw'));
    await db.insertCashEntry(CashEntry(
        businessId: 1, type: 'in', amount: 5000, note: 'test', dateTime: day));
    await db.insertExpense(Expense(
        businessId: 1, category: 'Diesel', amount: 1500, dateTime: day));
  });
  tearDownAll(() async => db.close());

  test('CSV export escapes commas and quotes', () {
    final csv = ExportService.toCsv(
        ['Name', 'Note'], [['Export, "Cust"', 'plain']]);
    final lines = const LineSplitter().convert(csv);
    expect(lines[1], '"Export, ""Cust""",plain');
  });

  test('parties book carries the live balance', () async {
    final book = await ExportService.book(db, 1, 'parties');
    expect(book.headers, contains('Balance'));
    final row = book.rows.single;
    expect(row[0], contains('Export'));
    expect(row[5], 42000);
  });

  test('single-book Excel decodes with the data inside', () async {
    final book = await ExportService.book(db, 1, 'expenses');
    final bytes = ExportService.toExcel('expenses', book.headers, book.rows);
    expect(bytes, isNotEmpty);
    final xl = Excel.decodeBytes(bytes);
    expect(xl.tables.keys, contains('expenses'));
    expect(xl.tables.keys, isNot(contains('Sheet1')));
    final sheet = xl['expenses'];
    expect(sheet.maxRows, 2); // header + 1 expense
    expect(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 1)).value.toString(), contains('Diesel'));
  });

  test('full-database workbook has one sheet per non-empty table', () async {
    final bytes = await ExportService.fullDatabaseExcel(db, 1);
    final xl = Excel.decodeBytes(bytes);
    expect(xl.tables.keys, containsAll(['parties', 'cash_entries', 'expenses']));
    final parties = xl['parties'];
    expect(parties.maxRows, greaterThanOrEqualTo(2));
  });
}
