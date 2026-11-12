import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';
import 'item_detail_screen.dart';
import 'item_form_screen.dart';

class _StockRow {
  final StockItem item;
  final double qty;
  final DateTime? lastDate;

  /// Rate used for valuation: the item's most recent stock 'in' rate,
  /// falling back to the most recent transaction rate of any type.
  final double rate;
  const _StockRow(this.item, this.qty, this.lastDate, this.rate);

  double get value => qty * rate;
}

/// Transactions come back newest-first (date_time DESC, id DESC), so the
/// first 'in' entry is the latest purchase; if there is no purchase, the
/// first entry of any type is the most recent rate available.
/// Stock Book: all items with current quantities, low-stock tab,
/// search and a stock PDF report.
class StockBookScreen extends StatefulWidget {
  const StockBookScreen({super.key});

  @override
  State<StockBookScreen> createState() => _StockBookScreenState();
}

class _StockBookScreenState extends State<StockBookScreen> {
  late Future<List<_StockRow>> _future;
  List<_StockRow> _lastRows = const [];
  int _tab = 0; // 0 = All Items, 1 = Low Stock
  String _search = '';
  String? _categoryFilter; // null = all categories

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_StockRow>> _load() async {
    final db = DatabaseHelper.instance;
    final bizId = context.read<AppProvider>().businessId;
    // One aggregate query for the whole list (was: a qty query plus
    // a full movement history fetch for every single item).
    final summaries = await db.getItemSummaries(bizId);
    final rows = summaries
        .map((s) => _StockRow(s.item, s.qty, s.lastDate, s.latestRate))
        .toList();
    _lastRows = rows;
    return rows;
  }

  void _reload() => setState(() => _future = _load());

  Future<Business> _currentBusiness() async {
    final bizId = context.read<AppProvider>().businessId;
    final bs = await DatabaseHelper.instance.getBusinesses();
    for (final b in bs) {
      if (b.id == bizId) return b;
    }
    return bs.isNotEmpty ? bs.first : Business(name: 'Namat Oil Mill');
  }

  Future<void> _exportPdf() async {
    final p = context.read<AppProvider>();
    final biz = await _currentBusiness();
    if (!mounted) return;
    await shareReportPdf(
      business: biz,
      title: p.t('stockReport'),
      headers: [p.t('name'), p.t('quantity'), p.t('unit')],
      rows: _lastRows
          .map((r) => [r.item.name, formatQty(r.qty), r.item.unit])
          .toList(),
      summaryLine: '${p.t('total')}: ${_lastRows.length}',
    );
  }

