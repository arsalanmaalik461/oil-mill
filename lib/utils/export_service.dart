import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import '../db/database_helper.dart';

/// Spreadsheet exports (accountant-friendly): every book as CSV or
/// Excel, plus a full-database Excel workbook (one sheet per table).
/// CSV needs no package; Excel uses the `excel` package.
class ExportService {
  static final _df = DateFormat('yyyy-MM-dd HH:mm');

  static String _csvCell(Object? v) {
    final s = v?.toString() ?? '';
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  static String toCsv(List<String> headers, List<List<Object?>> rows) {
    final b = StringBuffer();
    b.writeln(headers.map(_csvCell).join(','));
    for (final r in rows) {
      b.writeln(r.map(_csvCell).join(','));
    }
    return b.toString();
  }

  static CellValue _cell(Object? v) {
    if (v == null) return TextCellValue('');
    if (v is num) return DoubleCellValue(v.toDouble());
    return TextCellValue(v.toString());
  }

  static List<int> toExcel(String sheetName, List<String> headers,
      List<List<Object?>> rows) {
    final xl = Excel.createExcel();
    final sheet = xl[sheetName];
    sheet.appendRow(headers.map(_cell).toList());
    for (final r in rows) {
      sheet.appendRow(r.map(_cell).toList());
    }
    xl.delete('Sheet1');
    final bytes = xl.encode();
    return bytes ?? <int>[];
  }

  /// One book of the business as (headers, rows).
  static Future<({List<String> headers, List<List<Object?>> rows})> book(
      DatabaseHelper db, int bizId, String book) async {
    switch (book) {
      case 'parties':
        final sums = await db.getPartySummaries(bizId);
        return (
          headers: ['Name', 'Type', 'Phone', 'Address', 'Opening Balance', 'Balance'],
          rows: [
            for (final s in sums)
              [s.party.name, s.party.type, s.party.phone, s.party.address, s.party.openingBalance, s.balance]
          ],
        );
      case 'ledger':
        final parties = await db.getParties(bizId);
        final rows = <List<Object?>>[];
        for (final party in parties) {
          for (final t in await db.getPartyTransactions(party.id!)) {
            rows.add([
              party.name, _df.format(t.dateTime), t.type, t.amount, t.method, t.note,
            ]);
          }
        }
        return (
          headers: ['Party', 'Date', 'Type', 'Amount', 'Method', 'Note'],
          rows: rows,
        );
      case 'cash':
        final entries = await db.getCashEntries(bizId);
        return (
          headers: ['Date', 'Type', 'Amount', 'Note'],
          rows: [
            for (final e in entries) [_df.format(e.dateTime), e.type, e.amount, e.note]
          ],
        );
      case 'stock':
        final sums = await db.getItemSummaries(bizId);
        final rows = <List<Object?>>[];
        for (final s in sums) {
          final cost = await db.getItemUnitCost(s.item.id!);
          rows.add([
            s.item.name, s.item.unit, s.item.category, s.item.openingQty,
            s.qty, cost, s.qty * cost,
          ]);
        }
        return (
          headers: ['Item', 'Unit', 'Category', 'Opening Qty', 'Current Qty', 'Avg Cost', 'Stock Value'],
          rows: rows,
        );
      case 'bills':
        final bills = await db.getBills(bizId);
        return (
          headers: ['Bill No', 'Date', 'Party', 'Total', 'Status', 'Method'],
          rows: [
            for (final b in bills)
              [b.billNo, _df.format(b.dateTime), b.partyName, b.total, b.status, b.method]
          ],
        );
      case 'expenses':
        final expenses = await db.getExpenses(bizId);
        return (
          headers: ['Date', 'Category', 'Kind', 'Amount', 'Account', 'Note'],
          rows: [
            for (final e in expenses)
              [_df.format(e.dateTime), e.category, e.kind, e.amount, e.account, e.note]
          ],
        );
      default:
        return (headers: <String>[], rows: <List<Object?>>[]);
    }
  }

  /// The whole business as an Excel workbook: one sheet per table.
  static Future<List<int>> fullDatabaseExcel(
      DatabaseHelper db, int bizId) async {
    final data = await db.exportBusinessData(bizId);
    final xl = Excel.createExcel();
    var first = true;
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is! List || value.isEmpty) continue;
      final maps = value.whereType<Map>().toList();
      if (maps.isEmpty) continue;
      final headers = maps.first.keys.map((k) => k.toString()).toList();
      final sheetName = entry.key.length > 31
          ? entry.key.substring(0, 31)
          : entry.key;
      final sheet = first ? (xl['Sheet1']) : xl[sheetName];
      if (first) {
        xl.rename('Sheet1', sheetName);
        first = false;
      }
      sheet.appendRow(headers.map(_cell).toList());
      for (final m in maps) {
        sheet.appendRow(headers.map((h) => _cell(m[h])).toList());
      }
    }
    final bytes = xl.encode();
    return bytes ?? <int>[];
  }
}
