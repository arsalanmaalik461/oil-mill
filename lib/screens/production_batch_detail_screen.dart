import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _BatchDetail {
  final ProductionBatch batch;
  final List<ProductionInput> inputs;
  final List<ProductionOutput> outputs;
  final List<ProductionExpense> expenses;
  final Map<int, StockItem> itemById;
  _BatchDetail(
      this.batch, this.inputs, this.outputs, this.expenses, this.itemById);

  double get materialCost => inputs.fold<double>(0, (s, i) => s + i.cost);
  double get expenseTotal => expenses.fold<double>(0, (s, e) => s + e.amount);
  double get totalCost => materialCost + expenseTotal;
}

/// One production batch in full: materials consumed (at their WAC
/// snapshot), expenses, total production cost and the outputs with their
/// allocated cost per unit. Cancelling reverses every stock posting.
class ProductionBatchDetailScreen extends StatefulWidget {
  final int batchId;
  const ProductionBatchDetailScreen({super.key, required this.batchId});

  @override
  State<ProductionBatchDetailScreen> createState() =>
      _ProductionBatchDetailScreenState();
}

class _ProductionBatchDetailScreenState
    extends State<ProductionBatchDetailScreen> {
  final _db = DatabaseHelper.instance;
  late Future<_BatchDetail?> _future;
  bool _cancelling = false;

  static const _expenseKeys = {
    'labour': 'prodLabour',
    'electricity': 'prodElectricity',
    'machinery': 'prodMachinery',
    'transport': 'prodTransport',
    'other': 'prodOther',
  };

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_BatchDetail?> _load() async {
    final bizId = context.read<AppProvider>().businessId;
    final batches = await _db.getProductionBatches(bizId);
    ProductionBatch? batch;
    for (final b in batches) {
      if (b.id == widget.batchId) {
        batch = b;
        break;
      }
    }
    if (batch == null) return null;
    final inputs = await _db.getBatchInputs(widget.batchId);
    final outputs = await _db.getBatchOutputs(widget.batchId);
    final expenses = await _db.getBatchExpenses(widget.batchId);
    final items = await _db.getItems(bizId);
    return _BatchDetail(batch, inputs, outputs, expenses,
        {for (final i in items) if (i.id != null) i.id!: i});
  }

  void _reload() {
    setState(() => _future = _load());
  }

  Future<void> _cancelBatch(AppProvider p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        title: Text(p.t('cancelBatch')),
        content: const Text(
            'This will reverse all stock postings of this batch (materials back in, finished goods back out).'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dc, false),
            child: Text(p.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dc, true),
            child: Text(p.t('cancelBatch')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _cancelling = true);
    try {
      await _db.cancelProductionBatch(widget.batchId);
      if (!mounted) return;
      showSnack(context, p.t('batchCancelled'));
      _reload();
    } catch (e) {
      if (!mounted) return;
      showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      );

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(value,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                    fontSize: bold ? 16 : 14)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('production'))),
      body: FutureBuilder<_BatchDetail?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data;
          if (d == null) return Center(child: Text(p.t('noData')));
          final b = d.batch;
          final isDone = b.status == 'completed';
          final mainOut = d.outputs.isNotEmpty ? d.outputs.first : null;
          final mainItem =
              mainOut != null ? d.itemById[mainOut.itemId] : null;
          final kgFactor =
              mainItem != null ? unitToKgFactor(mainItem.unit) : 1.0;
          final perKg = (mainOut != null && kgFactor > 0)
              ? mainOut.costPerUnit / kgFactor
              : 0.0;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---------------- Header ----------------
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('${p.t('batchNo')} ${b.batchNo}',
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w800)),
                            const Spacer(),
                            Chip(
                              label: Text(isDone ? 'Completed' : 'Cancelled',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isDone
                                          ? AppColors.green
                                          : AppColors.textGrey)),
                              backgroundColor: (isDone
                                      ? AppColors.green
                                      : AppColors.textGrey)
                                  .withValues(alpha: 0.12),
                              side: BorderSide.none,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(dateTimeFmt.format(b.dateTime),
                            style:
                                const TextStyle(color: AppColors.textGrey)),
                        if (!isDone) ...[
                          const SizedBox(height: 8),
                          Text(p.t('batchCancelled'),
                              style: const TextStyle(
                                  color: AppColors.textGrey, fontSize: 12)),
                        ],
                        if (b.note.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(b.note),
                        ],
                      ],
                    ),
                  ),
                ),

                // ---------------- Inputs ----------------
                _sectionTitle(p.t('rawMaterial')),
                Card(
                  child: Column(
                    children: [
                      for (final inp in d.inputs)
                        ListTile(
                          dense: true,
                          title: Text(
                              d.itemById[inp.itemId]?.name ?? '?'),
                          subtitle: Text(
                              '${formatQty(inp.qty)} ${d.itemById[inp.itemId]?.unit ?? ''} × ${formatRs(inp.rate)}'),
                          trailing: Text(formatRs(inp.cost),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                        ),
                      if (d.inputs.isEmpty)
                        ListTile(dense: true, title: Text(p.t('noData'))),
                    ],
                  ),
                ),

                // ---------------- Expenses ----------------
                _sectionTitle(p.t('prodExpenses')),
                Card(
                  child: Column(
                    children: [
                      for (final e in d.expenses)
                        ListTile(
                          dense: true,
                          title:
                              Text(p.t(_expenseKeys[e.category] ?? 'prodOther')),
                          subtitle: e.note.isEmpty ? null : Text(e.note),
                          trailing: Text(formatRs(e.amount),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                        ),
                      if (d.expenses.isEmpty)
                        ListTile(dense: true, title: Text(p.t('noData'))),
                    ],
                  ),
                ),

                // ---------------- Totals ----------------
                Card(
                  color: AppColors.primary.withValues(alpha: 0.06),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        _row(p.t('materialCost'), formatRs(d.materialCost)),
                        _row(p.t('prodExpenses'), formatRs(d.expenseTotal)),
                        const Divider(),
                        _row(p.t('totalProdCost'), formatRs(d.totalCost),
                            bold: true),
                      ],
                    ),
                  ),
                ),

                // ---------------- Outputs ----------------
                _sectionTitle(p.t('finishedProduct')),
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < d.outputs.length; i++)
                        ListTile(
                          dense: true,
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                    d.itemById[d.outputs[i].itemId]?.name ??
                                        '?'),
                              ),
                              if (i > 0)
                                Chip(
                                  label: Text(p.t('byProduct'),
                                      style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600)),
                                  backgroundColor: AppColors.accent
                                      .withValues(alpha: 0.15),
                                  visualDensity: VisualDensity.compact,
                                  side: BorderSide.none,
                                ),
                            ],
                          ),
                          subtitle: Text(
                              '${formatQty(d.outputs[i].qty)} ${d.itemById[d.outputs[i].itemId]?.unit ?? ''} • ${formatRs(d.outputs[i].costPerUnit)} / unit'),
                          trailing: Text(
                              formatRs(d.outputs[i].allocatedCost),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                        ),
                      if (d.outputs.isEmpty)
                        ListTile(dense: true, title: Text(p.t('noData'))),
                    ],
                  ),
                ),

                // -------- Main output cost conversions --------
                if (mainOut != null && mainItem != null) ...[
                  _sectionTitle(mainItem.name),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: [
                          _row('Cost per ${mainItem.unit}',
                              formatRs(mainOut.costPerUnit)),
                          _row(p.t('costPerKg'), formatRs(perKg)),
                          _row(p.t('costPer40Kg'), formatRs(perKg * 40)),
                          _row(p.t('costPerTon'), formatRs(perKg * 1000)),
                        ],
                      ),
                    ),
                  ),
                ],

                // ---------------- Wastage ----------------
                if (b.wastageQty > 0) ...[
                  _sectionTitle(p.t('wastage')),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.delete_outline,
                          color: AppColors.accent),
                      title: Text(formatQty(b.wastageQty)),
                      subtitle:
                          b.wastageNote.isEmpty ? null : Text(b.wastageNote),
                    ),
                  ),
                ],

                // ---------------- Cancel ----------------
                if (isDone) ...[
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed:
                          _cancelling ? null : () => _cancelBatch(p),
                      icon: const Icon(Icons.cancel_outlined,
                          color: AppColors.red),
                      label: Text(p.t('cancelBatch'),
                          style: const TextStyle(color: AppColors.red)),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }
}
