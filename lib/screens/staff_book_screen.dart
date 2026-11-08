import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';
import 'staff_detail_screen.dart';
import 'staff_form_screen.dart';

class StaffBookScreen extends StatefulWidget {
  const StaffBookScreen({super.key});

  @override
  State<StaffBookScreen> createState() => _StaffBookScreenState();
}

class _StaffBookScreenState extends State<StaffBookScreen> {
  final _db = DatabaseHelper.instance;
  List<Staff> _staff = [];
  Map<int, Attendance> _dayRecords = {};
  DateTime _date = DateTime.now();
  String _query = '';
  bool _loading = true;

  String get _dateStr => dayKeyFmt.format(_date);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bizId = context.read<AppProvider>().businessId;
    final staff = await _db.getStaffList(bizId);
    final records = await _db.getAttendanceForDate(bizId, _dateStr);
    if (!mounted) return;
    setState(() {
      _staff = staff;
      _dayRecords = {for (final a in records) a.staffId: a};
      _loading = false;
    });
  }

  int get _presentCount =>
      _staff.where((s) => _dayRecords[s.id]?.status == 'present').length;

  // Everyone else (absent, half-day or not marked) counts as not fully present;
  // per spec, staff with no record count as absent.
  int get _absentCount => _staff
      .where((s) =>
          _dayRecords[s.id] == null || _dayRecords[s.id]!.status == 'absent')
      .length;

  Future<void> _mark(Staff s, String status) async {
    final existing = _dayRecords[s.id];
    await _db.markAttendance(Attendance(
      staffId: s.id!,
      date: _dateStr,
      status: status,
      overtimeHours: existing?.overtimeHours ?? 0,
    ));
    _load();
  }

  Future<void> _markAllPresent() async {
    for (final s in _staff) {
      await _db.markAttendance(Attendance(
        staffId: s.id!,
        date: _dateStr,
        status: 'present',
        overtimeHours: _dayRecords[s.id]?.overtimeHours ?? 0,
      ));
    }
    _load();
  }

  Future<void> _setOvertime(Staff s) async {
    final existing = _dayRecords[s.id];
    final ctrl = TextEditingController(
        text: existing != null && existing.overtimeHours > 0
            ? formatQty(existing.overtimeHours)
            : '');
    final p = context.read<AppProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${p.t('overtime')} — ${s.name}'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: p.t('hours')),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(p.t('cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(p.t('save'))),
        ],
      ),
    );
    final hoursText = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || !mounted) return;
    final hours = double.tryParse(hoursText) ?? 0;
    await _db.markAttendance(Attendance(
      staffId: s.id!,
      date: _dateStr,
      status: existing?.status ?? 'present',
      overtimeHours: hours,
    ));
    _load();
  }

  Widget _segButton(Staff s, String label, String status, Color color) {
    final active = _dayRecords[s.id]?.status == status;
    return InkWell(
      onTap: () => _mark(s, status),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color : Colors.transparent,
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: active ? Colors.white : color,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final list = _query.isEmpty
        ? _staff
        : _staff
            .where((s) => s.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('staffBook'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final done = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const StaffFormScreen()),
          );
          if (done == true) _load();
        },
        icon: const Icon(Icons.person_add),
        label: Text(p.t('addStaff')),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left,
                      color: AppColors.primary),
                  onPressed: () {
                    setState(() =>
                        _date = _date.subtract(const Duration(days: 1)));
                    _load();
                  },
                ),
                Text(dateFmt.format(_date),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                IconButton(
                  icon: const Icon(Icons.chevron_right,
                      color: AppColors.primary),
                  onPressed: () {
                    setState(() => _date = _date.add(const Duration(days: 1)));
                    _load();
                  },
                ),
              ],
            ),
          ),
          Card(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Text('$_presentCount',
                            style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: AppColors.green)),
                        Text(p.t('totalPresent'),
                            style: const TextStyle(color: AppColors.textGrey)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text('$_absentCount',
                            style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: AppColors.red)),
                        Text(p.t('totalAbsent'),
                            style: const TextStyle(color: AppColors.textGrey)),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _staff.isEmpty ? null : _markAllPresent,
                    child: Text(p.t('markAllPresent')),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: InputDecoration(
                hintText: p.t('search'),
                prefixIcon: const Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
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
                          final s = list[i];
                          final rec = _dayRecords[s.id];
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppColors.primary,
                                child: Text(initials(s.name),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700)),
                              ),
                              title: Text(s.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                  '${p.t('monthlySalary')}: ${formatRs(s.monthlySalary)}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _segButton(s, 'P', 'present', AppColors.green),
                                  const SizedBox(width: 4),
                                  _segButton(s, 'A', 'absent', AppColors.red),
                                  const SizedBox(width: 4),
                                  _segButton(
                                      s, 'H', 'half', AppColors.accent),
                                  IconButton(
                                    icon: Icon(Icons.more_time,
                                        size: 20,
                                        color: (rec?.overtimeHours ?? 0) > 0
                                            ? AppColors.primary
                                            : AppColors.textGrey),
                                    tooltip: p.t('overtime'),
                                    onPressed: () => _setOvertime(s),
                                  ),
                                ],
                              ),
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          StaffDetailScreen(staff: s)),
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
