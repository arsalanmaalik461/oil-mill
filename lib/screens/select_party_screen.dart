import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import 'party_form_screen.dart';

/// Searchable party picker modelled on the original app's "Select Party"
/// page: search box, each party's balance with You'll Get / You'll Give,
/// and an "Add New" shortcut at the top. Pops with the chosen [Party].
class SelectPartyScreen extends StatefulWidget {
  /// 'customer' | 'supplier' | 'dealer' | null (all parties).
  final String? type;
  const SelectPartyScreen({super.key, this.type});

  @override
  State<SelectPartyScreen> createState() => _SelectPartyScreenState();
}

class _SelectPartyScreenState extends State<SelectPartyScreen> {
  final _search = TextEditingController();
  late Future<List<Party>> _future;
  final Map<int, double> _balances = {};
  Map<int, DateTime> _lastActivity = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<List<Party>> _load() async {
    final db = DatabaseHelper.instance;
    final bizId = context.read<AppProvider>().businessId;
    final parties = await db.getParties(bizId, type: widget.type);
    _balances.clear();
    for (final party in parties) {
      _balances[party.id!] = await db.getPartyBalance(party.id!);
    }
    _lastActivity = await db.getPartyLastActivity(bizId);
    return parties;
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _addNew() async {
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PartyFormScreen(type: widget.type ?? 'customer'),
      ),
    );
    if (r == true && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('selectParty'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: p.t('search'),
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: AppColors.primary,
              child: Icon(Icons.person_add, color: Colors.white, size: 20),
            ),
            title: Text(
              '${p.t('addNewParty')} ${p.t(widget.type ?? 'customer')}',
              style: const TextStyle(
                  color: AppColors.primary, fontWeight: FontWeight.w600),
            ),
            onTap: _addNew,
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<Party>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final q = _search.text.trim().toLowerCase();
                final parties = snap.data!
                    .where((e) =>
                        q.isEmpty ||
                        e.name.toLowerCase().contains(q) ||
                        e.phone.contains(q))
                    .toList();
                if (parties.isEmpty) {
                  return Center(child: Text(p.t('noData')));
                }
                return ListView.separated(
                  itemCount: parties.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final party = parties[i];
                    final bal = _balances[party.id!] ?? 0;
                    final last = _lastActivity[party.id!];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.12),
                        child: Text(initials(party.name),
                            style: const TextStyle(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w700,
                                fontSize: 13)),
                      ),
                      title: Text(party.name),
                      subtitle: Text(last != null
                          ? dateFmt.format(last)
                          : (party.phone.isNotEmpty
                              ? party.phone
                              : p.t('noEntriesYet'))),
                      trailing: bal == 0
                          ? null
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                AmountText(bal.abs(),
                                    positiveIsGreen: bal < 0),
                                Text(
                                  bal > 0
                                      ? p.t('youWillGet')
                                      : p.t('youWillGive'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: bal > 0
                                        ? AppColors.red
                                        : AppColors.green,
                                  ),
                                ),
                              ],
                            ),
                      onTap: () => Navigator.pop(context, party),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
