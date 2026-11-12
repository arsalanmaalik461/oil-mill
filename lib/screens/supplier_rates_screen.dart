import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';

final _fmt = NumberFormat.decimalPattern('en_IN');
String _rs(double v) => 'Rs ${_fmt.format(v)}';
String _qty(double v) =>
    v == v.roundToDouble() ? _fmt.format(v.toInt()) : v.toStringAsFixed(2);

/// Supplier Rate Comparison: for one item, every supplier who sold it
/// — last rate, average, min/max, total quantity — cheapest first, so
/// the owner sees at a glance where the next purchase is cheapest.
class SupplierRatesScreen extends StatefulWidget {
  const SupplierRatesScreen({super.key});

  @override
  State<SupplierRatesScreen> createState() => _SupplierRatesScreenState();
}

class _SupplierRatesScreenState extends State<SupplierRatesScreen> {
  final _db = DatabaseHelper.instance;
  late Future<List<StockItem>> _itemsFuture;
  int? _itemId;

  @override
  void initState() {
    super.initState();
    _itemsFuture = _loadItems();
  }

  Future<List<StockItem>> _loadItems() async {
    final p = context.read<AppProvider>();
    final items = await _db.getPurchasedItems(p.businessId);
    if (items.isNotEmpty && _itemId == null) {
      _itemId = items.first.id;
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('supplierRates'))),
      body: FutureBuilder<List<StockItem>>(
        future: _itemsFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return Center(child: Text(p.t('noSupplierPurchases')));
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: DropdownButtonFormField<int>(
                  value: _itemId,
                  decoration:
                      InputDecoration(labelText: p.t('selectItem')),
                  items: items
                      .map((i) => DropdownMenuItem(
                          value: i.id, child: Text(i.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _itemId = v),
                ),
              ),
              Expanded(
                child: _itemId == null
                    ? const SizedBox.shrink()
                    : _RatesList(itemId: _itemId!, tick: p.tick),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RatesList extends StatelessWidget {
  final int itemId;
  final int tick;
  const _RatesList({required this.itemId, required this.tick});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return FutureBuilder(
      future: DatabaseHelper.instance.getSupplierRates(itemId),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snap.data!;
        if (rows.isEmpty) {
          return Center(child: Text(p.t('noSupplierPurchases')));
        }
        final df = DateFormat('dd MMM yyyy');
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: rows.length,
          itemBuilder: (_, i) {
            final r = rows[i];
            final cheapest = i == 0;
            return Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                    color: cheapest
                        ? AppColors.green
                        : AppColors.cardBorder,
                    width: cheapest ? 1.6 : 1),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(r.supplier.name,
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700)),
                        ),
                        if (cheapest)
                          Chip(
                            label: Text(p.t('cheapest'),
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11)),
                            backgroundColor: AppColors.green,
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                        '${p.t('lastRate')}: ${_rs(r.lastRate)}'
                        '   •   ${p.t('avgRate')}: ${_rs(r.avgRate)}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                        '${_rs(r.minRate)} – ${_rs(r.maxRate)}'
                        '   •   ${p.t('purchasesCount')}: ${r.purchases}'
                        '   •   ${_qty(r.totalQty)}'
                        '${r.lastDate != null ? '   •   ${df.format(r.lastDate!)}' : ''}',
                        style: const TextStyle(
                            fontSize: 12.5, color: AppColors.textGrey)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
