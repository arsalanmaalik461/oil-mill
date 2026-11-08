import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';

final _timeFmt = DateFormat('hh:mm a');

class _CashData {
  final List<CashEntry> entries;
  final double cashBalance;
  final List<Party> parties;
  const _CashData(this.entries, this.cashBalance, this.parties);
}

/// Cash Book: cash in hand, today's balance, entries grouped by day with
/// separate In / Out columns — layout copied from the reference screenshots.
class CashBookScreen extends StatefulWidget {
  const CashBookScreen({super.key});

  @override
  State<CashBookScreen> createState() => _CashBookScreenState();
}

class _CashBookScreenState extends State<CashBookScreen> {
  late Future<_CashData> _future;
  _CashData? _lastData;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_CashData> _load() async {
    final db = DatabaseHelper.instance;
    final bizId = context.read<AppProvider>().businessId;
    final entries = await db.getCashEntries(bizId);
    final balance = await db.getCashBalance(bizId);
    final parties = await db.getParties(bizId);
    final data = _CashData(entries, balance, parties);
    _lastData = data;
    return data;
  }

  void _reload() => setState(() => _future = _load());

  Future<Business> _currentBusiness() async {
    final bizId = context.read<AppProvider>().businessId;
    final bs = await DatabaseHelper.instance.getBusinesses();
    for (final b in bs) {
      if (b.id == bizId) return b;
    }
    return bs.isNotEmpty ? bs.first : Business(name: 'Namat Oil Mill');
  }

  Future<void> _exportPdf() async {
    final data = _lastData;
    if (data == null) return;
    final p = context.read<AppProvider>();
    final biz = await _currentBusiness();
    if (!mounted) return;
    await shareReportPdf(
      business: biz,
      title: p.t('cashReport'),
      headers: [p.t('date'), p.t('note'), p.t('in'), p.t('out')],
      rows: data.entries
          .map((e) => [
                dateTimeFmt.format(e.dateTime),
                e.note,
                e.type == 'in' ? formatRs(e.amount) : '',
                e.type == 'out' ? formatRs(e.amount) : '',
              ])
          .toList(),
      summaryLine:
          '${p.t('cashInHand')}: ${formatRs(data.cashBalance)}',
    );
  }

