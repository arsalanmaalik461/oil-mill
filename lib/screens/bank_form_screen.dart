import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../utils/helpers.dart';

class BankFormScreen extends StatefulWidget {
  final BankAccount? account;
  const BankFormScreen({super.key, this.account});

  @override
  State<BankFormScreen> createState() => _BankFormScreenState();
}

class _BankFormScreenState extends State<BankFormScreen> {
  final _db = DatabaseHelper.instance;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _bankCtrl;
  late final TextEditingController _titleCtrl;
  late final TextEditingController _noCtrl;
  late final TextEditingController _openingCtrl;
  bool _saving = false;

  bool get _isEdit => widget.account != null;

  @override
  void initState() {
    super.initState();
    _bankCtrl = TextEditingController(text: widget.account?.bankName ?? '');
    _titleCtrl =
        TextEditingController(text: widget.account?.accountTitle ?? '');
    _noCtrl = TextEditingController(text: widget.account?.accountNo ?? '');
    _openingCtrl = TextEditingController(
        text: widget.account != null && widget.account!.openingBalance != 0
            ? _fmtNum(widget.account!.openingBalance)
            : '');
  }

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _bankCtrl.dispose();
    _titleCtrl.dispose();
    _noCtrl.dispose();
    _openingCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = context.read<AppProvider>();
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final opening = double.tryParse(_openingCtrl.text.trim()) ?? 0;
    if (_isEdit) {
      await _db.updateBankAccount(BankAccount(
        id: widget.account!.id,
        businessId: widget.account!.businessId,
        bankName: _bankCtrl.text.trim(),
        accountTitle: _titleCtrl.text.trim(),
        accountNo: _noCtrl.text.trim(),
        openingBalance: opening,
        deleted: widget.account!.deleted,
      ));
    } else {
      await _db.insertBankAccount(BankAccount(
        businessId: p.businessId,
        bankName: _bankCtrl.text.trim(),
        accountTitle: _titleCtrl.text.trim(),
        accountNo: _noCtrl.text.trim(),
        openingBalance: opening,
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
      appBar: AppBar(title: Text(_isEdit ? p.t('edit') : p.t('addBank'))),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _bankCtrl,
              decoration: InputDecoration(labelText: p.t('bankName')),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? p.t('requiredField') : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _titleCtrl,
              decoration: InputDecoration(labelText: p.t('accountTitle')),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _noCtrl,
              decoration: InputDecoration(labelText: p.t('accountNo')),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _openingCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: p.t('openingBalance')),
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
