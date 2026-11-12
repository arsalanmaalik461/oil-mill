import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';
import '../services/firebase_service.dart';
import 'bank_detail_screen.dart';
import 'party_detail_screen.dart';
import 'party_form_screen.dart';
import 'reminders_screen.dart';

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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _autoSyncOnStart());
  }

  /// A returning, already-signed-in user gets a background cloud sync
  /// when the app opens, so the Firebase backup stays current on its own.
  Future<void> _autoSyncOnStart() async {
    final p = context.read<AppProvider>();
    if (!p.isLoggedIn || p.businessId <= 0) return;
    try {
      await FirebaseService.instance
          .syncUserData(p.sessionUsername, p.businessId);
    } catch (_) {}
  }

  String _tab = 'customers'; // customers | suppliers | dealers | banks | all
  String _search = '';
  String _filter = 'all'; // all | get | give (party list filter)
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
    // One aggregate query for the whole list (was: a balance query
    // plus a full entries fetch for every single party).
    final summaries = _tab == 'banks'
        ? <({Party party, double balance, DateTime? lastDate})>[]
        : await db.getPartySummaries(bizId, type: type);
    final partyRows = summaries
        .map((s) => _PartyRow(s.party, s.balance, s.lastDate))
        .toList();
    final totals = await db.getPartyTotals(bizId, type: type);
    final accounts = await db.getBankAccounts(bizId);
    final bankBalances = await db.getBankBalances(bizId);
    final bankRows = <_BankRow>[];
    var bankTotal = 0.0;
    for (final a in accounts) {
      final bal = bankBalances[a.id] ?? a.openingBalance;
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
      try {
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
      } catch (_) {
        if (mounted) showSnack(context, p.t('pdfError'));
      }
      return;
    }
    // Business-wide Account Statement in the original app's format,
    // covering the parties of the current tab, for a chosen date range.
    final range = await pickDateRange(context, p.t);
    if (range == null || !mounted) return;
    final db = DatabaseHelper.instance;
    final parties = data.parties.map((r) => r.party).toList();
    final byParty = <int, List<PartyTransaction>>{};
    for (final party in parties) {
      final txns = await db.getPartyTransactions(party.id!);
      byParty[party.id!] = txns
          .where((t) => inDateRange(t.dateTime, range.start, range.end))
          .toList();
    }
    try {
      await shareStatementPdf(
        business: data.business,
        parties: parties,
        transactionsByParty: byParty,
        periodLabel: range.start == null ? null : range.label,
      );
    } catch (_) {
      if (mounted) showSnack(context, p.t('pdfError'));
    }
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _hideBalance
                        ? Icons.visibility
                        : Icons.visibility_off,
                    size: 17,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _hideBalance ? p.t('showBalance') : p.t('hideBalance'),
                    style: const TextStyle(color: AppColors.primary),
                  ),
                ],
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
      trailing: _hideBalance
          ? const Text('••••••',
              style: TextStyle(fontSize: 15, color: AppColors.textGrey))
          : balance == 0
              ? const AmountText(0)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    AmountText(balance, positiveIsGreen: false),
                    const SizedBox(height: 2),
                    Text(
                      balance > 0 ? p.t('youWillGet') : p.t('youWillGive'),
                      style: TextStyle(
                        fontSize: 11,
                        color:
                            balance > 0 ? AppColors.red : AppColors.green,
                      ),
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
                          TextButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const RemindersScreen()),
                            ),
                            icon: const Icon(Icons.collections_bookmark,
                                color: Colors.white, size: 18),
                            label: Text(p.t('collection'),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12.5)),
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
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.filter_list,
                              color: AppColors.primary),
                          onSelected: (v) => setState(() => _filter = v),
                          itemBuilder: (c) => [
                            PopupMenuItem(
                                value: 'all', child: Text(p.t('all'))),
                            PopupMenuItem(
                                value: 'get', child: Text(p.t('youWillGet'))),
                            PopupMenuItem(
                                value: 'give',
                                child: Text(p.t('youWillGive'))),
                          ],
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
        .where((r) => q.isEmpty || r.party.name.toLowerCase().contains(q))
        .where((r) =>
            _filter == 'all' ||
            (_filter == 'get' && r.balance > 0) ||
            (_filter == 'give' && r.balance < 0))
        .toList();
    if (visible.isEmpty) return Center(child: Text(p.t('noData')));
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => _partyTile(p, visible[i], data),
    );
  }
}
