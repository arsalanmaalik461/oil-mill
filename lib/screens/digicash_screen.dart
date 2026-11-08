import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

const _channels = ['digicash', 'jazzcash', 'easypaisa', 'bank'];

String _channelKey(String channel) {
  switch (channel) {
    case 'digicash':
      return 'digiCash';
    case 'jazzcash':
      return 'jazzcash';
    case 'easypaisa':
      return 'easypaisa';
    default:
      return 'bank';
  }
}

IconData _channelIcon(String channel) {
  switch (channel) {
    case 'jazzcash':
    case 'easypaisa':
      return Icons.smartphone;
    case 'bank':
      return Icons.account_balance;
    default:
      return Icons.account_balance_wallet;
  }
}

String _typeKey(String type) {
  switch (type) {
    case 'in':
      return 'moneyIn';
    case 'out':
      return 'moneyOut';
    case 'request':
      return 'requestMoney';
    case 'send':
      return 'sendMoney';
    default:
      return 'recharge';
  }
}

IconData _typeIcon(String type) {
  switch (type) {
    case 'in':
      return Icons.call_received;
    case 'out':
      return Icons.call_made;
    case 'request':
      return Icons.request_page;
    case 'send':
      return Icons.send;
    default:
      return Icons.phone_android;
  }
}

class _WalletData {
  final Map<String, double> balances;
  final List<WalletTransaction> transactions;
  _WalletData(this.balances, this.transactions);
}

/// DigiCash / digital payments module. Also used as the bottom-nav
/// 'Money' tab, so it reloads whenever the provider tick or business changes.
class DigiCashScreen extends StatefulWidget {
  const DigiCashScreen({super.key});

  @override
  State<DigiCashScreen> createState() => _DigiCashScreenState();
}

