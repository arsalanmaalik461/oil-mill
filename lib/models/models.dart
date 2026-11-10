/// Plain data models. Every model maps 1:1 to a SQLite table.
class Business {
  final int? id;
  final String name;
  final String owner;
  final String phone;
  final String address;

  /// Login username this business belongs to (per-user data isolation).
  final String appUsername;
  Business({this.id, required this.name, this.owner = '', this.phone = '', this.address = '', this.appUsername = ''});
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name, 'owner': owner, 'phone': phone, 'address': address,
        'app_username': appUsername,
      };
  factory Business.fromMap(Map<String, dynamic> m) => Business(
        id: m['id'] as int?, name: m['name'] ?? '', owner: m['owner'] ?? '',
        phone: m['phone'] ?? '', address: m['address'] ?? '',
        appUsername: (m['app_username'] as String?) ?? '',
      );
}

/// type: 'customer' | 'supplier' | 'dealer'. openingBalance is signed:
/// positive = you will get (party owes you), negative = you will give.
class Party {
  final int? id;
  final int businessId;
  final String type;
  final String name;
  final String phone;
  final String address;
  final double openingBalance;
  final int deleted;

  /// When the last payment reminder was sent to this party (null = never).
  final DateTime? lastReminderAt;

  /// Optional payment due date ("Set Date" on the party screen).
  final DateTime? dueDate;
  Party({
    this.id, required this.businessId, required this.type, required this.name,
    this.phone = '', this.address = '', this.openingBalance = 0, this.deleted = 0,
    this.lastReminderAt,
    this.dueDate,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'type': type, 'name': name, 'phone': phone,
        'address': address, 'opening_balance': openingBalance, 'deleted': deleted,
        'last_reminder_at': lastReminderAt?.toIso8601String(),
        'due_date': dueDate?.toIso8601String(),
      };
  factory Party.fromMap(Map<String, dynamic> m) => Party(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1, type: m['type'] ?? 'customer',
        name: m['name'] ?? '', phone: m['phone'] ?? '', address: m['address'] ?? '',
        openingBalance: (m['opening_balance'] ?? 0).toDouble(), deleted: m['deleted'] ?? 0,
        // Old backups / rows may not carry the column at all.
        lastReminderAt: (m['last_reminder_at'] as String?)?.isNotEmpty == true
            ? DateTime.tryParse(m['last_reminder_at'] as String)
            : null,
        dueDate: (m['due_date'] as String?)?.isNotEmpty == true
            ? DateTime.tryParse(m['due_date'] as String)
            : null,
      );
}

/// type: 'udhaar' (you gave credit, balance += amount) |
///       'wasool' (you received payment, balance -= amount)
class PartyTransaction {
  final int? id;
  final int partyId;
  final String type;
  final double amount;
  final String note;
  final DateTime dateTime;
  final String? attachmentPath;

  /// How the money moved: 'cash' | 'bank' | 'jazzcash' | 'easypaisa'.
  /// Only 'cash' entries touch the physical cash drawer (cash_entries).
  final String method;
  PartyTransaction({
    this.id, required this.partyId, required this.type, required this.amount,
    this.note = '', required this.dateTime, this.attachmentPath,
    this.method = 'cash',
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'party_id': partyId, 'type': type, 'amount': amount, 'note': note,
        'date_time': dateTime.toIso8601String(), 'attachment_path': attachmentPath,
        'method': method,
      };
  factory PartyTransaction.fromMap(Map<String, dynamic> m) => PartyTransaction(
        id: m['id'] as int?, partyId: m['party_id'], type: m['type'],
        amount: (m['amount'] ?? 0).toDouble(), note: m['note'] ?? '',
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
        attachmentPath: m['attachment_path'],
        method: m['method'] ?? 'cash',
      );
}

/// type: 'in' | 'out'
class CashEntry {
  final int? id;
  final int businessId;
  final String type;
  final double amount;
  final String note;
  final int? partyId;
  final DateTime dateTime;
  final String? attachmentPath;

