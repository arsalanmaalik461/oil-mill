import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';
import 'bill_detail_screen.dart';
import 'create_bill_screen.dart';

class BillBookScreen extends StatefulWidget {
  const BillBookScreen({super.key});

  @override
  State<BillBookScreen> createState() => _BillBookScreenState();
}

class _BillBookScreenState extends State<BillBookScreen> {
  final _db = DatabaseHelper.instance;
  List<Bill> _bills = [];
  double _monthTotal = 0;
  String _query = '';
  DateTime? _start;
  DateTime? _end;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bizId = context.read<AppProvider>().businessId;
    final bills = await _db.getBills(bizId);
    final total = await _db.getTotalSales(bizId, month: DateTime.now());
    if (!mounted) return;
    setState(() {
      _bills = bills;
      _monthTotal = total;
      _loading = false;
    });
  }

  List<Bill> get _filtered {
    var list = _bills;
    if (_start != null) {
      final s = DateTime(_start!.year, _start!.month, _start!.day);
      list = list.where((b) => !b.dateTime.isBefore(s)).toList();
    }
    if (_end != null) {
      final e = DateTime(_end!.year, _end!.month, _end!.day, 23, 59, 59);
      list = list.where((b) => !b.dateTime.isAfter(e)).toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list
          .where((b) =>
              b.billNo.toString().contains(q) || b.partyName.toLowerCase().contains(q))
          .toList();
    }
    return list;
  }

  Future<void> _pickDate(bool isStart) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _start : _end) ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _start = picked;
      } else {
        _end = picked;
      }
    });
  }

  Future<void> _exportPdf() async {
    final p = context.read<AppProvider>();
    final businesses = await _db.getBusinesses();
    if (!mounted || businesses.isEmpty) return;
    final business = businesses.firstWhere(
      (b) => b.id == p.businessId,
      orElse: () => businesses.first,
    );
    final list = _filtered;
    final total = list.fold<double>(0, (s, b) => s + b.total);
    await shareReportPdf(
      business: business,
      title: p.t('billBook'),
      headers: [p.t('billNo'), p.t('date'), p.t('customer'), p.t('status'), p.t('amount')],
      rows: list
          .map((b) => [
                '${b.billNo}',
                dateTimeFmt.format(b.dateTime),
                b.partyName.isEmpty ? p.t('cashCustomer') : b.partyName,
                b.status == 'paid' ? p.t('paid') : p.t('pending'),
                formatRs(b.total),
              ])
          .toList(),
      summaryLine: '${p.t('total')}: ${formatRs(total)}',
    );
  }

  Future<void> _delete(Bill bill) async {
    final p = context.read<AppProvider>();
    final ok = await confirmDelete(context, p.t('confirmDelete'));
    if (!ok || !mounted) return;
    await _db.setBillDeleted(bill.id!, true);
    if (!mounted) return;
    showSnack(context, p.t('deleted'));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final monthName = DateFormat('MMMM').format(DateTime.now());
    final list = _filtered;
    return Scaffold(
      appBar: AppBar(title: Text(p.t('billBook'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final done = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const CreateBillScreen()),
          );
          if (done == true) _load();
        },
        icon: const Icon(Icons.add),
        label: Text(p.t('createBill')),
      ),
      body: Column(
        children: [
          GradientHeader(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${p.t('totalSale')} — $monthName',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        AmountText(_monthTotal, fontSize: 17),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white70),
                        ),
                        onPressed: () => _pickDate(true),
                        icon: const Icon(Icons.calendar_month, size: 16),
                        label: Text(_start == null
                            ? '${p.t('from')}: ${p.t('selectDate')}'
                            : '${p.t('from')}: ${dateFmt.format(_start!)}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white70),
                        ),
                        onPressed: () => _pickDate(false),
                        icon: const Icon(Icons.calendar_month, size: 16),
                        label: Text(_end == null
                            ? '${p.t('to')}: ${p.t('selectDate')}'
                            : '${p.t('to')}: ${dateFmt.format(_end!)}'),
                      ),
                    ),
                    if (_start != null || _end != null)
                      IconButton(
                        onPressed: () => setState(() {
                          _start = null;
                          _end = null;
                        }),
                        icon: const Icon(Icons.clear, color: Colors.white),
                        tooltip: p.t('cancel'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: p.t('search'),
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                ),
                IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.filter_list, color: AppColors.primary),
                ),
                IconButton(
                  onPressed: _exportPdf,
                  icon: const Icon(Icons.picture_as_pdf, color: AppColors.primary),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                    ? Center(child: Text(p.t('noData')))
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 90),
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final b = list[i];
                          final paid = b.status == 'paid';
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: ListTile(
                              leading: const CircleAvatar(
                                backgroundColor: Color(0xFFFFF3E8),
                                child: Icon(Icons.receipt_long,
                                    color: AppColors.accent),
                              ),
                              title: Text('${p.t('billNo')} ${b.billNo}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(dateTimeFmt.format(b.dateTime),
                                      style: const TextStyle(fontSize: 12)),
                                  if (b.partyName.isNotEmpty)
                                    Text(b.partyName,
                                        style: const TextStyle(fontSize: 12)),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: paid
                                          ? const Color(0xFFE5F6EC)
                                          : const Color(0xFFFDE8E8),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      paid ? p.t('cashIn') : p.t('pending'),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: paid
                                            ? AppColors.green
                                            : AppColors.red,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AmountText(b.total),
                                  PopupMenuButton<String>(
                                    onSelected: (v) {
                                      if (v == 'delete') _delete(b);
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text(p.t('delete')),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => BillDetailScreen(bill: b)),
                                );
                                _load();
                              },
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
