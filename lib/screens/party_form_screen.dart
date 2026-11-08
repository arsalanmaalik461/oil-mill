import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

String _numText(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Add / edit a customer, supplier or dealer.
class PartyFormScreen extends StatefulWidget {
  final String type; // 'customer' | 'supplier' | 'dealer'
  final Party? party; // null = add mode
  const PartyFormScreen({super.key, required this.type, this.party});

  @override
  State<PartyFormScreen> createState() => _PartyFormScreenState();
}

class _PartyFormScreenState extends State<PartyFormScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _opening = TextEditingController();
  String _openingKind = 'get'; // 'get' = you will get (positive) | 'give'

  bool get _editing => widget.party != null;

  @override
  void initState() {
    super.initState();
    final party = widget.party;
    if (party != null) {
      _name.text = party.name;
      _phone.text = party.phone;
      _address.text = party.address;
      if (party.openingBalance != 0) {
        _opening.text = _numText(party.openingBalance.abs());
      }
      _openingKind = party.openingBalance < 0 ? 'give' : 'get';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = context.read<AppProvider>();
    final name = _name.text.trim();
    if (name.isEmpty) {
      showSnack(context, p.t('requiredField'));
      return;
    }
    final amount = double.tryParse(_opening.text.trim()) ?? 0;
    final signed = _openingKind == 'get' ? amount.abs() : -amount.abs();
    final party = Party(
      id: widget.party?.id,
      businessId: widget.party?.businessId ?? p.businessId,
      type: widget.type,
      name: name,
      phone: _phone.text.trim(),
      address: _address.text.trim(),
      openingBalance: signed,
      deleted: widget.party?.deleted ?? 0,
    );
    final db = DatabaseHelper.instance;
    if (_editing) {
      await db.updateParty(party);
    } else {
      await db.insertParty(party);
    }
    if (!mounted) return;
    showSnack(context, p.t('savedSuccessfully'));
    Navigator.pop(context, true);
  }

  Widget _openingToggle(AppProvider p) {
    Widget option(String kind, String label) {
      final selected = _openingKind == kind;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _openingKind = kind),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? AppColors.primary : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: selected ? AppColors.primary : AppColors.cardBorder),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? Colors.white : Colors.black87,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        option('get', p.t('youWillGet')),
        const SizedBox(width: 10),
        option('give', p.t('youWillGive')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(
          title: Text(p.t(_editing
              ? 'editParty'
              : widget.type == 'dealer'
                  ? 'addDealer'
                  : 'addParty'))),
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
              controller: _phone,
              decoration: InputDecoration(labelText: p.t('phone')),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _address,
              decoration: InputDecoration(labelText: p.t('address')),
              maxLines: 2,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _opening,
              decoration: InputDecoration(labelText: p.t('openingBalance')),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 10),
            _openingToggle(p),
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