  /// Where this cash movement came from (e.g. 'party_transactions',
  /// 'expenses', 'salary_payments', 'bills', 'qr_payments'). Null for a
  /// manual Cash Book entry. (sourceTable, sourceId) is UNIQUE in the
  /// database, so an automatic posting can never be duplicated.
  final String? sourceTable;
  final int? sourceId;
  CashEntry({
    this.id, required this.businessId, required this.type, required this.amount,
    this.note = '', this.partyId, required this.dateTime, this.attachmentPath,
    this.sourceTable, this.sourceId,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'type': type, 'amount': amount, 'note': note,
        'party_id': partyId, 'date_time': dateTime.toIso8601String(),
        'attachment_path': attachmentPath,
        'source_table': sourceTable, 'source_id': sourceId,
      };
  factory CashEntry.fromMap(Map<String, dynamic> m) => CashEntry(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1, type: m['type'],
        amount: (m['amount'] ?? 0).toDouble(), note: m['note'] ?? '',
        sourceTable: m['source_table'], sourceId: m['source_id'],
        partyId: m['party_id'], dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
        attachmentPath: m['attachment_path'],
      );
}

class StockItem {
  final int? id;
  final int businessId;
  final String name;
  final String unit;
  final String category;
  final String kind; // 'general' | 'raw' | 'finished'
  final double openingQty;
  final double lowStockLimit;
  final int deleted;
  StockItem({
    this.id, required this.businessId, required this.name, this.unit = 'pcs',
    this.category = '', this.kind = 'general',
    this.openingQty = 0, this.lowStockLimit = 0, this.deleted = 0,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'name': name, 'unit': unit, 'category': category,
        'kind': kind,
        'opening_qty': openingQty, 'low_stock_limit': lowStockLimit, 'deleted': deleted,
      };
  factory StockItem.fromMap(Map<String, dynamic> m) => StockItem(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1, name: m['name'] ?? '',
        unit: m['unit'] ?? 'pcs', category: m['category'] ?? '',
        kind: m['kind'] ?? 'general',
        openingQty: (m['opening_qty'] ?? 0).toDouble(),
        lowStockLimit: (m['low_stock_limit'] ?? 0).toDouble(), deleted: m['deleted'] ?? 0,
      );
}

/// type: 'in' | 'out'
class StockTransaction {
  final int? id;
  final int itemId;
  final String type;
  final double qty;
  final double rate;
  final int? supplierId;
  final String billNo;
  final String note;
  final DateTime dateTime;
  final String? attachmentPath;
  StockTransaction({
    this.id, required this.itemId, required this.type, required this.qty,
    this.rate = 0, this.supplierId, this.billNo = '', this.note = '',
    required this.dateTime, this.attachmentPath,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'item_id': itemId, 'type': type, 'qty': qty, 'rate': rate,
        'supplier_id': supplierId, 'bill_no': billNo, 'note': note,
        'date_time': dateTime.toIso8601String(), 'attachment_path': attachmentPath,
      };
  factory StockTransaction.fromMap(Map<String, dynamic> m) => StockTransaction(
        id: m['id'] as int?, itemId: m['item_id'], type: m['type'],
        qty: (m['qty'] ?? 0).toDouble(), rate: (m['rate'] ?? 0).toDouble(),
        supplierId: m['supplier_id'], billNo: m['bill_no'] ?? '', note: m['note'] ?? '',
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
        attachmentPath: m['attachment_path'],
      );
}

/// status: 'paid' | 'pending'
class Bill {
  final int? id;
  final int businessId;
  final int billNo;
  final int? partyId;
  final String partyName;
  final double total;
  final String status;
  final DateTime dateTime;
  final int deleted;
  Bill({
    this.id, required this.businessId, required this.billNo, this.partyId,
    this.partyName = '', required this.total, this.status = 'paid',
    required this.dateTime, this.deleted = 0,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'bill_no': billNo, 'party_id': partyId,
        'party_name': partyName, 'total': total, 'status': status,
        'date_time': dateTime.toIso8601String(), 'deleted': deleted,
      };
  factory Bill.fromMap(Map<String, dynamic> m) => Bill(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1, billNo: m['bill_no'] ?? 0,
        partyId: m['party_id'], partyName: m['party_name'] ?? '',
        total: (m['total'] ?? 0).toDouble(), status: m['status'] ?? 'paid',
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
        deleted: m['deleted'] ?? 0,
      );
}

class BillItem {
  final int? id;
  final int billId;
  final int? itemId;
  final String name;
  final double qty;
  final double rate;
  double get amount => qty * rate;
  BillItem({this.id, required this.billId, this.itemId, required this.name, required this.qty, required this.rate});
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'bill_id': billId, 'item_id': itemId, 'name': name, 'qty': qty,
        'rate': rate, 'amount': amount,
      };
  factory BillItem.fromMap(Map<String, dynamic> m) => BillItem(
        id: m['id'] as int?, billId: m['bill_id'], itemId: m['item_id'],
        name: m['name'] ?? '', qty: (m['qty'] ?? 0).toDouble(), rate: (m['rate'] ?? 0).toDouble(),
      );
}

class Staff {
  final int? id;
  final int businessId;
  final String name;
  final String phone;
  final double monthlySalary;
  final int deleted;
  Staff({this.id, required this.businessId, required this.name, this.phone = '', this.monthlySalary = 0, this.deleted = 0});
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'name': name, 'phone': phone,
        'monthly_salary': monthlySalary, 'deleted': deleted,
      };
  factory Staff.fromMap(Map<String, dynamic> m) => Staff(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1, name: m['name'] ?? '',
        phone: m['phone'] ?? '', monthlySalary: (m['monthly_salary'] ?? 0).toDouble(),
        deleted: m['deleted'] ?? 0,
      );
}

/// status: 'present' | 'absent' | 'half'
class Attendance {
  final int? id;
  final int staffId;
  final String date; // yyyy-mm-dd
  final String status;
  final double overtimeHours;
  Attendance({this.id, required this.staffId, required this.date, required this.status, this.overtimeHours = 0});
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'staff_id': staffId, 'date': date, 'status': status, 'overtime_hours': overtimeHours,
      };
  factory Attendance.fromMap(Map<String, dynamic> m) => Attendance(
        id: m['id'] as int?, staffId: m['staff_id'], date: m['date'] ?? '',
        status: m['status'] ?? 'absent', overtimeHours: (m['overtime_hours'] ?? 0).toDouble(),
      );
}

/// type: 'salary' | 'bonus' | 'advance' | 'overtime'
class SalaryPayment {
  final int? id;
  final int staffId;
  final String type;
  final double amount;
  final String note;
  final DateTime dateTime;
  SalaryPayment({this.id, required this.staffId, required this.type, required this.amount, this.note = '', required this.dateTime});
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'staff_id': staffId, 'type': type, 'amount': amount, 'note': note,
        'date_time': dateTime.toIso8601String(),
      };
  factory SalaryPayment.fromMap(Map<String, dynamic> m) => SalaryPayment(
        id: m['id'] as int?, staffId: m['staff_id'], type: m['type'] ?? 'salary',
        amount: (m['amount'] ?? 0).toDouble(), note: m['note'] ?? '',
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
      );
}

class BankAccount {
  final int? id;
  final int businessId;
  final String bankName;
  final String accountTitle;
  final String accountNo;
  final double openingBalance;
  final int deleted;
  BankAccount({this.id, required this.businessId, required this.bankName, this.accountTitle = '', this.accountNo = '', this.openingBalance = 0, this.deleted = 0});
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'bank_name': bankName, 'account_title': accountTitle,
        'account_no': accountNo, 'opening_balance': openingBalance, 'deleted': deleted,
      };
  factory BankAccount.fromMap(Map<String, dynamic> m) => BankAccount(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1, bankName: m['bank_name'] ?? '',
        accountTitle: m['account_title'] ?? '', accountNo: m['account_no'] ?? '',
        openingBalance: (m['opening_balance'] ?? 0).toDouble(), deleted: m['deleted'] ?? 0,
      );
}

/// type: 'in' | 'out'
class BankTransaction {
  final int? id;
  final int bankId;
  final String type;
  final double amount;
  final String note;
  final DateTime dateTime;
  BankTransaction({this.id, required this.bankId, required this.type, required this.amount, this.note = '', required this.dateTime});
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'bank_id': bankId, 'type': type, 'amount': amount, 'note': note,
        'date_time': dateTime.toIso8601String(),
      };
  factory BankTransaction.fromMap(Map<String, dynamic> m) => BankTransaction(
        id: m['id'] as int?, bankId: m['bank_id'], type: m['type'],
        amount: (m['amount'] ?? 0).toDouble(), note: m['note'] ?? '',
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
      );
}

