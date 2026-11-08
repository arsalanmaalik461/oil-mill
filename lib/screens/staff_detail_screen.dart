import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import 'staff_form_screen.dart';

class StaffDetailScreen extends StatefulWidget {
  final Staff staff;
  const StaffDetailScreen({super.key, required this.staff});

  @override
  State<StaffDetailScreen> createState() => _StaffDetailScreenState();
}

class _StaffDetailScreenState extends State<StaffDetailScreen> {
  final _db = DatabaseHelper.instance;
  late Staff _staff;
  List<Attendance> _attendance = [];
  List<SalaryPayment> _payments = [];
  double _paidTotal = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _staff = widget.staff;
    _load();
  }

  String get _monthPrefix => DateFormat('yyyy-MM').format(DateTime.now());

  Future<void> _load() async {
    final att = await _db.getAttendance(_staff.id!, monthPrefix: _monthPrefix);
    final pays = await _db.getSalaryPayments(_staff.id!);
    final paid = await _db.getStaffPaidTotal(_staff.id!);
    if (!mounted) return;
    setState(() {
      _attendance = att;
      _payments = pays;
      _paidTotal = paid;
      _loading = false;
    });
  }

  int _count(String status) =>
      _attendance.where((a) => a.status == status).length;

  double get _overtimeTotal =>
      _attendance.fold<double>(0, (s, a) => s + a.overtimeHours);

  String _statusLabel(AppProvider p, String status) {
    switch (status) {
      case 'present':
        return p.t('present');
      case 'half':
        return p.t('halfDay');
      default:
        return p.t('absent');
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'present':
        return AppColors.green;
      case 'half':
        return AppColors.accent;
      default:
        return AppColors.red;
    }
  }

  String _typeLabel(AppProvider p, String type) {
    switch (type) {
      case 'bonus':
        return p.t('bonus');
      case 'advance':
        return p.t('advance');
      case 'overtime':
        return p.t('overtime');
      default:
        return p.t('salary');
    }
  }

  Future<void> _edit() async {
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => StaffFormScreen(staff: _staff)),
    );
    if (done == true && mounted) {
      // Reload salary/name via the staff list (no single-getter in the API).
      final list = await _db.getStaffList(_staff.businessId);
      if (!mounted) return;
      final fresh = list.where((s) => s.id == _staff.id);
      if (fresh.isNotEmpty) setState(() => _staff = fresh.first);
      _load();
    }
  }

  Future<void> _delete() async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await _db.setStaffDeleted(_staff.id!, true);
    if (!mounted) return;
    showSnack(context, p.t('deleted'));
    Navigator.pop(context);
  }

  Future<void> _paySalary() async {
    final p = context.read<AppProvider>();
    var type = 'salary';
    final amountCtrl =
        TextEditingController(text: _fmtNum(_staff.monthlySalary));
    final noteCtrl = TextEditingController();
    var when = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(p.t('paySalary')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: InputDecoration(labelText: p.t('status')),
                  items: ['salary', 'bonus', 'advance', 'overtime']
                      .map((t) => DropdownMenuItem(
                          value: t, child: Text(_typeLabel(p, t))))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setLocal(() {
                      type = v;
                      if (v == 'salary') {
                        amountCtrl.text = _fmtNum(_staff.monthlySalary);
                      }
                    });
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: p.t('amount')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: noteCtrl,
                  decoration: InputDecoration(labelText: p.t('note')),
                ),
                const SizedBox(height: 6),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_month,
                      color: AppColors.primary),
                  title: Text(dateTimeFmt.format(when)),
                  onTap: () async {
                    final dt = await pickDateTime(c, when);
                    if (dt != null) setLocal(() => when = dt);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text(p.t('cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(p.t('save'))),
          ],
        ),
      ),
    );
    final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
    final note = noteCtrl.text.trim();
    amountCtrl.dispose();
    noteCtrl.dispose();
    if (ok != true || !mounted) return;
    if (amount <= 0) {
      showSnack(context, p.t('invalidAmount'));
      return;
    }
    await _db.insertSalaryPayment(SalaryPayment(
      staffId: _staff.id!,
      type: type,
      amount: amount,
      note: note,
      dateTime: when,
    ));
    if (!mounted) return;
    showSnack(context, p.t('savedSuccessfully'));
    _load();
  }

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Widget _summaryTile(String label, String value, {Color? color}) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: color ?? Colors.black87)),
          const SizedBox(height: 2),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.textGrey)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final monthName = DateFormat('MMMM yyyy').format(DateTime.now());
    return Scaffold(
      appBar: AppBar(
        title: Text(_staff.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: p.t('edit'),
            onPressed: _edit,
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: p.t('delete'),
            onPressed: _delete,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(monthName,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            _summaryTile(p.t('present'), '${_count('present')}',
                                color: AppColors.green),
                            _summaryTile(p.t('absent'), '${_count('absent')}',
                                color: AppColors.red),
                            _summaryTile(p.t('halfDay'), '${_count('half')}',
                                color: AppColors.accent),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            _summaryTile(p.t('overtime'),
                                '${formatQty(_overtimeTotal)} ${p.t('hours')}'),
                            _summaryTile(p.t('monthlySalary'),
                                formatRs(_staff.monthlySalary)),
                            _summaryTile(
                                p.t('paid'), formatRs(_paidTotal)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _paySalary,
                    icon: const Icon(Icons.payments, size: 18),
                    label: Text(p.t('paySalary')),
                  ),
                ),
                const SizedBox(height: 16),
                Text(p.t('attendance'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                if (_attendance.isEmpty)
                  Text(p.t('noData'),
                      style: const TextStyle(color: AppColors.textGrey))
                else
                  ..._attendance.map(
                    (a) => Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.event_available,
                            color: _statusColor(a.status)),
                        title: Text(a.date),
                        subtitle: a.overtimeHours > 0
                            ? Text(
                                '${p.t('overtime')}: ${formatQty(a.overtimeHours)} ${p.t('hours')}')
                            : null,
                        trailing: Text(_statusLabel(p, a.status),
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _statusColor(a.status))),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(p.t('paymentHistory'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                if (_payments.isEmpty)
                  Text(p.t('noData'),
                      style: const TextStyle(color: AppColors.textGrey))
                else
                  ..._payments.map(
                    (pay) => Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        dense: true,
                        leading: const CircleAvatar(
                          backgroundColor: Color(0xFFFFF3E8),
                          child:
                              Icon(Icons.payments, color: AppColors.accent),
                        ),
                        title: Text(_typeLabel(p, pay.type),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          '${dateTimeFmt.format(pay.dateTime)}${pay.note.isNotEmpty ? ' • ${pay.note}' : ''}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: AmountText(pay.amount),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
