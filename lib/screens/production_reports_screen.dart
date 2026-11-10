import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _ProdAgg {
  final String name;
  final String unit;
  double soldQty = 0;
  double salesAmt = 0;
  double cogs = 0;
  _ProdAgg(this.name, this.unit);
  double get profit => salesAmt - cogs;
}

class _BatchRow {
  final ProductionBatch batch;
  final double totalCost;
  final double outputQty;
  final String mainName;
  final String mainUnit;
  final double mainCostPerUnit;
  _BatchRow(this.batch, this.totalCost, this.outputQty, this.mainName,
      this.mainUnit, this.mainCostPerUnit);
}

class _ReportData {
  final double sales;
  final double cogs;
  final double otherExpenses;

  /// Owner withdrawals + loan repayments + transfers of the period:
  /// real money out, but NOT operating expenses (Phase 4).
  final double nonOpExpenses;

  /// Salaries + advances paid in the period (Phase 5): an operating
  /// cost that used to be invisible to profit.
  final double salaries;
  final double prodExpensesInfo;
  final double rawStockValue;
  final double finishedStockValue;
  final List<_ProdAgg> products;
  final Map<String, double> prodByProduct; // item name -> qty produced
  final List<_BatchRow> batches;
  final List<MapEntry<String, double>> customers;
  _ReportData({
    required this.sales,
    required this.cogs,
    required this.otherExpenses,
    required this.nonOpExpenses,
    required this.salaries,
    required this.prodExpensesInfo,
    required this.rawStockValue,
    required this.finishedStockValue,
    required this.products,
    required this.prodByProduct,
    required this.batches,
    required this.customers,
  });
  double get grossProfit => sales - cogs;
  double get netProfit => grossProfit - otherExpenses - salaries;
}

/// Sales & Profit Reports.
///
/// PROFIT FORMULA (from real saved transactions only):
///   Sales        = sum of bill totals in the period (non-deleted bills)
///   COGS         = sum over the period's bill items of
///                  qty x getItemUnitCost(itemId)
///                  (production average cost for manufactured goods,
///                  weighted-average purchase cost otherwise)
///   Gross profit = Sales - COGS
///   Net profit   = Gross profit - Expense Book expenses of the period
/// Production expenses of the period are shown for information only:
/// they are already inside COGS through the unit costs, so they are
/// NEVER subtracted a second time.
class ProductionReportsScreen extends StatefulWidget {
  const ProductionReportsScreen({super.key});

  @override
  State<ProductionReportsScreen> createState() =>
      _ProductionReportsScreenState();
}

class _ProductionReportsScreenState extends State<ProductionReportsScreen> {
  String _period = 'today'; // today | week | month | range
  late DateTime _start;
  late DateTime _end; // exclusive
  late Future<_ReportData> _future;

  @override
  void initState() {
    super.initState();
    _setRangeFor('today');
    _future = _load();
  }

