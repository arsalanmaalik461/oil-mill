import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';

enum _RoznamchaFilter { all, cash, parties, bills, expenses }

class _RoznamchaEntry {
  final DateTime dateTime;
  final String title;
  final String subtitle;
  final double amount;
  final bool isInflow; // true: green (+), false: red (-)
  final _RoznamchaFilter category;
  final IconData icon;

  _RoznamchaEntry({
    required this.dateTime,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.isInflow,
    required this.category,
    required this.icon,
  });
}

class _RoznamchaSnapshot {
  final Business business;
  final DateTime date;
  final double openingCash;
  final double dayInflow;
  final double dayOutflow;
  final double closingCash;
  final List<_RoznamchaEntry> entries;
  final int batchCount;
  final double totalInputKg;
  final double totalOilKg;
  final double totalKhalKg;
  final double totalExpellerExpense;

  /// The frozen closing record for this date, when the day has been
  /// closed (Phase 4). Display figures come from it, not live sums.
  final DailyClosing? frozen;

  /// True when live sums no longer match the frozen record — entries
  /// were edited/backdated after the day was closed.
  final bool mismatch;

  _RoznamchaSnapshot({
    required this.business,
    required this.date,
    required this.openingCash,
    required this.dayInflow,
    required this.dayOutflow,
    required this.closingCash,
    required this.entries,
    required this.batchCount,
    required this.totalInputKg,
    required this.totalOilKg,
    required this.totalKhalKg,
    required this.totalExpellerExpense,
    this.frozen,
    this.mismatch = false,
  });
}

/// Roznamcha (روزنامچہ / Daily Journal):
/// Daily cash opening & closing, wasool & adaigi, crushing production summary,
/// chronological transaction timeline, WhatsApp closing broadcast, and PDF export.
class RoznamchaScreen extends StatefulWidget {
  const RoznamchaScreen({super.key});

  @override
  State<RoznamchaScreen> createState() => _RoznamchaScreenState();
}

