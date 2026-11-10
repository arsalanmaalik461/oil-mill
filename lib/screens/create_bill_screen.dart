import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _BillLine {
  StockItem? item;
  String name;
  double qty;
  double rate;

  /// Original sale-time COGS snapshot when editing an existing bill;
  /// null for brand-new lines (priced at save time).
  double? costRate;
  _BillLine({this.item, this.name = '', this.qty = 1, this.rate = 0, this.costRate});
  double get amount => qty * rate;
}

class CreateBillScreen extends StatefulWidget {
  /// When set, the screen edits this bill (same bill number; the old
  /// postings are reversed and re-posted atomically on save).
  final Bill? existing;
  const CreateBillScreen({super.key, this.existing});

  @override
  State<CreateBillScreen> createState() => _CreateBillScreenState();
}

class _CreateBillScreenState extends State<CreateBillScreen> {
  final _db = DatabaseHelper.instance;
  List<Party> _parties = []; // customers + dealers (everyone goods are sold to)
  List<StockItem> _items = [];
  Party? _customer;
  StockItem? _pickedItem;
  final _nameCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');
  final _rateCtrl = TextEditingController();
  final List<_BillLine> _lines = [];
  String _status = 'paid';
  DateTime _when = DateTime.now();
  bool _saving = false;

  double get _total => _lines.fold<double>(0, (s, l) => s + l.amount);

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _status = ex.status;
      _when = ex.dateTime;
    }
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _rateCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bizId = context.read<AppProvider>().businessId;
    // Customers and dealers both receive goods on a bill — a dealer bill
    // posts stock-out + udhaar through the same createBill machinery.
    final customers = await _db.getParties(bizId, type: 'customer');
    final dealers = await _db.getParties(bizId, type: 'dealer');
    final parties = [...customers, ...dealers]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final items = await _db.getItems(bizId);
    if (!mounted) return;
    setState(() {
      _parties = parties;
      _items = items;
    });
    final ex = widget.existing;
    if (ex != null) {
      final billItems = await _db.getBillItems(ex.id!);
      if (!mounted) return;
      setState(() {
        if (ex.partyId != null) {
          for (final party in parties) {
            if (party.id == ex.partyId) _customer = party;
          }
        }
        _lines
          ..clear()
          ..addAll(billItems.map((bi) => _BillLine(
                item: items
                    .where((i) => i.id != null && i.id == bi.itemId)
                    .firstOrNull,
                name: bi.name,
                qty: bi.qty,
                rate: bi.rate,
                costRate: bi.costRate,
              )));
      });
    }
  }

  void _addLine() {
    final p = context.read<AppProvider>();
    final name = _pickedItem?.name ?? _nameCtrl.text.trim();
    final qty = double.tryParse(_qtyCtrl.text.trim()) ?? 0;
    final rate = double.tryParse(_rateCtrl.text.trim()) ?? 0;
    if (name.isEmpty || qty <= 0) {
      showSnack(context, p.t('invalidAmount'));
      return;
    }
    setState(() {
      _lines.add(_BillLine(item: _pickedItem, name: name, qty: qty, rate: rate));
      _nameCtrl.clear();
      _qtyCtrl.text = '1';
      _rateCtrl.clear();
      _pickedItem = null;
    });
  }

  Future<void> _save() async {
    final p = context.read<AppProvider>();
    if (_lines.isEmpty || _total <= 0) {
      showSnack(context, p.t('invalidAmount'));
      return;
    }
    setState(() => _saving = true);
    final bizId = p.businessId;
    final billNo = widget.existing?.billNo ?? await _db.nextBillNo(bizId);
    final bill = Bill(
      businessId: bizId,
      billNo: billNo,
      partyId: _customer?.id,
      partyName: _customer?.name ?? p.t('cashCustomer'),
      total: _total,
      status: _status,
      dateTime: _when,
    );
    final items = _lines
        .map((l) => BillItem(
              billId: widget.existing?.id ?? 0,
              itemId: l.item?.id,
              name: l.name,
              qty: l.qty,
              rate: l.rate,
              costRate: l.costRate,
            ))
        .toList();
    if (_isEdit) {
      final edited = Bill(
        id: widget.existing!.id,
        businessId: bizId,
        billNo: widget.existing!.billNo,
        partyId: _customer?.id,
        partyName: _customer?.name ?? p.t('cashCustomer'),
        total: _total,
        status: _status,
        dateTime: _when,
      );
      await _db.updateBill(bill: edited, items: items);
    } else {
      await _db.createBill(businessId: bizId, bill: bill, items: items);
    }
    if (!mounted) return;
    showSnack(context, p.t('savedSuccessfully'));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(
          title: Text(_isEdit
              ? '${p.t('editBill')} #${widget.existing!.billNo}'
              : p.t('createBill'))),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                DropdownButtonFormField<Party?>(
                  value: _customer,
                  decoration: InputDecoration(labelText: p.t('customer')),
                  items: [
                    DropdownMenuItem<Party?>(
                      value: null,
                      child: Text(p.t('cashCustomer')),
                    ),
                    ..._parties.map(
                      (c) => DropdownMenuItem<Party?>(
                        value: c,
                        child: Text(c.name),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => _customer = v),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_month,
                      color: AppColors.primary),
                  title: Text(p.t('date')),
                  subtitle: Text(dateTimeFmt.format(_when)),
                  trailing: const Icon(Icons.edit_calendar),
                  onTap: () async {
                    final dt = await pickDateTime(context, _when);
                    if (dt != null && mounted) setState(() => _when = dt);
                  },
                ),
                const Divider(),
                Text(p.t('addToBill'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                DropdownButtonFormField<StockItem?>(
                  initialValue: _pickedItem,
                  decoration: InputDecoration(labelText: p.t('selectItem')),
                  items: [
                    const DropdownMenuItem<StockItem?>(
                      value: null,
                      child: Text('—'),
                    ),
                    ..._items.map(
                      (i) => DropdownMenuItem<StockItem?>(
                        value: i,
                        child: Text('${i.name} (${i.unit})'),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() {
                    _pickedItem = v;
                    if (v != null) _nameCtrl.text = v.name;
                  }),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameCtrl,
                  decoration: InputDecoration(labelText: p.t('name')),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _qtyCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: InputDecoration(labelText: p.t('quantity')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _rateCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: InputDecoration(labelText: p.t('rate')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _addLine,
                      child: Text(p.t('add')),
                    ),
                  ],
                ),
                const Divider(height: 24),
                if (_lines.isEmpty)
                  Text(p.t('noData'),
                      style: const TextStyle(color: AppColors.textGrey)),
                ..._lines.asMap().entries.map((e) {
                  final l = e.value;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      dense: true,
                      title: Text(l.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          '${formatQty(l.qty)} x ${formatRs(l.rate)}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(formatRs(l.amount),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          IconButton(
                            icon: const Icon(Icons.remove_circle,
                                color: AppColors.red),
                            onPressed: () =>
                                setState(() => _lines.removeAt(e.key)),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('${p.t('status')}: ',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(p.t('paid')),
                      selected: _status == 'paid',
                      selectedColor: const Color(0xFFE5F6EC),
                      onSelected: (_) => setState(() => _status = 'paid'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(p.t('pending')),
                      selected: _status == 'pending',
                      selectedColor: const Color(0xFFFDE8E8),
                      onSelected: (_) => setState(() => _status = 'pending'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: AppColors.cardBorder)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(p.t('billTotal'),
                          style: const TextStyle(color: AppColors.textGrey)),
                      Text(formatRs(_total),
                          style: const TextStyle(
                              fontSize: 19, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(p.t('generateBill')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
