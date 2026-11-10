import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';

/// Data-safety check: a database created by the OLD app (schema v1) must
/// upgrade to the current version with ZERO data loss — same parties, balances, stock, bills.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final helper = DatabaseHelper.instance;

  test('v1 database upgrades to v8 without losing data', () async {
    final path = '${await getDatabasesPath()}/namat_oil_mill.db';
    await databaseFactoryFfi.deleteDatabase(path);

    // --- Create a v1-era database with the OLD schema + real user data.
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (d, v) async {
          await d.execute('''CREATE TABLE businesses(
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, owner TEXT, phone TEXT, address TEXT)''');
          await d.execute('''CREATE TABLE parties(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, type TEXT, name TEXT,
            phone TEXT, address TEXT, opening_balance REAL DEFAULT 0, deleted INTEGER DEFAULT 0,
            created_at TEXT)''');
          await d.execute('''CREATE TABLE party_transactions(
            id INTEGER PRIMARY KEY AUTOINCREMENT, party_id INTEGER, type TEXT, amount REAL,
            note TEXT, date_time TEXT, attachment_path TEXT)''');
          await d.execute('''CREATE TABLE cash_entries(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, type TEXT, amount REAL,
            note TEXT, party_id INTEGER, date_time TEXT, attachment_path TEXT)''');
          await d.execute('''CREATE TABLE items(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, name TEXT, unit TEXT,
            opening_qty REAL DEFAULT 0, low_stock_limit REAL DEFAULT 0, deleted INTEGER DEFAULT 0)''');
          await d.execute('''CREATE TABLE stock_transactions(
            id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER, type TEXT, qty REAL, rate REAL,
            supplier_id INTEGER, bill_no TEXT, note TEXT, date_time TEXT, attachment_path TEXT)''');
          await d.execute('''CREATE TABLE bills(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, bill_no INTEGER, party_id INTEGER,
            party_name TEXT, total REAL, status TEXT, date_time TEXT, deleted INTEGER DEFAULT 0)''');
          await d.execute('''CREATE TABLE bill_items(
            id INTEGER PRIMARY KEY AUTOINCREMENT, bill_id INTEGER, item_id INTEGER, name TEXT,
            qty REAL, rate REAL, amount REAL)''');
          await d.execute('''CREATE TABLE staff(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, name TEXT, phone TEXT,
            monthly_salary REAL DEFAULT 0, deleted INTEGER DEFAULT 0)''');
          await d.execute('''CREATE TABLE attendance(
            id INTEGER PRIMARY KEY AUTOINCREMENT, staff_id INTEGER, date TEXT, status TEXT,
            overtime_hours REAL DEFAULT 0, UNIQUE(staff_id, date))''');
          await d.execute('''CREATE TABLE salary_payments(
            id INTEGER PRIMARY KEY AUTOINCREMENT, staff_id INTEGER, type TEXT, amount REAL,
            note TEXT, date_time TEXT)''');
          await d.execute('''CREATE TABLE bank_accounts(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, bank_name TEXT,
            account_title TEXT, account_no TEXT, opening_balance REAL DEFAULT 0, deleted INTEGER DEFAULT 0)''');
          await d.execute('''CREATE TABLE bank_transactions(
            id INTEGER PRIMARY KEY AUTOINCREMENT, bank_id INTEGER, type TEXT, amount REAL,
            note TEXT, date_time TEXT)''');
          await d.execute('''CREATE TABLE expenses(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, category TEXT, amount REAL,
            note TEXT, account TEXT, date_time TEXT)''');
          await d.execute('''CREATE TABLE wallet_transactions(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, channel TEXT, type TEXT,
            amount REAL, phone TEXT, note TEXT, commission REAL DEFAULT 0, date_time TEXT)''');
          await d.insert('businesses',
              {'name': 'Namat Oil Mill', 'owner': '', 'phone': '', 'address': ''});
        },
      ),
    );
    final partyId = await old.insert('parties', {
      'business_id': 1, 'type': 'customer', 'name': 'Purana Customer',
      'phone': '03001234567', 'address': '', 'opening_balance': 2000, 'deleted': 0,
    });
    await old.insert('party_transactions', {
      'party_id': partyId, 'type': 'udhaar', 'amount': 5000,
      'note': 'purana bill', 'date_time': '2026-10-01T10:00:00',
    });
    final itemId = await old.insert('items', {
      'business_id': 1, 'name': 'Sarson', 'unit': 'kg',
      'opening_qty': 100, 'low_stock_limit': 10, 'deleted': 0,
    });
    await old.insert('stock_transactions', {
      'item_id': itemId, 'type': 'in', 'qty': 400, 'rate': 100,
      'date_time': '2026-10-01T10:00:00',
    });
    final billId = await old.insert('bills', {
      'business_id': 1, 'bill_no': 1, 'party_id': partyId,
      'party_name': 'Purana Customer', 'total': 3000, 'status': 'pending',
      'date_time': '2026-10-02T10:00:00', 'deleted': 0,
    });
    await old.insert('bill_items', {
      'bill_id': billId, 'item_id': itemId, 'name': 'Sarson',
      'qty': 20, 'rate': 150, 'amount': 3000,
    });
    await old.close();

    // --- Open with the CURRENT app (v8): migration must keep everything.
    final d = await helper.db;
    expect(await d.getVersion(), 8);
    final party = await helper.getParty(partyId);
    expect(party, isNotNull);
    expect(party!.name, 'Purana Customer');
    expect(party.dueDate, isNull); // v6 column exists, empty for old rows
    // Balance = opening 2000 + udhaar 5000 (bill udhaar posting is a
    // party_transaction in real usage; here opening+txn only)
    expect(await helper.getPartyBalance(partyId), 7000);
    final item = (await helper.getItems(1)).single;
    expect(item.name, 'Sarson');
    expect(item.kind, 'general'); // new column defaults safely
    expect(await helper.getItemQty(itemId), 500); // 100 opening + 400 in
    // v7/v8 columns exist and default safely on old rows
    final oldTxn = await helper.getPartyTransactions(partyId);
    expect(oldTxn.single.method, 'cash'); // v7 default
    final bills = await helper.getBills(1);
    expect(bills.single.total, 3000);
    final oldBillItems = await helper.getBillItems(bills.single.id!);
    expect(oldBillItems.single.costAmount, isNull); // v8 snapshot: legacy = null
    // New tables exist and work after upgrade
    expect(await helper.getProductionBatches(1), isEmpty);
    expect(await helper.getQrPayments(1), isEmpty);
    // Backup covers every table, old + new
    final backup = await helper.exportJson();
    expect(backup.contains('Purana Customer'), isTrue);
    await helper.close();
  });
}
