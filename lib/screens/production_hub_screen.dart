import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import 'finished_goods_screen.dart';
import 'production_batches_screen.dart';
import 'production_expenses_screen.dart';
import 'production_purchases_screen.dart';
import 'production_reports_screen.dart';

class _DashData {
  final double sales;
  final double cogs;
  final double prodExpenses;
  final double otherExpenses;
  final double prodQty;
  final String prodUnit;
  final double soldQty;
  final double remainingFinished;
  final double rawValue;
  final double finishedValue;
  _DashData({
    required this.sales,
    required this.cogs,
    required this.prodExpenses,
    required this.otherExpenses,
    required this.prodQty,
    required this.prodUnit,
    required this.soldQty,
    required this.remainingFinished,
    required this.rawValue,
    required this.finishedValue,
  });
  double get grossProfit => sales - cogs;
  // Batch production expenses are already inside COGS (the unit cost of a
  // finished item includes its batch's material + expense allocation), so
  // net profit subtracts only the OTHER business expenses — subtracting
  // production expenses again would double-count them.
  double get netProfit => grossProfit - otherExpenses;
}

/// Production & Profit hub: today's dashboard (sales, COGS, gross/net
/// profit, production and stock figures — all from real transactions)
/// plus navigation tiles for the module's sections.
class ProductionHubScreen extends StatefulWidget {
  const ProductionHubScreen({super.key});

  @override
  State<ProductionHubScreen> createState() => _ProductionHubScreenState();
}

