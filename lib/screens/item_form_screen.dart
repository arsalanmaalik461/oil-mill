import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../utils/helpers.dart';

String _numText(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

const _unitSuggestions = [
  'Bags (bags)',
  'Bottles (btl)',
  'Kilogram (kg)',
  'Litre (L)',
  'Pieces (pcs)',
  'Mann (mann)',
];

/// Add / edit a stock item.
class ItemFormScreen extends StatefulWidget {
  final StockItem? item; // null = add mode
  const ItemFormScreen({super.key, this.item});

  @override
  State<ItemFormScreen> createState() => _ItemFormScreenState();
}

class _ItemFormScreenState extends State<ItemFormScreen> {
  final _name = TextEditingController();
  final _unit = TextEditingController();
  final _category = TextEditingController();
  final _openingQty = TextEditingController();
  final _lowStockLimit = TextEditingController();
  List<String> _categorySuggestions = const [];
  String _kind = 'general';

  bool get _editing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    if (item != null) {
      _name.text = item.name;
      _unit.text = item.unit;
      _category.text = item.category;
      _kind = item.kind;
      if (item.openingQty != 0) _openingQty.text = _numText(item.openingQty);
      if (item.lowStockLimit != 0) {
        _lowStockLimit.text = _numText(item.lowStockLimit);
      }
    }
    _loadCategories();
  }

  /// Distinct categories already used by other items, offered as chips so
  /// the same spelling is reused instead of creating near-duplicates.
  Future<void> _loadCategories() async {
    final bizId = widget.item?.businessId ??
        context.read<AppProvider>().businessId;
    final items = await DatabaseHelper.instance.getItems(bizId);
    final cats = <String>{};
    for (final i in items) {
      final c = i.category.trim();
      if (c.isNotEmpty) cats.add(c);
    }
    if (mounted) {
      setState(() => _categorySuggestions = cats.toList()..sort());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _category.dispose();
    _openingQty.dispose();
    _lowStockLimit.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = context.read<AppProvider>();
    final name = _name.text.trim();
    if (name.isEmpty) {
      showSnack(context, p.t('requiredField'));
      return;
    }
    final unit = _unit.text.trim();
    final item = StockItem(
      id: widget.item?.id,
      businessId: widget.item?.businessId ?? p.businessId,
      name: name,
      unit: unit.isEmpty ? 'pcs' : unit,
      category: _category.text.trim(),
      kind: _kind,
      openingQty: double.tryParse(_openingQty.text.trim()) ?? 0,
      lowStockLimit: double.tryParse(_lowStockLimit.text.trim()) ?? 0,
      deleted: widget.item?.deleted ?? 0,
    );
    final db = DatabaseHelper.instance;
    if (_editing) {
      await db.updateItem(item);
    } else {
      await db.insertItem(item);
    }
    if (!mounted) return;
    showSnack(context, p.t('savedSuccessfully'));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar:
          AppBar(title: Text(_editing ? p.t('edit') : p.t('addItem'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: p.t('name')),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _unit,
              decoration: InputDecoration(labelText: p.t('unit')),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _unitSuggestions
                  .map((u) => ChoiceChip(
                        label: Text(u),
                        selected: _unit.text.trim() == u,
                        onSelected: (_) => setState(() => _unit.text = u),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _category,
              decoration: InputDecoration(labelText: p.t('category')),
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
            ),
            if (_categorySuggestions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _categorySuggestions
                    .map((c) => ChoiceChip(
                          label: Text(c),
                          selected: _category.text.trim() == c,
                          onSelected: (_) =>
                              setState(() => _category.text = c),
                        ))
                    .toList(),
              ),
            ],
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _kind,
              decoration: InputDecoration(labelText: p.t('itemKind')),
              items: [
                DropdownMenuItem(
                    value: 'general', child: Text(p.t('kindGeneral'))),
                DropdownMenuItem(value: 'raw', child: Text(p.t('kindRaw'))),
                DropdownMenuItem(
                    value: 'finished', child: Text(p.t('kindFinished'))),
              ],
              onChanged: (v) => setState(() => _kind = v ?? 'general'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _openingQty,
              decoration: InputDecoration(labelText: p.t('openingQty')),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _lowStockLimit,
              decoration: InputDecoration(labelText: p.t('lowStockLimit')),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
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
      ),
    );
  }
}
