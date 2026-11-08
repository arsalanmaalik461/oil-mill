import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _ItemData {
  final double qty;
  final List<StockTransaction> transactions;
  final List<Party> suppliers;
  const _ItemData(this.qty, this.transactions, this.suppliers);
}

/// One item: current stock, Stock In / Stock Out entry and history.
class ItemDetailScreen extends StatefulWidget {
  final StockItem item;
  const ItemDetailScreen({super.key, required this.item});

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  late Future<_ItemData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_ItemData> _load() async {
    final db = DatabaseHelper.instance;
    final bizId = context.read<AppProvider>().businessId;
    final qty = await db.getItemQty(widget.item.id!);
    final txns = await db.getStockTransactions(widget.item.id!);
    final suppliers = await db.getParties(bizId, type: 'supplier');
    return _ItemData(qty, txns, suppliers);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _deleteTransaction(StockTransaction t) async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await DatabaseHelper.instance.deleteStockTransaction(t.id!);
    if (!mounted) return;
    _reload();
    context.read<AppProvider>().bump();
  }

  Future<void> _showTxnForm(String type, List<Party> suppliers) async {
    final p = context.read<AppProvider>();
    final qtyCtrl = TextEditingController();
    final rateCtrl = TextEditingController();
    final billCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var selectedDate = DateTime.now();
    int? selectedSupplierId;
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
                  type == 'in' ? p.t('stockIn') : p.t('stockOut'),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: qtyCtrl,
                  decoration: InputDecoration(labelText: p.t('quantity')),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: rateCtrl,
                  decoration: InputDecoration(labelText: p.t('rate')),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                if (type == 'in') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int?>(
                    value: selectedSupplierId,
                    decoration:
                        InputDecoration(labelText: p.t('selectSupplier')),
                    items: [
                      const DropdownMenuItem<int?>(
                          value: null, child: Text('None')),
                      ...suppliers.map((s) => DropdownMenuItem<int?>(
                            value: s.id,
                            child: Text(s.name),
                          )),
                    ],
                    onChanged: (v) =>
                        setSheetState(() => selectedSupplierId = v),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: billCtrl,
                  decoration: InputDecoration(labelText: p.t('billNo')),
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
                      backgroundColor:
                          type == 'in' ? AppColors.green : AppColors.red,
                    ),
                    onPressed: () async {
                      final qty = double.tryParse(qtyCtrl.text.trim());
                      if (qty == null || qty <= 0) {
                        showSnack(bc, p.t('invalidAmount'));
                        return;
                      }
                      await DatabaseHelper.instance.insertStockTransaction(
                        StockTransaction(
                          itemId: widget.item.id!,
                          type: type,
                          qty: qty,
                          rate: double.tryParse(rateCtrl.text.trim()) ?? 0,
                          supplierId:
                              type == 'in' ? selectedSupplierId : null,
                          billNo: billCtrl.text.trim(),
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
    qtyCtrl.dispose();
    rateCtrl.dispose();
    billCtrl.dispose();
    noteCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final item = widget.item;
    return Scaffold(
      appBar: AppBar(title: Text(item.name)),
      body: FutureBuilder<_ItemData>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!;
          final qty = data.qty;
          final isLow = qty <= item.lowStockLimit;
          return Column(
            children: [
              Card(
                margin: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(item.name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      if (item.category.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Chip(
                          label: Text(item.category.trim()),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: const Color(0xFFFFE3D3),
                          labelStyle: const TextStyle(
                              fontSize: 12,
                              color: AppColors.primaryDark,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(p.t('currentStock'),
                          style: const TextStyle(color: AppColors.textGrey)),
                      const SizedBox(height: 2),
                      Text(
                        '${formatQty(qty)} ${item.unit}',
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primaryDark,
                        ),
                      ),
                      if (isLow) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                size: 17,
                                color: qty <= 0
                                    ? AppColors.red
                                    : AppColors.accent),
                            const SizedBox(width: 5),
                            Text(
                              p.t('lowStock'),
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: qty <= 0
                                    ? AppColors.red
                                    : AppColors.accent,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.green),
                        onPressed: () =>
                            _showTxnForm('in', data.suppliers),
                        child: Text(p.t('stockIn')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.red),
                        onPressed: () =>
                            _showTxnForm('out', data.suppliers),
                        child: Text(p.t('stockOut')),
                      ),
                    ),
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
                          final isIn = t.type == 'in';
                          final subtitleParts = <String>[
                            if (t.note.isNotEmpty) t.note,
                            if (t.billNo.isNotEmpty)
                              '${p.t('billNo')}: ${t.billNo}',
                            dateTimeFmt.format(t.dateTime),
                          ];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isIn
                                  ? const Color(0xFFE2F6E9)
                                  : const Color(0xFFFDE8E8),
                              child: Icon(
                                isIn
                                    ? Icons.arrow_downward
                                    : Icons.arrow_upward,
                                color:
                                    isIn ? AppColors.green : AppColors.red,
                                size: 19,
                              ),
                            ),
                            title: Text(
                              '${isIn ? '+' : '-'} ${formatQty(t.qty)} '
                              '${item.unit}'
                              '${t.rate > 0 ? ' @ ${formatRs(t.rate)}' : ''}',
                            ),
                            subtitle: Text(subtitleParts.join(' • ')),
                            trailing: t.rate > 0
                                ? Text(
                                    formatRs(t.qty * t.rate),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600),
                                  )
                                : null,
                            onLongPress: () => _deleteTransaction(t),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
