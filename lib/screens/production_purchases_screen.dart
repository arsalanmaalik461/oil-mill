import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _PurchaseRow {
  final StockTransaction txn;
  final StockItem item;
  final String supplierName;
  _PurchaseRow(this.txn, this.item, this.supplierName);
  double get total => txn.qty * txn.rate;
}

class _PurchasesData {
  final List<_PurchaseRow> rows;
  final List<StockItem> rawItems;
  final List<Party> suppliers;
  _PurchasesData(this.rows, this.rawItems, this.suppliers);
}

/// Raw material purchases: every stock-IN of a raw item that is not a
/// production output (batch outputs post with note 'Production batch #N').
/// The item filter doubles as the rate-history view: pick one material and
/// you see every purchase of it with its rate, newest first.
class ProductionPurchasesScreen extends StatefulWidget {
  const ProductionPurchasesScreen({super.key});

  @override
  State<ProductionPurchasesScreen> createState() =>
      _ProductionPurchasesScreenState();
}

class _ProductionPurchasesScreenState
    extends State<ProductionPurchasesScreen> {
  late Future<_PurchasesData> _future;
  int? _itemFilter; // null = all raw materials

  @override
  void initState() {
    super.initState();
    _future = _load(context.read<AppProvider>().businessId);
  }

  Future<_PurchasesData> _load(int bizId) async {
    final db = DatabaseHelper.instance;
    final items = await db.getItems(bizId);
    final rawItems = items.where((i) => i.kind == 'raw').toList();
    final parties = await db.getParties(bizId);
    final partyName = <int, String>{
      for (final pt in parties) if (pt.id != null) pt.id!: pt.name
    };
    final suppliers = parties.where((pt) => pt.type == 'supplier').toList();
    final rows = <_PurchaseRow>[];
    for (final item in rawItems) {
      if (item.id == null) continue;
      for (final t in await db.getStockTransactions(item.id!)) {
        if (t.type != 'in') continue;
        if (t.note.startsWith('Production batch')) continue;
        rows.add(_PurchaseRow(
          t,
          item,
          t.supplierId != null ? (partyName[t.supplierId] ?? '') : '',
        ));
      }
    }
    rows.sort((a, b) => b.txn.dateTime.compareTo(a.txn.dateTime));
    return _PurchasesData(rows, rawItems, suppliers);
  }

  void _reload() {
    setState(() => _future = _load(context.read<AppProvider>().businessId));
  }

  Future<void> _newPurchase(_PurchasesData d) async {
    final p = context.read<AppProvider>();
    if (d.rawItems.isEmpty) {
      showSnack(context,
          'No raw material items yet — set Item Type to "${p.t('kindRaw')}" in the Stock Book item form first.');
      return;
    }
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const _PurchaseFormScreen()),
    );
    if (done == true && mounted) {
      context.read<AppProvider>().bump();
      _reload();
    }
  }

  Future<void> _returnPurchase(_PurchaseRow row) async {
    final p = context.read<AppProvider>();
    final db = DatabaseHelper.instance;
    final qtyC = TextEditingController(
        text: row.txn.qty == row.txn.qty.roundToDouble()
            ? row.txn.qty.toInt().toString()
            : row.txn.qty.toString());
    final qty = await showDialog<double>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${p.t('purchaseReturn')} — ${row.item.name}'),
        content: TextField(
          controller: qtyC,
          decoration: InputDecoration(labelText: p.t('quantity')),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: Text(p.t('cancel'))),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(c, double.tryParse(qtyC.text.trim()) ?? 0),
            child: Text(p.t('purchaseReturn')),
          ),
        ],
      ),
    );
    if (qty == null || qty <= 0 || !mounted) return;
    if (qty > row.txn.qty) {
      showSnack(context, p.t('insufficientStock'));
      return;
    }
    final inStock = await db.getItemQty(row.item.id!);
    if (qty > inStock) {
      if (!mounted) return;
      showSnack(context, p.t('insufficientStock'));
      return;
    }
    // One atomic transaction in the database layer (Phase 3):
    // stock-out + the supplier adjustment that reduces what we owe.
    await db.savePurchaseReturn(
      itemId: row.item.id!,
      qty: qty,
      rate: row.txn.rate,
      supplierId: row.txn.supplierId,
      dateTime: DateTime.now(),
    );
    if (!mounted) return;
    context.read<AppProvider>().bump();
    showSnack(context, p.t('savedSuccessfully'));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('rawPurchases'))),
      floatingActionButton: FutureBuilder<_PurchasesData>(
        future: _future,
        builder: (context, snap) => FloatingActionButton.extended(
          onPressed: snap.hasData ? () => _newPurchase(snap.data!) : null,
          icon: const Icon(Icons.add),
          label: Text(p.t('rawPurchases')),
        ),
      ),
      body: FutureBuilder<_PurchasesData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data ?? _PurchasesData(const [], const [], const []);
          final rows = _itemFilter == null
              ? d.rows
              : d.rows.where((r) => r.item.id == _itemFilter).toList();
          final totalValue =
              rows.fold<double>(0, (s, r) => s + r.total);
          final perSupplier = <String, double>{};
          for (final r in rows) {
            if (r.supplierName.isEmpty) continue;
            perSupplier[r.supplierName] =
                (perSupplier[r.supplierName] ?? 0) + r.total;
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.local_shipping,
                                color: AppColors.primary, size: 20),
                            const SizedBox(width: 8),
                            Text('${p.t('totalSale')}: ',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.textGrey)),
                            Text(formatRs(totalValue),
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int?>(
                          value: _itemFilter,
                          decoration:
                              InputDecoration(labelText: p.t('rawMaterial')),
                          items: [
                            DropdownMenuItem<int?>(
                                value: null, child: Text(p.t('all'))),
                            for (final i in d.rawItems)
                              DropdownMenuItem<int?>(
                                  value: i.id, child: Text(i.name)),
                          ],
                          onChanged: (v) => setState(() => _itemFilter = v),
                        ),
                        if (perSupplier.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: Text(p.t('suppliers'),
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                            children: [
                              for (final e in perSupplier.entries)
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(e.key),
                                  trailing: Text(formatRs(e.value),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: rows.isEmpty
                    ? Center(child: Text(p.t('noData')))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final r = rows[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    AppColors.primary.withValues(alpha: 0.12),
                                child: const Icon(Icons.arrow_downward,
                                    color: AppColors.green, size: 18),
                              ),
                              title: Text(r.item.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                [
                                  if (r.supplierName.isNotEmpty) r.supplierName,
                                  dateFmt.format(r.txn.dateTime),
                                  '${p.t('rate')}: ${formatRs(r.txn.rate)}',
                                ].join(' • '),
                              ),
                              onLongPress: () => _returnPurchase(r),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.end,
                                    children: [
                                      Text(formatRs(r.total),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      Text(
                                        '${r.txn.qty == r.txn.qty.roundToDouble() ? r.txn.qty.toInt() : r.txn.qty} ${r.item.unit}',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: AppColors.textGrey),
                                      ),
                                    ],
                                  ),
                                  IconButton(
                                    tooltip: p.t('purchaseReturn'),
                                    icon: const Icon(Icons.undo,
                                        color: AppColors.red),
                                    onPressed: () => _returnPurchase(r),
                                  ),
                                ],
                              ),
                            ),
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

/// New raw material purchase form. Saving posts into the EXISTING books:
/// stock-IN (raises raw stock), the supplier ledger (credit = 'wasool' —
/// we owe them; paid = 'wasool' + 'udhaar' pair so the full history shows
/// with a zero net balance) and, when paid, a cash-OUT entry.
class _PurchaseFormScreen extends StatefulWidget {
  const _PurchaseFormScreen();

  @override
  State<_PurchaseFormScreen> createState() => _PurchaseFormScreenState();
}

class _PurchaseFormScreenState extends State<_PurchaseFormScreen> {
  late Future<({List<StockItem> items, List<Party> suppliers})> _future;
  StockItem? _item;
  Party? _supplier;
  String _status = 'credit'; // 'paid' | 'credit'
  DateTime _date = DateTime.now();
  final _qty = TextEditingController();
  final _rate = TextEditingController();

  @override
  void initState() {
    super.initState();
    _future = _load(context.read<AppProvider>().businessId);
  }

  Future<({List<StockItem> items, List<Party> suppliers})> _load(
      int bizId) async {
    final db = DatabaseHelper.instance;
    final items = (await db.getItems(bizId))
        .where((i) => i.kind == 'raw')
        .toList();
    final suppliers =
        await db.getParties(bizId, type: 'supplier');
    return (items: items, suppliers: suppliers);
  }

  @override
  void dispose() {
    _qty.dispose();
    _rate.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _date = DateTime(picked.year, picked.month, picked.day,
          _date.hour, _date.minute));
    }
  }

  Future<void> _save() async {
    final p = context.read<AppProvider>();
    final qty = double.tryParse(_qty.text.trim()) ?? 0;
    final rate = double.tryParse(_rate.text.trim()) ?? 0;
    if (_item == null || qty <= 0) {
      showSnack(context, p.t('invalidAmount'));
      return;
    }
    final db = DatabaseHelper.instance;
    final bizId = p.businessId;
    final supplierId = _supplier?.id;

    // One atomic transaction in the database layer (Phase 3):
    // stock-in + supplier wasool (+ udhaar and cash-out when paid).
    await db.saveRawPurchase(
      businessId: bizId,
      itemId: _item!.id!,
      qty: qty,
      rate: rate,
      supplierId: supplierId,
      paid: _status == 'paid',
      dateTime: _date,
    );
    if (!mounted) return;
    p.bump();
    showSnack(context, p.t('savedSuccessfully'));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('rawPurchases'))),
      body: FutureBuilder<({List<StockItem> items, List<Party> suppliers})>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data ?? (items: <StockItem>[], suppliers: <Party>[]);
          if (d.items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No raw material items yet — set Item Type to "${p.t('kindRaw')}" in the Stock Book item form first.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          _item ??= d.items.first;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<StockItem>(
                  value: _item,
                  decoration:
                      InputDecoration(labelText: p.t('rawMaterial')),
                  items: d.items
                      .map((i) => DropdownMenuItem(
                          value: i, child: Text('${i.name} (${i.unit})')))
                      .toList(),
                  onChanged: (v) => setState(() => _item = v),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<Party?>(
                  value: _supplier,
                  decoration: InputDecoration(labelText: p.t('suppliers')),
                  items: [
                    DropdownMenuItem<Party?>(
                        value: null, child: Text(p.t('none'))),
                    for (final s in d.suppliers)
                      DropdownMenuItem<Party?>(value: s, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() => _supplier = v),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _qty,
                        decoration: InputDecoration(labelText: p.t('quantity')),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _rate,
                        decoration: InputDecoration(labelText: p.t('rate')),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _status,
                        decoration:
                            InputDecoration(labelText: p.t('status')),
                        items: [
                          DropdownMenuItem(
                              value: 'paid', child: Text(p.t('paid'))),
                          DropdownMenuItem(
                              value: 'credit', child: Text(p.t('pending'))),
                        ],
                        onChanged: (v) =>
                            setState(() => _status = v ?? 'credit'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.event, size: 18),
                        label: Text(dateFmt.format(_date)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _save,
                    child: Text(p.t('save')),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
