import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';

class _ReminderRow {
  final Party party;
  final double balance;
  _ReminderRow(this.party, this.balance);
}

class _ReminderData {
  final String businessName;
  final Business business;
  final List<_ReminderRow> rows;

  /// Parties due an automatic reminder right now (owe money, phone on
  /// file, last reminder at least 5 days ago or never sent).
  final List<_ReminderRow> dueRows;
  _ReminderData(this.businessName, this.business, this.rows,
      [this.dueRows = const []]);
}

/// Payment reminders: every party with a non-zero balance, biggest first,
/// with per-party due dates and WhatsApp / SMS / call actions.
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  late Future<_ReminderData> _future;
  late int _bizId;
  final Map<int, DateTime> _dueDates = {};

  /// Auto reminder toggle (SharedPreferences 'auto_reminder_enabled',
  /// default ON). WhatsApp still opens per party — sending always takes
  /// one tap on the WhatsApp button; nothing is sent on its own.
  bool _autoEnabled = true;

  @override
  void initState() {
    super.initState();
    _bizId = context.read<AppProvider>().businessId;
    _future = _load(_bizId);
    _loadAutoPref();
  }

  Future<void> _loadAutoPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _autoEnabled = prefs.getBool('auto_reminder_enabled') ?? true);
  }

  Future<void> _setAutoEnabled(bool value) async {
    setState(() => _autoEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_reminder_enabled', value);
  }

  void _reload() {
    setState(() => _future = _load(_bizId));
  }

  Future<_ReminderData> _load(int bizId) async {
    final db = DatabaseHelper.instance;
    final businesses = await db.getBusinesses();
    var bizName = 'Namat Oil Mill';
    Business? business;
    for (final b in businesses) {
      if (b.id == bizId) {
        bizName = b.name;
        business = b;
        break;
      }
    }
    if (business == null && businesses.isNotEmpty) {
      business = businesses.first;
      bizName = business.name;
    }
    business ??= Business(name: bizName);
    final parties = await db.getParties(bizId);
    final rows = <_ReminderRow>[];
    for (final party in parties) {
      if (party.id == null) continue;
      final bal = await db.getPartyBalance(party.id!);
      if (bal != 0) rows.add(_ReminderRow(party, bal));
    }
    rows.sort((a, b) => b.balance.abs().compareTo(a.balance.abs()));
    // Due-for-auto-reminder rows reuse the balances just computed.
    final dueParties = await db.getPartiesDueForReminder(bizId);
    final dueIds = dueParties.map((e) => e.id).toSet();
    final dueRows = rows.where((r) => dueIds.contains(r.party.id)).toList();
    return _ReminderData(bizName, business, rows, dueRows);
  }

  /// Opens WhatsApp for this party, then stamps the reminder as sent so
  /// the party drops out of the auto-reminder due section for 5 days.
  Future<void> _sendWhatsAppReminder(_ReminderData d, _ReminderRow row) async {
    final id = row.party.id;
    if (id == null) return;
    await openWhatsApp(row.party.phone, _reminderText(d, row));
    await DatabaseHelper.instance.markReminderSent(id);
    if (!mounted) return;
    _reload();
  }

  /// Sends the reminder WITH the party's full ledger PDF (all
  /// transactions). WhatsApp wa.me links cannot attach files, so the PDF
  /// goes through the system share sheet, where the user picks WhatsApp
  /// and the customer — one extra tap, no way around it on a personal
  /// number. Sharing the PDF counts as sending the reminder, so the
  /// party is stamped the same way as the WhatsApp action.
  Future<void> _sendLedgerPdfReminder(_ReminderData d, _ReminderRow row) async {
    final id = row.party.id;
    if (id == null) return;
    final transactions =
        await DatabaseHelper.instance.getPartyTransactions(id);
    await shareLedgerPdf(
      business: d.business,
      party: row.party,
      transactions: transactions,
      balance: row.balance,
    );
    await DatabaseHelper.instance.markReminderSent(id);
    if (!mounted) return;
    _reload();
  }

  DateTime _dueFor(int partyId) =>
      _dueDates[partyId] ?? DateTime.now().add(const Duration(days: 3));

  String _reminderText(_ReminderData d, _ReminderRow row) {
    final due = dateFmt.format(_dueFor(row.party.id ?? 0));
    final amount = formatRs(row.balance.abs());
    if (row.balance > 0) {
      return 'Dear ${row.party.name}, this is a payment reminder from ${d.businessName}. '
          'Your outstanding balance is $amount (payable by $due). '
          'Please arrange payment. Thank you!';
    }
    return 'Dear ${row.party.name}, this is a payment reminder from ${d.businessName}. '
        'We will pay you $amount by $due. Thank you!';
  }

  Future<void> _pickDue(_ReminderRow row) async {
    final id = row.party.id;
    if (id == null) return;
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueFor(id),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _dueDates[id] = picked);
    }
  }

  Future<void> _shareAll(AppProvider p, _ReminderData d) async {
    final buf = StringBuffer()
      ..writeln('${d.businessName} — ${p.t('outstanding')}')
      ..writeln('');
    for (final row in d.rows) {
      final kind = row.balance > 0 ? p.t('youWillGet') : p.t('youWillGive');
      buf.writeln(
        '${row.party.name}: ${formatRs(row.balance.abs())} ($kind) — '
        '${p.t('dueDate')}: ${dateFmt.format(_dueFor(row.party.id ?? 0))}',
      );
    }
    await shareText(buf.toString());
  }

  Widget _buildAutoCard(AppProvider p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Card(
        color: AppColors.primary.withValues(alpha: 0.07),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
        child: Column(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.alarm_on, color: AppColors.primary),
              title: Text(
                p.t('autoReminder'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(p.t('autoReminderDesc')),
              value: _autoEnabled,
              onChanged: _setAutoEnabled,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  p.t('autoReminderNote'),
                  style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDueSection(AppProvider p, _ReminderData d) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 300),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        itemCount: d.dueRows.length,
        itemBuilder: (context, i) {
          final row = d.dueRows[i];
          final party = row.party;
          final hasPhone = party.phone.trim().isNotEmpty;
          void needPhone() => showSnack(context, p.t('noPhone'));
          final lastText = party.lastReminderAt == null
              ? p.t('never')
              : dateFmt.format(party.lastReminderAt!);
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.accent),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppColors.accent.withValues(alpha: 0.15),
                      child: Text(
                        initials(party.name),
                        style: const TextStyle(
                          color: AppColors.primaryDark,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    title: Text(
                      party.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${p.t('youWillGet')}: ${formatRs(row.balance)} • '
                      '${p.t('lastReminder')}: $lastText',
                    ),
                    trailing: Chip(
                      label: Text(
                        p.t('dueNow'),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      backgroundColor: AppColors.primary,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
                    child: Row(
                      children: [
                        // Primary action: reminder WITH the full ledger PDF.
                        ElevatedButton.icon(
                          onPressed: () => _sendLedgerPdfReminder(d, row),
                          icon: const Icon(Icons.picture_as_pdf, size: 18),
                          label: Text('${p.t('ledger')} PDF'),
                        ),
                        const SizedBox(width: 4),
                        // Secondary action: plain WhatsApp text reminder.
                        IconButton(
                          tooltip: p.t('whatsappReminder'),
                          icon: const Icon(Icons.chat, color: AppColors.green),
                          onPressed: hasPhone
                              ? () => _sendWhatsAppReminder(d, row)
                              : needPhone,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('reminders'))),
      body: FutureBuilder<_ReminderData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data ??
              _ReminderData(
                  'Namat Oil Mill', Business(name: 'Namat Oil Mill'), const []);
          return Column(
            children: [
              _buildAutoCard(p),
              if (_autoEnabled && d.dueRows.isNotEmpty) _buildDueSection(p, d),
              if (d.rows.isEmpty)
                Expanded(child: Center(child: Text(p.t('noData'))))
              else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    // WhatsApp cannot open many chats one after another, so
                    // "send to all" shares one combined outstanding list that
                    // can be forwarded to a group or broadcast list.
                    onPressed: () => _shareAll(p, d),
                    icon: const Icon(Icons.share),
                    label: Text('${p.t('sendReminder')} (${p.t('all')}) — WhatsApp'),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: d.rows.length,
                  itemBuilder: (context, i) {
                    final row = d.rows[i];
                    final party = row.party;
                    final hasPhone = party.phone.trim().isNotEmpty;
                    void needPhone() => showSnack(context, p.t('noPhone'));
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          children: [
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                                child: Text(
                                  initials(party.name),
                                  style: const TextStyle(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              title: Text(
                                party.name,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(party.phone.isEmpty ? p.t('noPhone') : party.phone),
                              trailing: AmountText(row.balance, positiveIsGreen: false),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
                              child: Row(
                                children: [
                                  TextButton.icon(
                                    onPressed: () => _pickDue(row),
                                    icon: const Icon(Icons.event, size: 18),
                                    label: Text(
                                      '${p.t('dueDate')}: ${dateFmt.format(_dueFor(party.id ?? 0))}',
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    tooltip: '${p.t('ledger')} PDF',
                                    icon: const Icon(Icons.picture_as_pdf,
                                        color: AppColors.primary),
                                    onPressed: () => _sendLedgerPdfReminder(d, row),
                                  ),
                                  IconButton(
                                    tooltip: p.t('whatsappReminder'),
                                    icon: const Icon(Icons.chat, color: AppColors.green),
                                    onPressed: hasPhone
                                        ? () => _sendWhatsAppReminder(d, row)
                                        : needPhone,
                                  ),
                                  IconButton(
                                    tooltip: p.t('smsReminder'),
                                    icon: const Icon(Icons.sms, color: AppColors.primary),
                                    onPressed: hasPhone
                                        ? () => openSms(party.phone, _reminderText(d, row))
                                        : needPhone,
                                  ),
                                  IconButton(
                                    tooltip: p.t('callNow'),
                                    icon: const Icon(Icons.call, color: AppColors.accent),
                                    onPressed: hasPhone ? () => callPhone(party.phone) : needPhone,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              ],
            ],
          );
        },
      ),
    );
  }
}
