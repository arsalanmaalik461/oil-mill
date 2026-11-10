import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

/// Full-screen party entry form, modelled on the original khata app:
/// coloured header, big amount field, note, separate Date and Time
/// dropdown fields, optional bill photo, and a big coloured SAVE button.
/// Used both for adding a new entry and editing an existing one.
class PartyEntryFormScreen extends StatefulWidget {
  final Party party;
  final String type; // 'udhaar' | 'wasool'
  final PartyTransaction? existing;

  const PartyEntryFormScreen({
    super.key,
    required this.party,
    required this.type,
    this.existing,
  });

  @override
  State<PartyEntryFormScreen> createState() => _PartyEntryFormScreenState();
}

class _PartyEntryFormScreenState extends State<PartyEntryFormScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  late DateTime _when;
  String? _attachment;
  bool _saving = false;

  bool get _isUdhaar => widget.type == 'udhaar';
  Color get _color => _isUdhaar ? AppColors.red : AppColors.green;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _amount.text = e.amount == e.amount.roundToDouble()
          ? e.amount.toStringAsFixed(0)
          : e.amount.toString();
      _note.text = e.note;
      _when = e.dateTime;
      _attachment = e.attachmentPath;
    } else {
      _when = DateTime.now();
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Widget _dateTimeField({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 20),
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: Text(value, style: const TextStyle(fontSize: 15)),
      ),
    );
  }

  Future<void> _save() async {
    final p = context.read<AppProvider>();
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) {
      showSnack(context, p.t('invalidAmount'));
      return;
    }
    setState(() => _saving = true);
    final db = DatabaseHelper.instance;
    final txn = PartyTransaction(
      id: widget.existing?.id,
      partyId: widget.party.id!,
      type: widget.type,
      amount: amount,
      note: _note.text.trim(),
      dateTime: _when,
      attachmentPath: _attachment,
    );
    if (widget.existing == null) {
      await db.insertPartyTransaction(txn);
    } else {
      await db.updatePartyTransaction(txn);
    }
    if (!mounted) return;
    context.read<AppProvider>().bump();
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final party = widget.party;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _color,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${p.t(widget.type)}${_amount.text.trim().isNotEmpty ? ' ${formatRs(double.tryParse(_amount.text.trim()) ?? 0)}' : ''}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            Text(
              _isUdhaar ? '${party.name} →' : '← ${party.name}',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _amount,
            autofocus: widget.existing == null,
            decoration: InputDecoration(
              labelText: p.t('amount'),
              prefixText: 'Rs ',
              prefixStyle: const TextStyle(fontSize: 18),
            ),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            decoration: InputDecoration(
              labelText: p.t('note'),
              prefixIcon: const Icon(Icons.notes, size: 20),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _dateTimeField(
                  icon: Icons.calendar_month,
                  label: p.t('date'),
                  value: DateFormat('dd MMM yyyy').format(_when),
                  onTap: () async {
                    final d = await pickDateOnly(context, _when);
                    if (d != null) {
                      setState(() => _when = DateTime(d.year, d.month, d.day,
                          _when.hour, _when.minute));
                    }
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _dateTimeField(
                  icon: Icons.access_time,
                  label: p.t('timeLabel'),
                  value: DateFormat('hh:mm a').format(_when),
                  onTap: () async {
                    final t = await pickTimeOnly(context, _when);
                    if (t != null) {
                      setState(() => _when = DateTime(_when.year, _when.month,
                          _when.day, t.hour, t.minute));
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.camera_alt),
            title: Text(_attachment == null
                ? p.t('attachBill')
                : _attachment!.split('/').last),
            trailing: _attachment == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _attachment = null),
                  ),
            onTap: () async {
              final path = await pickAttachment(context);
              if (path != null) setState(() => _attachment = path);
            },
          ),
          if (_attachment != null)
            Align(
              alignment: Alignment.centerLeft,
              child: AttachmentThumb(path: _attachment!, size: 84),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 50,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _color),
              onPressed: _saving ? null : _save,
              child: Text(p.t('save'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
    );
  }
}
