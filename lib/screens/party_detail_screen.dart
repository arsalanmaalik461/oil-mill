import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';
import 'party_entry_detail_screen.dart';
import 'party_entry_form_screen.dart';
import 'party_form_screen.dart';

class _DetailData {
  final Party party;
  final List<PartyTransaction> transactions;
  final double balance;
  const _DetailData(this.party, this.transactions, this.balance);
}

/// One party's ledger, modelled on the original khata app: balance card,
/// Report / Set Date / Reminder / SMS actions, a ⋮ menu with profile,
/// switch-type and business card, entries in You Gave / You Got columns,
/// and tap-an-entry detail.
class PartyDetailScreen extends StatefulWidget {
  final Party party;
  const PartyDetailScreen({super.key, required this.party});

  @override
  State<PartyDetailScreen> createState() => _PartyDetailScreenState();
}

class _PartyDetailScreenState extends State<PartyDetailScreen> {
  late Future<_DetailData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_DetailData> _load() async {
    final db = DatabaseHelper.instance;
    final fresh = await db.getParty(widget.party.id!) ?? widget.party;
    final txns = await db.getPartyTransactions(widget.party.id!);
    final balance = await db.getPartyBalance(widget.party.id!);
    return _DetailData(fresh, txns, balance);
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

  /// Running balance after each transaction, keyed by transaction id.
  Map<int, double> _runningBalances(_DetailData data) {
    final sorted = [...data.transactions]..sort((a, b) {
        final c = a.dateTime.compareTo(b.dateTime);
        return c != 0 ? c : (a.id ?? 0).compareTo(b.id ?? 0);
      });
    var running = data.party.openingBalance;
    final map = <int, double>{};
    for (final t in sorted) {
      running += t.type == 'udhaar' ? t.amount : -t.amount;
      if (t.id != null) map[t.id!] = running;
    }
    return map;
  }

  /// One of the two summary boxes on the party ledger header.
  Widget _sumBox(String label, double amount,
      {required bool isGreen, required IconData icon}) {
    final color = isGreen ? AppColors.green : AppColors.red;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          AmountText(amount, positiveIsGreen: isGreen, fontSize: 19),
        ],
      ),
    );
  }

  String _reminderText(Party party, double balance, String businessName) {
    if (balance > 0) {
      return 'Dear ${party.name}, your outstanding balance at $businessName '
          'is ${formatRs(balance)}. Please pay at the earliest. Thank you!';
    }
    if (balance < 0) {
      return 'We will send your payment of ${formatRs(-balance)} soon. '
          '- $businessName';
    }
    return 'Hello ${party.name}, your ledger at $businessName is clear. '
        'Thank you!';
  }

  Party _copyParty(Party party,
      {String? type, DateTime? dueDate, bool clearDueDate = false}) {
    return Party(
      id: party.id,
      businessId: party.businessId,
      type: type ?? party.type,
      name: party.name,
      phone: party.phone,
      address: party.address,
      openingBalance: party.openingBalance,
      deleted: party.deleted,
      lastReminderAt: party.lastReminderAt,
      dueDate: clearDueDate ? null : (dueDate ?? party.dueDate),
    );
  }

  Future<void> _edit() async {
    final fresh =
        await DatabaseHelper.instance.getParty(widget.party.id!) ?? widget.party;
    if (!mounted) return;
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => PartyFormScreen(type: fresh.type, party: fresh)),
    );
    if (r == true && mounted) {
      _reload();
      context.read<AppProvider>().bump();
    }
  }

  Future<void> _switchType(Party party) async {
    final p = context.read<AppProvider>();
    final newType = party.type == 'customer' ? 'supplier' : 'customer';
    await DatabaseHelper.instance.updateParty(_copyParty(party, type: newType));
    if (!mounted) return;
    showSnack(context, p.t('savedSuccessfully'));
    _reload();
    context.read<AppProvider>().bump();
  }

  Future<void> _shareBusinessCard() async {
    final biz = await _currentBusiness();
    final lines = <String>[
      biz.name,
      if (biz.owner.isNotEmpty) biz.owner,
      if (biz.phone.isNotEmpty) biz.phone,
      if (biz.address.isNotEmpty) biz.address,
    ];
    await shareText(lines.join('\n'));
  }

  Future<void> _setDate(Party party) async {
    final picked = await pickDateOnly(context, party.dueDate ?? DateTime.now());
    if (picked == null || !mounted) return;
    final date = DateTime(picked.year, picked.month, picked.day);
    await DatabaseHelper.instance.updateParty(_copyParty(party, dueDate: date));
    if (!mounted) return;
    _reload();
    context.read<AppProvider>().bump();
  }

  Future<void> _clearDate(Party party) async {
    await DatabaseHelper.instance
        .updateParty(_copyParty(party, clearDueDate: true));
    if (!mounted) return;
    _reload();
    context.read<AppProvider>().bump();
  }

  Future<void> _deleteParty() async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await DatabaseHelper.instance.setPartyDeleted(widget.party.id!, true);
    if (!mounted) return;
    showSnack(context, p.t('deleted'));
    context.read<AppProvider>().bump();
    Navigator.pop(context, true);
  }

  Future<void> _deleteTransaction(PartyTransaction t) async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await DatabaseHelper.instance.deletePartyTransaction(t.id!);
    if (!mounted) return;
    _reload();
    context.read<AppProvider>().bump();
  }

  Future<void> _openEntryForm(String type, Party party) async {
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PartyEntryFormScreen(party: party, type: type),
      ),
    );
    if (r == true && mounted) _reload();
  }

  Future<void> _openEntryDetail(
      Party party, PartyTransaction t, Map<int, double> running) async {
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PartyEntryDetailScreen(
          party: party,
          transaction: t,
          runningBalance: t.id != null ? (running[t.id!] ?? 0) : 0,
        ),
      ),
    );
    if (r == true && mounted) _reload();
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  /// One ledger entry in the original layout: date-time header, note,
  /// pink "Bal." chip, and the amount in the You Gave / You Got column.
  Widget _entryRow(AppProvider p, Party party, PartyTransaction t,
      Map<int, double> running) {
    final isUdhaar = t.type == 'udhaar';
    final runBal = t.id != null ? running[t.id!] : null;
    Widget amountCol(bool gave) {
      final show = gave == isUdhaar;
      return SizedBox(
        width: 82,
        child: show
            ? AmountText(t.amount, positiveIsGreen: !gave, fontSize: 14.5)
            : null,
      );
    }

    return InkWell(
      onTap: () => _openEntryDetail(party, t, running),
      onLongPress: () => _deleteTransaction(t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DateFormat('EEE, dd MMM yy • hh:mm a').format(t.dateTime),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textGrey),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    t.note.isNotEmpty ? t.note : p.t(t.type),
                    style: const TextStyle(fontSize: 14.5),
                  ),
                  if (runBal != null) ...[
                    const SizedBox(height: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFCE4EC),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Bal. ${formatRs(runBal.abs())}${runBal < 0 ? ' cr' : ''}',
                        style: const TextStyle(
                            fontSize: 11.5, color: Color(0xFF880E4F)),
                      ),
                    ),
                  ],
                  if (t.attachmentPath != null &&
                      t.attachmentPath!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    AttachmentThumb(path: t.attachmentPath!, size: 44),
                  ],
                ],
              ),
            ),
            amountCol(true),
            amountCol(false),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.party.name),
        actions: [
          FutureBuilder<_DetailData>(
            future: _future,
            builder: (context, snap) {
              final party = snap.data?.party ?? widget.party;
              return PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') _edit();
                  if (v == 'switch') _switchType(party);
                  if (v == 'card') _shareBusinessCard();
                  if (v == 'report' && snap.data != null) {
                    final data = snap.data!;
                    _currentBusiness().then((biz) => shareLedgerPdf(
                          business: biz,
                          party: data.party,
                          transactions: data.transactions,
                          balance: data.balance,
                        ));
                  }
                  if (v == 'delete') _deleteParty();
                },
                itemBuilder: (c) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(party.type == 'supplier'
                        ? p.t('supplierProfile')
                        : p.t('customerProfile')),
                  ),
                  if (party.type == 'customer' || party.type == 'supplier')
                    PopupMenuItem(
                      value: 'switch',
                      child: Text(party.type == 'customer'
                          ? p.t('switchToSupplier')
                          : p.t('switchToCustomer')),
                    ),
                  PopupMenuItem(
                      value: 'card', child: Text(p.t('businessCard'))),
                  PopupMenuItem(
                      value: 'report', child: Text(p.t('reportLabel'))),
                  PopupMenuItem(value: 'delete', child: Text(p.t('delete'))),
                ],
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<_DetailData>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!;
          final party = data.party;
          final balance = data.balance;
          final running = _runningBalances(data);
          var totalGave =
              party.openingBalance > 0 ? party.openingBalance : 0.0;
          var totalGot = party.openingBalance < 0 ? -party.openingBalance : 0.0;
          for (final t in data.transactions) {
            if (t.type == 'udhaar') {
              totalGave += t.amount;
            } else {
              totalGot += t.amount;
            }
          }
          return Column(
            children: [
              Card(
                margin: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _sumBox(p.t('udhaar'), totalGave,
                                isGreen: false, icon: Icons.arrow_upward),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _sumBox(p.t('wasool'), totalGot,
                                isGreen: true, icon: Icons.arrow_downward),
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('${p.t('balance')}: ',
                              style: const TextStyle(
                                  color: AppColors.textGrey, fontSize: 15)),
                          AmountText(balance,
                              positiveIsGreen: false, fontSize: 19),
                          if (balance != 0) ...[
                            const SizedBox(width: 6),
                            Text(
                              balance > 0
                                  ? '(${p.t('youWillGet')})'
                                  : '(${p.t('youWillGive')})',
                              style: const TextStyle(
                                  color: AppColors.textGrey, fontSize: 13),
                            ),
                          ],
                        ],
                      ),
                      if (party.dueDate != null) ...[
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.event,
                                size: 16, color: AppColors.primary),
                            const SizedBox(width: 5),
                            Text(
                              '${p.t('paymentDate')}: ${DateFormat('dd MMM yyyy').format(party.dueDate!)}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              tooltip: p.t('clearDate'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _clearDate(party),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    _actionButton(Icons.picture_as_pdf, p.t('reportLabel'),
                        () async {
                      final biz = await _currentBusiness();
                      await shareLedgerPdf(
                        business: biz,
                        party: party,
                        transactions: data.transactions,
                        balance: balance,
                      );
                    }),
                    _actionButton(Icons.calendar_month, p.t('setDate'),
                        () => _setDate(party)),
                    _actionButton(Icons.chat_bubble, p.t('whatsappReminder'),
                        () async {
                      if (party.phone.trim().isEmpty) {
                        showSnack(context, p.t('noPhone'));
                        return;
                      }
                      final biz = await _currentBusiness();
                      await openWhatsApp(party.phone,
                          _reminderText(party, balance, biz.name));
                    }),
                    _actionButton(Icons.sms, p.t('smsReminder'), () async {
                      if (party.phone.trim().isEmpty) {
                        showSnack(context, p.t('noPhone'));
                        return;
                      }
                      final biz = await _currentBusiness();
                      await openSms(party.phone,
                          _reminderText(party, balance, biz.name));
                    }),
                    _actionButton(Icons.call, p.t('callNow'), () async {
                      if (party.phone.trim().isEmpty) {
                        showSnack(context, p.t('noPhone'));
                        return;
                      }
                      await callPhone(party.phone);
                    }),
                    _actionButton(Icons.share, p.t('share'), () async {
                      final biz = await _currentBusiness();
                      final label = balance > 0
                          ? p.t('youWillGet')
                          : p.t('youWillGive');
                      await shareText(
                        '${p.t('ledger')} — ${party.name}\n${biz.name}\n'
                        '${p.t('balance')}: ${formatRs(balance.abs())} '
                        '(${balance == 0 ? p.t('balance') : label})',
                      );
                    }),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (data.transactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 12, 2),
                  child: Row(
                    children: [
                      const Spacer(),
                      SizedBox(
                        width: 82,
                        child: Text(p.t('udhaar'),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.red)),
                      ),
                      SizedBox(
                        width: 82,
                        child: Text(p.t('wasool'),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.green)),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: data.transactions.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.lock_outline,
                                size: 40, color: AppColors.textGrey),
                            const SizedBox(height: 10),
                            Text(p.t('onlyYouCanSee'),
                                style: const TextStyle(
                                    color: AppColors.textGrey)),
                            const SizedBox(height: 26),
                            Text(p.t('addFirstEntry'),
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                            const Icon(Icons.arrow_downward,
                                color: AppColors.primary),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: data.transactions.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) =>
                            _entryRow(p, party, data.transactions[i], running),
                      ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.red),
                  onPressed: () => _openEntryForm('udhaar', widget.party),
                  child: Text(p.t('udhaar')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.green),
                  onPressed: () => _openEntryForm('wasool', widget.party),
                  child: Text(p.t('wasool')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
