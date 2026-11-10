import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';
import 'roznamcha_screen.dart';

class _ReportData {
  final Business business;
  final List<CashEntry> cashEntries;
  final double cashBalance;
  final double todayCashIn;
  final double todayCashOut;
  final double todaySales;
  final double monthSales;
  final double monthExpenses;
  final double willGet;
  final double willGive;
  final int lowStockCount;
  final List<Party> parties;
  final Map<int, double> partyBalances;
  final List<StockItem> items;
  final Map<int, double> itemQtys;
  final Map<int, double> itemRates;
  final double totalStockValue;

  _ReportData({
    required this.business,
    required this.cashEntries,
    required this.cashBalance,
    required this.todayCashIn,
    required this.todayCashOut,
    required this.todaySales,
    required this.monthSales,
    required this.monthExpenses,
    required this.willGet,
    required this.willGive,
    required this.lowStockCount,
    required this.parties,
    required this.partyBalances,
    required this.items,
    required this.itemQtys,
    required this.itemRates,
    required this.totalStockValue,
  });
}

/// Business reports: daily / monthly summary cards plus PDF exports for
/// cash, party and stock reports.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late Future<_ReportData> _future;
  late Future<int> _issuesFuture;

  @override
  void initState() {
    super.initState();
    final bizId = context.read<AppProvider>().businessId;
    _future = _load(bizId);
    _issuesFuture =
        DatabaseHelper.instance.countDeletedBillsWithPostings(bizId);
  }

  /// Book Check card (Phase 3): warns when soft-deleted bills still
  /// have postings in stock/ledger/cash (written before the reversal
  /// engine) and offers a one-tap repair.
  Widget _bookCheckCard(AppProvider p) {
    return FutureBuilder<int>(
      future: _issuesFuture,
      builder: (c, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        final n = snap.data ?? 0;
        if (n == 0) {
          return Card(
            color: AppColors.green.withValues(alpha: 0.08),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.verified, color: AppColors.green),
              title: Text('${p.t('bookCheck')}: ${p.t('bookCheckOk')}',
                  style: const TextStyle(fontSize: 13)),
            ),
          );
        }
        return Card(
          color: AppColors.accent.withValues(alpha: 0.12),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.warning_amber, color: AppColors.accent),
            title: Text('$n ${p.t('bookCheckIssues')}',
                style: const TextStyle(fontSize: 13)),
            trailing: TextButton(
              onPressed: () async {
                final bizId = context.read<AppProvider>().businessId;
                await DatabaseHelper.instance.repairDeletedBills(bizId);
                if (!mounted) return;
                showSnack(context, p.t('repaired'));
                setState(() {
                  _future = _load(bizId);
                  _issuesFuture = DatabaseHelper.instance
                      .countDeletedBillsWithPostings(bizId);
                });
              },
              child: Text(p.t('repair')),
            ),
          ),
        );
      },
    );
  }

  Future<_ReportData> _load(int bizId) async {
    final db = DatabaseHelper.instance;
    final now = DateTime.now();
    final todayKey = dayKeyFmt.format(now);

    final businesses = await db.getBusinesses();
    var business = businesses.isNotEmpty
        ? businesses.first
        : Business(name: 'Namat Oil Mill');
    for (final b in businesses) {
      if (b.id == bizId) {
        business = b;
        break;
      }
    }

    final cashEntries = await db.getCashEntries(bizId);
    double todayIn = 0, todayOut = 0;
    for (final e in cashEntries) {
      if (dayKeyFmt.format(e.dateTime) == todayKey) {
        if (e.type == 'in') {
          todayIn += e.amount;
        } else {
          todayOut += e.amount;
        }
      }
    }

    final bills = await db.getBills(bizId);
    double todaySales = 0;
    for (final b in bills) {
      if (dayKeyFmt.format(b.dateTime) == todayKey) todaySales += b.total;
    }

    final monthSales = await db.getTotalSales(bizId, month: now);
    final monthExpenses = await db.getExpenseTotal(bizId, month: now);
    final cashBalance = await db.getCashBalance(bizId);
    final totals = await db.getPartyTotals(bizId);

    final parties = await db.getParties(bizId);
    final partyBalances = <int, double>{};
    for (final party in parties) {
      if (party.id != null) {
        partyBalances[party.id!] = await db.getPartyBalance(party.id!);
      }
    }

    final items = await db.getItems(bizId);
    final itemQtys = <int, double>{};
    final itemRates = <int, double>{};
    var lowCount = 0;
    var stockValue = 0.0;
    for (final item in items) {
      if (item.id != null) {
        final q = await db.getItemQty(item.id!);
        itemQtys[item.id!] = q;
        if (q <= item.lowStockLimit) lowCount++;
        // One valuation method for the whole app (Phase 2): the
        // perpetual unit cost, same as Production screens and COGS.
        final rate = await db.getItemUnitCost(item.id!);
        itemRates[item.id!] = rate;
        stockValue += q * rate;
      }
    }

    return _ReportData(
      business: business,
      cashEntries: cashEntries,
      cashBalance: cashBalance,
      todayCashIn: todayIn,
      todayCashOut: todayOut,
      todaySales: todaySales,
      monthSales: monthSales,
      monthExpenses: monthExpenses,
      willGet: totals.willGet,
      willGive: totals.willGive,
      lowStockCount: lowCount,
      parties: parties,
      partyBalances: partyBalances,
      items: items,
      itemQtys: itemQtys,
      itemRates: itemRates,
      totalStockValue: stockValue,
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(
          text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      );

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

  Widget _statGrid(List<Widget> cards) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.55,
      children: cards,
    );
  }

  /// Per-product stock valuation rows: name, qty × rate used = value,
  /// biggest value first; items with no stock on hand are skipped.
  List<Widget> _stockValueRows(AppProvider p, _ReportData d) {
    final valued = d.items.where((i) {
      final q = d.itemQtys[i.id] ?? 0;
      return q != 0;
    }).toList()
      ..sort((a, b) {
        final va = (d.itemQtys[a.id] ?? 0) * (d.itemRates[a.id] ?? 0);
        final vb = (d.itemQtys[b.id] ?? 0) * (d.itemRates[b.id] ?? 0);
        return vb.compareTo(va);
      });
    return [
      for (final item in valued)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            dense: true,
            title: Text(item.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
                '${formatQty(d.itemQtys[item.id] ?? 0)} ${item.unit} × ${formatRs(d.itemRates[item.id] ?? 0)}'),
            trailing: Text(
              formatRs((d.itemQtys[item.id] ?? 0) *
                  (d.itemRates[item.id] ?? 0)),
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ),
    ];
  }

  Future<void> _exportCash(AppProvider p, _ReportData d) async {
    await shareReportPdf(
      business: d.business,
      title: p.t('cashReport'),
      headers: const ['Date', 'Note', 'In', 'Out'],
      rows: d.cashEntries
          .map((e) => [
                dateTimeFmt.format(e.dateTime),
                e.note,
                e.type == 'in' ? formatRs(e.amount) : '',
                e.type == 'out' ? formatRs(e.amount) : '',
              ])
          .toList(),
      summaryLine: '${p.t('cashInHand')}: ${formatRs(d.cashBalance)}',
    );
  }

  Future<void> _exportParty(AppProvider p, _ReportData d) async {
    await shareReportPdf(
      business: d.business,
      title: p.t('partyReport'),
      headers: const ['Name', 'Type', 'Phone', 'Balance'],
      rows: d.parties
          .map((party) => [
                party.name,
                party.type == 'customer' ? p.t('customer') : p.t('supplier'),
                party.phone,
                formatRs(d.partyBalances[party.id] ?? 0),
              ])
          .toList(),
      summaryLine:
          '${p.t('youWillGet')}: ${formatRs(d.willGet)} • ${p.t('youWillGive')}: ${formatRs(d.willGive)}',
    );
  }

  Future<void> _exportStock(AppProvider p, _ReportData d) async {
    await shareReportPdf(
      business: d.business,
      title: p.t('stockReport'),
      headers: const ['Item', 'Qty', 'Unit', 'Rate', 'Value'],
      rows: d.items
          .map((item) => [
                item.name,
                formatQty(d.itemQtys[item.id] ?? 0),
                item.unit,
                formatRs(d.itemRates[item.id] ?? 0),
                formatRs((d.itemQtys[item.id] ?? 0) *
                    (d.itemRates[item.id] ?? 0)),
              ])
          .toList(),
      summaryLine:
          '${p.t('totalStockValue')}: ${formatRs(d.totalStockValue)} • ${p.t('lowStock')}: ${d.lowStockCount}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('reports'))),
      body: FutureBuilder<_ReportData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.hasData) {
            return Center(child: Text(p.t('noData')));
          }
          final d = snap.data!;
          final monthNet = d.monthSales - d.monthExpenses;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
            children: [
              _bookCheckCard(p),
              Card(
                color: AppColors.primary.withValues(alpha: 0.08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: AppColors.primary,
                    child: Icon(Icons.auto_stories, color: Colors.white),
                  ),
                  title: Text(
                    p.t('dailyClosing'),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  subtitle: Text(
                    p.isUrdu
                        ? 'صبح کا کیش، وصولی، ادائیگی اور پیداواری خلاصہ'
                        : 'Opening & closing cash, wasool, adaigi and production',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.primary),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RoznamchaScreen()),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              _sectionTitle(p.t('dailyReport')),
              _statGrid([
                _statCard(p.t('cashIn'), formatRs(d.todayCashIn), Icons.arrow_downward, AppColors.green),
                _statCard(p.t('cashOut'), formatRs(d.todayCashOut), Icons.arrow_upward, AppColors.red),
                _statCard(p.t('netCashFlow'), formatRs(d.todayCashIn - d.todayCashOut), Icons.swap_horiz, AppColors.primary),
                _statCard(p.t('totalSale'), formatRs(d.todaySales), Icons.point_of_sale, AppColors.accent),
              ]),
              _sectionTitle(p.t('monthlyReport')),
              _statGrid([
                _statCard(p.t('totalSale'), formatRs(d.monthSales), Icons.point_of_sale, AppColors.green),
                _statCard(p.t('expenses'), formatRs(d.monthExpenses), Icons.money_off, AppColors.red),
                _statCard(p.t('profitNote'), formatRs(monthNet), Icons.trending_up, AppColors.primary),
                _statCard(p.t('cashInHand'), formatRs(d.cashBalance), Icons.wallet, AppColors.accent),
              ]),
              _sectionTitle(p.t('outstanding')),
              _statGrid([
                _statCard(p.t('youWillGet'), formatRs(d.willGet), Icons.call_received, AppColors.green),
                _statCard(p.t('youWillGive'), formatRs(d.willGive), Icons.call_made, AppColors.red),
                _statCard(p.t('lowStock'), '${d.lowStockCount}', Icons.warning_amber, AppColors.accent),
              ]),
              _sectionTitle(p.t('stockValue')),
              _statGrid([
                _statCard(p.t('totalStockValue'), formatRs(d.totalStockValue), Icons.inventory_2, AppColors.primary),
              ]),
              ..._stockValueRows(p, d),
              _sectionTitle(p.t('downloadPdf')),
              ElevatedButton.icon(
                onPressed: () => _exportCash(p, d),
                icon: const Icon(Icons.picture_as_pdf),
                label: Text(p.t('cashReport')),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () => _exportParty(p, d),
                icon: const Icon(Icons.picture_as_pdf),
                label: Text(p.t('partyReport')),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () => _exportStock(p, d),
                icon: const Icon(Icons.picture_as_pdf),
                label: Text(p.t('stockReport')),
              ),
            ],
          );
        },
      ),
    );
  }
}
