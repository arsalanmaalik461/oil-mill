import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _DashData {
  final double opening;
  final double cashIn;
  final double cashOut;
  final double closing;
  final bool dayFrozen;
  final double sales;
  final double cogs;
  final double gross;
  final double expenses;
  final double salaries;
  final double net;
  final double stockValue;
  final double willGet;
  final double willGive;
  final int pendingCount;
  final double pendingTotal;
  final int batchesToday;
  final double outputKgToday;
  _DashData({
    required this.opening,
    required this.cashIn,
    required this.cashOut,
    required this.closing,
    required this.dayFrozen,
    required this.sales,
    required this.cogs,
    required this.gross,
    required this.expenses,
    required this.salaries,
    required this.net,
    required this.stockValue,
    required this.willGet,
    required this.willGive,
    required this.pendingCount,
    required this.pendingTotal,
    required this.batchesToday,
    required this.outputKgToday,
  });
}

/// Owner Dashboard (Phase 5): the whole business on one screen —
/// today's cash (opening/in/out/closing), today's REAL profit
/// (sales, COGS from sale-time snapshots, gross, operating expenses,
/// salaries, net), stock value, receivables, payables, pending bills
/// and today's production. Every figure comes from the same helpers
/// the other screens use, so the numbers always agree.
class OwnerDashboardScreen extends StatefulWidget {
  const OwnerDashboardScreen({super.key});

  @override
  State<OwnerDashboardScreen> createState() => _OwnerDashboardScreenState();
}

class _OwnerDashboardScreenState extends State<OwnerDashboardScreen> {
  final _db = DatabaseHelper.instance;
  late Future<_DashData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load(context.read<AppProvider>().businessId);
  }

  Future<_DashData> _load(int bizId) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));

    final summary = await _db.getProfitSummary(bizId, start, end);
    final frozen = await _db.getDailyClosing(bizId, now);
    final live = await _db.liveDailyClosing(bizId, now);

    var stockValue = 0.0;
    for (final item in await _db.getItems(bizId)) {
      if (item.id == null) continue;
      final qty = await _db.getItemQty(item.id!);
      if (qty != 0) {
        stockValue += qty * await _db.getItemUnitCost(item.id!);
      }
    }

    final totals = await _db.getPartyTotals(bizId);
    var pendingCount = 0;
    var pendingTotal = 0.0;
    for (final b in await _db.getBills(bizId)) {
      if (b.status == 'pending') {
        pendingCount++;
        pendingTotal += b.total;
      }
    }

    var batchesToday = 0;
    var outputKg = 0.0;
    for (final b in await _db.getProductionBatches(bizId)) {
      if (b.status != 'completed' || b.id == null) continue;
      if (!b.dateTime.isBefore(start) && b.dateTime.isBefore(end)) {
        batchesToday++;
        outputKg += (await _db.getBatchRecovery(b.id!)).outputKg;
      }
    }

    return _DashData(
      opening: frozen?.opening ?? live.opening,
      cashIn: frozen?.totalIn ?? live.totalIn,
      cashOut: frozen?.totalOut ?? live.totalOut,
      closing: frozen?.closing ?? live.closing,
      dayFrozen: frozen != null,
      sales: summary.sales,
      cogs: summary.cogs,
      gross: summary.gross,
      expenses: summary.operatingExpenses,
      salaries: summary.salaries,
      net: summary.net,
      stockValue: stockValue,
      willGet: totals.willGet,
      willGive: totals.willGive,
      pendingCount: pendingCount,
      pendingTotal: pendingTotal,
      batchesToday: batchesToday,
      outputKgToday: outputKg,
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      );

  Widget _card(String label, String value, IconData icon, Color color,
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
            Text(label,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textGrey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: valueColor)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(List<Widget> cards) => GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.4,
        children: cards,
      );

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('ownerDashboard'))),
      body: FutureBuilder<_DashData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.hasData) {
            return Center(child: Text(p.t('noData')));
          }
          final d = snap.data!;
          return RefreshIndicator(
            onRefresh: () async {
              setState(() {
                _future = _load(context.read<AppProvider>().businessId);
              });
              await _future;
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
              children: [
                _section(p.t('cashBook')),
                _grid([
                  _card(p.t('openingCash'), formatRs(d.opening),
                      Icons.wb_sunny_outlined, AppColors.primary),
                  _card(p.t('cashIn'), formatRs(d.cashIn),
                      Icons.arrow_downward, AppColors.green),
                  _card(p.t('cashOut'), formatRs(d.cashOut),
                      Icons.arrow_upward, AppColors.red),
                  _card(
                      '${p.t('closingCash')}${d.dayFrozen ? ' 🔒' : ''}',
                      formatRs(d.closing),
                      Icons.nightlight_round,
                      AppColors.primary),
                ]),
                _section(p.t('netProfit')),
                _grid([
                  _card(p.t('totalSale'), formatRs(d.sales),
                      Icons.point_of_sale, AppColors.green),
                  _card(p.t('cogs'), formatRs(d.cogs), Icons.receipt_long,
                      AppColors.accent),
                  _card(p.t('grossProfit'), formatRs(d.gross),
                      Icons.trending_up,
                      d.gross >= 0 ? AppColors.green : AppColors.red,
                      valueColor:
                          d.gross >= 0 ? AppColors.green : AppColors.red),
                  _card(p.t('expenses'), formatRs(d.expenses),
                      Icons.money_off, AppColors.red),
                  if (d.salaries > 0)
                    _card(p.t('salary'), formatRs(d.salaries), Icons.badge,
                        AppColors.red),
                  _card(p.t('netProfit'), formatRs(d.net),
                      Icons.account_balance_wallet,
                      d.net >= 0 ? AppColors.green : AppColors.red,
                      valueColor:
                          d.net >= 0 ? AppColors.green : AppColors.red),
                ]),
                _section(p.t('outstanding')),
                _grid([
                  _card(p.t('stockValue'), formatRs(d.stockValue),
                      Icons.inventory_2, AppColors.primary),
                  _card(p.t('youWillGet'), formatRs(d.willGet),
                      Icons.call_received, AppColors.green),
                  _card(p.t('youWillGive'), formatRs(d.willGive),
                      Icons.call_made, AppColors.red),
                  _card(
                      '${p.t('pendingBills')} (${d.pendingCount})',
                      formatRs(d.pendingTotal),
                      Icons.pending_actions,
                      AppColors.accent),
                ]),
                _section(p.t('production')),
                _grid([
                  _card(p.t('batchesToday'), '${d.batchesToday}',
                      Icons.factory, AppColors.primary),
                  _card(p.t('outputToday'),
                      '${formatQty(d.outputKgToday)} kg', Icons.scale,
                      AppColors.accent),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }
}
