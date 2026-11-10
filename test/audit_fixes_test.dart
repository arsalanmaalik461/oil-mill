import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Verification for the post-implementation audit fixes:
///  - DB v11 bill payment method: a bill paid via bank/JazzCash must
///    NOT put physical cash in the drawer; only cash-paid bills do.
///  - Deleting a CONFIRMED QR payment reverses its wasool + cash-in.
///  - A salary payment can be deleted with its linked cash-out.
///  - Frozen daily closings travel in the JSON backup AND the
///    Firestore sync export (they were device-only before the fix).
///  - Book Check counts a deleted bill whose only surviving postings
///    are legacy (bill_id-less) party rows, and repair removes them.
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

  final day = DateTime(2026, 11, 6, 12);

  Future<List<CashEntry>> cashFrom(String table, int id) async =>
      (await db.getCashEntries(1))
          .where((e) => e.sourceTable == table && e.sourceId == id)
          .toList();

  test('paid bill via bank/jazzcash posts NO drawer cash; cash bill does',
      () async {
    final partyId = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Method Customer'));
    final itemId = await db.insertItem(
        StockItem(businessId: 1, name: 'Method Oil', unit: 'kg'));
    await db.insertStockTransaction(StockTransaction(
        itemId: itemId, type: 'in', qty: 100, rate: 100, dateTime: day));

    Future<int> bill(String method, double total) async {
      final no = await db.nextBillNo(1);
      return db.createBill(
        businessId: 1,
        bill: Bill(
            businessId: 1,
            billNo: no,
            partyId: partyId,
            partyName: 'Method Customer',
            total: total,
            status: 'paid',
            method: method,
            dateTime: day),
        items: [
          BillItem(
              billId: 0,
              itemId: itemId,
              name: 'Method Oil',
              qty: 10,
              rate: total / 10),
        ],
      );
    }

    final bankBill = await bill('bank', 2000);
    expect(await cashFrom('bills', bankBill), isEmpty);
    final jazzBill = await bill('jazzcash', 3000);
    expect(await cashFrom('bills', jazzBill), isEmpty);

    final txns = await db.getPartyTransactions(partyId);
    final wasools = txns.where((t) => t.type == 'wasool').toList();
    expect(wasools.map((t) => t.method), containsAll(['bank', 'jazzcash']));

    final cashBill = await bill('cash', 1000);
    final cashIns = await cashFrom('bills', cashBill);
    expect(cashIns, hasLength(1));
    expect(cashIns.single.amount, 1000);
  });

  test('deleting a confirmed QR payment reverses wasool + cash-in',
      () async {
    final partyId = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'QR Customer'));
    final qrId = await db.insertQrPayment(QrPayment(
        businessId: 1,
        partyId: partyId,
        amount: 7000,
        method: 'cash',
        dateTime: day));
    final q = (await db.getQrPayments(1)).firstWhere((e) => e.id == qrId);
    expect(await db.confirmQrPayment(q), isTrue);
    expect((await db.getPartyTransactions(partyId))
        .where((t) => t.note == 'QR payment'), hasLength(1));
    expect(await cashFrom('qr_payments', qrId), hasLength(1));

    await db.deleteQrPayment(qrId);
    expect((await db.getPartyTransactions(partyId))
        .where((t) => t.note == 'QR payment'), isEmpty);
    expect(await cashFrom('qr_payments', qrId), isEmpty);
    expect((await db.getQrPayments(1)).where((e) => e.id == qrId), isEmpty);
  });

  test('salary payment delete removes its linked cash-out', () async {
    final staffId = await db.insertStaff(
        Staff(businessId: 1, name: 'Fix Worker', monthlySalary: 30000));
    await db.insertSalaryPayment(SalaryPayment(
        staffId: staffId, type: 'salary', amount: 4000, dateTime: day));
    final pay = (await db.getSalaryPayments(staffId)).single;
    expect(await cashFrom('salary_payments', pay.id!), hasLength(1));

    await db.deleteSalaryPayment(pay.id!);
    expect(await db.getSalaryPayments(staffId), isEmpty);
    expect(await cashFrom('salary_payments', pay.id!), isEmpty);
  });

  test('daily closings are in the JSON backup and the sync export',
      () async {
    await db.insertCashEntry(CashEntry(
        businessId: 1, type: 'in', amount: 1234, note: 'fix seed', dateTime: day));
    final frozen = await db.freezeDailyClosing(1, day);
    expect(frozen.closing, isNonZero);

    final json = await db.exportJson();
    expect(json.contains('"daily_closings"'), isTrue);

    final sync = await db.exportBusinessData(1);
    expect(sync['daily_closings'], isA<List>());
    expect((sync['daily_closings'] as List), isNotEmpty);
  });

  test('Book Check counts a deleted bill with only legacy party postings',
      () async {
    final partyId = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Legacy Customer'));
    final itemId = await db.insertItem(
        StockItem(businessId: 1, name: 'Legacy Oil', unit: 'kg'));
    await db.insertStockTransaction(StockTransaction(
        itemId: itemId, type: 'in', qty: 50, rate: 100, dateTime: day));
    final no = await db.nextBillNo(1);
    final billId = await db.createBill(
      businessId: 1,
      bill: Bill(
          businessId: 1,
          billNo: no,
          partyId: partyId,
          partyName: 'Legacy Customer',
          total: 1500,
          status: 'paid',
          dateTime: day),
      items: [
        BillItem(
            billId: 0, itemId: itemId, name: 'Legacy Oil', qty: 10, rate: 150),
      ],
    );

    // Simulate a pre-Phase-3 book: strip the bill_id links, remove
    // the stock + cash postings, keep ONLY the legacy party rows, and
    // flag the bill deleted WITHOUT any reversal.
    final raw = await db.db;
    await raw.update('party_transactions', {'bill_id': null},
        where: 'bill_id = ?', whereArgs: [billId]);
    await raw.delete('stock_transactions',
        where: 'bill_id = ?', whereArgs: [billId]);
    await raw.delete('cash_entries',
        where: 'source_table = ? AND source_id = ?',
        whereArgs: ['bills', billId]);
    await raw.update('bills', {'deleted': 1},
        where: 'id = ?', whereArgs: [billId]);

    expect(await db.countDeletedBillsWithPostings(1), 1);
    await db.repairDeletedBills(1);
    expect(await db.countDeletedBillsWithPostings(1), 0);
    expect(
        (await db.getPartyTransactions(partyId))
            .where((t) => t.note.startsWith('Bill #')),
        isEmpty);
  });
}