  void _setRangeFor(String period) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (period) {
      case 'week':
        _start = today.subtract(Duration(days: today.weekday - 1));
        _end = _start.add(const Duration(days: 7));
        break;
      case 'month':
        _start = DateTime(now.year, now.month, 1);
        _end = DateTime(now.year, now.month + 1, 1);
        break;
      default:
        _start = today;
        _end = today.add(const Duration(days: 1));
    }
  }

  Future<void> _pickPeriod(String period) async {
    if (period == 'range') {
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        initialDateRange: DateTimeRange(start: _start, end: _end),
      );
      if (picked == null || !mounted) return;
      setState(() {
        _period = 'range';
        _start = DateTime(
            picked.start.year, picked.start.month, picked.start.day);
        _end = DateTime(picked.end.year, picked.end.month, picked.end.day)
            .add(const Duration(days: 1));
        _future = _load();
      });
      return;
    }
    setState(() {
      _period = period;
      _setRangeFor(period);
      _future = _load();
    });
  }

  bool _inPeriod(DateTime dt) => !dt.isBefore(_start) && dt.isBefore(_end);

  Future<_ReportData> _load() async {
    final db = DatabaseHelper.instance;
    final bizId = context.read<AppProvider>().businessId;

    final items = await db.getItems(bizId);
    final itemById = <int, StockItem>{
      for (final i in items)
        if (i.id != null) i.id!: i,
    };
    final costCache = <int, double>{};
    Future<double> costOf(int itemId) async {
      final cached = costCache[itemId];
      if (cached != null) return cached;
      final c = await db.getItemUnitCost(itemId);
      costCache[itemId] = c;
      return c;
    }

    // ---- Sales + COGS from bills of the period ----
    final bills =
        (await db.getBills(bizId)).where((b) => _inPeriod(b.dateTime));
    var sales = 0.0;
    var cogs = 0.0;
    final prodAgg = <int, _ProdAgg>{};
    final custAgg = <String, double>{};
    for (final bill in bills) {
      sales += bill.total;
      final name = bill.partyName.isNotEmpty ? bill.partyName : '—';
      custAgg[name] = (custAgg[name] ?? 0) + bill.total;
      if (bill.id == null) continue;
      for (final bi in await db.getBillItems(bill.id!)) {
        final itemId = bi.itemId;
        if (itemId == null) continue;
        // Sale-time COGS snapshot first (Phase 2): a past period's
        // profit can no longer be rewritten by a later purchase.
        // Legacy bills without a snapshot fall back to the current
        // unit cost.
        final lineCogs =
            bi.costAmount ?? bi.qty * await costOf(itemId);
        cogs += lineCogs;
        final agg = prodAgg.putIfAbsent(
          itemId,
          () => _ProdAgg(bi.name, itemById[itemId]?.unit ?? ''),
        );
        agg.soldQty += bi.qty;
        agg.salesAmt += bi.amount;
        agg.cogs += lineCogs;
      }
    }

    // ---- Expense Book expenses of the period ----
    // Only OPERATING expenses reduce net profit (Phase 4): owner
    // withdrawals, loan repayments and transfers are tracked apart.
    var otherExpenses = 0.0;
    var nonOpExpenses = 0.0;
    for (final e in await db.getExpenses(bizId)) {
      if (!_inPeriod(e.dateTime)) continue;
      if (e.kind == 'operating') {
        otherExpenses += e.amount;
      } else {
        nonOpExpenses += e.amount;
      }
    }

    // ---- Production expenses of the period (information only) ----
    var prodExpensesInfo = 0.0;
    for (final e in await db.getAllProductionExpenses(bizId)) {
      if (_inPeriod(e.dateTime)) prodExpensesInfo += e.amount;
    }

    // ---- Production of the period (completed batches) ----
    final prodByProduct = <String, double>{};
    final batchRows = <_BatchRow>[];
    final batches = (await db.getProductionBatches(bizId))
        .where((b) => b.status == 'completed' && _inPeriod(b.dateTime));
    for (final b in batches) {
      if (b.id == null) continue;
      var inputCost = 0.0;
      for (final i in await db.getBatchInputs(b.id!)) {
        inputCost += i.cost;
      }
      var expCost = 0.0;
      for (final e in await db.getBatchExpenses(b.id!)) {
        expCost += e.amount;
      }
      final outputs = await db.getBatchOutputs(b.id!);
      var outQty = 0.0;
      ProductionOutput? main;
      for (final o in outputs) {
        outQty += o.qty;
        final item = itemById[o.itemId];
        final label =
            '${item?.name ?? ''} (${item?.unit ?? ''})'.trim();
        prodByProduct[label] = (prodByProduct[label] ?? 0) + o.qty;
        if (main == null || o.qty > main.qty) main = o;
      }
      batchRows.add(_BatchRow(
        b,
        inputCost + expCost,
        outQty,
        main != null ? (itemById[main.itemId]?.name ?? '') : '',
        main != null ? (itemById[main.itemId]?.unit ?? '') : '',
        main?.costPerUnit ?? 0,
      ));
    }

    // ---- Current stock values (raw + finished) ----
    var rawValue = 0.0;
    var finishedValue = 0.0;
    for (final item in items) {
      if (item.id == null) continue;
      if (item.kind != 'raw' && item.kind != 'finished') continue;
      final qty = await db.getItemQty(item.id!);
      if (qty == 0) continue;
      final v = qty * await costOf(item.id!);
      if (item.kind == 'raw') {
        rawValue += v;
      } else {
        finishedValue += v;
      }
    }

    final products = prodAgg.values.toList()
      ..sort((a, b) => b.salesAmt.compareTo(a.salesAmt));
    final customers = custAgg.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return _ReportData(
      sales: sales,
      cogs: cogs,
      otherExpenses: otherExpenses,
      nonOpExpenses: nonOpExpenses,
      salaries: await db.getSalaryTotal(bizId, start: _start, end: _end),
      prodExpensesInfo: prodExpensesInfo,
      rawStockValue: rawValue,
      finishedStockValue: finishedValue,
      products: products,
      prodByProduct: prodByProduct,
      batches: batchRows,
      customers: customers,
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(
          text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      );

  Widget _statCard(String label, String value, IconData icon, Color color,
      {Color? valueColor}) {
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
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: valueColor),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(AppProvider p, String value, String label) {
    final selected = _period == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _pickPeriod(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('salesProfitReports'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    _chip(p, 'today', p.t('prodToday')),
                    _chip(p, 'week', p.t('thisWeek')),
                    _chip(p, 'month', p.t('thisMonth')),
                    _chip(p, 'range', p.t('dateRange')),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${dateFmt.format(_start)} — '
                  '${dateFmt.format(_end.subtract(const Duration(days: 1)))}',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textGrey),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<_ReportData>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final d = snap.data ??
                    _ReportData(
                      sales: 0,
                      cogs: 0,
                      otherExpenses: 0,
                      nonOpExpenses: 0,
                      salaries: 0,
                      prodExpensesInfo: 0,
                      rawStockValue: 0,
                      finishedStockValue: 0,
                      products: const [],
                      prodByProduct: const {},
                      batches: const [],
                      customers: const [],
                    );
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
                        _statCard(
                          _period == 'today' ? p.t('todaysSales') : 'Sales',
                          formatRs(d.sales),
                          Icons.point_of_sale,
                          AppColors.primary,
                        ),
                        _statCard(
                          p.t('cogs'),
                          formatRs(d.cogs),
                          Icons.receipt_long,
                          AppColors.accent,
                        ),
                        _statCard(
                          p.t('grossProfit'),
                          formatRs(d.grossProfit),
                          Icons.trending_up,
                          d.grossProfit >= 0
                              ? AppColors.green
                              : AppColors.red,
                          valueColor: d.grossProfit >= 0
                              ? AppColors.green
                              : AppColors.red,
                        ),
                        _statCard(
                          p.t('expenses'),
                          formatRs(d.otherExpenses),
                          Icons.money_off,
                          AppColors.red,
                        ),
                        if (d.salaries > 0)
                          _statCard(
                            p.t('salary'),
                            formatRs(d.salaries),
                            Icons.badge,
                            AppColors.red,
                          ),
                        _statCard(
                          p.t('netProfit'),
                          formatRs(d.netProfit),
                          Icons.account_balance_wallet,
                          d.netProfit >= 0 ? AppColors.green : AppColors.red,
                          valueColor: d.netProfit >= 0
                              ? AppColors.green
                              : AppColors.red,
                        ),
                        _statCard(
                          p.t('prodExpenses'),
                          formatRs(d.prodExpensesInfo),
                          Icons.factory,
                          AppColors.accent,
                        ),
                        if (d.nonOpExpenses > 0)
                          _statCard(
                            p.t('nonOpExpenses'),
                            formatRs(d.nonOpExpenses),
                            Icons.swap_horiz,
                            AppColors.textGrey,
                          ),
                        _statCard(
                          '${p.t('rawMaterial')} • ${p.t('stockValue')}',
                          formatRs(d.rawStockValue),
                          Icons.warehouse,
                          AppColors.primary,
                        ),
                        _statCard(
                          '${p.t('finishedGoods')} • ${p.t('stockValue')}',
                          formatRs(d.finishedStockValue),
                          Icons.inventory_2,
                          AppColors.primary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Production expenses are already included in COGS '
                      'through unit costs — shown here for information only, '
                      'never subtracted twice.',
                      style:
                          TextStyle(fontSize: 12, color: AppColors.textGrey),
                    ),
                    if (d.prodByProduct.isNotEmpty) ...[
                      _sectionTitle(p.t('prodQty')),
                      ...d.prodByProduct.entries.map(
                        (e) => Card(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          child: ListTile(
                            dense: true,
                            title: Text(e.key),
                            trailing: Text(
                              formatQty(e.value),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ),
                    ],
                    _sectionTitle('Product-wise Sales'),
                    if (d.products.isEmpty)
                      Text(p.t('noData'),
                          style: const TextStyle(color: AppColors.textGrey)),
                    ...d.products.map(
                      (pr) => Card(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        child: ListTile(
                          title: Text(pr.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            '${p.t('soldQty')}: ${formatQty(pr.soldQty)} ${pr.unit}'
                            ' • ${p.t('cogs')}: ${formatRs(pr.cogs)}',
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                formatRs(pr.salesAmt),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                              Text(
                                '${pr.profit >= 0 ? '+' : ''}'
                                '${formatRs(pr.profit)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: pr.profit >= 0
                                      ? AppColors.green
                                      : AppColors.red,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _sectionTitle('Batch-wise'),
                    if (d.batches.isEmpty)
                      Text(p.t('noData'),
                          style: const TextStyle(color: AppColors.textGrey)),
                    ...d.batches.map(
                      (b) => Card(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        child: ListTile(
                          title: Text(
                            '${p.t('batchNo')} ${b.batch.batchNo}'
                            '${b.mainName.isNotEmpty ? ' — ${b.mainName}' : ''}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${dateFmt.format(b.batch.dateTime)}'
                            ' • ${p.t('outputQty')}: ${formatQty(b.outputQty)}'
                            '${b.mainUnit.isNotEmpty ? ' ${b.mainUnit}' : ''}'
                            ' • ${formatRs(b.mainCostPerUnit)} / ${b.mainUnit}',
                          ),
                          trailing: Text(
                            formatRs(b.totalCost),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                    _sectionTitle('${p.t('customers')} — Sales'),
                    if (d.customers.isEmpty)
                      Text(p.t('noData'),
                          style: const TextStyle(color: AppColors.textGrey)),
                    ...d.customers.map(
                      (c) => Card(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        child: ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            backgroundColor:
                                AppColors.primary.withValues(alpha: 0.12),
                            child: Text(
                              initials(c.key),
                              style: const TextStyle(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          title: Text(c.key),
                          trailing: Text(
                            formatRs(c.value),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
