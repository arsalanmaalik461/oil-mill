import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';
import 'party_form_screen.dart';

class _DetailData {
  final Party party;
  final List<PartyTransaction> transactions;
  final double balance;
  const _DetailData(this.party, this.transactions, this.balance);
}

/// One party's ledger: balance card, contact actions, transaction history
/// and Udhaar / Wasool entry buttons.
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

  Future<void> _showTxnForm(String type) async {
    final p = context.read<AppProvider>();
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var selectedDate = DateTime.now();
    String? attachment;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (bc) => StatefulBuilder(
        builder: (bc, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(bc).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.t(type),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: amountCtrl,
                  decoration: InputDecoration(labelText: p.t('amount')),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  decoration: InputDecoration(labelText: p.t('note')),
                ),
                const SizedBox(height: 6),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_month),
                  title: Text(dateTimeFmt.format(selectedDate)),
                  onTap: () async {
                    final picked = await pickDateTime(bc, selectedDate);
                    if (picked != null) {
                      setSheetState(() => selectedDate = picked);
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.camera_alt),
                  title: Text(attachment == null
                      ? p.t('attachBill')
                      : attachment!.split('/').last),
                  onTap: () async {
                    final path = await pickAttachment(bc);
                    if (path != null) setSheetState(() => attachment = path);
                  },
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: type == 'udhaar'
                          ? AppColors.red
                          : AppColors.green,
                    ),
                    onPressed: () async {
                      final amount =
                          double.tryParse(amountCtrl.text.trim());
                      if (amount == null || amount <= 0) {
                        showSnack(bc, p.t('invalidAmount'));
                        return;
                      }
                      await DatabaseHelper.instance.insertPartyTransaction(
                        PartyTransaction(
                          partyId: widget.party.id!,
                          type: type,
                          amount: amount,
                          note: noteCtrl.text.trim(),
                          dateTime: selectedDate,
                          attachmentPath: attachment,
                        ),
                      );
                      if (!bc.mounted) return;
                      Navigator.pop(bc);
                      if (!mounted) return;
                      _reload();
                      context.read<AppProvider>().bump();
                    },
                    child: Text(p.t('save')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    amountCtrl.dispose();
    noteCtrl.dispose();
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.party.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') _edit();
              if (v == 'delete') _deleteParty();
            },
            itemBuilder: (c) => [
              PopupMenuItem(value: 'edit', child: Text(p.t('edit'))),
              PopupMenuItem(value: 'delete', child: Text(p.t('delete'))),
            ],
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
          return Column(
            children: [
              Card(
                margin: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(p.t('balance'),
                          style: const TextStyle(color: AppColors.textGrey)),
                      const SizedBox(height: 4),
                      AmountText(balance,
                          positiveIsGreen: false, fontSize: 27),
                      if (balance != 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          balance > 0 ? p.t('youWillGet') : p.t('youWillGive'),
                          style: const TextStyle(color: AppColors.textGrey),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
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
                    _actionButton(Icons.picture_as_pdf, 'PDF', () async {
                      final biz = await _currentBusiness();
                      await shareLedgerPdf(
                        business: biz,
                        party: party,
                        transactions: data.transactions,
                        balance: balance,
                      );
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
              Expanded(
                child: data.transactions.isEmpty
                    ? Center(child: Text(p.t('noData')))
                    : ListView.separated(
                        itemCount: data.transactions.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final t = data.transactions[i];
                          final isUdhaar = t.type == 'udhaar';
                          final runBal =
                              t.id != null ? running[t.id!] : null;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isUdhaar
                                  ? const Color(0xFFFDE8E8)
                                  : const Color(0xFFE2F6E9),
                              child: Icon(
                                isUdhaar
                                    ? Icons.arrow_upward
                                    : Icons.arrow_downward,
                                color: isUdhaar
                                    ? AppColors.red
                                    : AppColors.green,
                                size: 19,
                              ),
                            ),
                            title: Text(t.note.isNotEmpty
                                ? t.note
                                : p.t(t.type)),
                            subtitle: Text(dateTimeFmt.format(t.dateTime)),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                AmountText(t.amount,
                                    positiveIsGreen: !isUdhaar),
                                if (runBal != null)
                                  Text(
                                    '${p.t('balance')}: ${formatRs(runBal.abs())}',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textGrey),
                                  ),
                              ],
                            ),
                            onLongPress: () => _deleteTransaction(t),
                          );
                        },
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
                  onPressed: () => _showTxnForm('udhaar'),
                  child: Text(p.t('udhaar')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.green),
                  onPressed: () => _showTxnForm('wasool'),
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
