import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../utils/helpers.dart';

class StaffFormScreen extends StatefulWidget {
  final Staff? staff;
  const StaffFormScreen({super.key, this.staff});

  @override
  State<StaffFormScreen> createState() => _StaffFormScreenState();
}

class _StaffFormScreenState extends State<StaffFormScreen> {
  final _db = DatabaseHelper.instance;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _salaryCtrl;
  bool _saving = false;

  bool get _isEdit => widget.staff != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.staff?.name ?? '');
    _phoneCtrl = TextEditingController(text: widget.staff?.phone ?? '');
    _salaryCtrl = TextEditingController(
        text: widget.staff != null && widget.staff!.monthlySalary > 0
            ? formatSalary(widget.staff!.monthlySalary)
            : '');
  }

  static String formatSalary(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _salaryCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = context.read<AppProvider>();
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final salary = double.tryParse(_salaryCtrl.text.trim()) ?? 0;
    if (_isEdit) {
      await _db.updateStaff(Staff(
        id: widget.staff!.id,
        businessId: widget.staff!.businessId,
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        monthlySalary: salary,
        deleted: widget.staff!.deleted,
      ));
    } else {
      await _db.insertStaff(Staff(
        businessId: p.businessId,
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        monthlySalary: salary,
      ));
    }
    if (!mounted) return;
    showSnack(context, p.t('savedSuccessfully'));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? p.t('edit') : p.t('addStaff'))),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameCtrl,
              decoration: InputDecoration(labelText: p.t('name')),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? p.t('requiredField') : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: p.t('phone')),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _salaryCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: p.t('monthlySalary')),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                return double.tryParse(v.trim()) == null
                    ? p.t('invalidAmount')
                    : null;
              },
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(p.t('save')),
            ),
          ],
        ),
      ),
    );
  }
}