class _ProductionHubScreenState extends State<ProductionHubScreen> {
  late Future<_DashData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load(context.read<AppProvider>().businessId);
  }

  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  Future<_DashData> _load(int bizId) async {
    final db = DatabaseHelper.instance;
    final items = await db.getItems(bizId);
    final itemById = <int, StockItem>{for (final i in items) if (i.id != null) i.id!: i};

    // --- Today's sales + COGS (actual unit cost of the goods sold) ---
    var sales = 0.0;
    var cogs = 0.0;
    var soldQty = 0.0;
    final costCache = <int, double>{};
    final bills = await db.getBills(bizId);
    for (final b in bills) {
      if (!_isToday(b.dateTime)) continue;
      sales += b.total;
      if (b.id == null) continue;
      final lines = await db.getBillItems(b.id!);
      for (final li in lines) {
        soldQty += li.qty;
        final itemId = li.itemId;
        if (itemId == null) continue;
        // Sale-time COGS snapshot first (Phase 2), current cost as
        // the legacy fallback.
        var lineCogs = li.costAmount;
        if (lineCogs == null) {
          var cost = costCache[itemId];
          if (cost == null) {
            cost = await db.getItemUnitCost(itemId);
            costCache[itemId] = cost;
          }
          lineCogs = li.qty * cost;
        }
        cogs += lineCogs;
      }
    }

    // --- Today's expenses ---
    var prodExp = 0.0;
    for (final e in await db.getAllProductionExpenses(bizId)) {
      if (_isToday(e.dateTime)) prodExp += e.amount;
    }
    var otherExp = 0.0;
    // Salaries paid today are an operating cost too (Phase 5).
    final now = DateTime.now();
    otherExp += await db.getSalaryTotal(bizId,
        start: DateTime(now.year, now.month, now.day),
        end: DateTime(now.year, now.month, now.day + 1));
    for (final e in await db.getExpenses(bizId)) {
      // Operating expenses only (Phase 4): owner withdrawals, loan
      // repayments and transfers do not reduce net profit.
      if (_isToday(e.dateTime) && e.kind == 'operating') {
        otherExp += e.amount;
      }
    }

    // --- Today's production output (completed batches only) ---
    var prodQty = 0.0;
    var prodUnit = '';
    for (final batch in await db.getProductionBatches(bizId)) {
      if (batch.status != 'completed' || !_isToday(batch.dateTime)) continue;
      if (batch.id == null) continue;
      for (final o in await db.getBatchOutputs(batch.id!)) {
        prodQty += o.qty;
        if (prodUnit.isEmpty) {
          prodUnit = itemById[o.itemId]?.unit ?? '';
        }
      }
    }

    // --- Stock positions ---
    var remainingFinished = 0.0;
    var rawValue = 0.0;
    var finishedValue = 0.0;
    for (final i in items) {
      if (i.id == null) continue;
      final qty = await db.getItemQty(i.id!);
      if (i.kind == 'raw') {
        rawValue += qty * await db.getItemAvgCost(i.id!);
      } else if (i.kind == 'finished') {
        remainingFinished += qty;
        finishedValue += qty * await db.getItemUnitCost(i.id!);
      }
    }

    return _DashData(
      sales: sales,
      cogs: cogs,
      prodExpenses: prodExp,
      otherExpenses: otherExp,
      prodQty: prodQty,
      prodUnit: prodUnit,
      soldQty: soldQty,
      remainingFinished: remainingFinished,
      rawValue: rawValue,
      finishedValue: finishedValue,
    );
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

  Widget _tile(BuildContext context, String label, IconData icon, Widget screen) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.primary.withValues(alpha: 0.12),
          child: Icon(icon, color: AppColors.accent),
        ),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => screen),
        ).then((_) {
          if (mounted) {
            setState(() => _future =
                _load(context.read<AppProvider>().businessId));
          }
        }),
      ),
    );
  }

  String _qtyText(double q, String unit) {
    final n = q == q.roundToDouble() ? q.toInt().toString() : q.toStringAsFixed(2);
    return unit.isEmpty ? n : '$n $unit';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('production'))),
      body: FutureBuilder<_DashData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data ??
              _DashData(
                sales: 0, cogs: 0, prodExpenses: 0, otherExpenses: 0,
                prodQty: 0, prodUnit: '', soldQty: 0, remainingFinished: 0,
                rawValue: 0, finishedValue: 0,
              );
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Text(
                '${p.t('prodDashboard')} — ${p.t('prodToday')}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.45,
                children: [
                  _statCard(p.t('todaysSales'), formatRs(d.sales),
                      Icons.point_of_sale, AppColors.green),
                  _statCard(p.t('cogs'), formatRs(d.cogs),
                      Icons.shopping_basket, AppColors.red),
                  _statCard(p.t('grossProfit'), formatRs(d.grossProfit),
                      Icons.trending_up, AppColors.primary),
                  _statCard(p.t('netProfit'), formatRs(d.netProfit),
                      Icons.account_balance_wallet, AppColors.primaryDark),
                  _statCard(p.t('prodExpenses'), formatRs(d.prodExpenses),
                      Icons.factory, AppColors.accent),
                  _statCard(p.t('expenses'), formatRs(d.otherExpenses),
                      Icons.money_off, AppColors.red),
                  _statCard(p.t('prodQty'), _qtyText(d.prodQty, d.prodUnit),
                      Icons.precision_manufacturing, AppColors.primary),
                  _statCard(p.t('soldQty'), _qtyText(d.soldQty, ''),
                      Icons.sell, AppColors.green),
                  _statCard(
                      '${p.t('finishedGoods')} — ${p.t('remainingQty')}',
                      _qtyText(d.remainingFinished, ''),
                      Icons.inventory_2, AppColors.accent),
                  _statCard('${p.t('rawMaterial')} — ${p.t('stockValue')}',
                      formatRs(d.rawValue), Icons.warehouse, AppColors.primary),
                  _statCard('${p.t('finishedGoods')} — ${p.t('stockValue')}',
                      formatRs(d.finishedValue), Icons.inventory, AppColors.green),
                ],
              ),
              const SizedBox(height: 6),
              // Production expenses are already inside COGS through the
              // finished items' unit cost — shown here for information only,
              // they are NOT subtracted again in net profit.
              const Text(
                'Production expenses are already included in COGS via unit cost — shown for information only.',
                style: TextStyle(fontSize: 11, color: AppColors.textGrey),
              ),
              const SizedBox(height: 14),
              _tile(context, p.t('rawPurchases'), Icons.local_shipping,
                  const ProductionPurchasesScreen()),
              _tile(context, p.t('prodBatches'), Icons.factory,
                  const ProductionBatchesScreen()),
              _tile(context, p.t('finishedGoods'), Icons.inventory_2,
                  const FinishedGoodsScreen()),
              _tile(context, p.t('prodExpenses'), Icons.receipt_long,
                  const ProductionExpensesScreen()),
              _tile(context, p.t('salesProfitReports'), Icons.bar_chart,
                  const ProductionReportsScreen()),
              _tile(context, p.t('prodHistory'), Icons.history,
                  const ProductionBatchesScreen()),
            ],
          );
        },
      ),
    );
  }
}
