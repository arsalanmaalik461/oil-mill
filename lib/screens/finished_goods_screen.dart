import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _FinishedRow {
  final StockItem item;
  final double produced;
  final double sold;
  final double remaining;
  final double unitCost;
  double get value => remaining * unitCost;
  _FinishedRow({
    required this.item,
    required this.produced,
    required this.sold,
    required this.remaining,
    required this.unitCost,
  });
}

class _FinishedData {
  final List<_FinishedRow> rows;
  final List<Party> parties;
  final double totalValue;
  _FinishedData(this.rows, this.parties, this.totalValue);
}

/// Finished Goods: products manufactured by production batches
/// (StockItem.kind == 'finished'). Produced qty comes from the outputs
/// of completed batches, sold qty from bills, remaining from the stock
/// ledger; valuation uses the standard unit cost (production average
/// cost, falling back to weighted-average purchase cost).
class FinishedGoodsScreen extends StatefulWidget {
  const FinishedGoodsScreen({super.key});

  @override
  State<FinishedGoodsScreen> createState() => _FinishedGoodsScreenState();
}

class _FinishedGoodsScreenState extends State<FinishedGoodsScreen> {
  late Future<_FinishedData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load(context.read<AppProvider>().businessId);
  }

  Future<_FinishedData> _load(int bizId) async {
    final db = DatabaseHelper.instance;
    final items = (await db.getItems(bizId))
        .where((i) => i.kind == 'finished' && i.id != null)
        .toList();

    // Produced qty per item = sum of outputs of completed batches.
    final producedByItem = <int, double>{};
    final batches = await db.getProductionBatches(bizId);
    for (final b in batches) {
      if (b.status != 'completed' || b.id == null) continue;
      for (final o in await db.getBatchOutputs(b.id!)) {
        producedByItem[o.itemId] = (producedByItem[o.itemId] ?? 0) + o.qty;
      }
    }

    final parties = await db.getParties(bizId);
    final rows = <_FinishedRow>[];
    var totalValue = 0.0;
    for (final item in items) {
      final id = item.id!;
      final sold = await db.getItemSoldQty(id);
      final remaining = await db.getItemQty(id);
      final unitCost = await db.getItemUnitCost(id);
      final row = _FinishedRow(
        item: item,
        produced: producedByItem[id] ?? 0,
        sold: sold,
        remaining: remaining,
        unitCost: unitCost,
      );
      totalValue += row.value;
      rows.add(row);
    }
    rows.sort((a, b) => b.value.compareTo(a.value));
    return _FinishedData(rows, parties, totalValue);
  }

  void _reload() {
    setState(() {
      _future = _load(context.read<AppProvider>().businessId);
    });
  }

  Future<void> _salesReturn(_FinishedRow row, List<Party> parties) async {
    final p = context.read<AppProvider>();
    final qtyC = TextEditingController();
    final rateC = TextEditingController();
    Party? party;
    var refund = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('${p.t('salesReturn')} — ${row.item.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: qtyC,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: '${p.t('quantity')} (${row.item.unit})',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: rateC,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: p.t('rate')),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<Party?>(
                  initialValue: party,
                  decoration: InputDecoration(labelText: p.t('customers')),
                  items: [
                    DropdownMenuItem<Party?>(
                      value: null,
                      child: Text(p.t('none')),
                    ),
                    ...parties.map(
                      (pt) => DropdownMenuItem<Party?>(
                        value: pt,
                        child: Text(pt.name),
                      ),
                    ),
                  ],
                  onChanged: (v) => setD(() => party = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Refund paid amount'),
                  value: refund,
                  onChanged: (v) => setD(() => refund = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(p.t('cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(p.t('save')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final qty = double.tryParse(qtyC.text.trim()) ?? 0;
    final rate = double.tryParse(rateC.text.trim()) ?? 0;
    if (qty <= 0 || rate < 0) {
      showSnack(context, p.t('invalidAmount'));
      return;
    }
    final db = DatabaseHelper.instance;
    final bizId = p.businessId;
    final now = DateTime.now();
    final amount = qty * rate;
    // Goods come back into finished stock.
    await db.insertStockTransaction(StockTransaction(
      itemId: row.item.id!,
      type: 'in',
      qty: qty,
      rate: rate,
      note: 'Sales return',
      dateTime: now,
    ));
    // The customer's outstanding udhaar drops by the returned amount.
    if (party != null && amount > 0) {
      await db.insertPartyTransaction(PartyTransaction(
        partyId: party!.id!,
        type: 'wasool',
        amount: amount,
        note: 'Sales return',
        dateTime: now,
      ));
    }
    // Cash actually handed back to the customer.
    if (refund && amount > 0) {
      await db.insertCashEntry(CashEntry(
        businessId: bizId,
        type: 'out',
        amount: amount,
        note: 'Sales return refund',
        partyId: party?.id,
        dateTime: now,
      ));
    }
    if (!mounted) return;
    p.bump();
    showSnack(context, p.t('salesReturn'));
    _reload();
  }

  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.only(right: 14, top: 2),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$label: ',
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textGrey),
              ),
              TextSpan(
                text: value,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('finishedGoods'))),
      body: FutureBuilder<_FinishedData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data ?? _FinishedData(const [], const [], 0);
          if (d.rows.isEmpty) {
            return Center(child: Text(p.t('noData')));
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                color: AppColors.primary,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.inventory_2,
                          color: Colors.white, size: 28),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.t('totalStockValue'),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                          ),
                          Text(
                            formatRs(d.totalValue),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ...d.rows.map(
                (row) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      row.item.name,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (row.item.category.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Chip(
                                      label: Text(row.item.category,
                                          style: const TextStyle(fontSize: 10)),
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                children: [
                                  _kv(p.t('producedQty'),
                                      '${formatQty(row.produced)} ${row.item.unit}'),
                                  _kv(p.t('soldQty'),
                                      '${formatQty(row.sold)} ${row.item.unit}'),
                                  _kv(p.t('remainingQty'),
                                      '${formatQty(row.remaining)} ${row.item.unit}'),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${p.t('cogs')}: ${formatRs(row.unitCost)} / ${row.item.unit}'
                                '  •  ${p.t('stockValue')}: ${formatRs(row.value)}',
                                style: const TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: p.t('salesReturn'),
                          icon: const Icon(Icons.assignment_return,
                              color: AppColors.primary),
                          onPressed: () => _salesReturn(row, d.parties),
                        ),
                      ],
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
