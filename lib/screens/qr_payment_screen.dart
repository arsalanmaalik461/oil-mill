import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

class _QrData {
  final Business? business;
  final List<QrPayment> payments;
  final Map<int, String> partyNames;
  _QrData(this.business, this.payments, this.partyNames);

  int get pendingCount => payments.where((q) => q.status == 'pending').length;
}

/// QR Payments: the business shows one QR carrying its payment DETAILS
/// (account title + number) so customers can scan, copy the number and pay
/// in their own JazzCash / Easypaisa / bank app.
///
/// HONESTY NOTE: this is NOT a Raast / interbank QR and it does not collect
/// money by itself — it only carries the payment details as plain text.
/// Incoming payments are recorded manually (Receive Payment) as PENDING
/// and only post to the books when the owner confirms them here; the
/// pending list is the in-app "payment notifications" view.
class QrPaymentScreen extends StatefulWidget {
  const QrPaymentScreen({super.key});

  @override
  State<QrPaymentScreen> createState() => _QrPaymentScreenState();
}

class _QrPaymentScreenState extends State<QrPaymentScreen> {
  final _db = DatabaseHelper.instance;
  late Future<_QrData> _future;
  String _accountTitle = '';
  String _accountNumber = '';

  static const _methods = <String, String>{
    'jazzcash': 'JazzCash',
    'easypaisa': 'Easypaisa',
    'bank': 'Bank',
    'cash': 'Cash',
  };

  @override
  void initState() {
    super.initState();
    _future = _load(context.read<AppProvider>().businessId);
    _loadQrDetails();
  }