class _DigiCashScreenState extends State<DigiCashScreen> {
  late Future<_WalletData> _future;
  int _seenTick = -1;
  int _seenBiz = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Provider.of<AppProvider>(context);
    if (p.tick != _seenTick || p.businessId != _seenBiz) {
      _seenTick = p.tick;
      _seenBiz = p.businessId;
      _future = _load(p.businessId);
    }
  }

  Future<_WalletData> _load(int bizId) async {
    final db = DatabaseHelper.instance;
    final balances = <String, double>{};
    for (final ch in _channels) {
      balances[ch] = await db.getWalletBalance(bizId, ch);
    }
    final txns = await db.getWalletTransactions(bizId);
    return _WalletData(balances, txns);
  }

  void _reload() {
    final p = context.read<AppProvider>();
    setState(() => _future = _load(p.businessId));
  }

  Future<String> _businessName(int bizId) async {
    final list = await DatabaseHelper.instance.getBusinesses();
    for (final b in list) {
      if (b.id == bizId) return b.name;
    }
    return list.isNotEmpty ? list.first.name : 'Namat Oil Mill';
  }

  Future<void> _openForm(String type) async {
    final p = context.read<AppProvider>();
    var channel = 'digicash';
    var when = DateTime.now();
    final amountC = TextEditingController();
    final phoneC = TextEditingController();
    final noteC = TextEditingController();
    final commissionC = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  p.t(_typeKey(type)),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: channel,
                  decoration: InputDecoration(labelText: p.t('channel')),
                  items: _channels
                      .map((c) => DropdownMenuItem(value: c, child: Text(p.t(_channelKey(c)))))
                      .toList(),
                  onChanged: (v) => setSheet(() => channel = v ?? channel),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: amountC,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: p.t('amount')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: phoneC,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: p.t('mobileNumber')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: noteC,
                  decoration: InputDecoration(labelText: p.t('note')),
                ),
                if (type == 'recharge') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: commissionC,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: p.t('commission')),
                  ),
                ],
                const SizedBox(height: 6),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event, color: AppColors.primary),
                  title: Text(p.t('date')),
                  subtitle: Text(dateTimeFmt.format(when)),
                  onTap: () async {
                    final picked = await pickDateTime(sheetCtx, when);
                    if (picked != null) setSheet(() => when = picked);
                  },
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () async {
                    final amount = double.tryParse(amountC.text.trim());
                    if (amount == null || amount <= 0) {
                      showSnack(sheetCtx, p.t('invalidAmount'));
                      return;
                    }
                    final phone = phoneC.text.trim();
                    await DatabaseHelper.instance.insertWalletTransaction(
                      WalletTransaction(
                        businessId: p.businessId,
                        channel: channel,
                        type: type,
                        amount: amount,
                        phone: phone,
                        note: noteC.text.trim(),
                        commission: type == 'recharge'
                            ? (double.tryParse(commissionC.text.trim()) ?? 0)
                            : 0,
                        dateTime: when,
                      ),
                    );
                    if (!sheetCtx.mounted) return;
                    Navigator.pop(sheetCtx);
                    // Collection-link placeholder: a plain WhatsApp message
                    // asking the customer to pay on any channel.
                    if (type == 'request' && phone.isNotEmpty) {
                      final bizName = await _businessName(p.businessId);
                      await openWhatsApp(
                        phone,
                        'Payment request of ${formatRs(amount)} from $bizName. '
                        'Please pay via JazzCash/Easypaisa/Bank. Thank you!',
                      );
                    }
                    if (!mounted) return;
                    p.bump();
                    _reload();
                  },
                  child: Text(p.t('save')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    amountC.dispose();
    phoneC.dispose();
    noteC.dispose();
    commissionC.dispose();
  }

  Future<void> _deleteTx(AppProvider p, WalletTransaction t) async {
    if (t.id == null) return;
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await DatabaseHelper.instance.deleteWalletTransaction(t.id!);
    if (!mounted) return;
    p.bump();
    _reload();
  }

  Widget _amountFor(WalletTransaction t) {
    switch (t.type) {
      case 'in':
        return Text(
          '+ ${formatRs(t.amount)}',
          style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w700, fontSize: 15),
        );
      case 'request':
        return Text(
          formatRs(t.amount),
          style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 15),
        );
      default: // out / send / recharge
        return Text(
          '- ${formatRs(t.amount)}',
          style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w700, fontSize: 15),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    const actions = ['in', 'out', 'request', 'send', 'recharge'];
    return Scaffold(
      appBar: AppBar(title: Text(p.t('digiCash'))),
      body: FutureBuilder<_WalletData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data ?? _WalletData(const {}, const []);
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              SizedBox(
                height: 96,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _channels.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, i) {
                    final ch = _channels[i];
                    return Container(
                      width: 150,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(_channelIcon(ch), size: 18, color: AppColors.accent),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  p.t(_channelKey(ch)),
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Text(
                            p.t('walletBalance'),
                            style: const TextStyle(fontSize: 11, color: AppColors.textGrey),
                          ),
                          Text(
                            formatRs(data.balances[ch] ?? 0),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.05,
                ),
                itemCount: actions.length,
                itemBuilder: (context, i) {
                  final type = actions[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _openForm(type),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(_typeIcon(type), color: AppColors.accent),
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              p.t(_typeKey(type)),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(
                p.t('recentTransactions'),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              if (data.transactions.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(p.t('noData'), style: const TextStyle(color: AppColors.textGrey)),
                  ),
                )
              else
                ...data.transactions.map(
                  (t) => Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppColors.primary.withValues(alpha: 0.10),
                        child: Icon(_typeIcon(t.type), color: AppColors.primary, size: 20),
                      ),
                      title: Text('${p.t(_typeKey(t.type))} • ${p.t(_channelKey(t.channel))}'),
                      subtitle: Text(
                        [
                          if (t.phone.isNotEmpty) t.phone,
                          if (t.note.isNotEmpty) t.note,
                          dateTimeFmt.format(t.dateTime),
                        ].join('\n'),
                      ),
                      trailing: _amountFor(t),
                      onLongPress: () => _deleteTx(p, t),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
