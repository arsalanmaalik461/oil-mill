import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';

typedef _Summary = ({
  double sales,
  double cogs,
  double gross,
  double operatingExpenses,
  double salaries,
  double nonOperating,
  double net,
  double unknownCostSales,
  int unknownCostLines
});

class _PlData {
  final _Summary summary;
  final _Summary previous;
  final List<({String category, double total})> categories;
  const _PlData(this.summary, this.previous, this.categories);
}

/// Profit & Loss statement: Sales − COGS = Gross − operating
/// expenses (broken down by category) − salaries = Net, for this
/// month / this year / a custom range, with a previous-period
/// comparison and a shareable PDF. All figures come from the one
/// getProfitSummary the whole app uses.
class ProfitLossScreen extends StatefulWidget {
  const ProfitLossScreen({super.key});

  @override
  State<ProfitLossScreen> createState() => _ProfitLossScreenState();
}

class _ProfitLossScreenState extends State<ProfitLossScreen> {
  String _mode = 'month'; // month | year | custom
  DateTimeRange? _custom;
  Future<_PlData>? _future;

  ({DateTime start, DateTime end, String label}) _period(AppProvider p) {
    final now = DateTime.now();
    switch (_mode) {
      case 'year':
        return (
          start: DateTime(now.year),
          end: DateTime(now.year + 1),
          label: p.t('thisYear')
        );
      case 'custom':
        final r = _custom;
        if (r != null) {
          return (
            start: r.start,
            end: r.end.add(const Duration(days: 1)),
            label:
                '${DateFormat('dd MMM yy').format(r.start)} – ${DateFormat('dd MMM yy').format(r.end)}'
          );
        }
        continue month;
      month:
      default:
        return (
          start: DateTime(now.year, now.month),
          end: DateTime(now.year, now.month + 1),
          label: p.t('thisMonth')
        );
    }
  }

  Future<_PlData> _load(AppProvider p) async {
    final db = DatabaseHelper.instance;
    final per = _period(p);
    final summary =
        await db.getProfitSummary(p.businessId, per.start, per.end);
    final cats = await db.getExpenseCategoryTotals(
        p.businessId, per.start, per.end);
    final span = per.end.difference(per.start);
    final previous = await db.getProfitSummary(
        p.businessId, per.start.subtract(span), per.start);
    return _PlData(summary, previous, cats);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    _future ??= _load(p);
    return Scaffold(
      appBar: AppBar(
        title: Text(p.t('profitLoss')),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () async {
              final data = await _future;
              if (data == null || !context.mounted) return;
              final per = _period(p);
              final s = data.summary;
              final biz = await DatabaseHelper.instance.getBusinesses();
              final business = biz.isEmpty
                  ? Business(name: 'Namat Oil Mill')
                  : biz.firstWhere((b) => b.id == p.businessId,
                      orElse: () => biz.first);
              await shareReportPdf(
                business: business,
                title: 'Profit and Loss ${per.label}',
                headers: const ['Item', 'Amount (Rs)'],
                rows: [
                  ['Sales', _n(s.sales)],
                  ['Cost of Goods Sold', _n(s.cogs)],
                  ['Gross Profit', _n(s.gross)],
                  ['Operating Expenses', _n(s.operatingExpenses)],
                  for (final c in data.categories)
                    ['  ${c.category}', _n(c.total)],
                  ['Salaries', _n(s.salaries)],
                  ['Net Profit', _n(s.net)],
                ],
                summaryLine: 'Net Profit: Rs ${_n(s.net)}',
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(p.t('thisMonth')),
                  selected: _mode == 'month',
                  onSelected: (_) =>
                      setState(() { _mode = 'month'; _future = null; }),
                ),
                ChoiceChip(
                  label: Text(p.t('thisYear')),
                  selected: _mode == 'year',
                  onSelected: (_) =>
                      setState(() { _mode = 'year'; _future = null; }),
                ),
                ChoiceChip(
                  label: Text(p.t('custom')),
                  selected: _mode == 'custom',
                  onSelected: (_) async {
                    final r = await pickDateRange(context, p.t);
                    if (r?.start != null && r?.end != null && mounted) {
                      setState(() {
                        _mode = 'custom';
                        _custom = DateTimeRange(start: r!.start!, end: r.end!);
                        _future = null;
                      });
                    }
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<_PlData>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final d = snap.data!;
                final s = d.summary;
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _line(p.t('totalSale'), s.sales),
                    _line(p.t('cogs'), -s.cogs),
                    const Divider(),
                    _line(p.t('grossProfit'), s.gross, bold: true),
                    const SizedBox(height: 10),
                    _line(p.t('expenses'), -s.operatingExpenses),
                    for (final c in d.categories)
                      _line('    ${c.category == 'Other' ? p.t('otherCategory') : c.category}',
                          -c.total, small: true),
                    _line(p.t('salary'), -s.salaries),
                    const Divider(),
                    _line(p.t('netProfit'), s.net,
                        bold: true,
                        color: s.net >= 0 ? AppColors.green : AppColors.red),
                    if (s.nonOperating != 0) ...[
                      const SizedBox(height: 12),
                      Text(
                          '${p.t('nonOperatingNote')}: ${formatRs(s.nonOperating)}',
                          style: const TextStyle(
                              fontSize: 12.5, color: AppColors.textGrey)),
                    ],
                    const SizedBox(height: 18),
                    _comparison(p, s.net, d.previous.net, p.t('netProfit')),
                    _comparison(p, s.sales, d.previous.sales, p.t('totalSale')),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _n(double v) =>
      NumberFormat.decimalPattern('en_IN').format(v.round());

  Widget _line(String label, double amount,
      {bool bold = false, bool small = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: small ? 13 : 15,
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                    color: small ? AppColors.textGrey : null)),
          ),
          Text(formatRs(amount),
              style: TextStyle(
                  fontSize: small ? 13 : 15,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
                  color: color)),
        ],
      ),
    );
  }

  Widget _comparison(AppProvider p, double now, double before, String label) {
    if (before == 0) return const SizedBox.shrink();
    final pct = (now - before) / before.abs() * 100;
    final up = pct >= 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(up ? Icons.trending_up : Icons.trending_down,
              size: 18, color: up ? AppColors.green : AppColors.red),
          const SizedBox(width: 6),
          Text(
              '$label: ${up ? '+' : ''}${pct.toStringAsFixed(1)}% ${p.t('vsPrevious')}',
              style: const TextStyle(fontSize: 13.5)),
        ],
      ),
    );
  }
}
