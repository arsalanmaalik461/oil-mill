import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import 'party_entry_form_screen.dart';

/// One ledger entry in full, modelled on the original khata app:
/// party + amount card, details, running balance, EDIT / DELETE ENTRY,
/// a "move entry" flip (You Gave <-> You Got), and WhatsApp / SMS
/// share buttons at the bottom.
class PartyEntryDetailScreen extends StatefulWidget {
  final Party party;
  final PartyTransaction transaction;

  /// Balance immediately after this entry (computed by the caller, which
  /// owns the full ledger ordering).
  final double runningBalance;

  const PartyEntryDetailScreen({
    super.key,
    required this.party,
    required this.transaction,
    required this.runningBalance,
  });

  @override
  State<PartyEntryDetailScreen> createState() => _PartyEntryDetailScreenState();
}

class _PartyEntryDetailScreenState extends State<PartyEntryDetailScreen> {
  late PartyTransaction _txn;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _txn = widget.transaction;
  }

  bool get _isUdhaar => _txn.type == 'udhaar';

  Future<void> _reload() async {
    final rows = await DatabaseHelper.instance
        .getPartyTransactions(widget.party.id!);
    for (final t in rows) {
      if (t.id == _txn.id) {
        if (mounted) setState(() => _txn = t);
        return;
      }
    }
  }

  Future<void> _edit() async {
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PartyEntryFormScreen(
          party: widget.party,
          type: _txn.type,
          existing: _txn,
        ),
      ),
    );
    if (r == true) {
      _changed = true;
      await _reload();
    }
  }

  Future<void> _delete() async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok) return;
    await DatabaseHelper.instance.deletePartyTransaction(_txn.id!);
    if (!mounted) return;
    context.read<AppProvider>().bump();
    Navigator.pop(context, true);
  }

  /// The original app's swap action: move this entry to the other side
  /// (You Got -> You Gave or the reverse) after an explicit confirm.
  Future<void> _move() async {
    final p = context.read<AppProvider>();
    final go = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.t('moveEntryTitle'),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(p.t(_isUdhaar ? 'moveFromGave' : 'moveFromGot'),
                  style: const TextStyle(color: AppColors.textGrey)),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: Text(p.t('moveBtn')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (go != true) return;
    final flipped = PartyTransaction(
      id: _txn.id,
      partyId: _txn.partyId,
      type: _isUdhaar ? 'wasool' : 'udhaar',
      amount: _txn.amount,
      note: _txn.note,
      dateTime: _txn.dateTime,
      attachmentPath: _txn.attachmentPath,
    );
    await DatabaseHelper.instance.updatePartyTransaction(flipped);
    if (!mounted) return;
    _changed = true;
    context.read<AppProvider>().bump();
    setState(() => _txn = flipped);
    showSnack(context, p.t('savedSuccessfully'));
  }

  String _shareText(AppProvider p) =>
      '${widget.party.name}\n'
      '${p.t(_txn.type)}: ${formatRs(_txn.amount)}\n'
      '${dateTimeFmt.format(_txn.dateTime)}'
      '${_txn.note.isNotEmpty ? '\n${_txn.note}' : ''}';

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final party = widget.party;
    final color = _isUdhaar ? AppColors.red : AppColors.green;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(p.t('entryDetail')),
          actions: [
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: p.t('moveBtn'),
              onPressed: _move,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor:
                          AppColors.primary.withValues(alpha: 0.12),
                      child: Text(initials(party.name),
                          style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(party.name,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(dateTimeFmt.format(_txn.dateTime),
                              style: const TextStyle(
                                  color: AppColors.textGrey, fontSize: 13)),
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 30),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              alignment: Alignment.centerLeft,
                            ),
                            onPressed: _move,
                            child: Text(p.t('changeLabel')),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        AmountText(_txn.amount,
                            positiveIsGreen: !_isUdhaar, fontSize: 19),
                        Text(p.t(_txn.type),
                            style: TextStyle(color: color, fontSize: 13)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_txn.attachmentPath != null &&
                _txn.attachmentPath!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: AttachmentThumb(path: _txn.attachmentPath!, size: 110),
              ),
            ],
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.t('detailsLabel'),
                        style: const TextStyle(
                            color: AppColors.textGrey, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(_txn.note.isNotEmpty ? _txn.note : '—',
                        style: const TextStyle(fontSize: 15)),
                    const Divider(height: 26),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(p.t('runningBalance'),
                              style: const TextStyle(
                                  color: AppColors.textGrey, fontSize: 13)),
                        ),
                        AmountText(widget.runningBalance,
                            positiveIsGreen: false, fontSize: 16),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.edit_outlined),
              label: Text(p.t('editEntry')),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cloud_done, size: 16, color: AppColors.green),
                const SizedBox(width: 6),
                Text(p.t('entryBackedUp'),
                    style: const TextStyle(
                        color: AppColors.textGrey, fontSize: 12.5)),
              ],
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              label: Text(p.t('deleteEntry'),
                  style: const TextStyle(color: Colors.red)),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('WHATSAPP'),
                    onPressed: party.phone.trim().isEmpty
                        ? null
                        : () => openWhatsApp(party.phone, _shareText(p)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.sms_outlined),
                    label: const Text('SMS'),
                    onPressed: party.phone.trim().isEmpty
                        ? null
                        : () => openSms(party.phone, _shareText(p)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
