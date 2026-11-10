import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _InputRow {
  StockItem? item;
  final qtyCtrl = TextEditingController();
  double avail = 0;
  double wac = 0;
  double get qty => double.tryParse(qtyCtrl.text.trim()) ?? 0;
  double get cost => qty * wac;
  void dispose() => qtyCtrl.dispose();
}

class _OutputRow {
  StockItem? item;
  final qtyCtrl = TextEditingController();
  final rateCtrl = TextEditingController();
  double get qty => double.tryParse(qtyCtrl.text.trim()) ?? 0;
  double get saleRate => double.tryParse(rateCtrl.text.trim()) ?? 0;
  void dispose() {
    qtyCtrl.dispose();
    rateCtrl.dispose();
  }
}

class _ExpenseRow {
  String category = 'labour';
  final amountCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  double get amount => double.tryParse(amountCtrl.text.trim()) ?? 0;
  void dispose() {
    amountCtrl.dispose();
    noteCtrl.dispose();
  }
}

/// Create a production batch: raw materials are consumed from the Stock
/// Book at weighted-average cost, expenses are added, and the total cost
/// is allocated across the outputs by quantity (done inside
/// createProductionBatch, in one DB transaction).
class ProductionBatchFormScreen extends StatefulWidget {
  const ProductionBatchFormScreen({super.key});

  @override
  State<ProductionBatchFormScreen> createState() =>
      _ProductionBatchFormScreenState();
}

class _ProductionBatchFormScreenState extends State<ProductionBatchFormScreen> {
  final _db = DatabaseHelper.instance;
  List<StockItem> _rawItems = [];
  List<StockItem> _finishedItems = [];
  final List<_InputRow> _inputs = [_InputRow()];
  final List<_OutputRow> _outputs = [_OutputRow()];
  final List<_ExpenseRow> _expenses = [];
  final _wastageQtyCtrl = TextEditingController();
  final _wastageNoteCtrl = TextEditingController();
  int _batchNo = 0;
  DateTime _date = DateTime.now();
  bool _allowNegative = false;
  String _allocMethod = 'quantity';
  bool _saving = false;
  bool _loading = true;

  static const _expenseKeys = {
    'labour': 'prodLabour',
    'electricity': 'prodElectricity',
    'machinery': 'prodMachinery',
    'transport': 'prodTransport',
    'other': 'prodOther',
  };

