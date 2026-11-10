import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/models.dart';

/// Single offline SQLite store for the whole app.
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  DatabaseHelper._();
  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'namat_oil_mill.db'),
      version: 7,
      onUpgrade: (d, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v2: track when a payment reminder was last sent to each party.
          await d.execute(
              'ALTER TABLE parties ADD COLUMN last_reminder_at TEXT');
        }
        if (oldVersion < 3) {
          // v3: product categories on stock items + QR payments table.
          await d.execute('ALTER TABLE items ADD COLUMN category TEXT');
          await d.execute('''CREATE TABLE IF NOT EXISTS qr_payments(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, party_id INTEGER,
            payer_name TEXT, amount REAL, method TEXT, status TEXT, note TEXT, date_time TEXT)''');
        }
        if (oldVersion < 4) {
          // v4: item kind (general/raw/finished) + production module tables.
          await d.execute('ALTER TABLE items ADD COLUMN kind TEXT');
          await d.execute('''CREATE TABLE IF NOT EXISTS production_batches(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, batch_no INTEGER,
            date_time TEXT, status TEXT, note TEXT, wastage_qty REAL DEFAULT 0, wastage_note TEXT)''');
          await d.execute('''CREATE TABLE IF NOT EXISTS production_inputs(
            id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id INTEGER, item_id INTEGER,
            qty REAL, rate REAL, cost REAL)''');
          await d.execute('''CREATE TABLE IF NOT EXISTS production_outputs(
            id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id INTEGER, item_id INTEGER,
            qty REAL, allocated_cost REAL, cost_per_unit REAL)''');
          await d.execute('''CREATE TABLE IF NOT EXISTS production_expenses(
            id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id INTEGER, category TEXT,
            amount REAL, note TEXT, date_time TEXT)''');
        }
        if (oldVersion < 5) {
          // v5: per-user data isolation — a business can be bound to one
          // app login username (Firebase app_users record).
          await d.execute(
              "ALTER TABLE businesses ADD COLUMN app_username TEXT DEFAULT ''");
        }
        if (oldVersion < 7) {
          // v7 (Phase 1 — cash accounting): payment method on ledger
          // entries, and source linkage on cash entries so every
          // automatic cash posting is traceable and can never duplicate
          // (UNIQUE index on (source_table, source_id)).
          await d.execute(
              "ALTER TABLE party_transactions ADD COLUMN method TEXT DEFAULT 'cash'");
          await d.execute(
              'ALTER TABLE cash_entries ADD COLUMN source_table TEXT');
          await d.execute(
              'ALTER TABLE cash_entries ADD COLUMN source_id INTEGER');
          await d.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_cash_source '
              'ON cash_entries(source_table, source_id) '
              'WHERE source_id IS NOT NULL');
        }
        if (oldVersion < 6) {
          // v6: optional payment due date on a party (the original app's
          // "Set Date" on the party screen).
          await d.execute('ALTER TABLE parties ADD COLUMN due_date TEXT');
        }
      },
      onCreate: (d, v) async {
        await d.execute('''CREATE TABLE businesses(
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, owner TEXT, phone TEXT, address TEXT, app_username TEXT DEFAULT '')''');
        await d.execute('''CREATE TABLE parties(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, type TEXT, name TEXT,
          phone TEXT, address TEXT, opening_balance REAL DEFAULT 0, deleted INTEGER DEFAULT 0,
          last_reminder_at TEXT, created_at TEXT, due_date TEXT)''');
        await d.execute('''CREATE TABLE party_transactions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, party_id INTEGER, type TEXT, amount REAL,
          note TEXT, date_time TEXT, attachment_path TEXT, method TEXT DEFAULT 'cash')''');
        await d.execute('''CREATE TABLE cash_entries(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, type TEXT, amount REAL,
          note TEXT, party_id INTEGER, date_time TEXT, attachment_path TEXT,
          source_table TEXT, source_id INTEGER)''');
        await d.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_cash_source '
            'ON cash_entries(source_table, source_id) '
            'WHERE source_id IS NOT NULL');
        await d.execute('''CREATE TABLE items(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, name TEXT, unit TEXT,
          opening_qty REAL DEFAULT 0, low_stock_limit REAL DEFAULT 0, deleted INTEGER DEFAULT 0,
          category TEXT, kind TEXT)''');
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
        await d.execute('''CREATE TABLE qr_payments(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, party_id INTEGER,
          payer_name TEXT, amount REAL, method TEXT, status TEXT, note TEXT, date_time TEXT)''');
        await d.execute('''CREATE TABLE production_batches(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, batch_no INTEGER,
          date_time TEXT, status TEXT, note TEXT, wastage_qty REAL DEFAULT 0, wastage_note TEXT)''');
        await d.execute('''CREATE TABLE production_inputs(
          id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id INTEGER, item_id INTEGER,
          qty REAL, rate REAL, cost REAL)''');
        await d.execute('''CREATE TABLE production_outputs(
          id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id INTEGER, item_id INTEGER,
          qty REAL, allocated_cost REAL, cost_per_unit REAL)''');
        await d.execute('''CREATE TABLE production_expenses(
          id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id INTEGER, category TEXT,
          amount REAL, note TEXT, date_time TEXT)''');
        // Default business so the app works out of the box.
        await d.insert('businesses', {
          'name': 'Namat Oil Mill', 'owner': '', 'phone': '', 'address': '',
        });
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ---------------- Businesses ----------------
  Future<List<Business>> getBusinesses() async {
    final d = await db;
    final rows = await d.query('businesses', orderBy: 'id');
    return rows.map(Business.fromMap).toList();
  }

  Future<int> insertBusiness(Business b) async =>
      (await db).insert('businesses', b.toMap());

  Future<void> updateBusiness(Business b) async =>
      (await db).update('businesses', b.toMap(), where: 'id = ?', whereArgs: [b.id]);

  // ---------------- Parties ----------------
  Future<List<Party>> getParties(int businessId, {String? type, bool deleted = false}) async {
    final d = await db;
    final rows = await d.query(
      'parties',
      where: 'business_id = ? AND deleted = ?' + (type != null ? ' AND type = ?' : ''),
      whereArgs: [businessId, deleted ? 1 : 0, if (type != null) type],
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(Party.fromMap).toList();
  }

  Future<Party?> getParty(int id) async {
    final d = await db;
    final rows = await d.query('parties', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Party.fromMap(rows.first);
  }

  Future<int> insertParty(Party party) async {
    final d = await db;
    final map = party.toMap();
    map['created_at'] = DateTime.now().toIso8601String();
    return d.insert('parties', map);
  }

  Future<void> updateParty(Party party) async =>
      (await db).update('parties', party.toMap(), where: 'id = ?', whereArgs: [party.id]);

  Future<void> setPartyDeleted(int id, bool deleted) async => (await db).update(
        'parties', {'deleted': deleted ? 1 : 0}, where: 'id = ?', whereArgs: [id]);

  Future<void> deletePartyForever(int id) async {
    final d = await db;
    await d.delete('party_transactions', where: 'party_id = ?', whereArgs: [id]);
    await d.delete('parties', where: 'id = ?', whereArgs: [id]);
  }

  Future<double> getPartyBalance(int partyId) async {
    final d = await db;
    final party = await getParty(partyId);
    if (party == null) return 0;
    final r = await d.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN type='udhaar' THEN amount ELSE -amount END),0) AS s "
      'FROM party_transactions WHERE party_id = ?',
      [partyId],
    );
    return party.openingBalance + (r.first['s'] as num).toDouble();
  }

  Future<List<PartyTransaction>> getPartyTransactions(int partyId) async {
    final d = await db;
    final rows = await d.query('party_transactions',
        where: 'party_id = ?', whereArgs: [partyId], orderBy: 'date_time DESC, id DESC');
    return rows.map(PartyTransaction.fromMap).toList();
  }

  Future<int> insertPartyTransaction(PartyTransaction t) async =>
      (await db).insert('party_transactions', t.toMap());

  // ---------------- Linked cash postings (Phase 1) ----------------
  // Automatic cash movements are written as cash_entries rows carrying
  // (source_table, source_id); the UNIQUE index on that pair makes a
  // duplicate posting impossible at the database level.

  Future<int?> _businessIdOfParty(Transaction txn, int partyId) async {
    final rows = await txn.query('parties',
        columns: ['business_id'], where: 'id = ?', whereArgs: [partyId]);
    if (rows.isEmpty) return null;
    return (rows.first['business_id'] as num?)?.toInt();
  }

  Future<int?> _businessIdOfStaff(Transaction txn, int staffId) async {
    final rows = await txn.query('staff',
        columns: ['business_id'], where: 'id = ?', whereArgs: [staffId]);
    if (rows.isEmpty) return null;
    return (rows.first['business_id'] as num?)?.toInt();
  }

  /// Inserts the cash-drawer twin of an automatic posting inside [txn].
  Future<void> _postLinkedCash(
    Transaction txn, {
    required int businessId,
    required String type,
    required double amount,
    required String note,
    int? partyId,
    required DateTime dateTime,
    String? attachmentPath,
    required String sourceTable,
    required int sourceId,
  }) async {
    await txn.insert('cash_entries', {
      'business_id': businessId,
      'type': type,
      'amount': amount,
      'note': note,
      'party_id': partyId,
      'date_time': dateTime.toIso8601String(),
      'attachment_path': attachmentPath,
      'source_table': sourceTable,
      'source_id': sourceId,
    });
  }

  Future<void> _deleteLinkedCash(
      Transaction txn, String sourceTable, int sourceId) async {
    await txn.delete('cash_entries',
        where: 'source_table = ? AND source_id = ?',
        whereArgs: [sourceTable, sourceId]);
  }

  /// Saves a MANUAL ledger entry from the party entry form. When the
  /// payment method is cash, the matching drawer movement is posted in
  /// the same transaction (wasool -> cash in, udhaar -> cash out);
  /// bank / JazzCash / Easypaisa entries never touch physical cash.
  /// Internal flows (bills, purchases, QR) keep using the raw
  /// [insertPartyTransaction] and manage their own cash explicitly.
  Future<int> insertLedgerEntry(PartyTransaction t) async {
    final d = await db;
    return d.transaction((txn) async {
      final id = await txn.insert('party_transactions', t.toMap());
      if (t.method == 'cash') {
        final biz = await _businessIdOfParty(txn, t.partyId);
        if (biz != null) {
          await _postLinkedCash(txn,
              businessId: biz,
              type: t.type == 'wasool' ? 'in' : 'out',
              amount: t.amount,
              note: t.note,
              partyId: t.partyId,
              dateTime: t.dateTime,
              attachmentPath: t.attachmentPath,
              sourceTable: 'party_transactions',
              sourceId: id);
        }
      }
      return id;
    });
  }

  Future<void> deletePartyTransaction(int id) async {
    final d = await db;
    await d.transaction((txn) async {
      await _deleteLinkedCash(txn, 'party_transactions', id);
      await txn.delete('party_transactions', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> updatePartyTransaction(PartyTransaction t) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.update('party_transactions', t.toMap(),
          where: 'id = ?', whereArgs: [t.id]);
      // Re-sync the linked drawer movement with the edited values.
      await _deleteLinkedCash(txn, 'party_transactions', t.id!);
      if (t.method == 'cash') {
        final biz = await _businessIdOfParty(txn, t.partyId);
        if (biz != null) {
          await _postLinkedCash(txn,
              businessId: biz,
              type: t.type == 'wasool' ? 'in' : 'out',
              amount: t.amount,
              note: t.note,
              partyId: t.partyId,
              dateTime: t.dateTime,
              attachmentPath: t.attachmentPath,
              sourceTable: 'party_transactions',
              sourceId: t.id!);
        }
      }
    });
  }

  /// Latest ledger activity per party (partyId -> newest entry time) for
  /// one business; parties with no entries are absent from the map.
  Future<Map<int, DateTime>> getPartyLastActivity(int businessId) async {
    final d = await db;
    final rows = await d.rawQuery(
      'SELECT t.party_id AS pid, MAX(t.date_time) AS last_at '
      'FROM party_transactions t JOIN parties p ON p.id = t.party_id '
      'WHERE p.business_id = ? GROUP BY t.party_id',
      [businessId],
    );
    return {
      for (final r in rows)
        (r['pid'] as num).toInt(): DateTime.parse(r['last_at'] as String),
    };
  }

  /// Total you will get (sum of positive balances) & you will give (negative).
  Future<({double willGet, double willGive})> getPartyTotals(int businessId, {String? type}) async {
    final parties = await getParties(businessId, type: type);
    double get = 0, give = 0;
    for (final party in parties) {
      final b = await getPartyBalance(party.id!);
      if (b > 0) {
        get += b;
      } else {
        give += -b;
      }
    }
    return (willGet: get, willGive: give);
  }

  /// Records that a payment reminder was just sent to this party.
  Future<void> markReminderSent(int partyId) async => (await db).update(
        'parties',
        {'last_reminder_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [partyId],
      );

  /// Parties due an automatic reminder: they owe money (balance > 0, the
  /// "you will get" sign), have a phone number, and were last reminded at
  /// least [intervalDays] ago (or never). Balance is computed per party via
  /// [getPartyBalance], same as the reminder screen's outstanding list.
  Future<List<Party>> getPartiesDueForReminder(int businessId,
      {int intervalDays = 5}) async {
    final parties = await getParties(businessId); // deleted = 0 only
    final cutoff = DateTime.now().subtract(Duration(days: intervalDays));
    final due = <Party>[];
    for (final party in parties) {
      if (party.id == null) continue;
      if (party.phone.trim().isEmpty) continue;
      final last = party.lastReminderAt;
      if (last != null && last.isAfter(cutoff)) continue;
      final bal = await getPartyBalance(party.id!);
      if (bal > 0) due.add(party);
    }
    return due;
  }

  // ---------------- Cash Book ----------------
  Future<List<CashEntry>> getCashEntries(int businessId) async {
    final d = await db;
    final rows = await d.query('cash_entries',
        where: 'business_id = ?', whereArgs: [businessId], orderBy: 'date_time DESC, id DESC');
    return rows.map(CashEntry.fromMap).toList();
  }

  Future<int> insertCashEntry(CashEntry e) async => (await db).insert('cash_entries', e.toMap());

  Future<void> deleteCashEntry(int id) async =>
      (await db).delete('cash_entries', where: 'id = ?', whereArgs: [id]);

  Future<double> getCashBalance(int businessId) async {
    final d = await db;
    final r = await d.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN type='in' THEN amount ELSE -amount END),0) AS s "
      'FROM cash_entries WHERE business_id = ?',
      [businessId],
    );
    return (r.first['s'] as num).toDouble();
  }

  // ---------------- Stock ----------------
  Future<List<StockItem>> getItems(int businessId, {bool deleted = false}) async {
    final d = await db;
    final rows = await d.query('items',
        where: 'business_id = ? AND deleted = ?',
        whereArgs: [businessId, deleted ? 1 : 0],
        orderBy: 'name COLLATE NOCASE');
    return rows.map(StockItem.fromMap).toList();
  }

  Future<int> insertItem(StockItem i) async => (await db).insert('items', i.toMap());

  Future<void> updateItem(StockItem i) async =>
      (await db).update('items', i.toMap(), where: 'id = ?', whereArgs: [i.id]);

  Future<void> setItemDeleted(int id, bool deleted) async => (await db).update(
        'items', {'deleted': deleted ? 1 : 0}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteItemForever(int id) async {
    final d = await db;
    await d.delete('stock_transactions', where: 'item_id = ?', whereArgs: [id]);
    await d.delete('items', where: 'id = ?', whereArgs: [id]);
  }

  Future<double> getItemQty(int itemId) async {
    final d = await db;
    final rows = await d.query('items', where: 'id = ?', whereArgs: [itemId]);
    if (rows.isEmpty) return 0;
    final opening = (rows.first['opening_qty'] as num).toDouble();
    final r = await d.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN type='in' THEN qty ELSE -qty END),0) AS s "
      'FROM stock_transactions WHERE item_id = ?',
      [itemId],
    );
    return opening + (r.first['s'] as num).toDouble();
  }

  Future<List<StockTransaction>> getStockTransactions(int itemId) async {
    final d = await db;
    final rows = await d.query('stock_transactions',
        where: 'item_id = ?', whereArgs: [itemId], orderBy: 'date_time DESC, id DESC');
    return rows.map(StockTransaction.fromMap).toList();
  }

  Future<int> insertStockTransaction(StockTransaction t) async =>
      (await db).insert('stock_transactions', t.toMap());

  Future<void> deleteStockTransaction(int id) async =>
      (await db).delete('stock_transactions', where: 'id = ?', whereArgs: [id]);

  // ---------------- Bills ----------------
  Future<List<Bill>> getBills(int businessId, {bool deleted = false}) async {
    final d = await db;
    final rows = await d.query('bills',
        where: 'business_id = ? AND deleted = ?',
        whereArgs: [businessId, deleted ? 1 : 0],
        orderBy: 'date_time DESC, id DESC');
    return rows.map(Bill.fromMap).toList();
  }

  Future<int> nextBillNo(int businessId) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COALESCE(MAX(bill_no),0) AS m FROM bills WHERE business_id = ?', [businessId]);
    return (r.first['m'] as num).toInt() + 1;
  }

  /// Creates a bill + its items, posts stock-out for stocked items, and (when a
  /// customer is selected) an udhaar entry on that customer's ledger. If the
  /// bill is marked paid, a matching cash-in entry is also posted.
  Future<int> createBill({
    required int businessId,
    required Bill bill,
    required List<BillItem> items,
  }) async {
    final d = await db;
    return d.transaction((txn) async {
      final billId = await txn.insert('bills', bill.toMap());
      for (final it in items) {
        await txn.insert('bill_items', {...it.toMap(), 'bill_id': billId});
        if (it.itemId != null) {
          await txn.insert('stock_transactions', {
            'item_id': it.itemId, 'type': 'out', 'qty': it.qty, 'rate': it.rate,
            'supplier_id': null, 'bill_no': bill.billNo.toString(),
            'note': 'Bill #${bill.billNo}', 'date_time': bill.dateTime.toIso8601String(),
            'attachment_path': null,
          });
        }
      }
      if (bill.partyId != null) {
        await txn.insert('party_transactions', {
          'party_id': bill.partyId, 'type': 'udhaar', 'amount': bill.total,
          'note': 'Bill #${bill.billNo}', 'date_time': bill.dateTime.toIso8601String(),
          'attachment_path': null,
        });
        if (bill.status == 'paid') {
          await txn.insert('party_transactions', {
            'party_id': bill.partyId, 'type': 'wasool', 'amount': bill.total,
            'note': 'Bill #${bill.billNo} payment', 'date_time': bill.dateTime.toIso8601String(),
            'attachment_path': null,
          });
        }
      }
      if (bill.status == 'paid') {
        await txn.insert('cash_entries', {
          'business_id': businessId, 'type': 'in', 'amount': bill.total,
          'note': 'Bill #${bill.billNo}', 'party_id': bill.partyId,
          'date_time': bill.dateTime.toIso8601String(), 'attachment_path': null,
        });
      }
      return billId;
    });
  }

  Future<List<BillItem>> getBillItems(int billId) async {
    final d = await db;
    final rows = await d.query('bill_items', where: 'bill_id = ?', whereArgs: [billId]);
    return rows.map(BillItem.fromMap).toList();
  }

  Future<void> setBillDeleted(int id, bool deleted) async => (await db).update(
        'bills', {'deleted': deleted ? 1 : 0}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteBillForever(int id) async {
    final d = await db;
    await d.delete('bill_items', where: 'bill_id = ?', whereArgs: [id]);
    await d.delete('bills', where: 'id = ?', whereArgs: [id]);
  }

  Future<double> getTotalSales(int businessId, {DateTime? month}) async {
    final d = await db;
    String where = 'business_id = ? AND deleted = 0';
    final args = <Object?>[businessId];
    if (month != null) {
      final start = DateTime(month.year, month.month).toIso8601String();
      final end = DateTime(month.year, month.month + 1).toIso8601String();
      where += ' AND date_time >= ? AND date_time < ?';
      args.addAll([start, end]);
    }
    final r = await d.rawQuery('SELECT COALESCE(SUM(total),0) AS s FROM bills WHERE $where', args);
    return (r.first['s'] as num).toDouble();
  }

  // ---------------- Staff ----------------
  Future<List<Staff>> getStaffList(int businessId, {bool deleted = false}) async {
    final d = await db;
    final rows = await d.query('staff',
        where: 'business_id = ? AND deleted = ?',
        whereArgs: [businessId, deleted ? 1 : 0],
        orderBy: 'name COLLATE NOCASE');
    return rows.map(Staff.fromMap).toList();
  }

  Future<int> insertStaff(Staff s) async => (await db).insert('staff', s.toMap());

  Future<void> updateStaff(Staff s) async =>
      (await db).update('staff', s.toMap(), where: 'id = ?', whereArgs: [s.id]);

  Future<void> setStaffDeleted(int id, bool deleted) async => (await db).update(
        'staff', {'deleted': deleted ? 1 : 0}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteStaffForever(int id) async {
    final d = await db;
    await d.delete('attendance', where: 'staff_id = ?', whereArgs: [id]);
    await d.delete('salary_payments', where: 'staff_id = ?', whereArgs: [id]);
    await d.delete('staff', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markAttendance(Attendance a) async {
    final d = await db;
    await d.insert('attendance', a.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Attendance>> getAttendance(int staffId, {String? monthPrefix}) async {
    final d = await db;
    final rows = await d.query('attendance',
        where: 'staff_id = ?' + (monthPrefix != null ? " AND date LIKE ?" : ''),
        whereArgs: [staffId, if (monthPrefix != null) '$monthPrefix%'],
        orderBy: 'date');
    return rows.map(Attendance.fromMap).toList();
  }

  Future<List<Attendance>> getAttendanceForDate(int businessId, String date) async {
    final d = await db;
    final rows = await d.rawQuery(
      'SELECT a.* FROM attendance a JOIN staff s ON s.id = a.staff_id '
      'WHERE s.business_id = ? AND a.date = ?',
      [businessId, date],
    );
    return rows.map(Attendance.fromMap).toList();
  }

  /// Inserts a salary/advance payment and posts the matching cash
  /// outflow in the same transaction — salary money always leaves the
  /// drawer, and the Staff Book was previously invisible to the cash
  /// book (audit Phase 1).
  Future<int> insertSalaryPayment(SalaryPayment p) async {
    final d = await db;
    return d.transaction((txn) async {
      final id = await txn.insert('salary_payments', p.toMap());
      final biz = await _businessIdOfStaff(txn, p.staffId);
      if (biz != null) {
        await _postLinkedCash(txn,
            businessId: biz,
            type: 'out',
            amount: p.amount,
            note: p.note.isNotEmpty ? p.note : 'Salary',
            dateTime: p.dateTime,
            sourceTable: 'salary_payments',
            sourceId: id);
      }
      return id;
    });
  }

  Future<List<SalaryPayment>> getSalaryPayments(int staffId) async {
    final d = await db;
    final rows = await d.query('salary_payments',
        where: 'staff_id = ?', whereArgs: [staffId], orderBy: 'date_time DESC, id DESC');
    return rows.map(SalaryPayment.fromMap).toList();
  }

  Future<double> getStaffPaidTotal(int staffId) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS s FROM salary_payments WHERE staff_id = ?', [staffId]);
    return (r.first['s'] as num).toDouble();
  }

  // ---------------- Banks ----------------
  Future<List<BankAccount>> getBankAccounts(int businessId, {bool deleted = false}) async {
    final d = await db;
    final rows = await d.query('bank_accounts',
        where: 'business_id = ? AND deleted = ?',
        whereArgs: [businessId, deleted ? 1 : 0],
        orderBy: 'bank_name COLLATE NOCASE');
    return rows.map(BankAccount.fromMap).toList();
  }

  Future<int> insertBankAccount(BankAccount b) async =>
      (await db).insert('bank_accounts', b.toMap());

  Future<void> updateBankAccount(BankAccount b) async =>
      (await db).update('bank_accounts', b.toMap(), where: 'id = ?', whereArgs: [b.id]);

  Future<void> setBankDeleted(int id, bool deleted) async => (await db).update(
        'bank_accounts', {'deleted': deleted ? 1 : 0}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteBankForever(int id) async {
    final d = await db;
    await d.delete('bank_transactions', where: 'bank_id = ?', whereArgs: [id]);
    await d.delete('bank_accounts', where: 'id = ?', whereArgs: [id]);
  }

  Future<double> getBankBalance(int bankId) async {
    final d = await db;
    final rows = await d.query('bank_accounts', where: 'id = ?', whereArgs: [bankId]);
    if (rows.isEmpty) return 0;
    final opening = (rows.first['opening_balance'] as num).toDouble();
    final r = await d.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN type='in' THEN amount ELSE -amount END),0) AS s "
      'FROM bank_transactions WHERE bank_id = ?',
      [bankId],
    );
    return opening + (r.first['s'] as num).toDouble();
  }

  Future<List<BankTransaction>> getBankTransactions(int bankId) async {
    final d = await db;
    final rows = await d.query('bank_transactions',
        where: 'bank_id = ?', whereArgs: [bankId], orderBy: 'date_time DESC, id DESC');
    return rows.map(BankTransaction.fromMap).toList();
  }

  Future<int> insertBankTransaction(BankTransaction t) async =>
      (await db).insert('bank_transactions', t.toMap());

  Future<void> deleteBankTransaction(int id) async =>
      (await db).delete('bank_transactions', where: 'id = ?', whereArgs: [id]);

  // ---------------- Expenses ----------------
  Future<List<Expense>> getExpenses(int businessId) async {
    final d = await db;
    final rows = await d.query('expenses',
        where: 'business_id = ?', whereArgs: [businessId], orderBy: 'date_time DESC, id DESC');
    return rows.map(Expense.fromMap).toList();
  }

  /// Inserts an expense; a CASH expense also posts its drawer outflow
  /// in the same transaction (bank expenses never touch the drawer).
  Future<int> insertExpense(Expense e) async {
    final d = await db;
    return d.transaction((txn) async {
      final id = await txn.insert('expenses', e.toMap());
      if (e.account == 'cash') {
        await _postLinkedCash(txn,
            businessId: e.businessId,
            type: 'out',
            amount: e.amount,
            note: e.note.isNotEmpty ? e.note : e.category,
            dateTime: e.dateTime,
            sourceTable: 'expenses',
            sourceId: id);
      }
      return id;
    });
  }

  Future<void> updateExpense(Expense e) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.update('expenses', e.toMap(), where: 'id = ?', whereArgs: [e.id]);
      await _deleteLinkedCash(txn, 'expenses', e.id!);
      if (e.account == 'cash') {
        await _postLinkedCash(txn,
            businessId: e.businessId,
            type: 'out',
            amount: e.amount,
            note: e.note.isNotEmpty ? e.note : e.category,
            dateTime: e.dateTime,
            sourceTable: 'expenses',
            sourceId: e.id!);
      }
    });
  }

  Future<void> deleteExpense(int id) async {
    final d = await db;
    await d.transaction((txn) async {
      await _deleteLinkedCash(txn, 'expenses', id);
      await txn.delete('expenses', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<double> getExpenseTotal(int businessId, {DateTime? month}) async {
    final d = await db;
    String where = 'business_id = ?';
    final args = <Object?>[businessId];
    if (month != null) {
      final start = DateTime(month.year, month.month).toIso8601String();
      final end = DateTime(month.year, month.month + 1).toIso8601String();
      where += ' AND date_time >= ? AND date_time < ?';
      args.addAll([start, end]);
    }
    final r = await d.rawQuery('SELECT COALESCE(SUM(amount),0) AS s FROM expenses WHERE $where', args);
    return (r.first['s'] as num).toDouble();
  }

  Future<Map<String, double>> getExpenseByCategory(int businessId) async {
    final d = await db;
    final r = await d.rawQuery(
      'SELECT category, COALESCE(SUM(amount),0) AS s FROM expenses WHERE business_id = ? GROUP BY category',
      [businessId],
    );
    return {for (final row in r) (row['category'] as String? ?? ''): (row['s'] as num).toDouble()};
  }

  // ---------------- DigiCash wallet ----------------
  Future<List<WalletTransaction>> getWalletTransactions(int businessId) async {
    final d = await db;
    final rows = await d.query('wallet_transactions',
        where: 'business_id = ?', whereArgs: [businessId], orderBy: 'date_time DESC, id DESC');
    return rows.map(WalletTransaction.fromMap).toList();
  }

  Future<int> insertWalletTransaction(WalletTransaction t) async =>
      (await db).insert('wallet_transactions', t.toMap());

  Future<void> deleteWalletTransaction(int id) async =>
      (await db).delete('wallet_transactions', where: 'id = ?', whereArgs: [id]);

  /// Balance per channel: 'in' adds, 'out'/'send'/'recharge' subtract.
  /// 'request' rows are promises, not movements, so they are excluded.
  /// NOTE: the stored commission is intentionally NOT part of the balance —
  /// it is ambiguous whether a recharge commission should be credited back
  /// to the channel or kept as separate earnings, so it is only recorded
  /// on the transaction for reporting until that is decided.
  Future<double> getWalletBalance(int businessId, String channel) async {
    final d = await db;
    final r = await d.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN type='in' THEN amount ELSE -amount END),0) AS s "
      'FROM wallet_transactions WHERE business_id = ? AND channel = ? AND type != ?',
      [businessId, channel, 'request'],
    );
    return (r.first['s'] as num).toDouble();
  }

  // ---------------- QR Payments ----------------
  Future<int> insertQrPayment(QrPayment q) async =>
      (await db).insert('qr_payments', q.toMap());

  Future<List<QrPayment>> getQrPayments(int businessId) async {
    final d = await db;
    final rows = await d.query('qr_payments',
        where: 'business_id = ?', whereArgs: [businessId], orderBy: 'date_time DESC');
    return rows.map(QrPayment.fromMap).toList();
  }

  /// Confirms a QR payment EXACTLY ONCE, in a single transaction:
  /// flips the status, posts the party wasool (tagged with the real
  /// payment method), and posts the drawer entry ONLY when the money
  /// actually arrived as cash — a JazzCash/Easypaisa/bank receipt is
  /// not physical cash (audit Phase 1). Returns false when the payment
  /// was already confirmed, so a double tap can never double-post.
  Future<bool> confirmQrPayment(QrPayment q) async {
    final d = await db;
    return d.transaction((txn) async {
      final rows = await txn.query('qr_payments',
          columns: ['status'], where: 'id = ?', whereArgs: [q.id]);
      if (rows.isEmpty || rows.first['status'] == 'confirmed') return false;
      await txn.update('qr_payments', {'status': 'confirmed'},
          where: 'id = ?', whereArgs: [q.id]);
      if (q.partyId != null) {
        await txn.insert(
            'party_transactions',
            PartyTransaction(
              partyId: q.partyId!,
              type: 'wasool',
              amount: q.amount,
              note: 'QR payment',
              dateTime: q.dateTime,
              method: q.method,
            ).toMap());
      }
      if (q.method == 'cash') {
        await _postLinkedCash(txn,
            businessId: q.businessId,
            type: 'in',
            amount: q.amount,
            note:
                'QR payment${q.payerName.isNotEmpty ? ' — ${q.payerName}' : ''}',
            partyId: q.partyId,
            dateTime: q.dateTime,
            sourceTable: 'qr_payments',
            sourceId: q.id!);
      }
      return true;
    });
  }

  Future<void> updateQrPaymentStatus(int id, String status) async =>
      (await db).update('qr_payments', {'status': status},
          where: 'id = ?', whereArgs: [id]);

  Future<void> deleteQrPayment(int id) async =>
      (await db).delete('qr_payments', where: 'id = ?', whereArgs: [id]);

  // ---------------- Production & Manufacturing ----------------
  /// Weighted-average purchase cost of an item: total value of all
  /// stock-IN transactions divided by their total quantity. Falls back to
  /// the latest transaction rate, then 0. This is THE costing method for
  /// the whole app (purchases -> consumption -> COGS), used consistently.
  Future<double> getItemAvgCost(int itemId) async {
    final d = await db;
    final r = await d.rawQuery(
      "SELECT COALESCE(SUM(qty * rate), 0) AS v, COALESCE(SUM(qty), 0) AS q "
      "FROM stock_transactions WHERE item_id = ? AND type = 'in' AND rate > 0",
      [itemId],
    );
    final q = (r.first['q'] as num).toDouble();
    if (q > 0) return (r.first['v'] as num).toDouble() / q;
    final txns = await getStockTransactions(itemId);
    for (final t in txns) {
      if (t.rate > 0) return t.rate;
    }
    return 0;
  }

  /// Average production cost per unit of a finished item, from the cost
  /// allocations of all completed (non-cancelled) batches that produced it.
  Future<double> getItemProductionAvgCost(int itemId) async {
    final d = await db;
    final r = await d.rawQuery(
      'SELECT COALESCE(SUM(o.allocated_cost), 0) AS v, COALESCE(SUM(o.qty), 0) AS q '
      'FROM production_outputs o JOIN production_batches b ON b.id = o.batch_id '
      "WHERE o.item_id = ? AND b.status = 'completed'",
      [itemId],
    );
    final q = (r.first['q'] as num).toDouble();
    if (q > 0) return (r.first['v'] as num).toDouble() / q;
    return 0;
  }

  /// The unit cost used for COGS / valuation of an item: production cost
  /// for manufactured goods, weighted-average purchase cost otherwise.
  Future<double> getItemUnitCost(int itemId) async {
    final produced = await getItemProductionAvgCost(itemId);
    if (produced > 0) return produced;
    return getItemAvgCost(itemId);
  }

  Future<int> getNextBatchNo(int businessId) async {
    final d = await db;
    final r = await d.rawQuery(
      'SELECT COALESCE(MAX(batch_no), 0) AS m FROM production_batches WHERE business_id = ?',
      [businessId],
    );
    return (r.first['m'] as num).toInt() + 1;
  }

  /// Creates a production batch in ONE transaction:
  /// validates raw stock (unless [allowNegative]), snapshots each input's
  /// weighted-average cost, posts stock-OUT for inputs and stock-IN for
  /// outputs into the EXISTING stock book, allocates the total batch cost
  /// (materials + expenses) across outputs by output quantity, and stores
  /// the expense lines. Throws StateError('INSUFFICIENT:<item name>') when
  /// a raw material is short and negative stock is not allowed.
  Future<int> createProductionBatch({
    required ProductionBatch batch,
    required List<({int itemId, double qty})> inputs,
    required List<({int itemId, double qty})> outputs,
    required List<ProductionExpense> expenses,
    bool allowNegative = false,
  }) async {
    final d = await db;
    return d.transaction((txn) async {
      Future<double> qtyOf(int itemId) async {
        final rows = await txn.query('items', where: 'id = ?', whereArgs: [itemId]);
        if (rows.isEmpty) return 0;
        final opening = (rows.first['opening_qty'] as num).toDouble();
        final r = await txn.rawQuery(
          "SELECT COALESCE(SUM(CASE WHEN type='in' THEN qty ELSE -qty END),0) AS s "
          'FROM stock_transactions WHERE item_id = ?',
          [itemId],
        );
        return opening + (r.first['s'] as num).toDouble();
      }

      Future<double> wacOf(int itemId) async {
        final r = await txn.rawQuery(
          "SELECT COALESCE(SUM(qty * rate), 0) AS v, COALESCE(SUM(qty), 0) AS q "
          "FROM stock_transactions WHERE item_id = ? AND type = 'in' AND rate > 0",
          [itemId],
        );
        final q = (r.first['q'] as num).toDouble();
        if (q > 0) return (r.first['v'] as num).toDouble() / q;
        final rows = await txn.query('stock_transactions',
            where: 'item_id = ?', whereArgs: [itemId],
            orderBy: 'date_time DESC, id DESC');
        for (final row in rows) {
          final rate = (row['rate'] as num).toDouble();
          if (rate > 0) return rate;
        }
        return 0;
      }

      Future<String> nameOf(int itemId) async {
        final rows = await txn.query('items', where: 'id = ?', whereArgs: [itemId]);
        return rows.isEmpty ? '#$itemId' : (rows.first['name'] as String? ?? '#$itemId');
      }

      final totalOutQty = outputs.fold<double>(0, (s, o) => s + o.qty);
      if (inputs.isEmpty) throw StateError('NO_INPUTS');
      if (totalOutQty <= 0) throw StateError('NO_OUTPUT');

      final batchId = await txn.insert('production_batches', batch.toMap());
      final stamp = batch.dateTime.toIso8601String();
      var materialCost = 0.0;
      for (final inp in inputs) {
        if (inp.qty <= 0) continue;
        if (!allowNegative) {
          final available = await qtyOf(inp.itemId);
          if (inp.qty > available + 1e-9) {
            throw StateError('INSUFFICIENT:${await nameOf(inp.itemId)}');
          }
        }
        final rate = await wacOf(inp.itemId);
        final cost = inp.qty * rate;
        materialCost += cost;
        await txn.insert('production_inputs', {
          'batch_id': batchId, 'item_id': inp.itemId,
          'qty': inp.qty, 'rate': rate, 'cost': cost,
        });
        await txn.insert('stock_transactions', {
          'item_id': inp.itemId, 'type': 'out', 'qty': inp.qty, 'rate': rate,
          'supplier_id': null, 'bill_no': '',
          'note': 'Production batch #${batch.batchNo}',
          'date_time': stamp, 'attachment_path': null,
        });
      }
      var expenseCost = 0.0;
      for (final e in expenses) {
        if (e.amount <= 0) continue;
        expenseCost += e.amount;
        await txn.insert('production_expenses', {
          'batch_id': batchId, 'category': e.category, 'amount': e.amount,
          'note': e.note, 'date_time': stamp,
        });
      }
      final totalCost = materialCost + expenseCost;
      for (final out in outputs) {
        if (out.qty <= 0) continue;
        final allocated = totalCost * (out.qty / totalOutQty);
        final perUnit = allocated / out.qty;
        await txn.insert('production_outputs', {
          'batch_id': batchId, 'item_id': out.itemId, 'qty': out.qty,
          'allocated_cost': allocated, 'cost_per_unit': perUnit,
        });
        await txn.insert('stock_transactions', {
          'item_id': out.itemId, 'type': 'in', 'qty': out.qty, 'rate': perUnit,
          'supplier_id': null, 'bill_no': '',
          'note': 'Production batch #${batch.batchNo}',
          'date_time': stamp, 'attachment_path': null,
        });
      }
      return batchId;
    });
  }

  /// Cancels a batch and reverses its stock postings (inputs go back IN,
  /// outputs come back OUT) in one transaction. The batch and its lines
  /// stay in the database for audit; reports exclude cancelled batches.
  Future<void> cancelProductionBatch(int batchId) async {
    final d = await db;
    await d.transaction((txn) async {
      final rows = await txn.query('production_batches',
          where: 'id = ?', whereArgs: [batchId]);
      if (rows.isEmpty) return;
      final batch = ProductionBatch.fromMap(rows.first);
      if (batch.status == 'cancelled') return;
      final stamp = DateTime.now().toIso8601String();
      final note = 'Batch #${batch.batchNo} cancelled';
      final ins = await txn.query('production_inputs',
          where: 'batch_id = ?', whereArgs: [batchId]);
      for (final r in ins) {
        await txn.insert('stock_transactions', {
          'item_id': r['item_id'], 'type': 'in', 'qty': r['qty'],
          'rate': r['rate'], 'supplier_id': null, 'bill_no': '',
          'note': note, 'date_time': stamp, 'attachment_path': null,
        });
      }
      final outs = await txn.query('production_outputs',
          where: 'batch_id = ?', whereArgs: [batchId]);
      for (final r in outs) {
        await txn.insert('stock_transactions', {
          'item_id': r['item_id'], 'type': 'out', 'qty': r['qty'],
          'rate': r['cost_per_unit'], 'supplier_id': null, 'bill_no': '',
          'note': note, 'date_time': stamp, 'attachment_path': null,
        });
      }
      await txn.update('production_batches', {'status': 'cancelled'},
          where: 'id = ?', whereArgs: [batchId]);
    });
  }

  Future<List<ProductionBatch>> getProductionBatches(int businessId) async {
    final d = await db;
    final rows = await d.query('production_batches',
        where: 'business_id = ?', whereArgs: [businessId],
        orderBy: 'date_time DESC, id DESC');
    return rows.map(ProductionBatch.fromMap).toList();
  }

  Future<List<ProductionInput>> getBatchInputs(int batchId) async {
    final d = await db;
    final rows = await d.query('production_inputs',
        where: 'batch_id = ?', whereArgs: [batchId], orderBy: 'id');
    return rows.map(ProductionInput.fromMap).toList();
  }

  Future<List<ProductionOutput>> getBatchOutputs(int batchId) async {
    final d = await db;
    final rows = await d.query('production_outputs',
        where: 'batch_id = ?', whereArgs: [batchId], orderBy: 'id');
    return rows.map(ProductionOutput.fromMap).toList();
  }

  Future<List<ProductionExpense>> getBatchExpenses(int batchId) async {
    final d = await db;
    final rows = await d.query('production_expenses',
        where: 'batch_id = ?', whereArgs: [batchId], orderBy: 'id');
    return rows.map(ProductionExpense.fromMap).toList();
  }

  /// All production expenses of completed batches of a business, newest
  /// first (cancelled batches excluded so nothing is double-counted).
  Future<List<ProductionExpense>> getAllProductionExpenses(int businessId) async {
    final d = await db;
    final rows = await d.rawQuery(
      'SELECT e.* FROM production_expenses e '
      'JOIN production_batches b ON b.id = e.batch_id '
      "WHERE b.business_id = ? AND b.status = 'completed' "
      'ORDER BY e.date_time DESC, e.id DESC',
      [businessId],
    );
    return rows.map(ProductionExpense.fromMap).toList();
  }

  /// Total quantity of an item sold through bills (non-deleted bills).
  Future<double> getItemSoldQty(int itemId) async {
    final d = await db;
    final r = await d.rawQuery(
      'SELECT COALESCE(SUM(bi.qty), 0) AS s FROM bill_items bi '
      'JOIN bills b ON b.id = bi.bill_id '
      'WHERE bi.item_id = ? AND b.deleted = 0',
      [itemId],
    );
    return (r.first['s'] as num).toDouble();
  }

  // ---------------- Backup / Restore ----------------
  static const List<String> allTables = [
    'businesses', 'parties', 'party_transactions', 'cash_entries', 'items',
    'stock_transactions', 'bills', 'bill_items', 'staff', 'attendance',
    'salary_payments', 'bank_accounts', 'bank_transactions', 'expenses',
    'wallet_transactions', 'qr_payments', 'production_batches',
    'production_inputs', 'production_outputs', 'production_expenses',
  ];

  Future<String> exportJson() async {
    final d = await db;
    final out = <String, dynamic>{'app': 'namat_oil_mill', 'version': 1};
    for (final t in allTables) {
      out[t] = await d.query(t);
    }
    return jsonEncode(out);
  }

  Future<void> importJson(String source) async {
    final data = jsonDecode(source) as Map<String, dynamic>;
    if (data['app'] != 'namat_oil_mill') {
      throw const FormatException('Not a Namat Oil Mill backup file');
    }
    final d = await db;
    await d.transaction((txn) async {
      for (final t in allTables.reversed) {
        await txn.delete(t);
      }
      for (final t in allTables) {
        final rows = (data[t] as List?) ?? [];
        for (final row in rows) {
          await txn.insert(
            t,
            Map<String, dynamic>.from(row as Map),
            // attendance has UNIQUE(staff_id, date): a backup containing a
            // duplicate day must not abort the whole restore.
            conflictAlgorithm:
                t == 'attendance' ? ConflictAlgorithm.replace : null,
          );
        }
      }
    });
  }

  // ---------------- Per-user (Firebase) data sync ----------------
  static const _bizTables = [
    'parties', 'cash_entries', 'items', 'bills', 'staff', 'bank_accounts',
    'expenses', 'wallet_transactions', 'qr_payments', 'production_batches',
  ];
  static const _childTables = <String, String>{
    'party_transactions': 'parties',
    'stock_transactions': 'items',
    'bill_items': 'bills',
    'attendance': 'staff',
    'salary_payments': 'staff',
    'bank_transactions': 'bank_accounts',
    'production_inputs': 'production_batches',
    'production_outputs': 'production_batches',
    'production_expenses': 'production_batches',
  };
  static String _fkOf(String child) => switch (child) {
        'party_transactions' => 'party_id',
        'stock_transactions' => 'item_id',
        'bill_items' => 'bill_id',
        'attendance' || 'salary_payments' => 'staff_id',
        'bank_transactions' => 'bank_id',
        _ => 'batch_id',
      };

  /// Cross-references that are NOT the scoping parent FK but still point
  /// at another table's row (rewritten on import like the parent FKs).
  static const _secondaryRefs = <String, Map<String, String>>{
    'cash_entries': {'party_id': 'parties'},
    'bills': {'party_id': 'parties'},
    'qr_payments': {'party_id': 'parties'},
    'stock_transactions': {'supplier_id': 'parties'},
    'bill_items': {'item_id': 'items'},
    'production_inputs': {'item_id': 'items'},
    'production_outputs': {'item_id': 'items'},
  };

  /// Total data rows owned by one business (parent tables only — enough
  /// to tell "this business has data" from "this business is empty").
  Future<int> businessRowCount(int bizId) async {
    final d = await db;
    var total = 0;
    for (final t in _bizTables) {
      final r = await d.rawQuery(
          'SELECT COUNT(*) AS c FROM $t WHERE business_id = ?', [bizId]);
      total += (r.first['c'] as int?) ?? 0;
    }
    return total;
  }

  /// All data belonging to ONE business, as a JSON-safe map
  /// (same shape as [exportJson] but business-scoped).
  Future<Map<String, dynamic>> exportBusinessData(int bizId) async {
    final d = await db;
    final out = <String, dynamic>{'app': 'namat_oil_mill', 'version': 1};
    out['businesses'] =
        await d.query('businesses', where: 'id = ?', whereArgs: [bizId]);
    final parentIds = <String, List<int>>{};
    for (final t in _bizTables) {
      final rows =
          await d.query(t, where: 'business_id = ?', whereArgs: [bizId]);
      out[t] = rows;
      parentIds[t] = rows.map((r) => r['id'] as int).toList();
    }
    for (final e in _childTables.entries) {
      final ids = parentIds[e.value] ?? const [];
      if (ids.isEmpty) {
        out[e.key] = const [];
      } else {
        final marks = List.filled(ids.length, '?').join(',');
        out[e.key] = await d.query(e.key,
            where: '${_fkOf(e.key)} IN ($marks)', whereArgs: ids);
      }
    }
    return out;
  }

  /// Replaces ALL local data of business [bizId] with [data] (from
  /// [exportBusinessData] of the same user's business, possibly on
  /// ANOTHER device). Other businesses on this device are untouched.
  ///
  /// Cross-device safety: every row is re-scoped to [bizId]. A row keeps
  /// its original id only when that id is still free in its table;
  /// otherwise it gets a fresh id and every reference to it (child FKs
  /// and cross-references) is rewritten to the new id. Without this, a
  /// restore onto a phone that already holds another user's rows would
  /// silently drop colliding rows or attach them to the wrong business.
  Future<void> importBusinessData(int bizId, Map<String, dynamic> data) async {
    if (data['app'] != 'namat_oil_mill') {
      throw const FormatException('Not a Namat Oil Mill backup');
    }
    final d = await db;
    await d.transaction((txn) async {
      // Collect current scoped parent ids, then delete children first.
      final parentIds = <String, List<int>>{};
      for (final t in _bizTables) {
        final rows = await txn.query(t,
            columns: ['id'], where: 'business_id = ?', whereArgs: [bizId]);
        parentIds[t] = rows.map((r) => r['id'] as int).toList();
      }
      for (final e in _childTables.entries) {
        final ids = parentIds[e.value] ?? const [];
        if (ids.isNotEmpty) {
          final marks = List.filled(ids.length, '?').join(',');
          await txn.delete(e.key,
              where: '${_fkOf(e.key)} IN ($marks)', whereArgs: ids);
        }
      }
      for (final t in _bizTables) {
        await txn.delete(t, where: 'business_id = ?', whereArgs: [bizId]);
      }

      Future<bool> idTaken(String table, int id) async {
        final r = await txn.query(table,
            columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
        return r.isNotEmpty;
      }

      void remapRefs(Map<String, dynamic> row, String table,
          Map<String, Map<int, int>> idMaps) {
        final refs = _secondaryRefs[table];
        if (refs == null) return;
        refs.forEach((column, refTable) {
          final v = row[column];
          if (v is int) {
            // Unknown reference -> null, never point at another
            // business's row by accident.
            row[column] = idMaps[refTable]?[v];
          }
        });
      }

      // Parents first (their id maps drive every reference rewrite).
      final idMaps = <String, Map<int, int>>{};
      for (final t in _bizTables) {
        final rows = (data[t] as List?) ?? const [];
        final map = <int, int>{};
        for (final raw in rows) {
          final row = Map<String, dynamic>.from(raw as Map);
          final oldId = row['id'] as int?;
          row['business_id'] = bizId;
          remapRefs(row, t, idMaps);
          if (oldId != null && !await idTaken(t, oldId)) {
            await txn.insert(t, row);
            map[oldId] = oldId;
          } else {
            row.remove('id');
            final newId = await txn.insert(t, row);
            if (oldId != null) map[oldId] = newId;
          }
        }
        idMaps[t] = map;
      }
      // Children: parent FK + cross-references rewritten via the maps.
      for (final e in _childTables.entries) {
        final rows = (data[e.key] as List?) ?? const [];
        final fk = _fkOf(e.key);
        final parentMap = idMaps[e.value] ?? const <int, int>{};
        for (final raw in rows) {
          final row = Map<String, dynamic>.from(raw as Map);
          final oldFk = row[fk] as int?;
          final newFk = oldFk == null ? null : parentMap[oldFk];
          if (newFk == null) continue; // parent not in backup: skip orphan
          row[fk] = newFk;
          remapRefs(row, e.key, idMaps);
          final oldId = row['id'] as int?;
          if (oldId == null || await idTaken(e.key, oldId)) {
            row.remove('id');
          }
          await txn.insert(e.key, row,
              conflictAlgorithm: e.key == 'attendance'
                  ? ConflictAlgorithm.replace
                  : ConflictAlgorithm.ignore);
        }
      }
      // Refresh the business profile itself (never its id / binding).
      final bizRows = (data['businesses'] as List?) ?? const [];
      if (bizRows.isNotEmpty) {
        final b = Map<String, dynamic>.from(bizRows.first as Map)
          ..remove('id')
          ..remove('app_username');
        await txn.update('businesses', b, where: 'id = ?', whereArgs: [bizId]);
      }
    });
  }

  Future<Business?> getBusinessByUsername(String username) async {
    final d = await db;
    final rows = await d.query('businesses',
        where: 'app_username = ?', whereArgs: [username], limit: 1);
    return rows.isEmpty ? null : Business.fromMap(rows.first);
  }
}
