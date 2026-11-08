import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import 'production_batch_detail_screen.dart';
import 'production_batch_form_screen.dart';

class _BatchRow {
  final ProductionBatch batch;
  final String mainOutput;
  final double totalCost;
  _BatchRow(this.batch, this.mainOutput, this.totalCost);
}

/// Production batches list. Completed batches are the live production
/// record; cancelled batches stay visible as the audit/history trail
/// (their stock postings were reversed by cancelProductionBatch).
class ProductionBatchesScreen extends StatefulWidget {
  const ProductionBatchesScreen({super.key});

  @override
  State<ProductionBatchesScreen> createState() =>
      _ProductionBatchesScreenState();
}

class _ProductionBatchesScreenState extends State<ProductionBatchesScreen> {
  final _db = DatabaseHelper.instance;
  late Future<List<_BatchRow>> _future;
  String _filter = 'all'; // all | completed | cancelled

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_BatchRow>> _load() async {
    final bizId = context.read<AppProvider>().businessId;
    final batches = await _db.getProductionBatches(bizId);
    final items = await _db.getItems(bizId);
    final itemById = {for (final i in items) i.id: i};
    final rows = <_BatchRow>[];
    for (final b in batches) {
      if (b.id == null) continue;
      final outputs = await _db.getBatchOutputs(b.id!);
      final inputs = await _db.getBatchInputs(b.id!);
      final expenses = await _db.getBatchExpenses(b.id!);
      var main = '';
      if (outputs.isNotEmpty) {
        final o = outputs.first;
        final item = itemById[o.itemId];
        final unit = item?.unit ?? '';
        main = '${item?.name ?? '?'} • ${formatQty(o.qty)} $unit';
      }
      final total = inputs.fold<double>(0, (s, i) => s + i.cost) +
          expenses.fold<double>(0, (s, e) => s + e.amount);
      rows.add(_BatchRow(b, main, total));
    }
    return rows;
  }

  void _reload() {
    setState(() => _future = _load());
  }

  Future<void> _newBatch() async {
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ProductionBatchFormScreen()),
    );
    if (done == true && mounted) _reload();
  }

  Widget _statusChip(String status) {
    final isDone = status == 'completed';
    return Chip(
      label: Text(isDone ? 'Completed' : 'Cancelled',
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDone ? AppColors.green : AppColors.textGrey)),
      backgroundColor: (isDone ? AppColors.green : AppColors.textGrey)
          .withValues(alpha: 0.12),
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('prodBatches'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newBatch,
        icon: const Icon(Icons.add),
        label: Text(p.t('newBatch')),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                ChoiceChip(
                  label: Text(p.t('all')),
                  selected: _filter == 'all',
                  onSelected: (_) => setState(() => _filter = 'all'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Completed'),
                  selected: _filter == 'completed',
                  onSelected: (_) => setState(() => _filter = 'completed'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Cancelled'),
                  selected: _filter == 'cancelled',
                  onSelected: (_) => setState(() => _filter = 'cancelled'),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<_BatchRow>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final all = snap.data ?? const <_BatchRow>[];
                final rows = _filter == 'all'
                    ? all
                    : all.where((r) => r.batch.status == _filter).toList();
                if (rows.isEmpty) {
                  return Center(child: Text(p.t('noData')));
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    final b = r.batch;
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              AppColors.primary.withValues(alpha: 0.12),
                          child: Text('#${b.batchNo}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w700)),
                        ),
                        title: Text(
                          r.mainOutput.isEmpty
                              ? '${p.t('batchNo')} ${b.batchNo}'
                              : r.mainOutput,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(dateFmt.format(b.dateTime)),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(formatRs(r.totalCost),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            _statusChip(b.status),
                          ],
                        ),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ProductionBatchDetailScreen(
                                  batchId: b.id!),
                            ),
                          );
                          if (mounted) _reload();
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
