import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';
import 'bank_detail_screen.dart';
import 'bill_book_screen.dart';
import 'cash_book_screen.dart';
import 'party_detail_screen.dart';
import 'party_form_screen.dart';
import 'recycle_bin_screen.dart';
import 'roznamcha_screen.dart';
import 'staff_book_screen.dart';
import 'stock_book_screen.dart';

class _PartyRow {
  final Party party;
  final double balance;
  final DateTime? lastDate;
  const _PartyRow(this.party, this.balance, this.lastDate);
}

class _BankRow {
  final BankAccount account;
  final double balance;
  const _BankRow(this.account, this.balance);
}

class _HomeData {
  final Business business;
  final List<_PartyRow> parties;
  final List<_BankRow> banks;
  final double willGet;
  final double willGive;
  final double bankTotal;
  const _HomeData({
    required this.business,
    required this.parties,
    required this.banks,
    required this.willGet,
    required this.willGive,
    required this.bankTotal,
  });
}

/// Home tab: gradient header with Customers / Suppliers / Dealers / Banks /
/// All tabs,
/// give/get summary card, module shortcuts and the party (or bank) list —
/// layout copied from the reference screenshots.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _tab = 'customers'; // customers | suppliers | dealers | banks | all
  String _search = '';
  bool _hideBalance = false;
  Future<_HomeData>? _future;
  int _seenTick = -1;
  int _seenBiz = -1;
  String _seenTab = '';

  Future<_HomeData> _load(int bizId) async {
    final db = DatabaseHelper.instance;
    final businesses = await db.getBusinesses();
    var business =
        businesses.isNotEmpty ? businesses.first : Business(name: 'Namat Oil Mill');
    for (final b in businesses) {
      if (b.id == bizId) {
        business = b;
        break;
      }
    }
    final type = _tab == 'customers'
        ? 'customer'
        : _tab == 'suppliers'
            ? 'supplier'
            : _tab == 'dealers'
                ? 'dealer'
                : null;
    final parties =
        _tab == 'banks' ? <Party>[] : await db.getParties(bizId, type: type);
    final partyRows = <_PartyRow>[];
    for (final party in parties) {
      final bal = await db.getPartyBalance(party.id!);
      final txns = await db.getPartyTransactions(party.id!);
      partyRows.add(
          _PartyRow(party, bal, txns.isEmpty ? null : txns.first.dateTime));
    }
    final totals = await db.getPartyTotals(bizId, type: type);
    final accounts = await db.getBankAccounts(bizId);
    final bankRows = <_BankRow>[];
    var bankTotal = 0.0;
    for (final a in accounts) {
      final bal = await db.getBankBalance(a.id!);
      bankRows.add(_BankRow(a, bal));
      bankTotal += bal;
    }
    return _HomeData(
      business: business,
      parties: partyRows,
      banks: bankRows,
      willGet: totals.willGet,
      willGive: totals.willGive,
      bankTotal: bankTotal,
    );
  }

  void _ensureFuture(AppProvider p) {
    if (_future == null ||
        _seenTick != p.tick ||
        _seenBiz != p.businessId ||
        _seenTab != _tab) {
      _seenTick = p.tick;
      _seenBiz = p.businessId;
      _seenTab = _tab;
      _future = _load(p.businessId);
    }
  }

  void _forceRefresh() => setState(() => _seenTick = -1);

  // ---------------- party actions ----------------

  Future<void> _openParty(Party party) async {
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PartyDetailScreen(party: party)),
    );
    if (r == true && mounted) _forceRefresh();
  }

  Future<void> _editParty(Party party) async {
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => PartyFormScreen(type: party.type, party: party)),
    );
    if (r == true && mounted) _forceRefresh();
  }

  Future<void> _deleteParty(Party party) async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await DatabaseHelper.instance.setPartyDeleted(party.id!, true);
    if (!mounted) return;
    showSnack(context, p.t('deleted'));
    _forceRefresh();
  }

  Future<void> _partyMenu(Party party) async {
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
              onTap: () {
                Navigator.pop(c);
                _editParty(party);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppColors.red),
              title: Text(p.t('delete')),
              onTap: () {
                Navigator.pop(c);
                _deleteParty(party);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _remind(_PartyRow row, _HomeData data, {required bool request}) {
    final p = context.read<AppProvider>();
    final party = row.party;
    if (party.phone.trim().isEmpty) {
      showSnack(context, p.t('noPhone'));
      return;
    }
    final msg = request
        ? 'Dear ${party.name}, your outstanding balance at '
            '${data.business.name} is ${formatRs(row.balance)}. '
            'Please pay at the earliest. Thank you!'
        : 'We will send your payment of ${formatRs(-row.balance)} soon. '
            '- ${data.business.name}';
    openWhatsApp(party.phone, msg);
  }

  Future<void> _addParty() async {
    if (_tab == 'suppliers') {
      await _pushPartyForm('supplier');
    } else if (_tab == 'dealers') {
      await _pushPartyForm('dealer');
    } else if (_tab == 'all') {
      final p = context.read<AppProvider>();
      final type = await showModalBottomSheet<String>(
        context: context,
        builder: (c) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.person),
                title: Text(p.t('customers')),
                onTap: () => Navigator.pop(c, 'customer'),
              ),
              ListTile(
                leading: const Icon(Icons.local_shipping),
                title: Text(p.t('suppliers')),
                onTap: () => Navigator.pop(c, 'supplier'),
              ),
              ListTile(
                leading: const Icon(Icons.storefront),
                title: Text(p.t('dealers')),
                onTap: () => Navigator.pop(c, 'dealer'),
              ),
            ],
          ),
        ),
      );
      if (type != null && mounted) await _pushPartyForm(type);
    } else {
      await _pushPartyForm('customer');
    }
  }

  Future<void> _pushPartyForm(String type) async {
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PartyFormScreen(type: type)),
    );
    if (r == true && mounted) _forceRefresh();
  }

  Future<void> _exportPdf(_HomeData data) async {
    final p = context.read<AppProvider>();
    if (_tab == 'banks') {
      await shareReportPdf(
        business: data.business,
        title: p.t('bankBook'),
        headers: [p.t('bankName'), p.t('accountNo'), p.t('bankBalance')],
        rows: data.banks
            .map((r) => [
                  r.account.bankName,
                  r.account.accountNo,
                  formatRs(r.balance),
                ])
            .toList(),
        summaryLine: '${p.t('total')}: ${formatRs(data.bankTotal)}',
      );
      return;
    }
    await shareReportPdf(
      business: data.business,
      title: p.t('partyReport'),
      headers: [p.t('name'), p.t('phone'), p.t('balance')],
      rows: data.parties
          .map((r) => [r.party.name, r.party.phone, formatRs(r.balance)])
          .toList(),
    );
  }

  // ---------------- UI pieces ----------------

  Widget _tabChip(String value, String label) {
    final selected = _tab == value;
    return InkWell(
      onTap: () => setState(() => _tab = value),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 13),
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white70,
                fontSize: 15,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          Container(
            height: 3,
            color: selected ? Colors.white : Colors.transparent,
          ),
        ],
      ),
    );
  }

  Widget _moduleButton(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Icon(icon, color: AppColors.accent, size: 24),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(AppProvider p, _HomeData data) {
    String amountText(double v) => _hideBalance ? '••••••' : formatRs(v);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton(
              onPressed: () => setState(() => _hideBalance = !_hideBalance),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _hideBalance ? p.t('showBalance') : p.t('hideBalance'),
                style: const TextStyle(color: AppColors.primary),
              ),
            ),
            if (_tab == 'banks')
              Column(
                children: [
                  Text(
                    amountText(data.bankTotal),
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: AppColors.green,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(p.t('bankBalance'),
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textGrey)),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          amountText(data.willGive),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: AppColors.green,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(p.t('youWillGive'),
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textGrey)),
                      ],
                    ),
                  ),
                  Container(
                      width: 1, height: 36, color: AppColors.cardBorder),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          amountText(data.willGet),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: AppColors.red,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(p.t('youWillGet'),
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textGrey)),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _partyTile(AppProvider p, _PartyRow row, _HomeData data) {
    final balance = row.balance;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFFFFE3D3),
        child: Text(
          initials(row.party.name),
          style: const TextStyle(
              color: AppColors.primaryDark, fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(row.party.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle:
          Text(row.lastDate == null ? '' : dateTimeFmt.format(row.lastDate!)),
      trailing: balance == 0
          ? const AmountText(0)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                AmountText(balance, positiveIsGreen: false),
                const SizedBox(height: 4),
                OutlinedButton(
                  onPressed: () =>
                      _remind(row, data, request: balance > 0),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        balance > 0 ? AppColors.red : AppColors.green,
                    side: BorderSide(
                        color: balance > 0 ? AppColors.red : AppColors.green),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                    minimumSize: const Size(0, 27),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  child: Text(p.t(balance > 0 ? 'request' : 'send')),
                ),
              ],
            ),
      onTap: () => _openParty(row.party),
      onLongPress: () => _partyMenu(row.party),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    _ensureFuture(p);
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<_HomeData>(
          future: _future,
          builder: (context, snap) {
            final data = snap.data;
            final tabCount = _tab == 'banks'
                ? (data?.banks.length ?? 0)
                : (data?.parties.length ?? 0);
            return Column(
              children: [
                GradientHeader(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              data?.business.name ?? 'Namat Oil Mill',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.calendar_month,
                                color: Colors.white),
                            onPressed: () {},
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _tabChip('customers', p.t('customers')),
                            _tabChip('suppliers', p.t('suppliers')),
                            _tabChip('dealers', p.t('dealers')),
                            _tabChip('banks', p.t('banks')),
                            _tabChip('all', p.t('all')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (data == null)
                  const Expanded(
                      child: Center(child: CircularProgressIndicator()))
                else ...[
                  _summaryCard(p, data),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _moduleButton(Icons.book, p.t('cashBook'), () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const CashBookScreen()));
                        }),
                        _moduleButton(Icons.auto_stories, p.t('roznamcha'), () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const RoznamchaScreen()));
                        }),
                        _moduleButton(Icons.inventory_2, p.t('stockBook'), () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const StockBookScreen()));
                        }),
                        _moduleButton(Icons.receipt_long, p.t('billBook'), () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => BillBookScreen()));
                        }),
                        _moduleButton(Icons.groups, p.t('staffBook'), () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => StaffBookScreen()));
                        }),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            onChanged: (v) => setState(() => _search = v),
                            decoration: InputDecoration(
                              hintText: '$tabCount ${p.t(_tab)}',
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
                          onPressed: () => _exportPdf(data),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: _buildList(p, data)),
                ],
              ],
            );
          },
        ),
      ),
      floatingActionButton: _tab == 'banks'
          ? null
          : FloatingActionButton.extended(
              onPressed: _addParty,
              icon: const Icon(Icons.person_add),
              label: Text(p.t(_tab == 'suppliers'
                  ? 'addSupplier'
                  : _tab == 'dealers'
                      ? 'addDealer'
                      : _tab == 'all'
                          ? 'addParty'
                          : 'addCustomer')),
            ),
    );
  }

  Widget _buildList(AppProvider p, _HomeData data) {
    final q = _search.trim().toLowerCase();
    if (_tab == 'banks') {
      final visible = data.banks
          .where((r) =>
              q.isEmpty || r.account.bankName.toLowerCase().contains(q))
          .toList();
      if (visible.isEmpty) return Center(child: Text(p.t('noData')));
      return ListView.separated(
        itemCount: visible.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final row = visible[i];
          return ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFFFE3D3),
              child: Icon(Icons.account_balance,
                  color: AppColors.primaryDark, size: 20),
            ),
            title: Text(row.account.bankName,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(row.account.accountNo),
            trailing: AmountText(row.balance),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => BankDetailScreen(account: row.account)),
              );
              if (mounted) _forceRefresh();
            },
          );
        },
      );
    }
    final visible = data.parties
        .where(
            (r) => q.isEmpty || r.party.name.toLowerCase().contains(q))
        .toList();
    if (visible.isEmpty) return Center(child: Text(p.t('noData')));
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => _partyTile(p, visible[i], data),
    );
  }
}
