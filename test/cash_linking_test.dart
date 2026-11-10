import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Phase 1 (Cash Accounting) verification on a real ffi SQLite DB:
/// ledger entries, expenses and salaries post LINKED cash movements;
/// digital methods never touch the drawer; QR confirm is idempotent;
/// and the audit's Scenario A now closes correctly for the right
/// reason (in 70,000 / out 20,000, not by coincidence).
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

  final day = DateTime(2026, 11, 5, 12);
  final prevDay = DateTime(2026, 11, 4, 12);
  late int customerId;
  late int supplierId;

  Future<double> dayIn() async {
    final rows = await db.getCashEntries(1);
    return rows
        .where((e) =>
            e.type == 'in' &&
            e.dateTime.year == day.year &&
            e.dateTime.month == day.month &&
            e.dateTime.day == day.day)
        .fold<double>(0.0, (s, e) => s + e.amount);
  }

  Future<double> dayOut() async {
    final rows = await db.getCashEntries(1);
    return rows
        .where((e) =>
            e.type == 'out' &&
            e.dateTime.year == day.year &&
            e.dateTime.month == day.month &&
            e.dateTime.day == day.day)
        .fold<double>(0.0, (s, e) => s + e.amount);
  }

  test('Scenario A: closing 150,000 for the RIGHT reason', () async {
    customerId = await db.insertParty(
        Party(businessId: 1, type: 'customer', name: 'Cash Customer'));
    supplierId = await db.insertParty(
        Party(businessId: 1, type: 'supplier', name: 'Cash Supplier'));

    // Opening cash 100,000 (manual entry, previous day)
    await db.insertCashEntry(CashEntry(
        businessId: 1,
        type: 'in',
        amount: 100000,
        note: 'Opening',
        dateTime: prevDay));

    // Paid bill 50,000 (createBill posts its own cash-in)
    await db.createBill(
      businessId: 1,
      bill: Bill(
          businessId: 1,
          billNo: 1,
          partyId: customerId,
          partyName: 'Cash Customer',
          total: 50000,
          status: 'paid',
          dateTime: day),
      items: [
        BillItem(billId: 0, name: 'Oil', qty: 10, rate: 5000),
      ],
    );

    // Party wasool 20,000 in CASH via the manual ledger path
    await db.insertLedgerEntry(PartyTransaction(
        partyId: customerId,
        type: 'wasool',
        amount: 20000,
        note: 'wasool',
        dateTime: day,
        method: 'cash'));

    // Cash expense 5,000
    await db.insertExpense(Expense(
        businessId: 1,
        category: 'Fuel',
        amount: 5000,
        account: 'cash',
        dateTime: day));

    // Supplier payment 15,000 in CASH via the manual ledger path
    await db.insertLedgerEntry(PartyTransaction(
        partyId: supplierId,
        type: 'udhaar',
        amount: 15000,
        note: 'supplier payment',
        dateTime: day,
        method: 'cash'));

    expect(await dayIn(), 70000, reason: 'bill 50,000 + wasool 20,000');
    expect(await dayOut(), 20000, reason: 'expense 5,000 + supplier 15,000');
    expect(await db.getCashBalance(1), 150000);
  });

  test('digital wasool never touches the drawer', () async {
    final before = await db.getCashBalance(1);
    await db.insertLedgerEntry(PartyTransaction(
        partyId: customerId,
        type: 'wasool',
        amount: 8000,
        dateTime: day,
        method: 'jazzcash'));
    expect(await db.getCashBalance(1), before);
    // ...but the ledger balance still moves
    expect(await db.getPartyBalance(customerId), -58000 + 30000);
  });

  test('expense edit/delete re-sync the linked cash entry', () async {
    final id = await db.insertExpense(Expense(
        businessId: 1,
        category: 'Misc',
        amount: 2000,
        account: 'cash',
        dateTime: day));
    var bal = await db.getCashBalance(1);
    await db.updateExpense(Expense(
        id: id,
        businessId: 1,
        category: 'Misc',
        amount: 3500,
        account: 'cash',
        dateTime: day));
    expect(await db.getCashBalance(1), bal - 1500);
    // Switching to bank removes the drawer entry entirely
    await db.updateExpense(Expense(
        id: id,
        businessId: 1,
        category: 'Misc',
        amount: 3500,
        account: 'bank',
        dateTime: day));
    expect(await db.getCashBalance(1), bal + 2000);
    await db.deleteExpense(id);
    expect(await db.getCashBalance(1), bal + 2000);
  });

  test('ledger entry edit and delete keep the drawer in sync', () async {
    final id = await db.insertLedgerEntry(PartyTransaction(
        partyId: customerId, type: 'wasool', amount: 4000, dateTime: day));
    final bal = await db.getCashBalance(1);
    await db.updatePartyTransaction(PartyTransaction(
        id: id,
        partyId: customerId,
        type: 'udhaar', // flipped: money now goes OUT
        amount: 6000,
        dateTime: day));
    expect(await db.getCashBalance(1), bal - 10000);
    await db.deletePartyTransaction(id);
    expect(await db.getCashBalance(1), bal - 4000);
  });

  test('salary payment posts a cash outflow', () async {
    final staffId = await db.insertStaff(
        Staff(businessId: 1, name: 'Worker', monthlySalary: 30000));
    final bal = await db.getCashBalance(1);
    await db.insertSalaryPayment(SalaryPayment(
        staffId: staffId, type: 'salary', amount: 30000, dateTime: day));
    expect(await db.getCashBalance(1), bal - 30000);
  });

  test('QR confirm: idempotent, and digital money is not drawer cash',
      () async {
    final qrId = await db.insertQrPayment(QrPayment(
        businessId: 1,
        partyId: customerId,
        payerName: 'Payer',
        amount: 9000,
        method: 'jazzcash',
        status: 'pending',
        dateTime: day));
    final q = (await db.getQrPayments(1)).firstWhere((e) => e.id == qrId);
    final bal = await db.getCashBalance(1);
    expect(await db.confirmQrPayment(q), isTrue);
    expect(await db.getCashBalance(1), bal,
        reason: 'JazzCash receipt must not inflate physical cash');
    final txns = await db.getPartyTransactions(customerId);
    final wasools =
        txns.where((t) => t.type == 'wasool' && t.amount == 9000).toList();
    expect(wasools.length, 1);
    expect(wasools.single.method, 'jazzcash');
    // Second confirm: no-op, nothing double-posts
    expect(await db.confirmQrPayment(q), isFalse);
    final txns2 = await db.getPartyTransactions(customerId);
    expect(txns2.where((t) => t.type == 'wasool' && t.amount == 9000).length,
        1);
  });

  test('QR confirm with cash method posts exactly one drawer entry',
      () async {
    final qrId = await db.insertQrPayment(QrPayment(
        businessId: 1,
        payerName: 'Cash Payer',
        amount: 2500,
        method: 'cash',
        status: 'pending',
        dateTime: day));
    final q = (await db.getQrPayments(1)).firstWhere((e) => e.id == qrId);
    final bal = await db.getCashBalance(1);
    expect(await db.confirmQrPayment(q), isTrue);
    expect(await db.getCashBalance(1), bal + 2500);
    expect(await db.confirmQrPayment(q), isFalse);
    expect(await db.getCashBalance(1), bal + 2500);
  });
}