  Future<void> _deleteEntry(CashEntry e) async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await DatabaseHelper.instance.deleteCashEntry(e.id!);
    if (!mounted) return;
    _reload();
    context.read<AppProvider>().bump();
  }

  Future<void> _showEntryForm(String type, List<Party> parties) async {
    final p = context.read<AppProvider>();
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var selectedDate = DateTime.now();
    int? selectedPartyId;
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
                  type == 'in' ? p.t('cashIn') : p.t('cashOut'),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: amountCtrl,
                  decoration: InputDecoration(labelText: p.t('amount')),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  decoration: InputDecoration(labelText: p.t('note')),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int?>(
                  value: selectedPartyId,
                  decoration: InputDecoration(
                      labelText: '${p.t('customer')} / ${p.t('supplier')}'),
                  items: [
                    DropdownMenuItem<int?>(
                        value: null, child: Text(p.t('none'))),
                    ...parties.map((party) => DropdownMenuItem<int?>(
                          value: party.id,
                          child: Text(party.name),
                        )),
                  ],
                  onChanged: (v) =>
                      setSheetState(() => selectedPartyId = v),
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
                      final amount = double.tryParse(amountCtrl.text.trim());
                      if (amount == null || amount <= 0) {
                        showSnack(bc, p.t('invalidAmount'));
                        return;
                      }
                      await DatabaseHelper.instance.insertCashEntry(
                        CashEntry(
                          businessId: p.businessId,
                          type: type,
                          amount: amount,
                          note: noteCtrl.text.trim(),
                          partyId: selectedPartyId,
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
    amountCtrl.dispose();
    noteCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(p.t('cashBook')),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _exportPdf,
          ),
        ],
      ),
      body: FutureBuilder<_CashData>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!;
          final todayKey = dayKeyFmt.format(DateTime.now());
          var todayNet = 0.0;
          for (final e in data.entries) {
            if (dayKeyFmt.format(e.dateTime) == todayKey) {
              todayNet += e.type == 'in' ? e.amount : -e.amount;
            }
          }
          final q = _search.trim().toLowerCase();
          final filtered = data.entries
              .where((e) => q.isEmpty || e.note.toLowerCase().contains(q))
              .toList();
          // Group by day, keeping newest-first order.
          final groups = <String, List<CashEntry>>{};
          for (final e in filtered) {
            groups.putIfAbsent(dayKeyFmt.format(e.dateTime), () => []).add(e);
          }
          final dayKeys = groups.keys.toList();
          final partyNames = {for (final party in data.parties) party.id: party.name};
          return Column(
            children: [
              GradientHeader(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              formatRs(data.cashBalance),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: data.cashBalance < 0
                                    ? AppColors.red
                                    : AppColors.green,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(p.t('cashInHand'),
                                style: const TextStyle(
                                    fontSize: 11, color: AppColors.textGrey)),
                          ],
                        ),
                      ),
                      Container(
                          width: 1, height: 34, color: AppColors.cardBorder),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              formatRs(todayNet),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: todayNet < 0
                                    ? AppColors.red
                                    : AppColors.green,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(p.t('todayBalance'),
                                style: const TextStyle(
                                    fontSize: 11, color: AppColors.textGrey)),
                          ],
                        ),
                      ),
                      Container(
                          width: 1, height: 34, color: AppColors.cardBorder),
                      Expanded(
                        child: Column(
                          children: [
                            const Icon(Icons.history,
                                color: AppColors.primary, size: 20),
                            const SizedBox(height: 2),
                            Text(p.t('history'),
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  decoration: InputDecoration(
                    hintText: p.t('search'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? Center(child: Text(p.t('noData')))
                    : ListView.builder(
                        itemCount: dayKeys.length,
                        itemBuilder: (context, gi) {
                          final dayEntries = groups[dayKeys[gi]]!;
                          var dayIn = 0.0, dayOut = 0.0;
                          for (final e in dayEntries) {
                            if (e.type == 'in') {
                              dayIn += e.amount;
                            } else {
                              dayOut += e.amount;
                            }
                          }
                          final dayDate = dayEntries.first.dateTime;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                color: Colors.white,
                                padding: const EdgeInsets.fromLTRB(
                                    16, 10, 16, 10),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            dateFmt.format(dayDate)
                                                .toUpperCase(),
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13),
                                          ),
                                          Text(
                                            '${dayEntries.length} ${p.t('entries')}',
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: AppColors.textGrey),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Text(
                                      '${p.t('out')}: ${formatRs(dayOut)}',
                                      style: const TextStyle(
                                          color: AppColors.red,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      '${p.t('in')}: ${formatRs(dayIn)}',
                                      style: const TextStyle(
                                          color: AppColors.green,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              ...dayEntries.map((e) {
                                final partyName = e.partyId != null
                                    ? partyNames[e.partyId]
                                    : null;
                                return InkWell(
                                  onLongPress: () => _deleteEntry(e),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 9),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                _timeFmt.format(e.dateTime),
                                                style: const TextStyle(
                                                    fontSize: 12,
                                                    color:
                                                        AppColors.textGrey),
                                              ),
                                              if (e.note.isNotEmpty)
                                                Text(e.note,
                                                    style: const TextStyle(
                                                        fontSize: 13)),
                                              if (partyName != null)
                                                Text(partyName,
                                                    style: const TextStyle(
                                                        fontSize: 12,
                                                        color: AppColors
                                                            .textGrey)),
                                            ],
                                          ),
                                        ),
                                        SizedBox(
                                          width: 84,
                                          child: Text(
                                            e.type == 'out'
                                                ? formatRs(e.amount)
                                                : '',
                                            textAlign: TextAlign.right,
                                            style: const TextStyle(
                                                color: AppColors.red,
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 84,
                                          child: Text(
                                            e.type == 'in'
                                                ? formatRs(e.amount)
                                                : '',
                                            textAlign: TextAlign.right,
                                            style: const TextStyle(
                                                color: AppColors.green,
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                              const Divider(height: 1),
                            ],
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.red),
                  onPressed: () =>
                      _showEntryForm('out', _lastData?.parties ?? []),
                  child: Text(p.t('cashOut')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.green),
                  onPressed: () =>
                      _showEntryForm('in', _lastData?.parties ?? []),
                  child: Text(p.t('cashIn')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
