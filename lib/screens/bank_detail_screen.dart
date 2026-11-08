import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';

class BankDetailScreen extends StatefulWidget {
  final BankAccount account;
  const BankDetailScreen({super.key, required this.account});

  @override
  State<BankDetailScreen> createState() => _BankDetailScreenState();
}

class _BankDetailScreenState extends State<BankDetailScreen> {
  final _db = DatabaseHelper.instance;
  List<BankTransaction> _txns = [];
  double _balance = 0;
  bool _loading = true;

  BankAccount get _account => widget.account;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final txns = await _db.getBankTransactions(_account.id!);
    final balance = await _db.getBankBalance(_account.id!);
    if (!mounted) return;
    setState(() {
      _txns = txns;
      _balance = balance;
      _loading = false;
    });
  }

  Future<void> _exportPdf() async {
    final p = context.read<AppProvider>();
    final businesses = await _db.getBusinesses();
    if (!mounted || businesses.isEmpty) return;
    final business = businesses.firstWhere(
      (b) => b.id == p.businessId,
      orElse: () => businesses.first,
    );
    await shareReportPdf(
      business: business,
      title: '${_account.bankName} — ${p.t('bankBook')}',
      headers: [p.t('date'), p.t('note'), p.t('in'), p.t('out')],
      rows: _txns
          .map((t) => [
                dateTimeFmt.format(t.dateTime),
                t.note,
                t.type == 'in' ? formatRs(t.amount) : '',
                t.type == 'out' ? formatRs(t.amount) : '',
              ])
          .toList(),
      summaryLine: '${p.t('bankBalance')}: ${formatRs(_balance)}',
    );
  }

  Future<void> _addTransaction(String type) async {
    final p = context.read<AppProvider>();
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var when = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(type == 'in' ? p.t('moneyIn') : p.t('moneyOut')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: p.t('amount')),
                  autofocus: true,
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
    await _db.insertBankTransaction(BankTransaction(
      bankId: _account.id!,
      type: type,
      amount: amount,
      note: note,
      dateTime: when,
    ));
    if (!mounted) return;
    showSnack(context, p.t('savedSuccessfully'));
    _load();
  }

  Future<void> _deleteTransaction(BankTransaction t) async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await _db.deleteBankTransaction(t.id!);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_account.bankName),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: p.t('downloadPdf'),
            onPressed: _exportPdf,
          ),
        ],
      ),
      body: Column(
        children: [
          GradientHeader(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.t('bankBalance'),
                        style: const TextStyle(color: AppColors.textGrey)),
                    const SizedBox(height: 4),
                    Text(formatRs(_balance),
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w800)),
                    if (_account.accountTitle.isNotEmpty ||
                        _account.accountNo.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          [
                            if (_account.accountTitle.isNotEmpty)
                              _account.accountTitle,
                            if (_account.accountNo.isNotEmpty)
                              _account.accountNo,
                          ].join(' • '),
                          style: const TextStyle(color: AppColors.textGrey),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.green),
                    onPressed: () => _addTransaction('in'),
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    label: Text(p.t('moneyIn')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.red),
                    onPressed: () => _addTransaction('out'),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    label: Text(p.t('moneyOut')),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _txns.isEmpty
                    ? Center(child: Text(p.t('noData')))
                    : ListView.builder(
                        itemCount: _txns.length,
                        itemBuilder: (context, i) {
                          final t = _txns[i];
                          final isIn = t.type == 'in';
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isIn
                                    ? const Color(0xFFE5F6EC)
                                    : const Color(0xFFFDE8E8),
                                child: Icon(
                                  isIn
                                      ? Icons.arrow_downward
                                      : Icons.arrow_upward,
                                  color:
                                      isIn ? AppColors.green : AppColors.red,
                                ),
                              ),
                              title: Text(
                                t.note.isEmpty
                                    ? (isIn ? p.t('moneyIn') : p.t('moneyOut'))
                                    : t.note,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(dateTimeFmt.format(t.dateTime),
                                  style: const TextStyle(fontSize: 12)),
                              trailing: Text(
                                '${isIn ? '+' : '−'} ${formatRs(t.amount)}',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color:
                                      isIn ? AppColors.green : AppColors.red,
                                ),
                              ),
                              onLongPress: () => _deleteTransaction(t),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