  Future<void> _openItem(StockItem item) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ItemDetailScreen(item: item)),
    );
    if (mounted) _reload();
  }

  Future<void> _itemMenu(_StockRow row) async {
    final p = context.read<AppProvider>();
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(p.t('edit')),
              onTap: () async {
                Navigator.pop(c);
                final r = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ItemFormScreen(item: row.item)),
                );
                if (r == true && mounted) {
                  _reload();
                  context.read<AppProvider>().bump();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppColors.red),
              title: Text(p.t('delete')),
              onTap: () async {
                Navigator.pop(c);
                final ok =
                    await confirmDelete(context, p.t('confirmDelete'));
                if (!ok || !mounted) return;
                await DatabaseHelper.instance
                    .setItemDeleted(row.item.id!, true);
                if (!mounted) return;
                showSnack(context, p.t('deleted'));
                _reload();
                context.read<AppProvider>().bump();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabToggle(AppProvider p) {
    Widget option(int index, String label) {
      final selected = _tab == index;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _tab = index),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? AppColors.primary : AppColors.textGrey,
                  ),
                ),
              ),
              Container(
                height: 3,
                color: selected ? AppColors.primary : Colors.transparent,
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      color: Colors.white,
      child: Row(
        children: [
          option(0, p.t('allItems')),
          option(1, p.t('lowStock')),
        ],
      ),
    );
  }

  /// Horizontal category filter: All + every distinct non-empty category
  /// present in the loaded items.
  Widget _categoryChips(AppProvider p) {
    final cats = <String>{};
    for (final r in _lastRows) {
      final c = r.item.category.trim();
      if (c.isNotEmpty) cats.add(c);
    }
    if (cats.isEmpty) return const SizedBox.shrink();
    final sorted = cats.toList()..sort();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Row(
        children: [
          ChoiceChip(
            label: Text(p.t('all')),
            selected: _categoryFilter == null,
            onSelected: (_) => setState(() => _categoryFilter = null),
          ),
          for (final c in sorted) ...[
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text(c),
              selected: _categoryFilter == c,
              onSelected: (_) => setState(() => _categoryFilter = c),
            ),
          ],
        ],
      ),
    );
  }

  /// Total value of the whole inventory (every item, unfiltered).
  Widget _valuationCard(AppProvider p, double totalValue) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.inventory_2,
                color: AppColors.primary, size: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.t('totalStockValue'),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textGrey),
                  ),
                  Text(
                    formatRs(totalValue),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryDark,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _qtyColor(_StockRow row) {
    if (row.qty <= 0) return AppColors.red;
    if (row.qty <= row.item.lowStockLimit) return AppColors.accent;
    return AppColors.green;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('stockBook'))),
      body: Column(
        children: [
          _tabToggle(p),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _search = v),
                    decoration: InputDecoration(
                      hintText: p.t('search'),
                      prefixIcon: const Icon(Icons.search),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.filter_list,
                      color: AppColors.primary),
                  onPressed: () {},
                ),
                IconButton(
                  icon: const Icon(Icons.picture_as_pdf,
                      color: AppColors.primary),
                  onPressed: _exportPdf,
                ),
              ],
            ),
          ),
          _categoryChips(p),
          Expanded(
            child: FutureBuilder<List<_StockRow>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final all = snap.data!;
                final totalValue =
                    all.fold<double>(0, (s, r) => s + r.value);
                final catsPresent = <String>{
                  for (final r in all)
                    if (r.item.category.trim().isNotEmpty)
                      r.item.category.trim(),
                };
                final catFilter = (_categoryFilter != null &&
                        catsPresent.contains(_categoryFilter))
                    ? _categoryFilter
                    : null;
                final q = _search.trim().toLowerCase();
                final visible = all
                    .where((r) =>
                        (_tab == 0 || r.qty <= r.item.lowStockLimit) &&
                        (catFilter == null ||
                            r.item.category.trim() == catFilter) &&
                        (q.isEmpty ||
                            r.item.name.toLowerCase().contains(q)))
                    .toList();
                return Column(
                  children: [
                    _valuationCard(p, totalValue),
                    Expanded(
                      child: visible.isEmpty
                          ? Center(child: Text(p.t('noData')))
                          : ListView.separated(
                              itemCount: visible.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final row = visible[i];
                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor:
                                        const Color(0xFFFFE3D3),
                                    child: Text(
                                      initials(row.item.name),
                                      style: const TextStyle(
                                          color: AppColors.primaryDark,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  title: Text(row.item.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (row.item.category
                                          .trim()
                                          .isNotEmpty)
                                        Padding(
                                          padding:
                                              const EdgeInsets.symmetric(
                                                  vertical: 2),
                                          child: Container(
                                            padding: const EdgeInsets
                                                .symmetric(
                                                horizontal: 7,
                                                vertical: 1),
                                            decoration: BoxDecoration(
                                              color:
                                                  const Color(0xFFFFE3D3),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              row.item.category.trim(),
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color:
                                                    AppColors.primaryDark,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      Text(row.lastDate == null
                                          ? ''
                                          : dateTimeFmt
                                              .format(row.lastDate!)),
                                    ],
                                  ),
                                  trailing: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        formatQty(row.qty),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16,
                                          color: _qtyColor(row),
                                        ),
                                      ),
                                      Text(
                                        row.item.unit,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: AppColors.textGrey),
                                      ),
                                      if (row.value > 0)
                                        Text(
                                          '${p.t('stockValue')}: ${formatRs(row.value)}',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: AppColors.textGrey),
                                        ),
                                    ],
                                  ),
                                  onTap: () => _openItem(row.item),
                                  onLongPress: () => _itemMenu(row),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final r = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const ItemFormScreen()),
          );
          if (r == true && mounted) {
            _reload();
            context.read<AppProvider>().bump();
          }
        },
        icon: const Icon(Icons.add),
        label: Text(p.t('addItem')),
      ),
    );
  }
}
