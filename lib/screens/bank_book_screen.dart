import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import 'bank_detail_screen.dart';
import 'bank_form_screen.dart';

class BankBookScreen extends StatefulWidget {
  const BankBookScreen({super.key});

  @override
  State<BankBookScreen> createState() => _BankBookScreenState();
}

class _BankBookScreenState extends State<BankBookScreen> {
  final _db = DatabaseHelper.instance;
  List<BankAccount> _accounts = [];
  Map<int, double> _balances = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bizId = context.read<AppProvider>().businessId;
    final accounts = await _db.getBankAccounts(bizId);
    final balances = <int, double>{};
    for (final a in accounts) {
      balances[a.id!] = await _db.getBankBalance(a.id!);
    }
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _balances = balances;
      _loading = false;
    });
  }

  double get _totalBalance =>
      _balances.values.fold<double>(0, (s, v) => s + v);

  Future<void> _delete(BankAccount account) async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await _db.setBankDeleted(account.id!, true);
    if (!mounted) return;
    showSnack(context, p.t('deleted'));
    _load();
  }

  Future<void> _openForm([BankAccount? account]) async {
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => BankFormScreen(account: account)),
    );
    if (done == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('bankBook'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: Text(p.t('addBank')),
      ),
      body: Column(
        children: [
          GradientHeader(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(p.t('bankBalance'),
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    AmountText(_totalBalance, fontSize: 17),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _accounts.isEmpty
                    ? Center(child: Text(p.t('noData')))
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 90),
                        itemCount: _accounts.length,
                        itemBuilder: (context, i) {
                          final a = _accounts[i];
                          final balance = _balances[a.id] ?? 0;
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: ListTile(
                              leading: const CircleAvatar(
                                backgroundColor: Color(0xFFFFF3E8),
                                child: Icon(Icons.account_balance,
                                    color: AppColors.accent),
                              ),
                              title: Text(a.bankName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                [
                                  if (a.accountTitle.isNotEmpty) a.accountTitle,
                                  if (a.accountNo.isNotEmpty) a.accountNo,
                                ].join(' • '),
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AmountText(balance),
                                  PopupMenuButton<String>(
                                    onSelected: (v) {
                                      if (v == 'edit') _openForm(a);
                                      if (v == 'delete') _delete(a);
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text(p.t('edit')),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text(p.t('delete')),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          BankDetailScreen(account: a)),
                                );
                                _load();
                              },
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