  double get _materialCost => _inputs.fold<double>(0, (s, r) => s + r.cost);
  double get _expenseTotal => _expenses.fold<double>(0, (s, r) => s + r.amount);
  double get _totalCost => _materialCost + _expenseTotal;
  double get _totalOutputQty => _outputs.fold<double>(0, (s, r) => s + r.qty);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final r in _inputs) {
      r.dispose();
    }
    for (final r in _outputs) {
      r.dispose();
    }
    for (final r in _expenses) {
      r.dispose();
    }
    _wastageQtyCtrl.dispose();
    _wastageNoteCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bizId = context.read<AppProvider>().businessId;
    final items = await _db.getItems(bizId);
    final no = await _db.getNextBatchNo(bizId);
    if (!mounted) return;
    setState(() {
      _rawItems = items.where((i) => i.kind == 'raw').toList();
      _finishedItems = items.where((i) => i.kind == 'finished').toList();
      _batchNo = no;
      _loading = false;
    });
  }

  Future<void> _refreshInputInfo(_InputRow r) async {
    if (r.item == null) {
      setState(() {
        r.avail = 0;
        r.wac = 0;
      });
      return;
    }
    final q = await _db.getItemQty(r.item!.id!);
    final c = await _db.getItemAvgCost(r.item!.id!);
    if (!mounted) return;
    setState(() {
      r.avail = q;
      r.wac = c;
    });
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      );

  Future<void> _save() async {
    final p = context.read<AppProvider>();
    final inputs = <({int itemId, double qty})>[];
    for (final r in _inputs) {
      if (r.item != null && r.qty > 0) {
        inputs.add((itemId: r.item!.id!, qty: r.qty));
      }
    }
    final outputs = <({int itemId, double qty, double? saleRate})>[];
    for (final r in _outputs) {
      if (r.item != null && r.qty > 0) {
        outputs.add((itemId: r.item!.id!,
            qty: r.qty,
            saleRate: r.saleRate > 0 ? r.saleRate : null));
      }
    }
    if (_allocMethod == 'value' &&
        outputs.any((o) => o.saleRate == null)) {
      showSnack(context, p.t('saleRateReq'));
      return;
    }
    if (inputs.isEmpty || outputs.isEmpty) {
      showSnack(context,
          'Add at least one raw material and one finished product with quantity.');
      return;
    }
    setState(() => _saving = true);
    try {
      await _db.createProductionBatch(
        batch: ProductionBatch(
          businessId: p.businessId,
          batchNo: _batchNo,
          dateTime: _date,
          note: '',
          wastageQty: double.tryParse(_wastageQtyCtrl.text.trim()) ?? 0,
          wastageNote: _wastageNoteCtrl.text.trim(),
          allocationMethod: _allocMethod,
        ),
        inputs: inputs,
        outputs: outputs,
        expenses: [
          for (final r in _expenses)
            if (r.amount > 0)
              ProductionExpense(
                batchId: 0,
                category: r.category,
                amount: r.amount,
                note: r.noteCtrl.text.trim(),
                dateTime: _date,
              ),
        ],
        allowNegative: _allowNegative,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final msg = e.message;
      if (msg.startsWith('INSUFFICIENT:')) {
        showSnack(context,
            '${p.t('insufficientStock')}: ${msg.substring('INSUFFICIENT:'.length)}');
      } else {
        showSnack(context,
            'Add at least one raw material and one finished product with quantity.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(p.t('newBatch'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // Main output conversions (first output row), using the same
    // by-quantity allocation the DB applies on save.
    final mainRow = _outputs.first;
    final mainQty = mainRow.qty;
    final totalOut = _totalOutputQty;
    final perUnit =
        totalOut > 0 ? _totalCost / totalOut : 0.0; // cost per main unit
    final kgFactor =
        mainRow.item != null ? unitToKgFactor(mainRow.item!.unit) : 1.0;
    final perKg = kgFactor > 0 ? perUnit / kgFactor : 0.0;

    return Scaffold(
      appBar: AppBar(title: Text('${p.t('newBatch')} #$_batchNo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.calendar_month,
                    color: AppColors.primary),
                title: Text('${p.t('batchNo')} $_batchNo'),
                subtitle: Text(dateTimeFmt.format(_date)),
                trailing: const Icon(Icons.edit_calendar),
                onTap: () async {
                  final picked = await pickDateTime(context, _date);
                  if (picked != null && mounted) {
                    setState(() => _date = picked);
                  }
                },
              ),
            ),

            // ---------------- Inputs (raw materials) ----------------
            _sectionTitle(p.t('rawMaterial')),
            if (_rawItems.isEmpty)
              Text(p.t('noData'),
                  style: const TextStyle(color: AppColors.textGrey)),
            for (var i = 0; i < _inputs.length; i++) _inputRow(p, i),
            TextButton.icon(
              onPressed: () => setState(() => _inputs.add(_InputRow())),
              icon: const Icon(Icons.add),
              label: Text(p.t('addEntry')),
            ),

            // ---------------- Outputs (finished goods) ----------------
            _sectionTitle(p.t('finishedProduct')),
            Row(
              children: [
                Text('${p.t('allocMethod')}: ',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                ChoiceChip(
                  label: Text(p.t('allocQty')),
                  selected: _allocMethod == 'quantity',
                  onSelected: (_) => setState(() => _allocMethod = 'quantity'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(p.t('allocValue')),
                  selected: _allocMethod == 'value',
                  onSelected: (_) => setState(() => _allocMethod = 'value'),
                ),
              ],
            ),
            if (_finishedItems.isEmpty)
              Text(p.t('noData'),
                  style: const TextStyle(color: AppColors.textGrey)),
            for (var i = 0; i < _outputs.length; i++) _outputRow(p, i),
            TextButton.icon(
              onPressed: () => setState(() => _outputs.add(_OutputRow())),
              icon: const Icon(Icons.add),
              label: Text(p.t('addEntry')),
            ),

            // ---------------- Expenses ----------------
            _sectionTitle(p.t('prodExpenses')),
            for (var i = 0; i < _expenses.length; i++) _expenseRow(p, i),
            TextButton.icon(
              onPressed: () => setState(() => _expenses.add(_ExpenseRow())),
              icon: const Icon(Icons.add),
              label: Text(p.t('addEntry')),
            ),

            // ---------------- Wastage (record only) ----------------
            _sectionTitle(p.t('wastage')),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _wastageQtyCtrl,
                    decoration:
                        InputDecoration(labelText: p.t('quantity')),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _wastageNoteCtrl,
                    decoration: InputDecoration(labelText: p.t('note')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Record only — enter the NET output above; wastage is kept in the batch history, not posted to stock again.',
              style: TextStyle(fontSize: 12, color: AppColors.textGrey),
            ),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(p.t('allowNegative')),
              value: _allowNegative,
              onChanged: (v) => setState(() => _allowNegative = v),
            ),

            // ---------------- Live summary ----------------
            Card(
              color: AppColors.primary.withValues(alpha: 0.06),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    _summaryRow(p.t('materialCost'), formatRs(_materialCost)),
                    _summaryRow(p.t('prodExpenses'), formatRs(_expenseTotal)),
                    const Divider(),
                    _summaryRow(p.t('totalProdCost'), formatRs(_totalCost),
                        bold: true),
                    if (mainRow.item != null && mainQty > 0) ...[
                      const Divider(),
                      _summaryRow(
                          'Cost per ${mainRow.item!.unit}', formatRs(perUnit)),
                      _summaryRow(p.t('costPerKg'), formatRs(perKg)),
                      _summaryRow(p.t('costPer40Kg'), formatRs(perKg * 40)),
                      _summaryRow(p.t('costPerTon'), formatRs(perKg * 1000)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(p.t('save')),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(value,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                    fontSize: bold ? 16 : 14)),
          ],
        ),
      );

  Widget _inputRow(AppProvider p, int i) {
    final r = _inputs[i];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<StockItem>(
                    value: r.item,
                    decoration:
                        InputDecoration(labelText: p.t('rawMaterial')),
                    items: _rawItems
                        .map((it) => DropdownMenuItem<StockItem>(
                              value: it,
                              child: Text(it.name),
                            ))
                        .toList(),
                    onChanged: (v) {
                      setState(() => r.item = v);
                      _refreshInputInfo(r);
                    },
                  ),
                ),
                if (_inputs.length > 1)
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: AppColors.red),
                    onPressed: () => setState(() {
                      _inputs.removeAt(i).dispose();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: r.qtyCtrl,
                    decoration:
                        InputDecoration(labelText: p.t('consumedQty')),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    r.item == null
                        ? ''
                        : '${formatQty(r.avail)} ${r.item!.unit} • ${formatRs(r.wac)}\n= ${formatRs(r.cost)}',
                    style: const TextStyle(color: AppColors.textGrey),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _outputRow(AppProvider p, int i) {
    final r = _outputs[i];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Chip(
                  label: Text(p.t('byProduct'),
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600)),
                  backgroundColor:
                      AppColors.accent.withValues(alpha: 0.15),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<StockItem>(
                    value: r.item,
                    decoration:
                        InputDecoration(labelText: p.t('finishedProduct')),
                    items: _finishedItems
                        .map((it) => DropdownMenuItem<StockItem>(
                              value: it,
                              child: Text(it.name),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => r.item = v),
                  ),
                ),
                if (_outputs.length > 1)
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: AppColors.red),
                    onPressed: () => setState(() {
                      _outputs.removeAt(i).dispose();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: r.qtyCtrl,
              decoration: InputDecoration(labelText: p.t('outputQty')),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
            ),
            if (_allocMethod == 'value') ...[
              const SizedBox(height: 10),
              TextField(
                controller: r.rateCtrl,
                decoration: InputDecoration(labelText: p.t('expSaleRate')),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _expenseRow(AppProvider p, int i) {
    final r = _expenses[i];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: r.category,
                    decoration: InputDecoration(labelText: p.t('category')),
                    items: _expenseKeys.entries
                        .map((e) => DropdownMenuItem<String>(
                              value: e.key,
                              child: Text(p.t(e.value)),
                            ))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => r.category = v ?? 'other'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline,
                      color: AppColors.red),
                  onPressed: () => setState(() {
                    _expenses.removeAt(i).dispose();
                  }),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: r.amountCtrl,
                    decoration: InputDecoration(labelText: p.t('amount')),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: r.noteCtrl,
                    decoration: InputDecoration(labelText: p.t('note')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
