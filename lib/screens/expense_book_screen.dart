import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';

class ExpenseBookScreen extends StatefulWidget {
  const ExpenseBookScreen({super.key});

  @override
  State<ExpenseBookScreen> createState() => _ExpenseBookScreenState();
}

class _ExpenseBookScreenState extends State<ExpenseBookScreen> {
  final _db = DatabaseHelper.instance;
  List<Expense> _expenses = [];
  Map<String, double> _byCategory = {};
  double _monthTotal = 0;
  bool _loading = true;

  static const _suggestions = [
    'Fuel',
    'Labour',
    'Rent',
    'Electricity',
    'Maintenance',
    'Transport',
    'Food',
    'Misc',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bizId = context.read<AppProvider>().businessId;
    final expenses = await _db.getExpenses(bizId);
    final byCat = await _db.getExpenseByCategory(bizId);
    final monthTotal = await _db.getExpenseTotal(bizId, month: DateTime.now());
    if (!mounted) return;
    setState(() {
      _expenses = expenses;
      _byCategory = byCat;
      _monthTotal = monthTotal;
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
    final total = _expenses.fold<double>(0, (s, e) => s + e.amount);
    await shareReportPdf(
      business: business,
      title: p.t('expenseBook'),
      headers: [p.t('date'), p.t('category'), p.t('note'), p.t('amount')],
      rows: _expenses
          .map((e) => [
                dateTimeFmt.format(e.dateTime),
                e.category,
                e.note,
                formatRs(e.amount),
              ])
          .toList(),
      summaryLine: '${p.t('total')}: ${formatRs(total)}',
    );
  }

  Future<void> _addExpense([Expense? existing]) async {
    final p = context.read<AppProvider>();
    final categoryCtrl = TextEditingController(text: existing?.category ?? '');
    final amountCtrl = TextEditingController(
        text: existing == null
            ? ''
            : (existing.amount == existing.amount.roundToDouble()
                ? existing.amount.toStringAsFixed(0)
                : existing.amount.toString()));
    final noteCtrl = TextEditingController(text: existing?.note ?? '');
    var account = existing?.account ?? 'cash';
    var kind = existing?.kind ?? 'operating';
    var when = existing?.dateTime ?? DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(existing == null ? p.t('addExpense') : p.t('editEntry')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: _suggestions
                      .map((s) => ActionChip(
                            label: Text(s),
                            onPressed: () => setLocal(() {
                              categoryCtrl.text = s;
                              categoryCtrl.selection =
                                  TextSelection.collapsed(offset: s.length);
                            }),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: categoryCtrl,
                  decoration: InputDecoration(labelText: p.t('category')),
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
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: account,
                  decoration: InputDecoration(labelText: p.t('channel')),
                  items: [
                    DropdownMenuItem(
                        value: 'cash', child: Text(p.t('cashInHand'))),
                    DropdownMenuItem(
                        value: 'bank', child: Text(p.t('bank'))),
                  ],
                  onChanged: (v) {
                    if (v != null) setLocal(() => account = v);
                  },
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration: InputDecoration(labelText: p.t('expKind')),
                  items: [
                    DropdownMenuItem(
                        value: 'operating', child: Text(p.t('kindOperating'))),
                    DropdownMenuItem(
                        value: 'owner', child: Text(p.t('kindOwner'))),
                    DropdownMenuItem(
                        value: 'loan', child: Text(p.t('kindLoan'))),
                    DropdownMenuItem(
                        value: 'transfer', child: Text(p.t('kindTransfer'))),
                  ],
                  onChanged: (v) {
                    if (v != null) setLocal(() => kind = v);
                  },
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
    final category = categoryCtrl.text.trim();
    final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
    final note = noteCtrl.text.trim();
    categoryCtrl.dispose();
    amountCtrl.dispose();
    noteCtrl.dispose();
    if (ok != true || !mounted) return;
    if (category.isEmpty) {
      showSnack(context, p.t('requiredField'));
      return;
    }
    if (amount <= 0) {
      showSnack(context, p.t('invalidAmount'));
      return;
    }
    final entry = Expense(
      id: existing?.id,
      businessId: p.businessId,
      category: category,
      amount: amount,
      note: note,
      account: account,
      kind: kind,
      dateTime: when,
    );
    if (existing == null) {
      await _db.insertExpense(entry);
    } else {
      // The linked cash entry follows the edit automatically.
      await _db.updateExpense(entry);
    }
    if (!mounted) return;
    showSnack(context, p.t('savedSuccessfully'));
    _load();
  }

  Future<void> _deleteExpense(Expense e) async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await _db.deleteExpense(e.id!);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final categories = _byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Scaffold(
      appBar: AppBar(
        title: Text(p.t('expenseBook')),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: p.t('downloadPdf'),
            onPressed: _exportPdf,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addExpense,
        icon: const Icon(Icons.add),
        label: Text(p.t('addExpense')),
      ),
      body: Column(
        children: [
          GradientHeader(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${p.t('thisMonth')} — ${p.t('expenses')}',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        Text(formatRs(_monthTotal),
                            style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: AppColors.red)),
                      ],
                    ),
                  ),
                ),
                if (categories.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: categories
                        .map((e) => Chip(
                              backgroundColor: Colors.white,
                              label: Text(
                                  '${e.key} • ${formatRs(e.value)}',
                                  style: const TextStyle(fontSize: 12)),
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _expenses.isEmpty
                    ? Center(child: Text(p.t('noData')))
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 90),
                        itemCount: _expenses.length,
                        itemBuilder: (context, i) {
                          final e = _expenses[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: ListTile(
                              leading: const CircleAvatar(
                                backgroundColor: Color(0xFFFFF3E8),
                                child: Icon(Icons.category,
                                    color: AppColors.accent),
                              ),
                              title: Text(
                                e.note.isEmpty
                                    ? e.category
                                    : '${e.category} — ${e.note}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                '${dateTimeFmt.format(e.dateTime)} • ${e.account == 'bank' ? p.t('bank') : p.t('cashInHand')}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Text(formatRs(e.amount),
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.red)),
                              onTap: () => _addExpense(e),
                              onLongPress: () => _deleteExpense(e),
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
