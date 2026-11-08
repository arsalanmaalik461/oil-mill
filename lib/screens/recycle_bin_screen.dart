import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

/// Recycle Bin: soft-deleted parties, items, bills, staff and bank accounts,
/// each with Restore and Delete Forever actions.
class RecycleBinScreen extends StatelessWidget {
  const RecycleBinScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final db = DatabaseHelper.instance;
    final bizId = p.businessId;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(p.t('recycleBin')),
          bottom: TabBar(
            isScrollable: true,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [
              Tab(text: p.t('parties')),
              Tab(text: p.t('items')),
              Tab(text: p.t('bills')),
              Tab(text: p.t('staff')),
              Tab(text: p.t('banks')),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _BinTab<Party>(
              loader: () => db.getParties(bizId, deleted: true),
              titleOf: (party) => party.name,
              subtitleOf: (party) => [
                party.type == 'customer' ? p.t('customer') : p.t('supplier'),
                if (party.phone.isNotEmpty) party.phone,
              ].join(' • '),
              idOf: (party) => party.id,
              onRestore: (party) => db.setPartyDeleted(party.id!, false),
              onDeleteForever: (party) => db.deletePartyForever(party.id!),
            ),
            _BinTab<StockItem>(
              loader: () => db.getItems(bizId, deleted: true),
              titleOf: (item) => item.name,
              subtitleOf: (item) => item.unit,
              idOf: (item) => item.id,
              onRestore: (item) => db.setItemDeleted(item.id!, false),
              onDeleteForever: (item) => db.deleteItemForever(item.id!),
            ),
            _BinTab<Bill>(
              loader: () => db.getBills(bizId, deleted: true),
              titleOf: (bill) => '${p.t('billNo')} ${bill.billNo} — ${bill.partyName}',
              subtitleOf: (bill) =>
                  '${dateTimeFmt.format(bill.dateTime)} • ${formatRs(bill.total)}',
              idOf: (bill) => bill.id,
              onRestore: (bill) => db.setBillDeleted(bill.id!, false),
              onDeleteForever: (bill) => db.deleteBillForever(bill.id!),
            ),
            _BinTab<Staff>(
              loader: () => db.getStaffList(bizId, deleted: true),
              titleOf: (staff) => staff.name,
              subtitleOf: (staff) => staff.phone,
              idOf: (staff) => staff.id,
              onRestore: (staff) => db.setStaffDeleted(staff.id!, false),
              onDeleteForever: (staff) => db.deleteStaffForever(staff.id!),
            ),
            _BinTab<BankAccount>(
              loader: () => db.getBankAccounts(bizId, deleted: true),
              titleOf: (bank) => bank.bankName,
              subtitleOf: (bank) => [bank.accountTitle, bank.accountNo]
                  .where((s) => s.isNotEmpty)
                  .join(' • '),
              idOf: (bank) => bank.id,
              onRestore: (bank) => db.setBankDeleted(bank.id!, false),
              onDeleteForever: (bank) => db.deleteBankForever(bank.id!),
            ),
          ],
        ),
      ),
    );
  }
}

class _BinTab<T> extends StatefulWidget {
  final Future<List<T>> Function() loader;
  final String Function(T) titleOf;
  final String Function(T) subtitleOf;
  final int? Function(T) idOf;
  final Future<void> Function(T) onRestore;
  final Future<void> Function(T) onDeleteForever;

  const _BinTab({
    required this.loader,
    required this.titleOf,
    required this.subtitleOf,
    required this.idOf,
    required this.onRestore,
    required this.onDeleteForever,
  });

  @override
  State<_BinTab<T>> createState() => _BinTabState<T>();
}

class _BinTabState<T> extends State<_BinTab<T>> {
  late Future<List<T>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  void _reload() => setState(() => _future = widget.loader());

  Future<void> _restore(AppProvider p, T item) async {
    await widget.onRestore(item);
    if (!mounted) return;
    showSnack(context, p.t('restored'));
    p.bump();
    _reload();
  }

  Future<void> _deleteForever(AppProvider p, T item) async {
    final ok = await confirmDelete(context, p.t('deleteForever'));
    if (!ok || !mounted) return;
    await widget.onDeleteForever(item);
    if (!mounted) return;
    p.bump();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return FutureBuilder<List<T>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snap.data ?? <T>[];
        if (items.isEmpty) {
          return Center(
            child: Text(p.t('noData'), style: const TextStyle(color: AppColors.textGrey)),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            final subtitle = widget.subtitleOf(item);
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text(widget.titleOf(item)),
                subtitle: subtitle.isEmpty ? null : Text(subtitle),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: p.t('restore'),
                      icon: const Icon(Icons.restore, color: AppColors.green),
                      onPressed: widget.idOf(item) == null
                          ? null
                          : () => _restore(p, item),
                    ),
                    IconButton(
                      tooltip: p.t('deleteForever'),
                      icon: const Icon(Icons.delete_forever, color: AppColors.red),
                      onPressed: widget.idOf(item) == null
                          ? null
                          : () => _deleteForever(p, item),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
