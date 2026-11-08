import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _ExpenseData {
  final List<ProductionExpense> expenses;
  final Map<String, double> totalsByCategory;
  final Map<int, int> batchNoById;
  final double grandTotal;
  _ExpenseData(
      this.expenses, this.totalsByCategory, this.batchNoById, this.grandTotal);
}

/// Production Expenses register: every expense line of every completed
/// production batch, summarised by category. These amounts live ONLY in
/// the batches (they are part of each batch's production cost) and are
/// never copied into the Expense Book, so they can never be counted
/// twice in profit reports. Expenses are added inside a batch; this
/// screen is the register / report view.
class ProductionExpensesScreen extends StatefulWidget {
  const ProductionExpensesScreen({super.key});

  @override
  State<ProductionExpensesScreen> createState() =>
      _ProductionExpensesScreenState();
}

class _ProductionExpensesScreenState extends State<ProductionExpensesScreen> {
  late Future<_ExpenseData> _future;

  static const _categories = [
    'labour',
    'electricity',
    'machinery',
    'transport',
    'other',
  ];

  @override
  void initState() {
    super.initState();
    _future = _load(context.read<AppProvider>().businessId);
  }

  String _catLabel(AppProvider p, String cat) {
    switch (cat) {
      case 'labour':
        return p.t('prodLabour');
      case 'electricity':
        return p.t('prodElectricity');
      case 'machinery':
        return p.t('prodMachinery');
      case 'transport':
        return p.t('prodTransport');
      default:
        return p.t('prodOther');
    }
  }

  IconData _catIcon(String cat) {
    switch (cat) {
      case 'labour':
        return Icons.groups;
      case 'electricity':
        return Icons.electric_bolt;
      case 'machinery':
        return Icons.precision_manufacturing;
      case 'transport':
        return Icons.local_shipping;
      default:
        return Icons.more_horiz;
    }
  }

  Future<_ExpenseData> _load(int bizId) async {
    final db = DatabaseHelper.instance;
    final expenses = await db.getAllProductionExpenses(bizId);
    final batches = await db.getProductionBatches(bizId);
    final batchNoById = <int, int>{
      for (final b in batches)
        if (b.id != null) b.id!: b.batchNo,
    };
    final totals = <String, double>{for (final c in _categories) c: 0};
    var grand = 0.0;
    for (final e in expenses) {
      final key = _categories.contains(e.category) ? e.category : 'other';
      totals[key] = (totals[key] ?? 0) + e.amount;
      grand += e.amount;
    }
    return _ExpenseData(expenses, totals, batchNoById, grand);
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('prodExpenses'))),
      body: FutureBuilder<_ExpenseData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data ?? _ExpenseData(const [], const {}, const {}, 0);
          if (d.expenses.isEmpty) {
            return Center(child: Text(p.t('noData')));
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.55,
                children: [
                  ..._categories.map(
                    (c) => _statCard(
                      _catLabel(p, c),
                      formatRs(d.totalsByCategory[c] ?? 0),
                      _catIcon(c),
                      AppColors.accent,
                    ),
                  ),
                  _statCard(
                    p.t('total'),
                    formatRs(d.grandTotal),
                    Icons.summarize,
                    AppColors.primary,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'These expenses are counted inside each batch\'s production '
                'cost — they are not entered in the Expense Book, so they '
                'are never double-counted in profit.',
                style: TextStyle(fontSize: 12, color: AppColors.textGrey),
              ),
              const SizedBox(height: 6),
              ...d.expenses.map(
                (e) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          AppColors.accent.withValues(alpha: 0.15),
                      child: Icon(_catIcon(e.category),
                          color: AppColors.accent, size: 20),
                    ),
                    title: Text(
                      _catLabel(p, e.category),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      [
                        if (d.batchNoById[e.batchId] != null)
                          '${p.t('batchNo')} ${d.batchNoById[e.batchId]}',
                        if (e.note.isNotEmpty) e.note,
                        dateTimeFmt.format(e.dateTime),
                      ].join(' • '),
                    ),
                    trailing: Text(
                      formatRs(e.amount),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