  Future<void> _loadQrDetails() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _accountTitle = prefs.getString('qr_account_title') ?? '';
      _accountNumber = prefs.getString('qr_account_number') ?? '';
    });
  }

  Future<_QrData> _load(int bizId) async {
    final businesses = await _db.getBusinesses();
    Business? biz;
    for (final b in businesses) {
      if (b.id == bizId) {
        biz = b;
        break;
      }
    }
    biz ??= businesses.isNotEmpty ? businesses.first : null;
    final payments = await _db.getQrPayments(bizId);
    final parties = await _db.getParties(bizId);
    final names = <int, String>{
      for (final party in parties)
        if (party.id != null) party.id!: party.name,
    };
    return _QrData(biz, payments, names);
  }

  void _reload() {
    setState(() {
      _future = _load(context.read<AppProvider>().businessId);
    });
  }

  String _payload(_QrData d) {
    final bizName = d.business?.name ?? 'Namat Oil Mill';
    return 'Payment details\n'
        'Business: $bizName\n'
        'Account Title: $_accountTitle\n'
        'Account Number: $_accountNumber\n'
        'Pay via JazzCash / Easypaisa / Bank transfer to this number.';
  }

  Future<void> _editQrDetails(AppProvider p) async {
    final titleCtrl = TextEditingController(text: _accountTitle);
    final numberCtrl = TextEditingController(text: _accountNumber);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        title: Text(p.t('businessQr')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(labelText: p.t('accountTitle')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: numberCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: p.t('accountNumber')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dc, false),
            child: Text(p.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dc, true),
            child: Text(p.t('save')),
          ),
        ],
      ),
    );
    final newTitle = titleCtrl.text.trim();
    final newNumber = numberCtrl.text.trim();
    titleCtrl.dispose();
    numberCtrl.dispose();
    if (saved != true || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('qr_account_title', newTitle);
    await prefs.setString('qr_account_number', newNumber);
    if (!mounted) return;
    setState(() {
      _accountTitle = newTitle;
      _accountNumber = newNumber;
    });
  }

  Future<void> _receivePayment(AppProvider p, _QrData d) async {
    final parties = await _db.getParties(p.businessId);
    if (!mounted) return;
    final nameCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var method = 'jazzcash';
    int? partyId;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, setSheetState) => AlertDialog(
          title: Text(p.t('receivePayment')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(labelText: p.t('payerName')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: p.t('amount')),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: method,
                  decoration: const InputDecoration(labelText: 'Method'),
                  items: _methods.entries
                      .map((e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ))
                      .toList(),
                  onChanged: (v) =>
                      setSheetState(() => method = v ?? 'jazzcash'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int?>(
                  initialValue: partyId,
                  decoration: InputDecoration(labelText: p.t('customers')),
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text(p.t('none')),
                    ),
                    ...parties
                        .where((party) => party.id != null)
                        .map((party) => DropdownMenuItem<int?>(
                              value: party.id,
                              child: Text(party.name),
                            )),
                  ],
                  onChanged: (v) => setSheetState(() => partyId = v),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: noteCtrl,
                  decoration: InputDecoration(labelText: p.t('note')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dc, false),
              child: Text(p.t('cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dc, true),
              child: Text(p.t('save')),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      final amount = double.tryParse(amountCtrl.text.trim());
      if (amount == null || amount <= 0) {
        nameCtrl.dispose();
        amountCtrl.dispose();
        noteCtrl.dispose();
        if (mounted) showSnack(context, p.t('invalidAmount'));
        return;
      }
      await _db.insertQrPayment(QrPayment(
        businessId: p.businessId,
        partyId: partyId,
        payerName: nameCtrl.text.trim(),
        amount: amount,
        method: method,
        status: 'pending',
        note: noteCtrl.text.trim(),
        dateTime: DateTime.now(),
      ));
      if (!mounted) return;
      _reload();
      context.read<AppProvider>().bump();
    }
    nameCtrl.dispose();
    amountCtrl.dispose();
    noteCtrl.dispose();
  }

  /// Confirm = the money really arrived. Follows the PAID-BILL pattern in
  /// DatabaseHelper.createBill: post a 'wasool' party transaction when a
  /// party is linked (settles that party's ledger balance, which is
  /// computed from party_transactions only) AND a cash 'in' entry (the
  /// cash book, computed from cash_entries only). The two books are read
  /// separately by Reports/Home, so posting both is the bill flow's own
  /// pattern, not a double count. (A manual wasool typed in Party Detail
  /// is ledger-only by design — that is a book adjustment, while a QR
  /// confirmation is actual money received, like a paid bill.)
  Future<void> _confirm(AppProvider p, QrPayment q) async {
    if (q.id == null) return;
    // One transactional, idempotent confirm in the database layer:
    // wasool carries the real method, and only true cash receipts post
    // a drawer entry (JazzCash/Easypaisa/bank no longer inflate cash).
    final done = await _db.confirmQrPayment(q);
    if (!mounted) return;
    if (done) showSnack(context, p.t('paymentConfirmed'));
    _reload();
    context.read<AppProvider>().bump();
  }

  Future<void> _delete(AppProvider p, QrPayment q) async {
    if (q.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        title: Text(p.t('delete')),
        content: Text('${q.payerName} — ${formatRs(q.amount)}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dc, false),
            child: Text(p.t('cancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(dc, true),
            child: Text(p.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _db.deleteQrPayment(q.id!);
    if (!mounted) return;
    _reload();
    context.read<AppProvider>().bump();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(p.t('qrPayments'))),
      body: FutureBuilder<_QrData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data ?? _QrData(null, const [], const {});
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _qrCard(p, d),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _receivePayment(p, d),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(p.t('receivePayment')),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    p.t('history'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  // Pending payments are the in-app notifications: how many
                  // recorded payments still wait for confirmation.
                  if (d.pendingCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${d.pendingCount} ${p.t('pending')}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (d.payments.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text(p.t('noData'))),
                )
              else
                ...d.payments.map((q) => _paymentCard(p, d, q)),
            ],
          );
        },
      ),
    );
  }

  Widget _qrCard(AppProvider p, _QrData d) {
    final hasNumber = _accountNumber.trim().isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  p.t('businessQr'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: p.t('edit'),
                  icon: const Icon(Icons.edit, size: 20),
                  onPressed: () => _editQrDetails(p),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (hasNumber) ...[
              // The QR encodes the payment DETAILS as plain text (see the
              // class comment) — scanning shows/copies the number; payment
              // itself happens in the customer's own banking/wallet app.
              QrImageView(
                data: _payload(d),
                version: QrVersions.auto,
                size: 200,
                backgroundColor: Colors.white,
              ),
              const SizedBox(height: 10),
              Text(
                p.t('scanQrNote'),
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 12.5, color: AppColors.textGrey),
              ),
              const SizedBox(height: 8),
              if (_accountTitle.isNotEmpty)
                Text(
                  _accountTitle,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              Text(
                _accountNumber,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    Text(
                      '${p.t('accountTitle')} / ${p.t('accountNumber')}',
                      style: const TextStyle(color: AppColors.textGrey),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => _editQrDetails(p),
                      icon: const Icon(Icons.edit, size: 18),
                      label: Text(p.t('edit')),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _paymentCard(AppProvider p, _QrData d, QrPayment q) {
    final isPending = q.status == 'pending';
    final displayName = q.partyId != null && d.partyNames[q.partyId] != null
        ? d.partyNames[q.partyId]!
        : q.payerName;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                child: const Icon(Icons.qr_code, color: AppColors.primary),
              ),
              title: Text(
                displayName.isEmpty ? '—' : displayName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${_methods[q.method] ?? q.method} • ${dateFmt.format(q.dateTime)}'
                '${q.note.isNotEmpty ? '\n${q.note}' : ''}',
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatRs(q.amount),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.green,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: (isPending ? AppColors.accent : AppColors.green)
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      isPending ? p.t('pending') : p.t('paid'),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color:
                            isPending ? AppColors.accent : AppColors.green,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
              child: Row(
                children: [
                  if (isPending)
                    ElevatedButton.icon(
                      onPressed: () => _confirm(p, q),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(p.t('confirmPayment')),
                    ),
                  const Spacer(),
                  IconButton(
                    tooltip: p.t('delete'),
                    icon: const Icon(Icons.delete_outline,
                        color: AppColors.red),
                    onPressed: () => _delete(p, q),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
