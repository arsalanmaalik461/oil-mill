import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';

class BillDetailScreen extends StatefulWidget {
  final Bill bill;
  const BillDetailScreen({super.key, required this.bill});

  @override
  State<BillDetailScreen> createState() => _BillDetailScreenState();
}

class _BillDetailScreenState extends State<BillDetailScreen> {
  final _db = DatabaseHelper.instance;
  List<BillItem> _items = [];
  bool _loading = true;

  Bill get _bill => widget.bill;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _db.getBillItems(_bill.id!);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<Business?> _currentBusiness() async {
    final bizId = context.read<AppProvider>().businessId;
    final businesses = await _db.getBusinesses();
    if (businesses.isEmpty) return null;
    return businesses.firstWhere(
      (b) => b.id == bizId,
      orElse: () => businesses.first,
    );
  }

  Future<void> _sharePdf() async {
    final business = await _currentBusiness();
    if (business == null || !mounted) return;
    await shareBillPdf(business: business, bill: _bill, items: _items);
  }

  Future<void> _shareWhatsApp() async {
    final p = context.read<AppProvider>();
    final buf = StringBuffer()
      ..writeln('${p.t('appName')} — ${p.t('billNo')} ${_bill.billNo}')
      ..writeln('${p.t('date')}: ${dateTimeFmt.format(_bill.dateTime)}');
    for (final i in _items) {
      buf.writeln(
          '${i.name}: ${formatQty(i.qty)} x ${formatRs(i.rate)} = ${formatRs(i.amount)}');
    }
    buf.writeln('${p.t('billTotal')}: ${formatRs(_bill.total)}');
    buf.writeln(
        '${p.t('status')}: ${_bill.status == 'paid' ? p.t('paid') : p.t('pending')}');
    final text = buf.toString();
    if (_bill.partyId != null) {
      final party = await _db.getParty(_bill.partyId!);
      if (party != null && party.phone.trim().isNotEmpty) {
        await openWhatsApp(party.phone, text);
        return;
      }
    }
    await shareText(text);
  }

  Future<void> _delete() async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await _db.setBillDeleted(_bill.id!, true);
    if (!mounted) return;
    showSnack(context, p.t('deleted'));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final paid = _bill.status == 'paid';
    return Scaffold(
      appBar: AppBar(title: Text('${p.t('billNo')} ${_bill.billNo}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _bill.partyName.isEmpty
                                    ? 'Cash Customer'
                                    : _bill.partyName,
                                style: const TextStyle(
                                    fontSize: 17, fontWeight: FontWeight.w700),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: paid
                                    ? const Color(0xFFE5F6EC)
                                    : const Color(0xFFFDE8E8),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                paid ? p.t('paid') : p.t('pending'),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color:
                                      paid ? AppColors.green : AppColors.red,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(dateTimeFmt.format(_bill.dateTime),
                            style: const TextStyle(color: AppColors.textGrey)),
                        const Divider(height: 24),
                        ..._items.map(
                          (i) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: Text(i.name),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    '${formatQty(i.qty)} x ${formatRs(i.rate)}',
                                    style: const TextStyle(
                                        color: AppColors.textGrey),
                                  ),
                                ),
                                Text(formatRs(i.amount),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                        const Divider(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(p.t('billTotal'),
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                            Text(formatRs(_bill.total),
                                style: const TextStyle(
                                    fontSize: 17, fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _sharePdf,
                        icon: const Icon(Icons.picture_as_pdf, size: 18),
                        label: Text(p.t('downloadPdf')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.green),
                        onPressed: _shareWhatsApp,
                        icon: const Icon(Icons.chat, size: 18),
                        label: Text(p.t('shareWhatsapp')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _delete,
                      icon: const Icon(Icons.delete, color: AppColors.red),
                      tooltip: p.t('delete'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