class _RoznamchaScreenState extends State<RoznamchaScreen> {
  DateTime _selectedDate = DateTime.now();
  _RoznamchaFilter _filter = _RoznamchaFilter.all;
  late Future<_RoznamchaSnapshot> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final bizId = context.read<AppProvider>().businessId;
    setState(() {
      _future = _fetchData(bizId, _selectedDate);
    });
  }

  Future<_RoznamchaSnapshot> _fetchData(int bizId, DateTime date) async {
    final db = DatabaseHelper.instance;
    final rawDb = await db.db;

    // 1. Business
    final businesses = await db.getBusinesses();
    var business = businesses.isNotEmpty
        ? businesses.first
        : Business(name: 'Namat Oil Mill');
    for (final b in businesses) {
      if (b.id == bizId) {
        business = b;
        break;
      }
    }

    final startOfDay = DateTime(date.year, date.month, date.day);
    final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59, 999);
    final startIso = startOfDay.toIso8601String();
    final endIso = endOfDay.toIso8601String();

    // 2. Opening Cash in Hand prior to this day
    final openRes = await rawDb.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN type='in' THEN amount ELSE -amount END), 0) AS s "
      'FROM cash_entries WHERE business_id = ? AND date_time < ?',
      [bizId, startIso],
    );
    final openingCash = (openRes.first['s'] as num).toDouble();

    final entries = <_RoznamchaEntry>[];

    // 3. Cash Book Entries on this day
    final cashRows = await rawDb.query(
      'cash_entries',
      where: 'business_id = ? AND date_time >= ? AND date_time <= ?',
      whereArgs: [bizId, startIso, endIso],
      orderBy: 'date_time ASC, id ASC',
    );
    double dayCashIn = 0;
    double dayCashOut = 0;
    for (final row in cashRows) {
      final e = CashEntry.fromMap(row);
      final isIn = e.type == 'in';
      if (isIn) {
        dayCashIn += e.amount;
      } else {
        dayCashOut += e.amount;
      }
      entries.add(_RoznamchaEntry(
        dateTime: e.dateTime,
        title: isIn ? 'کیش آمد (Cash In)' : 'کیش ادائیگی (Cash Out)',
        subtitle: e.note.isNotEmpty ? e.note : (isIn ? 'کیش موصول ہوا' : 'کیش ادا کیا'),
        amount: e.amount,
        isInflow: isIn,
        category: _RoznamchaFilter.cash,
        icon: isIn ? Icons.arrow_downward : Icons.arrow_upward,
      ));
    }

    // 4. Party Transactions on this day
    final partyRows = await rawDb.rawQuery('''
      SELECT pt.*, p.name AS party_name, p.phone AS party_phone, p.type AS party_type
      FROM party_transactions pt
      JOIN parties p ON pt.party_id = p.id
      WHERE p.business_id = ? AND pt.date_time >= ? AND pt.date_time <= ?
      ORDER BY pt.date_time ASC, pt.id ASC
    ''', [bizId, startIso, endIso]);
    for (final r in partyRows) {
      final dt = DateTime.tryParse(r['date_time'] as String? ?? '') ?? date;
      final type = r['type'] as String? ?? 'wasool';
      final isWasool = type == 'wasool';
      final amt = (r['amount'] as num?)?.toDouble() ?? 0;
      final partyName = r['party_name'] as String? ?? 'Party';
      final note = r['note'] as String? ?? '';
      final method = r['method'] as String? ?? 'cash';
      final methodLabel = method == 'cash'
          ? 'نقد (Cash)'
          : method == 'bank'
              ? 'بینک (Bank)'
              : method == 'jazzcash'
                  ? 'JazzCash'
                  : 'Easypaisa';
      entries.add(_RoznamchaEntry(
        dateTime: dt,
        title: partyName,
        subtitle: '${isWasool ? 'وصولی (Got)' : 'ادائیگی (Gave)'} • $methodLabel${note.isNotEmpty ? ' • $note' : ''}',
        amount: amt,
        isInflow: isWasool,
        category: _RoznamchaFilter.parties,
        icon: isWasool ? Icons.person_add : Icons.person_remove,
      ));
    }

    // 5. Bills on this day
    final billRows = await rawDb.query(
      'bills',
      where:
          'business_id = ? AND deleted = 0 AND date_time >= ? AND date_time <= ?',
      whereArgs: [bizId, startIso, endIso],
      orderBy: 'date_time ASC, id ASC',
    );
    for (final r in billRows) {
      final b = Bill.fromMap(r);
      entries.add(_RoznamchaEntry(
        dateTime: b.dateTime,
        title: 'Bill #${b.billNo}',
        subtitle:
            '${b.partyName.isNotEmpty ? b.partyName : 'Counter Sale'} • ${b.status == 'paid' ? 'نقد ادائیگی (Paid)' : 'ادھار (Credit)'}',
        amount: b.total,
        isInflow: true,
        category: _RoznamchaFilter.bills,
        icon: Icons.receipt_long,
      ));
    }

    // 6. Direct Expenses on this day
    final expRows = await rawDb.query(
      'expenses',
      where: 'business_id = ? AND date_time >= ? AND date_time <= ?',
      whereArgs: [bizId, startIso, endIso],
      orderBy: 'date_time ASC, id ASC',
    );
    for (final r in expRows) {
      final exp = Expense.fromMap(r);
      entries.add(_RoznamchaEntry(
        dateTime: exp.dateTime,
        title: 'خرچہ: ${exp.category}',
        subtitle:
            '${exp.note.isNotEmpty ? exp.note : 'روزانہ اخراجات'} • ${exp.account == 'bank' ? 'بینک (Bank)' : 'نقد (Cash)'}',
        amount: exp.amount,
        isInflow: false,
        category: _RoznamchaFilter.expenses,
        icon: Icons.money_off,
      ));
    }

    // Sort entries chronologically
    entries.sort((a, b) => a.dateTime.compareTo(b.dateTime));

    // 7. Production batches on this day
    final batchRows = await rawDb.query(
      'production_batches',
      where: 'business_id = ? AND date_time >= ? AND date_time <= ?',
      whereArgs: [bizId, startIso, endIso],
    );
    int batchCount = 0;
    double totalInputKg = 0;
    double totalOilKg = 0;
    double totalKhalKg = 0;
    double totalExpellerExpense = 0;

    for (final r in batchRows) {
      final b = ProductionBatch.fromMap(r);
      if (b.status == 'cancelled') continue;
      batchCount++;
      if (b.id != null) {
        final inRows = await rawDb.rawQuery('''
          SELECT pi.qty, i.name, i.unit
          FROM production_inputs pi
          JOIN items i ON pi.item_id = i.id
          WHERE pi.batch_id = ?
        ''', [b.id]);
        for (final inp in inRows) {
          final q = (inp['qty'] as num?)?.toDouble() ?? 0;
          final u = inp['unit'] as String? ?? 'kg';
          totalInputKg += q * unitToKgFactor(u);
        }

        final outRows = await rawDb.rawQuery('''
          SELECT po.qty, i.name, i.unit
          FROM production_outputs po
          JOIN items i ON po.item_id = i.id
          WHERE po.batch_id = ?
        ''', [b.id]);
        for (final out in outRows) {
          final q = (out['qty'] as num?)?.toDouble() ?? 0;
          final u = out['unit'] as String? ?? 'kg';
          final kg = q * unitToKgFactor(u);
          final n = (out['name'] as String? ?? '').toLowerCase();
          if (n.contains('oil') || n.contains('تیل')) {
            totalOilKg += kg;
          } else {
            totalKhalKg += kg;
          }
        }

        final exps = await db.getBatchExpenses(b.id!);
        for (final ex in exps) {
          totalExpellerExpense += ex.amount;
        }
      }
    }

    // Frozen day (Phase 4): sealed figures win; live sums are only
    // used to detect post-close edits.
    final frozen = await db.getDailyClosing(bizId, date);
    var showOpening = openingCash;
    var showIn = dayCashIn;
    var showOut = dayCashOut;
    var mismatch = false;
    if (frozen != null) {
      mismatch = (frozen.opening - openingCash).abs() > 0.005 ||
          (frozen.totalIn - dayCashIn).abs() > 0.005 ||
          (frozen.totalOut - dayCashOut).abs() > 0.005;
      showOpening = frozen.opening;
      showIn = frozen.totalIn;
      showOut = frozen.totalOut;
    }
    return _RoznamchaSnapshot(
      business: business,
      date: date,
      openingCash: showOpening,
      dayInflow: showIn,
      dayOutflow: showOut,
      closingCash: showOpening + showIn - showOut,
      entries: entries,
      batchCount: batchCount,
      totalInputKg: totalInputKg,
      totalOilKg: totalOilKg,
      totalKhalKg: totalKhalKg,
      totalExpellerExpense: totalExpellerExpense,
      frozen: frozen,
      mismatch: mismatch,
    );
  }

  void _changeDate(int offset) {
    setState(() {
      _selectedDate = _selectedDate.add(Duration(days: offset));
      _reload();
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        _reload();
      });
    }
  }

  Future<void> _shareWhatsApp(_RoznamchaSnapshot s, AppProvider p) async {
    final dateStr = DateFormat('dd MMMM yyyy (EEEE)').format(s.date);
    final sb = StringBuffer();
    sb.writeln('═════════════════════════');
    sb.writeln('🛢️ *${s.business.name}*');
    sb.writeln('📅 *روزنامچہ (Daily Closing Report)*');
    sb.writeln('تاریخ: $dateStr');
    sb.writeln('═════════════════════════');
    sb.writeln('🌅 *صبح کا اوپننگ کیش:* ${formatRs(s.openingCash)}');
    sb.writeln('📥 *آج کی کل وصولی (+):* ${formatRs(s.dayInflow)}');
    sb.writeln('📤 *آج کی کل ادائیگی (-):* ${formatRs(s.dayOutflow)}');
    sb.writeln('─────────────────────────');
    sb.writeln('🌙 *شام کا کیش بیلنس: ${formatRs(s.closingCash)}*');
    sb.writeln('═════════════════════════');

    if (s.batchCount > 0) {
      sb.writeln('🏭 *آج کا پیداواری کام (Crushing):*');
      sb.writeln('• کل بیجز: ${s.batchCount}');
      sb.writeln('• کرشنگ بیج: ${s.totalInputKg.toStringAsFixed(1)} KG (${(s.totalInputKg / 40).toStringAsFixed(1)} من)');
      sb.writeln('• تیار شدہ تیل: ${s.totalOilKg.toStringAsFixed(1)} KG');
      sb.writeln('• تیار شدہ کھل: ${s.totalKhalKg.toStringAsFixed(1)} KG');
      if (s.totalExpellerExpense > 0) {
        sb.writeln('• فیکٹری اخراجات: ${formatRs(s.totalExpellerExpense)}');
      }
      sb.writeln('─────────────────────────');
    }

    sb.writeln('الحمدللہ آج کا تمام حساب اور روزنامچہ مکمل ہے۔');
    sb.writeln('_Generated by Namat Oil Mill App_');

    await shareText(sb.toString());
  }

  Future<void> _exportPdf(_RoznamchaSnapshot s, AppProvider p) async {
    final dateStr = DateFormat('dd_MMM_yyyy').format(s.date);
    final headers = ['Time', 'Category', 'Description', 'Type', 'Amount (Rs)'];
    final rows = s.entries.map((e) {
      return [
        DateFormat('hh:mm a').format(e.dateTime),
        e.category.name.toUpperCase(),
        '${e.title}\n${e.subtitle}',
        e.isInflow ? 'IN (+)' : 'OUT (-)',
        formatRs(e.amount),
      ];
    }).toList();

    final summary = 'Opening: ${formatRs(s.openingCash)} | Today In: +${formatRs(s.dayInflow)} | '
        'Today Out: -${formatRs(s.dayOutflow)} | Closing: ${formatRs(s.closingCash)}';

    await shareReportPdf(
      business: s.business,
      title: 'Roznamcha (Daily Closing) - $dateStr',
      headers: headers,
      rows: rows,
      summaryLine: summary,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final isUrdu = p.isUrdu;
    final isToday = dayKeyFmt.format(_selectedDate) == dayKeyFmt.format(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: Text(isUrdu ? 'روزنامچہ (شام کی کلوزنگ)' : 'Roznamcha (Daily Closing)'),
        actions: [
          IconButton(
            tooltip: isUrdu ? 'تاریخ تبدیل کریں' : 'Change Date',
            icon: const Icon(Icons.calendar_month),
            onPressed: _pickDate,
          ),
          IconButton(
            tooltip: isUrdu ? 'تازہ کریں' : 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder<_RoznamchaSnapshot>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Error loading Roznamcha: ${snapshot.error}',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            );
          }

          final data = snapshot.data!;
          final filteredEntries = _filter == _RoznamchaFilter.all
              ? data.entries
              : data.entries.where((e) => e.category == _filter).toList();

          return Column(
            children: [
              // 1. Date Navigation Bar
              _buildDateBar(isToday, isUrdu),

              // 2. Scrollable Body
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    // 4 Balance Summary Cards
                    _buildBalanceMatrix(p, data, isUrdu),

                    const SizedBox(height: 12),

                    // Production summary of the day (if batches run)
                    if (data.batchCount > 0) ...[
                      _buildProductionCard(data, isUrdu),
                      const SizedBox(height: 12),
                    ],

                    // Filter chips row
                    _buildFilterRow(isUrdu, data.entries.length),

                    const SizedBox(height: 8),

                    // Chronological Entries List
                    if (filteredEntries.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
                        alignment: Alignment.center,
                        child: Column(
                          children: [
                            Icon(Icons.event_note, size: 48, color: Colors.grey.shade400),
                            const SizedBox(height: 10),
                            Text(
                              isUrdu
                                  ? 'اس تاریخ کا کوئی لین دین ریکارڈ نہیں ہوا'
                                  : 'No transactions recorded on this date',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    else
                      ...filteredEntries.map((e) => _buildEntryTile(e, isUrdu)),

                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      bottomSheet: FutureBuilder<_RoznamchaSnapshot>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const SizedBox.shrink();
          final data = snapshot.data!;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.share, size: 20),
                    label: Text(
                      isUrdu ? 'واٹس ایپ شیئر' : 'WhatsApp Share',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => _shareWhatsApp(data, p),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.picture_as_pdf, size: 20),
                  label: Text(
                    isUrdu ? 'پی ڈی ایف' : 'PDF',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => _exportPdf(data, p),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildDateBar(bool isToday, bool isUrdu) {
    return Container(
      color: Colors.grey.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: isUrdu ? 'پچھلا دن' : 'Previous Day',
            onPressed: () => _changeDate(-1),
          ),
          InkWell(
            onTap: _pickDate,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, size: 16, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('EEEE, dd MMM yyyy').format(_selectedDate),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  if (isToday) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isUrdu ? 'آج' : 'Today',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: isUrdu ? 'اگلا دن' : 'Next Day',
            onPressed: () => _changeDate(1),
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceMatrix(AppProvider p, _RoznamchaSnapshot d, bool isUrdu) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _card(
                title: isUrdu ? 'صبح کا اوپننگ کیش' : 'Opening Cash',
                amount: d.openingCash,
                icon: Icons.wb_sunny_outlined,
                color: const Color(0xFF1E88E5), // Blue
                prefix: '',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _card(
                title: isUrdu ? 'کل وصولی / ان' : 'Total In (Wasool)',
                amount: d.dayInflow,
                icon: Icons.south_west,
                color: const Color(0xFF2E7D32), // Green
                prefix: '+',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _card(
                title: isUrdu ? 'کل ادائیگی / آؤٹ' : 'Total Out (Adaigi)',
                amount: d.dayOutflow,
                icon: Icons.north_east,
                color: const Color(0xFFC62828), // Red
                prefix: '-',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _card(
                title: isUrdu ? 'شام کا کیش بیلنس' : 'Closing Cash',
                amount: d.closingCash,
                icon: Icons.nightlight_round,
                color: AppColors.primary, // Brand Primary
                prefix: '',
                isHighlight: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (d.frozen != null) ...[
          Row(
            children: [
              const Icon(Icons.lock, size: 16, color: AppColors.green),
              const SizedBox(width: 6),
              Text(
                '${p.t('dayClosed')} • ${dateTimeFmt.format(d.frozen!.frozenAt)}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.green),
              ),
            ],
          ),
          if (d.mismatch) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber,
                      size: 18, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(p.t('dayMismatch'),
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],
        ] else
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () async {
                final bizId = context.read<AppProvider>().businessId;
                await DatabaseHelper.instance
                    .freezeDailyClosing(bizId, d.date);
                if (mounted) _reload();
              },
              icon: const Icon(Icons.lock_clock, size: 16),
              label: Text(p.t('closeDay')),
            ),
          ),
      ],
    );
  }

  Widget _card({
    required String title,
    required double amount,
    required IconData icon,
    required Color color,
    required String prefix,
    bool isHighlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: isHighlight ? color.withValues(alpha: 0.1) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isHighlight ? color : color.withValues(alpha: 0.25),
          width: isHighlight ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$prefix${formatRs(amount)}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductionCard(_RoznamchaSnapshot d, bool isUrdu) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1), // Light amber
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFB300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.factory, size: 18, color: Color(0xFFE65100)),
              const SizedBox(width: 8),
              Text(
                isUrdu ? 'آج کا پیداواری کام (Crushing & Output)' : 'Today\'s Crushing & Production',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFE65100)),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFE65100),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${d.batchCount} ${isUrdu ? 'بیچ' : 'Batches'}',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const Divider(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _metric(
                label: isUrdu ? 'کرشنگ شدہ بیج' : 'Crushed Seed',
                value: '${(d.totalInputKg / 40).toStringAsFixed(1)} Man',
                subValue: '${d.totalInputKg.toStringAsFixed(0)} KG',
              ),
              _metric(
                label: isUrdu ? 'تیار شدہ تیل' : 'Oil Extracted',
                value: '${d.totalOilKg.toStringAsFixed(1)} KG',
                subValue: '',
              ),
              _metric(
                label: isUrdu ? 'تیار شدہ کھل' : 'Khal / Cake',
                value: '${d.totalKhalKg.toStringAsFixed(1)} KG',
                subValue: '',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric({required String label, required String value, required String subValue}) {
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
        if (subValue.isNotEmpty)
          Text(subValue, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _buildFilterRow(bool isUrdu, int totalCount) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _filterChip(_RoznamchaFilter.all, isUrdu ? 'تمام ($totalCount)' : 'All ($totalCount)'),
          const SizedBox(width: 6),
          _filterChip(_RoznamchaFilter.cash, isUrdu ? 'کیش بک' : 'Cash Book'),
          const SizedBox(width: 6),
          _filterChip(_RoznamchaFilter.parties, isUrdu ? 'کھاتہ' : 'Parties'),
          const SizedBox(width: 6),
          _filterChip(_RoznamchaFilter.bills, isUrdu ? 'بلز' : 'Bills'),
          const SizedBox(width: 6),
          _filterChip(_RoznamchaFilter.expenses, isUrdu ? 'اخراجات' : 'Expenses'),
        ],
      ),
    );
  }

  Widget _filterChip(_RoznamchaFilter f, String label) {
    final sel = _filter == f;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
      selected: sel,
      selectedColor: AppColors.primary.withValues(alpha: 0.15),
      onSelected: (_) => setState(() => _filter = f),
    );
  }

  Widget _buildEntryTile(_RoznamchaEntry e, bool isUrdu) {
    final timeStr = DateFormat('hh:mm a').format(e.dateTime);
    final color = e.isInflow ? const Color(0xFF2E7D32) : const Color(0xFFC62828);

    return Card(
      elevation: 0.6,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(e.icon, color: color, size: 20),
        ),
        title: Text(
          e.title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: Text(
          '$timeStr • ${e.subtitle}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        trailing: Text(
          '${e.isInflow ? '+' : '-'}${formatRs(e.amount)}',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
