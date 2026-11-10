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
      version: 11,
      onUpgrade: (d, oldVersion, newVersion) async {
        if (oldVersion < 11) {
          // Phase 5 audit fix: a bill paid via bank/JazzCash/Easypaisa
          // must not post physical drawer cash — the payment method
          // now lives on the bill itself.
          await d.execute(
              "ALTER TABLE bills ADD COLUMN method TEXT DEFAULT 'cash'");
        }
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
        if (oldVersion < 10) {
          // v10 (Phase 4 — daily accounting): frozen daily closings,
          // expense classification, expected batch recovery.
          await d.execute('''CREATE TABLE IF NOT EXISTS daily_closings(
            id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, date TEXT,
            opening REAL, total_in REAL, total_out REAL, closing REAL,
            frozen_at TEXT, UNIQUE(business_id, date))''');
          await d.execute(
              "ALTER TABLE expenses ADD COLUMN kind TEXT DEFAULT 'operating'");
          await d.execute(
              'ALTER TABLE production_batches ADD COLUMN expected_recovery_pct REAL');
        }
        if (oldVersion < 9) {
          // v9 (Phase 3 — transaction integrity): every bill posting
          // carries its bill_id so a bill can be reversed exactly.
          await d.execute(
              'ALTER TABLE stock_transactions ADD COLUMN bill_id INTEGER');
          await d.execute(
              'ALTER TABLE party_transactions ADD COLUMN bill_id INTEGER');
        }
        if (oldVersion < 8) {
          // v8 (Phase 2 — inventory & COGS): sale-time cost snapshot on
          // bill lines, joint-cost allocation method on batches, and
          // density (kg per litre) on items.
          await d.execute('ALTER TABLE bill_items ADD COLUMN cost_rate REAL');
          await d.execute('ALTER TABLE bill_items ADD COLUMN cost_amount REAL');
          await d.execute(
              "ALTER TABLE production_batches ADD COLUMN allocation_method TEXT DEFAULT 'quantity'");
          await d.execute('ALTER TABLE items ADD COLUMN density REAL');
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
          note TEXT, date_time TEXT, attachment_path TEXT, method TEXT DEFAULT 'cash', bill_id INTEGER)''');
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
          category TEXT, kind TEXT, density REAL)''');
        await d.execute('''CREATE TABLE stock_transactions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER, type TEXT, qty REAL, rate REAL,
          supplier_id INTEGER, bill_no TEXT, note TEXT, date_time TEXT, attachment_path TEXT, bill_id INTEGER)''');
        await d.execute('''CREATE TABLE bills(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, bill_no INTEGER, party_id INTEGER,
          party_name TEXT, total REAL, status TEXT, date_time TEXT, deleted INTEGER DEFAULT 0, method TEXT DEFAULT 'cash')''');
        await d.execute('''CREATE TABLE bill_items(
          id INTEGER PRIMARY KEY AUTOINCREMENT, bill_id INTEGER, item_id INTEGER, name TEXT,
          qty REAL, rate REAL, amount REAL, cost_rate REAL, cost_amount REAL)''');
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
          note TEXT, account TEXT, date_time TEXT, kind TEXT DEFAULT 'operating')''');
        await d.execute('''CREATE TABLE wallet_transactions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, channel TEXT, type TEXT,
          amount REAL, phone TEXT, note TEXT, commission REAL DEFAULT 0, date_time TEXT)''');
        await d.execute('''CREATE TABLE qr_payments(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, party_id INTEGER,
          payer_name TEXT, amount REAL, method TEXT, status TEXT, note TEXT, date_time TEXT)''');
        await d.execute('''CREATE TABLE production_batches(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, batch_no INTEGER,
          date_time TEXT, status TEXT, note TEXT, wastage_qty REAL DEFAULT 0, wastage_note TEXT,
          allocation_method TEXT DEFAULT 'quantity', expected_recovery_pct REAL)''');
        await d.execute('''CREATE TABLE daily_closings(
          id INTEGER PRIMARY KEY AUTOINCREMENT, business_id INTEGER, date TEXT,
          opening REAL, total_in REAL, total_out REAL, closing REAL,
          frozen_at TEXT, UNIQUE(business_id, date))''');
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

  Future<void> updateCashEntry(CashEntry e) async => (await db)
      .update('cash_entries', e.toMap(), where: 'id = ?', whereArgs: [e.id]);

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
    // COGS snapshot (Phase 2): price every stocked line at the unit
    // cost of THIS moment, before the sale is posted. Reports read the
    // snapshot, so a later purchase can never rewrite a past period's
    // profit. Free-text lines keep a null cost (unknown, flagged).
    final enriched = <BillItem>[];
    final costOf = <int, double>{};
    for (final it in items) {
      double? unitCost = it.costRate;
      if (unitCost == null && it.itemId != null) {
        unitCost = costOf[it.itemId!] ??=
            await getItemUnitCost(it.itemId!);
      }
      enriched.add(BillItem(
        billId: it.billId,
        itemId: it.itemId,
        name: it.name,
        qty: it.qty,
        rate: it.rate,
        costRate: unitCost,
        costAmount: unitCost == null ? null : unitCost * it.qty,
      ));
    }
    return d.transaction((txn) async {
      final billId = await txn.insert('bills', bill.toMap());
      final posted = Bill(
        id: billId,
        businessId: bill.businessId,
        billNo: bill.billNo,
        partyId: bill.partyId,
        partyName: bill.partyName,
        total: bill.total,
        status: bill.status,
        dateTime: bill.dateTime,
        deleted: bill.deleted,
        method: bill.method,
      );
      await _postBillEntries(txn, businessId, posted, enriched);
      return billId;
    });
  }

  /// Inserts a bill's items and ALL of its accounting postings (stock
  /// out, ledger udhaar/wasool, cash in) inside [txn]. Every posting
  /// carries the bill_id (Phase 3) so it can be reversed exactly.
  /// Items must already carry their COGS snapshot (costRate).
  Future<void> _postBillEntries(Transaction txn, int businessId, Bill bill,
      List<BillItem> items) async {
    for (final it in items) {
      await txn.insert('bill_items', {
        ...it.toMap(),
        'bill_id': bill.id,
        'cost_amount':
            it.costRate == null ? null : it.costRate! * it.qty,
      });
      if (it.itemId != null) {
        await txn.insert('stock_transactions', {
          'item_id': it.itemId, 'type': 'out', 'qty': it.qty, 'rate': it.rate,
          'supplier_id': null, 'bill_no': bill.billNo.toString(),
          'note': 'Bill #${bill.billNo}',
          'date_time': bill.dateTime.toIso8601String(),
          'attachment_path': null,
          'bill_id': bill.id,
        });
      }
    }
    if (bill.partyId != null) {
      await txn.insert('party_transactions', {
        'party_id': bill.partyId, 'type': 'udhaar', 'amount': bill.total,
        'note': 'Bill #${bill.billNo}',
        'date_time': bill.dateTime.toIso8601String(),
        'attachment_path': null, 'method': 'cash', 'bill_id': bill.id,
      });
      if (bill.status == 'paid') {
        await txn.insert('party_transactions', {
          'party_id': bill.partyId, 'type': 'wasool', 'amount': bill.total,
          'note': 'Bill #${bill.billNo} payment',
          'date_time': bill.dateTime.toIso8601String(),
          'attachment_path': null, 'method': bill.method, 'bill_id': bill.id,
        });
      }
    }
    // Only a cash-paid bill puts physical money in the drawer; a
    // bank/JazzCash/Easypaisa payment is recorded on the ledger only.
    if (bill.status == 'paid' && bill.method == 'cash') {
      await txn.insert('cash_entries', {
        'business_id': businessId, 'type': 'in', 'amount': bill.total,
        'note': 'Bill #${bill.billNo}', 'party_id': bill.partyId,
        'date_time': bill.dateTime.toIso8601String(), 'attachment_path': null,
        'source_table': 'bills', 'source_id': bill.id,
      });
    }
  }

  /// Removes ALL of a bill's postings inside [txn]: the exact rows by
  /// bill_id / cash source, plus a best-effort legacy sweep for bills
  /// created before bill_id existed (matched by bill number + note,
  /// which are unique per business). After this runs, the bill has
  /// zero effect on stock, ledgers and cash.
  Future<void> _reverseBillPostings(Transaction txn, Bill bill) async {
    final no = bill.billNo.toString();
    await txn.delete('stock_transactions',
        where: 'bill_id = ?', whereArgs: [bill.id]);
    await txn.delete('stock_transactions',
        where: 'bill_id IS NULL AND bill_no = ?', whereArgs: [no]);
    await txn.delete('party_transactions',
        where: 'bill_id = ?', whereArgs: [bill.id]);
    if (bill.partyId != null) {
      await txn.delete('party_transactions',
          where: 'bill_id IS NULL AND party_id = ? AND note IN (?, ?)',
          whereArgs: [bill.partyId, 'Bill #$no', 'Bill #$no payment']);
    }
    await txn.delete('cash_entries',
        where: 'source_table = ? AND source_id = ?',
        whereArgs: ['bills', bill.id]);
    await txn.delete('cash_entries',
        where: 'source_id IS NULL AND business_id = ? AND note = ?',
        whereArgs: [bill.businessId, 'Bill #$no']);
  }

  Future<Bill?> _billById(DatabaseExecutor e, int id) async {
    final rows = await e.query('bills', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Bill.fromMap(rows.first);
  }

  /// Edits a bill atomically: reverses the old postings, updates the
  /// bill row, and re-posts from the edited items — same transaction,
  /// same bill number. Lines that already carry a COGS snapshot keep
  /// their original sale-time cost; only brand-new lines are priced at
  /// today's unit cost.
  Future<void> updateBill({
    required Bill bill,
    required List<BillItem> items,
  }) async {
    final d = await db;
    final enriched = <BillItem>[];
    final costOf = <int, double>{};
    for (final it in items) {
      double? unitCost = it.costRate;
      if (unitCost == null && it.itemId != null) {
        unitCost = costOf[it.itemId!] ??=
            await getItemUnitCost(it.itemId!);
      }
      enriched.add(BillItem(
        billId: bill.id!,
        itemId: it.itemId,
        name: it.name,
        qty: it.qty,
        rate: it.rate,
        costRate: unitCost,
        costAmount: unitCost == null ? null : unitCost * it.qty,
      ));
    }
    await d.transaction((txn) async {
      final old = await _billById(txn, bill.id!);
      if (old == null) return;
      await _reverseBillPostings(txn, old);
      await txn.delete('bill_items', where: 'bill_id = ?', whereArgs: [bill.id]);
      await txn.update('bills', bill.toMap(), where: 'id = ?', whereArgs: [bill.id]);
      await _postBillEntries(txn, bill.businessId, bill, enriched);
    });
  }

  Future<List<BillItem>> getBillItems(int billId) async {
    final d = await db;
    final rows = await d.query('bill_items', where: 'bill_id = ?', whereArgs: [billId]);
    return rows.map(BillItem.fromMap).toList();
  }

  /// Soft-delete / restore WITH full accounting effect (Phase 3):
  /// deleting a bill reverses its stock, ledger and cash postings in
  /// the same transaction; restoring re-posts them from the stored
  /// bill and items (original COGS snapshots preserved). Before this,
  /// a deleted bill kept haunting stock, balances and cash forever.
  Future<void> setBillDeleted(int id, bool deleted) async {
    final d = await db;
    await d.transaction((txn) async {
      final bill = await _billById(txn, id);
      if (bill == null) return;
      if (deleted) {
        await _reverseBillPostings(txn, bill);
        await txn.update('bills', {'deleted': 1},
            where: 'id = ?', whereArgs: [id]);
      } else {
        await txn.update('bills', {'deleted': 0},
            where: 'id = ?', whereArgs: [id]);
        final rows = await txn.query('bill_items',
            where: 'bill_id = ?', whereArgs: [id]);
        final items = rows.map(BillItem.fromMap).toList();
        await txn.delete('bill_items', where: 'bill_id = ?', whereArgs: [id]);
        await _postBillEntries(txn, bill.businessId, bill, items);
      }
    });
  }

  Future<void> deleteBillForever(int id) async {
    final d = await db;
    await d.transaction((txn) async {
      final bill = await _billById(txn, id);
      if (bill != null) await _reverseBillPostings(txn, bill);
      await txn.delete('bill_items', where: 'bill_id = ?', whereArgs: [id]);
      await txn.delete('bills', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Book check (Phase 3): how many soft-deleted bills still have
  /// surviving postings (only possible for bills deleted before the
  /// reversal engine existed). Zero is healthy.
  Future<int> countDeletedBillsWithPostings(int businessId) async {
    final d = await db;
    final bills = await d.query('bills',
        where: 'business_id = ? AND deleted = 1', whereArgs: [businessId]);
    var count = 0;
    for (final r in bills) {
      final b = Bill.fromMap(r);
      final no = b.billNo.toString();
      final checks = await Future.wait([
        d.rawQuery('SELECT COUNT(*) AS c FROM stock_transactions '
            'WHERE bill_id = ? OR (bill_id IS NULL AND bill_no = ?)',
            [b.id, no]),
        d.rawQuery('SELECT COUNT(*) AS c FROM party_transactions '
            'WHERE bill_id = ? OR (bill_id IS NULL AND party_id = ? '
            'AND note IN (?, ?))',
            [b.id, b.partyId, 'Bill #$no', 'Bill #$no payment']),
        d.rawQuery('SELECT COUNT(*) AS c FROM cash_entries '
            'WHERE (source_table = ? AND source_id = ?) OR '
            '(source_id IS NULL AND business_id = ? AND note = ?)',
            ['bills', b.id, businessId, 'Bill #$no']),
      ]);
      if (checks.any((c) => (c.first['c'] as num) > 0)) count++;
    }
    return count;
  }

  /// Reverses the surviving postings of every soft-deleted bill of
  /// the business (repairs books written before Phase 3).
  Future<int> repairDeletedBills(int businessId) async {
    final d = await db;
    final bills = await d.query('bills',
        where: 'business_id = ? AND deleted = 1', whereArgs: [businessId]);
    var repaired = 0;
    for (final r in bills) {
      final b = Bill.fromMap(r);
      await d.transaction((txn) async {
        await _reverseBillPostings(txn, b);
      });
      repaired++;
    }
    return repaired;
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

  /// Deletes a QR payment. A CONFIRMED payment already posted a
  /// party wasool and (for cash) a drawer entry — those are reversed
  /// in the same transaction so deleting can never orphan money in
  /// the books (Phase 1 audit fix).
  Future<void> deleteQrPayment(int id) async {
    final d = await db;
    await d.transaction((txn) async {
      final rows =
          await txn.query('qr_payments', where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      final q = QrPayment.fromMap(rows.first);
      if (q.status == 'confirmed') {
        if (q.partyId != null) {
          final cands = await txn.query('party_transactions',
              columns: ['id', 'date_time'],
              where: "party_id = ? AND type = 'wasool' AND amount = ? "
                  "AND note = 'QR payment'",
              whereArgs: [q.partyId, q.amount]);
          for (final c in cands) {
            if (c['date_time'] == q.dateTime.toIso8601String()) {
              await txn.delete('party_transactions',
                  where: 'id = ?', whereArgs: [c['id']]);
              break;
            }
          }
        }
        await _deleteLinkedCash(txn, 'qr_payments', id);
      }
      await txn.delete('qr_payments', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Deletes a salary payment and its linked drawer cash-out in one
  /// transaction (Phase 1 audit fix: salary entries previously had
  /// no correction path at all).
  Future<void> deleteSalaryPayment(int id) async {
    final d = await db;
    await d.transaction((txn) async {
      await _deleteLinkedCash(txn, 'salary_payments', id);
      await txn.delete('salary_payments', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ---------------- Raw material purchases (atomic) ----------------
  /// Saves a raw-material purchase in ONE transaction: stock-in, the
  /// supplier's wasool (we owe), the udhaar payment when paid on the
  /// spot, and the cash-out — previously four separate writes that a
  /// crash could leave half-posted (Phase 3). Returns the stock
  /// transaction id.
  Future<int> saveRawPurchase({
    required int businessId,
    required int itemId,
    required double qty,
    required double rate,
    int? supplierId,
    required bool paid,
    required DateTime dateTime,
  }) async {
    final d = await db;
    final total = qty * rate;
    return d.transaction((txn) async {
      final stockId = await txn.insert('stock_transactions', {
        'item_id': itemId, 'type': 'in', 'qty': qty, 'rate': rate,
        'supplier_id': supplierId, 'bill_no': '', 'note': 'Purchase',
        'date_time': dateTime.toIso8601String(), 'attachment_path': null,
      });
      if (supplierId != null) {
        await txn.insert(
            'party_transactions',
            PartyTransaction(
              partyId: supplierId,
              type: 'wasool',
              amount: total,
              note: 'Purchase',
              dateTime: dateTime,
            ).toMap());
        if (paid) {
          await txn.insert(
              'party_transactions',
              PartyTransaction(
                partyId: supplierId,
                type: 'udhaar',
                amount: total,
                note: 'Purchase payment',
                dateTime: dateTime,
              ).toMap());
        }
      }
      if (paid) {
        await _postLinkedCash(txn,
            businessId: businessId,
            type: 'out',
            amount: total,
            note: 'Purchase payment',
            partyId: supplierId,
            dateTime: dateTime,
            sourceTable: 'purchases',
            sourceId: stockId);
      }
      return stockId;
    });
  }

  /// Saves a purchase return in ONE transaction: stock-out plus the
  /// supplier ledger adjustment that reduces what we owe them.
  Future<void> savePurchaseReturn({
    required int itemId,
    required double qty,
    required double rate,
    int? supplierId,
    required DateTime dateTime,
  }) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.insert('stock_transactions', {
        'item_id': itemId, 'type': 'out', 'qty': qty, 'rate': rate,
        'supplier_id': supplierId, 'bill_no': '', 'note': 'Purchase return',
        'date_time': dateTime.toIso8601String(), 'attachment_path': null,
      });
      if (supplierId != null) {
        await txn.insert(
            'party_transactions',
            PartyTransaction(
              partyId: supplierId,
              type: 'udhaar',
              amount: qty * rate,
              note: 'Purchase return',
              dateTime: dateTime,
            ).toMap());
      }
    });
  }

  // ---------------- Daily closings (Phase 4) ----------------
  String _dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  Future<DailyClosing?> getDailyClosing(int businessId, DateTime day) async {
    final d = await db;
    final rows = await d.query('daily_closings',
        where: 'business_id = ? AND date = ?',
        whereArgs: [businessId, _dayKey(day)]);
    return rows.isEmpty ? null : DailyClosing.fromMap(rows.first);
  }

  /// Freezes a day's cash closing from the CURRENT cash_entries: the
  /// sealed record is what Roznamcha shows from then on, so later
  /// backdated edits surface as a mismatch instead of silently
  /// rewriting a closed day. Re-freezing overwrites with fresh sums.
  Future<DailyClosing> freezeDailyClosing(int businessId, DateTime day) async {
    final live = await liveDailyClosing(businessId, day);
    final record = DailyClosing(
      businessId: businessId,
      date: _dayKey(day),
      opening: live.opening,
      totalIn: live.totalIn,
      totalOut: live.totalOut,
      closing: live.closing,
      frozenAt: DateTime.now(),
    );
    final d = await db;
    await d.insert('daily_closings', record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return record;
  }

  /// Live (unfrozen) closing figures for a day — Roznamcha compares
  /// these against the frozen record to detect post-close edits.
  Future<({double opening, double totalIn, double totalOut, double closing})>
      liveDailyClosing(int businessId, DateTime day) async {
    final d = await db;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await d.query('cash_entries',
        where: 'business_id = ?', whereArgs: [businessId]);
    var openNet = 0.0, dayIn = 0.0, dayOut = 0.0;
    for (final r in rows) {
      final e = CashEntry.fromMap(r);
      if (e.dateTime.isBefore(start)) {
        openNet += e.type == 'in' ? e.amount : -e.amount;
      } else if (e.dateTime.isBefore(end)) {
        if (e.type == 'in') {
          dayIn += e.amount;
        } else {
          dayOut += e.amount;
        }
      }
    }
    return (
      opening: openNet,
      totalIn: dayIn,
      totalOut: dayOut,
      closing: openNet + dayIn - dayOut
    );
  }

  /// Yield / wastage analysis for one batch (Phase 4): everything in
  /// kg (litres converted through item density, mann = 40). The
  /// recorded wastage is treated as kg. [recoveryPct] is what actually
  /// came out; [accountedPct] adds the recorded wastage back — the gap
  /// to 100% is unexplained loss.
  Future<
      ({
        double inputKg,
        double outputKg,
        double wastageKg,
        double recoveryPct,
        double accountedPct
      })> getBatchRecovery(int batchId) async {
    final d = await db;
    double kgFactor(String unit, double? density) {
      final u = unit.toLowerCase();
      if (u.contains('ton')) return 1000;
      if (u.contains('mann') || u.contains('maund') || u.contains('mun')) {
        return 40;
      }
      if (u.contains('litre') || u.contains('liter') || u.contains('ltr')) {
        return density ?? 1;
      }
      if (u.contains('40')) return 40;
      return 1;
    }

    Future<double> kgOf(String table) async {
      final rows = await d.rawQuery(
          'SELECT t.qty AS q, i.unit AS u, i.density AS den '
          'FROM $table t JOIN items i ON i.id = t.item_id '
          'WHERE t.batch_id = ?',
          [batchId]);
      var total = 0.0;
      for (final r in rows) {
        total += (r['q'] as num).toDouble() *
            kgFactor(r['u'] as String? ?? '', (r['den'] as num?)?.toDouble());
      }
      return total;
    }

    final inputKg = await kgOf('production_inputs');
    final outputKg = await kgOf('production_outputs');
    final brows = await d.query('production_batches',
        columns: ['wastage_qty'], where: 'id = ?', whereArgs: [batchId]);
    final wastageKg =
        brows.isEmpty ? 0.0 : (brows.first['wastage_qty'] as num).toDouble();
    final recovery = inputKg > 0 ? outputKg / inputKg * 100 : 0.0;
    final accounted =
        inputKg > 0 ? (outputKg + wastageKg) / inputKg * 100 : 0.0;
    return (
      inputKg: inputKg,
      outputKg: outputKg,
      wastageKg: wastageKg,
      recoveryPct: recovery,
      accountedPct: accounted
    );
  }

  // ---------------- Profit & batch profitability (Phase 5) ----------------
  /// Total salaries + advances paid to the business's staff in a
  /// period. Salaries are operating costs (Phase 4 classification);
  /// until Phase 5 they were invisible to every profit figure.
  Future<double> getSalaryTotal(int businessId,
      {DateTime? start, DateTime? end}) async {
    final d = await db;
    var where = 's.business_id = ?';
    final args = <Object?>[businessId];
    if (start != null) {
      where += ' AND sp.date_time >= ?';
      args.add(start.toIso8601String());
    }
    if (end != null) {
      where += ' AND sp.date_time < ?';
      args.add(end.toIso8601String());
    }
    final r = await d.rawQuery(
        'SELECT COALESCE(SUM(sp.amount),0) AS s FROM salary_payments sp '
        'JOIN staff s ON s.id = sp.staff_id WHERE $where',
        args);
    return (r.first['s'] as num).toDouble();
  }

  /// THE profit calculation of the app (Phase 5) — one implementation
  /// used by Production Reports, general Reports and the Owner
  /// Dashboard so every screen agrees:
  ///   Sales  = non-deleted bill totals of the period
  ///   COGS   = sale-time cost snapshots (legacy lines: current cost)
  ///   Gross  = Sales - COGS
  ///   Net    = Gross - operating expenses - salaries paid
  /// Owner withdrawals / loan repayments / transfers are reported as
  /// [nonOperating] and never touch Net. Free-text bill lines have no
  /// cost: their sales are counted in [unknownCostSales] so the user
  /// can see how much of Sales carries no COGS.
  Future<
      ({
        double sales,
        double cogs,
        double gross,
        double operatingExpenses,
        double salaries,
        double nonOperating,
        double net,
        double unknownCostSales,
        int unknownCostLines
      })> getProfitSummary(int businessId, DateTime start, DateTime end) async {
    bool inPeriod(DateTime t) => !t.isBefore(start) && t.isBefore(end);

    var sales = 0.0, cogs = 0.0, unknownSales = 0.0;
    var unknownLines = 0;
    final costCache = <int, double>{};
    final bills = await getBills(businessId);
    for (final b in bills) {
      if (!inPeriod(b.dateTime) || b.id == null) continue;
      sales += b.total;
      for (final bi in await getBillItems(b.id!)) {
        if (bi.costAmount != null) {
          cogs += bi.costAmount!;
        } else if (bi.itemId != null) {
          final c = costCache[bi.itemId!] ??=
              await getItemUnitCost(bi.itemId!);
          cogs += bi.qty * c;
        } else {
          unknownLines++;
          unknownSales += bi.amount;
        }
      }
    }
    var opEx = 0.0, nonOp = 0.0;
    for (final e in await getExpenses(businessId)) {
      if (!inPeriod(e.dateTime)) continue;
      if (e.kind == 'operating') {
        opEx += e.amount;
      } else {
        nonOp += e.amount;
      }
    }
    final salaries = await getSalaryTotal(businessId, start: start, end: end);
    final gross = sales - cogs;
    return (
      sales: sales,
      cogs: cogs,
      gross: gross,
      operatingExpenses: opEx,
      salaries: salaries,
      nonOperating: nonOp,
      net: gross - opEx - salaries,
      unknownCostSales: unknownSales,
      unknownCostLines: unknownLines
    );
  }

  /// Batch-wise profitability (Phase 5), computed by a FIFO replay of
  /// the stock book: every stock-IN opens a lot (production lots are
  /// recognised by their 'Production batch #N' note and carry the
  /// batch's allocated unit cost); bill stock-OUTs consume lots
  /// oldest-first, attributing revenue (qty x sale rate) and COGS
  /// (qty x lot cost) to the batch that supplied them. Other outs
  /// (production consumption, purchase returns, cancellations) consume
  /// lots without revenue. Cumulative, all-time figures.
  Future<
      List<
          ({
            int batchId,
            int batchNo,
            double producedQty,
            double soldQty,
            double revenue,
            double cogs,
            double profit,
            double unsoldQty
          })>> getBatchProfits(int businessId) async {
    final d = await db;
    final batches = await getProductionBatches(businessId);
    final byNo = <int, ProductionBatch>{
      for (final b in batches) b.batchNo: b,
    };
    final rows = await d.rawQuery(
        'SELECT st.* FROM stock_transactions st '
        'JOIN items i ON i.id = st.item_id '
        'WHERE i.business_id = ? '
        'ORDER BY st.date_time ASC, st.id ASC',
        [businessId]);
    final lotsByItem = <int, List<({int? batchId, double qty, double cost})>>{};
    final agg = <int, ({double produced, double sold, double revenue, double cogs})>{};
    final batchNoRe = RegExp(r'Production batch #(\d+)');
    for (final r in rows) {
      final itemId = (r['item_id'] as num).toInt();
      final qty = (r['qty'] as num).toDouble();
      final rate = (r['rate'] as num).toDouble();
      final note = r['note'] as String? ?? '';
      final lots = lotsByItem.putIfAbsent(itemId, () => []);
      if (r['type'] == 'in') {
        final m = batchNoRe.firstMatch(note);
        final b = m == null ? null : byNo[int.tryParse(m.group(1)!) ?? -1];
        lots.add((batchId: b?.id, qty: qty, cost: rate));
        if (b?.id != null) {
          final a = agg[b!.id!] ?? (produced: 0.0, sold: 0.0, revenue: 0.0, cogs: 0.0);
          agg[b.id!] = (
            produced: a.produced + qty,
            sold: a.sold,
            revenue: a.revenue,
            cogs: a.cogs
          );
        }
      } else {
        final isBillSale = r['bill_id'] != null || note.startsWith('Bill #');
        var remaining = qty;
        while (remaining > 1e-9 && lots.isNotEmpty) {
          final lot = lots.first;
          final take = remaining < lot.qty ? remaining : lot.qty;
          if (isBillSale && lot.batchId != null) {
            final a = agg[lot.batchId!] ??
                (produced: 0.0, sold: 0.0, revenue: 0.0, cogs: 0.0);
            agg[lot.batchId!] = (
              produced: a.produced,
              sold: a.sold + take,
              revenue: a.revenue + take * rate,
              cogs: a.cogs + take * lot.cost
            );
          }
          remaining -= take;
          if (take >= lot.qty - 1e-9) {
            lots.removeAt(0);
          } else {
            lots[0] = (
              batchId: lot.batchId,
              qty: lot.qty - take,
              cost: lot.cost
            );
          }
        }
      }
    }
    final result = <({
      int batchId,
      int batchNo,
      double producedQty,
      double soldQty,
      double revenue,
      double cogs,
      double profit,
      double unsoldQty
    })>[];
    for (final b in batches) {
      final a = agg[b.id];
      if (a == null) continue;
      result.add((
        batchId: b.id!,
        batchNo: b.batchNo,
        producedQty: a.produced,
        soldQty: a.sold,
        revenue: a.revenue,
        cogs: a.cogs,
        profit: a.revenue - a.cogs,
        unsoldQty: a.produced - a.sold
      ));
    }
    result.sort((x, y) => y.batchNo.compareTo(x.batchNo));
    return result;
  }

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

  /// Perpetual (moving) weighted-average unit cost, replayed from the
  /// item's stock history in chronological order: every stock-IN adds
  /// qty x rate to the pool; every stock-OUT removes qty at the pool's
  /// current average. Consumed stock therefore LEAVES the pool — the
  /// old lifetime formula (all receipts ever) priced new batches from
  /// long-consumed lots. Returns the pool's unit cost, or the last
  /// known unit cost when the pool is empty, or 0 with no costed
  /// history. Out-row rates are ignored on purpose (bill outs carry
  /// SALE rates; the pool average is the cost).
  Future<double> _replayUnitCost(DatabaseExecutor e, int itemId) async {
    final rows = await e.query('stock_transactions',
        where: 'item_id = ?', whereArgs: [itemId],
        orderBy: 'date_time ASC, id ASC');
    var poolQty = 0.0;
    var poolValue = 0.0;
    var lastCost = 0.0;
    for (final r in rows) {
      final qty = (r['qty'] as num).toDouble();
      final rate = (r['rate'] as num).toDouble();
      if (r['type'] == 'in') {
        if (rate > 0) {
          poolQty += qty;
          poolValue += qty * rate;
          if (poolQty > 0) lastCost = poolValue / poolQty;
        }
      } else if (poolQty > 0) {
        final avg = poolValue / poolQty;
        lastCost = avg;
        final take = qty < poolQty ? qty : poolQty;
        poolValue -= take * avg;
        poolQty -= take;
      }
    }
    if (poolQty > 0) return poolValue / poolQty;
    return lastCost;
  }

  /// The unit cost used for COGS / valuation of an item: the perpetual
  /// moving average of the stock actually on hand. Falls back to the
  /// production average, then the lifetime purchase average, for items
  /// with no replayable stock history (e.g. opening-qty only).
  Future<double> getItemUnitCost(int itemId) async {
    final d = await db;
    final replay = await _replayUnitCost(d, itemId);
    if (replay > 0) return replay;
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
    required List<({int itemId, double qty, double? saleRate})> outputs,
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

      Future<double> wacOf(int itemId) => _replayUnitCost(txn, itemId);

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
      // Joint-cost allocation (Phase 2): 'value' splits the total by
      // each output's relative sales value (qty x expected sale rate),
      // so oil and khal no longer share one identical per-unit cost;
      // 'quantity' splits by kg-normalised quantity (litres converted
      // through the item's density, mann = 40 kg). Falls back to raw
      // quantity when no usable weights exist.
      double kgFactor(String unit, double? density) {
        final u = unit.toLowerCase();
        if (u.contains('ton')) return 1000;
        if (u.contains('mann') || u.contains('maund') || u.contains('mun')) {
          return 40;
        }
        if (u.contains('litre') || u.contains('liter') || u.contains('ltr')) {
          return density ?? 1;
        }
        if (u.contains('40')) return 40;
        return 1;
      }

      final weights = <double>[];
      var totalWeight = 0.0;
      for (final out in outputs) {
        var w = 0.0;
        if (batch.allocationMethod == 'value') {
          w = out.qty * (out.saleRate ?? 0);
        } else {
          final rows =
              await txn.query('items', where: 'id = ?', whereArgs: [out.itemId]);
          if (rows.isNotEmpty) {
            w = out.qty *
                kgFactor(rows.first['unit'] as String? ?? '',
                    (rows.first['density'] as num?)?.toDouble());
          }
        }
        weights.add(w);
        totalWeight += w;
      }
      if (totalWeight <= 0) {
        weights
          ..clear()
          ..addAll(outputs.map((o) => o.qty));
        totalWeight = totalOutQty;
      }
      var oi = 0;
      for (final out in outputs) {
        final w = weights[oi++];
        if (out.qty <= 0) continue;
        final allocated = totalCost * (w / totalWeight);
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
    'daily_closings',
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
    'daily_closings',
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