/// account: 'cash' | 'bank'
class Expense {
  final int? id;
  final int businessId;
  final String category;
  final double amount;
  final String note;
  final String account;
  final DateTime dateTime;
  Expense({this.id, required this.businessId, required this.category, required this.amount, this.note = '', this.account = 'cash', required this.dateTime});
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'category': category, 'amount': amount,
        'note': note, 'account': account, 'date_time': dateTime.toIso8601String(),
      };
  factory Expense.fromMap(Map<String, dynamic> m) => Expense(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1, category: m['category'] ?? '',
        amount: (m['amount'] ?? 0).toDouble(), note: m['note'] ?? '', account: m['account'] ?? 'cash',
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
      );
}

/// channel: 'digicash' | 'jazzcash' | 'easypaisa' | 'bank'
/// type: 'in' | 'out' | 'request' | 'send' | 'recharge'
class WalletTransaction {
  final int? id;
  final int businessId;
  final String channel;
  final String type;
  final double amount;
  final String phone;
  final String note;
  final double commission;
  final DateTime dateTime;
  WalletTransaction({
    this.id, required this.businessId, required this.channel, required this.type,
    required this.amount, this.phone = '', this.note = '', this.commission = 0, required this.dateTime,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'channel': channel, 'type': type, 'amount': amount,
        'phone': phone, 'note': note, 'commission': commission,
        'date_time': dateTime.toIso8601String(),
      };
  factory WalletTransaction.fromMap(Map<String, dynamic> m) => WalletTransaction(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1, channel: m['channel'] ?? 'digicash',
        type: m['type'] ?? 'in', amount: (m['amount'] ?? 0).toDouble(), phone: m['phone'] ?? '',
        note: m['note'] ?? '', commission: (m['commission'] ?? 0).toDouble(),
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
      );
}

/// A payment received (or requested) through the business QR code.
/// method: 'jazzcash' | 'easypaisa' | 'bank' | 'cash'
/// status: 'pending' | 'confirmed'
class QrPayment {
  final int? id;
  final int businessId;
  final int? partyId;
  final String payerName;
  final double amount;
  final String method;
  final String status;
  final String note;
  final DateTime dateTime;
  QrPayment({
    this.id, required this.businessId, this.partyId, this.payerName = '',
    required this.amount, this.method = 'jazzcash', this.status = 'pending',
    this.note = '', required this.dateTime,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'party_id': partyId, 'payer_name': payerName,
        'amount': amount, 'method': method, 'status': status, 'note': note,
        'date_time': dateTime.toIso8601String(),
      };
  factory QrPayment.fromMap(Map<String, dynamic> m) => QrPayment(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1,
        partyId: m['party_id'], payerName: m['payer_name'] ?? '',
        amount: (m['amount'] ?? 0).toDouble(), method: m['method'] ?? 'jazzcash',
        status: m['status'] ?? 'pending', note: m['note'] ?? '',
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
      );
}

/// A production batch: raw materials consumed -> finished goods produced.
/// status: 'completed' | 'cancelled' (cancelled batches keep their rows for
/// audit; their stock postings are reversed and reports exclude them).
class ProductionBatch {
  final int? id;
  final int businessId;
  final int batchNo;
  final DateTime dateTime;
  final String status;
  final String note;
  final double wastageQty;
  final String wastageNote;
  ProductionBatch({
    this.id, required this.businessId, required this.batchNo,
    required this.dateTime, this.status = 'completed', this.note = '',
    this.wastageQty = 0, this.wastageNote = '',
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId, 'batch_no': batchNo,
        'date_time': dateTime.toIso8601String(), 'status': status,
        'note': note, 'wastage_qty': wastageQty, 'wastage_note': wastageNote,
      };
  factory ProductionBatch.fromMap(Map<String, dynamic> m) => ProductionBatch(
        id: m['id'] as int?, businessId: m['business_id'] ?? 1,
        batchNo: m['batch_no'] ?? 0,
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
        status: m['status'] ?? 'completed', note: m['note'] ?? '',
        wastageQty: (m['wastage_qty'] ?? 0).toDouble(),
        wastageNote: m['wastage_note'] ?? '',
      );
}

/// One raw material consumed by a batch. [rate] is the weighted-average
/// cost snapshot taken when the batch was created; [cost] = qty * rate.
class ProductionInput {
  final int? id;
  final int batchId;
  final int itemId;
  final double qty;
  final double rate;
  final double cost;
  ProductionInput({
    this.id, required this.batchId, required this.itemId,
    required this.qty, required this.rate, required this.cost,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'batch_id': batchId, 'item_id': itemId, 'qty': qty,
        'rate': rate, 'cost': cost,
      };
  factory ProductionInput.fromMap(Map<String, dynamic> m) => ProductionInput(
        id: m['id'] as int?, batchId: m['batch_id'], itemId: m['item_id'],
        qty: (m['qty'] ?? 0).toDouble(), rate: (m['rate'] ?? 0).toDouble(),
        cost: (m['cost'] ?? 0).toDouble(),
      );
}

/// One output of a batch (finished product or sellable by-product).
/// [allocatedCost] is this output's share of the batch's total cost
/// (allocated by output quantity); [costPerUnit] = allocatedCost / qty.
class ProductionOutput {
  final int? id;
  final int batchId;
  final int itemId;
  final double qty;
  final double allocatedCost;
  final double costPerUnit;
  ProductionOutput({
    this.id, required this.batchId, required this.itemId,
    required this.qty, required this.allocatedCost, required this.costPerUnit,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'batch_id': batchId, 'item_id': itemId, 'qty': qty,
        'allocated_cost': allocatedCost, 'cost_per_unit': costPerUnit,
      };
  factory ProductionOutput.fromMap(Map<String, dynamic> m) => ProductionOutput(
        id: m['id'] as int?, batchId: m['batch_id'], itemId: m['item_id'],
        qty: (m['qty'] ?? 0).toDouble(),
        allocatedCost: (m['allocated_cost'] ?? 0).toDouble(),
        costPerUnit: (m['cost_per_unit'] ?? 0).toDouble(),
      );
}

/// One production expense line of a batch.
/// category: 'labour' | 'electricity' | 'machinery' | 'transport' | 'other'
/// These live ONLY here (never copied into the Expense Book) so a batch
/// expense is counted exactly once - inside the batch's production cost.
class ProductionExpense {
  final int? id;
  final int batchId;
  final String category;
  final double amount;
  final String note;
  final DateTime dateTime;
  ProductionExpense({
    this.id, required this.batchId, required this.category,
    required this.amount, this.note = '', required this.dateTime,
  });
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'batch_id': batchId, 'category': category, 'amount': amount,
        'note': note, 'date_time': dateTime.toIso8601String(),
      };
  factory ProductionExpense.fromMap(Map<String, dynamic> m) => ProductionExpense(
        id: m['id'] as int?, batchId: m['batch_id'],
        category: m['category'] ?? 'other',
        amount: (m['amount'] ?? 0).toDouble(), note: m['note'] ?? '',
        dateTime: DateTime.tryParse(m['date_time'] ?? '') ?? DateTime.now(),
      );
}
