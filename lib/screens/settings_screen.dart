import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/google_drive_service.dart';
import '../utils/helpers.dart';
import '../utils/pdf_service.dart';
import '../services/firebase_service.dart';
import 'data_export_screen.dart';

String _hashPin(String pin) => sha256.convert(utf8.encode(pin)).toString();

bool _validPin(String pin) =>
    pin.length >= 4 && pin.length <= 6 && RegExp(r'^[0-9]+$').hasMatch(pin);

/// Settings: business profile, business switching, language, PIN /
/// fingerprint security, JSON backup & restore, about.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _db = DatabaseHelper.instance;
  final _nameC = TextEditingController();
  final _ownerC = TextEditingController();
  final _phoneC = TextEditingController();
  final _addressC = TextEditingController();

  List<Business> _businesses = [];
  bool _loading = true;
  bool _filled = false;
  bool _pinSet = false;

  final _drive = GoogleDriveService.instance;
  GoogleSignInAccount? _googleAccount;
  bool _googleBusy = false;
  bool _autoDriveBackup = true;
  String? _backupStatus;
  String? _backupWhen;
  bool _accountBusy = false;
  bool _syncBusy = false;
  bool _restoreBusy = false;
  final _firebase = FirebaseService.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameC.dispose();
    _ownerC.dispose();
    _phoneC.dispose();
    _addressC.dispose();
    super.dispose();
  }

  Business? _current(List<Business> list, int bizId) {
    for (final b in list) {
      if (b.id == bizId) return b;
    }
    return list.isNotEmpty ? list.first : null;
  }

  Future<void> _load() async {
    final list = await _db.getBusinesses();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final bizId = context.read<AppProvider>().businessId;
    setState(() {
      _businesses = list;
      _pinSet = prefs.getString('pin_hash') != null;
      _autoDriveBackup = prefs.getBool('auto_drive_backup_enabled') ?? true;
      _backupStatus = prefs.getString('drive_backup_status');
      _backupWhen = prefs.getString('last_auto_drive_backup_time') ??
          prefs.getString('drive_backup_last_attempt');
      _loading = false;
      final cur = _current(list, bizId);
      if (cur != null && !_filled) {
        _nameC.text = cur.name;
        _ownerC.text = cur.owner;
        _phoneC.text = cur.phone;
        _addressC.text = cur.address;
        _filled = true;
      }
    });
    _refreshGoogle();
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
          ),
        ),
      );

  // ---------------- Business profile ----------------

  Future<void> _saveProfile(AppProvider p) async {
    final cur = _current(_businesses, p.businessId);
    if (cur?.id == null) return;
    if (_nameC.text.trim().isEmpty) {
      showSnack(context, p.t('requiredField'));
      return;
    }
    await _db.updateBusiness(
      Business(
        id: cur!.id,
        name: _nameC.text.trim(),
        owner: _ownerC.text.trim(),
        phone: _phoneC.text.trim(),
        address: _addressC.text.trim(),
      ),
    );
    if (!mounted) return;
    p.bump();
    showSnack(context, p.t('savedSuccessfully'));
    await _load();
  }

  Future<void> _addBusiness(AppProvider p) async {
    final nameC = TextEditingController();
    final ownerC = TextEditingController();
    final phoneC = TextEditingController();
    final addressC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(p.t('addBusiness')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameC, decoration: InputDecoration(labelText: p.t('businessName'))),
              const SizedBox(height: 8),
              TextField(controller: ownerC, decoration: InputDecoration(labelText: p.t('ownerName'))),
              const SizedBox(height: 8),
              TextField(controller: phoneC, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: p.t('phone'))),
              const SizedBox(height: 8),
              TextField(controller: addressC, decoration: InputDecoration(labelText: p.t('address'))),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(p.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(p.t('save'))),
        ],
      ),
    );
    final name = nameC.text.trim();
    final owner = ownerC.text.trim();
    final phone = phoneC.text.trim();
    final address = addressC.text.trim();
    nameC.dispose();
    ownerC.dispose();
    phoneC.dispose();
    addressC.dispose();
    if (ok != true) return;
    if (name.isEmpty) {
      if (mounted) showSnack(context, p.t('requiredField'));
      return;
    }
    final id = await _db.insertBusiness(
      Business(
          name: name,
          owner: owner,
          phone: phone,
          address: address,
          appUsername: p.sessionUsername),
    );
    if (!mounted) return;
    await p.setBusiness(id);
    if (!mounted) return;
    _filled = false;
    await _load();
  }

  // ---------------- PIN security ----------------

  Widget _pinField(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: InputDecoration(labelText: label, counterText: ''),
      ),
    );
  }

  /// Shows a PIN dialog; [fields] is a list of (key, label). Returns the
  /// entered values by key, or null when cancelled.
  Future<Map<String, String>?> _pinDialog(
    String title,
    List<(String, String)> fields,
  ) async {
    final controllers = {for (final f in fields) f.$1: TextEditingController()};
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in fields)
                _pinField(controllers[f.$1]!, f.$2),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(context.read<AppProvider>().t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, {
              for (final e in controllers.entries) e.key: e.value.text.trim(),
            }),
            child: Text(context.read<AppProvider>().t('save')),
          ),
        ],
      ),
    );
    for (final c in controllers.values) {
      c.dispose();
    }
    return result;
  }

  Future<void> _setPin(AppProvider p) async {
    final values = await _pinDialog(p.t('setPin'), [
      ('pin', p.t('enterPin')),
      ('confirm', p.t('confirmPin')),
    ]);
    if (values == null || !mounted) return;
    final pin = values['pin'] ?? '';
    if (!_validPin(pin) || pin != values['confirm']) {
      showSnack(context, p.t('pinMismatch'));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pin_hash', _hashPin(pin));
    if (!mounted) return;
    p.refreshLockState(true);
    setState(() => _pinSet = true);
    showSnack(context, p.t('savedSuccessfully'));
  }

  Future<void> _changePin(AppProvider p) async {
    final values = await _pinDialog(p.t('changePin'), [
      ('old', p.t('oldPin')),
      ('pin', p.t('enterPin')),
      ('confirm', p.t('confirmPin')),
    ]);
    if (values == null || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('pin_hash') != _hashPin(values['old'] ?? '')) {
      showSnack(context, p.t('wrongPin'));
      return;
    }
    final pin = values['pin'] ?? '';
    if (!_validPin(pin) || pin != values['confirm']) {
      showSnack(context, p.t('pinMismatch'));
      return;
    }
    await prefs.setString('pin_hash', _hashPin(pin));
    if (!mounted) return;
    showSnack(context, p.t('savedSuccessfully'));
  }

  Future<void> _removePin(AppProvider p) async {
    final values = await _pinDialog(p.t('removePin'), [
      ('old', p.t('enterPin')),
    ]);
    if (values == null || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('pin_hash') != _hashPin(values['old'] ?? '')) {
      showSnack(context, p.t('wrongPin'));
      return;
    }
    await prefs.remove('pin_hash');
    if (!mounted) return;
    await p.setFingerprintEnabled(false);
    if (!mounted) return;
    p.refreshLockState(false);
    setState(() => _pinSet = false);
    showSnack(context, p.t('savedSuccessfully'));
  }

  // ---------------- Backup ----------------

  Future<void> _exportBackup() async {
    final json = await _db.exportJson();
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/namat_backup.json');
    await file.writeAsString(json);
    await shareFilePath(file.path);
  }

  /// After an import, push the data to the signed-in user's cloud area
  /// in the background, so the Firebase backup is complete without the
  /// user having to press the sync button.
  void _autoSyncAfterImport(AppProvider p) {
    if (!p.isLoggedIn) return;
    unawaited(() async {
      try {
        await FirebaseService.instance
            .syncUserData(p.sessionUsername, p.businessId);
      } catch (_) {}
    }());
  }

  Future<void> _importBackup(AppProvider p) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(p.t('importWarning')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(p.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(p.t('importBackup')),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    // Picking itself can throw (permissions, content:// providers on
    // some Android skins) — it must never crash the screen. withData
    // loads the bytes in memory, so WhatsApp / Downloads / Drive
    // files work even when no plain file path comes back.
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
    } catch (_) {
      if (mounted) showSnack(context, p.t('importFailed'));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    try {
      final picked = result.files.single;
      final String content;
      if (picked.bytes != null) {
        content = utf8.decode(picked.bytes!);
      } else if (picked.path != null) {
        content = await File(picked.path!).readAsString();
      } else {
        throw FormatException(p.t('couldNotReadFile'));
      }
      await _db.importJson(content);
      // The restore replaced the businesses table, so the currently
      // open business id may no longer exist — reopen the restored
      // business (this account's own when the file carries it).
      final allBiz = await _db.getBusinesses();
      if (allBiz.isNotEmpty) {
        final mine = allBiz
            .where((b) => b.appUsername == p.sessionUsername)
            .toList();
        await p.setBusiness(
            (mine.isNotEmpty ? mine.first : allBiz.first).id!);
      }
      if (!mounted) return;
      p.bump();
      showSnack(context, p.t('restored'));
      _autoSyncAfterImport(p);
      _filled = false;
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, '${p.t('importFailed')}: $e');
    }
  }

  /// Imports a backup/statement JSON file into the CURRENTLY OPEN
  /// account only (unlike full restore, which replaces every account).
  /// The current account's existing data is replaced by the file's data;
  /// other accounts on this phone are untouched.
  Future<void> _importIntoAccount(AppProvider p) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(p.t('importIntoAccountConfirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(p.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(p.t('importIntoAccount')),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    // Picking itself can throw (permissions, content:// providers on
    // some Android skins) — it must never crash the screen. withData
    // loads the bytes in memory, so WhatsApp / Downloads / Drive
    // files work even when no plain file path comes back.
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
    } catch (_) {
      if (mounted) showSnack(context, p.t('importFailed'));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    try {
      final picked = result.files.single;
      final String content;
      if (picked.bytes != null) {
        content = utf8.decode(picked.bytes!);
      } else if (picked.path != null) {
        content = await File(picked.path!).readAsString();
      } else {
        throw FormatException(p.t('couldNotReadFile'));
      }
      final data = jsonDecode(content) as Map<String, dynamic>;
      if (data['app'] != 'namat_oil_mill') {
        throw FormatException(p.t('importFailed'));
      }
      await _db.importBusinessData(p.businessId, data);
      if (!mounted) return;
      p.bump();
      showSnack(context, p.t('importedToAccount'));
      _autoSyncAfterImport(p);
      _filled = false;
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, '${p.t('importFailed')}: $e');
    }
  }

  // ---------------- Google Drive ----------------

  /// Restores an existing Google session (silently) so the section can
  /// show the connected state. Never throws — without the one-time
  /// setup (see README) there is simply no session to restore.
  Future<void> _refreshGoogle() async {
    try {
      if (await _drive.isSignedIn()) {
        await _drive.googleSignIn.signInSilently();
      }
    } catch (_) {
      // No session / setup missing: stay in the "not connected" state.
    }
    if (!mounted) return;
    setState(() => _googleAccount = _drive.currentAccount);
  }

  /// Builds the full-ledger PDF for [business] and uploads it to the
  /// "Namat Oil Mill" Drive folder. Throws on failure.
  Future<void> _doUploadLedger(Business business) async {
    final parties = await _db.getParties(business.id!);
    final balances = <int, double>{};
    final transactionsByParty = <int, List<PartyTransaction>>{};
    for (final party in parties) {
      if (party.id == null) continue;
      balances[party.id!] = await _db.getPartyBalance(party.id!);
      transactionsByParty[party.id!] =
          await _db.getPartyTransactions(party.id!);
    }
    final bytes = await buildFullLedgerPdfBytes(
      business: business,
      parties: parties,
      balances: balances,
      transactionsByParty: transactionsByParty,
    );
    final fileName =
        'Ledger-${business.name}-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.pdf';
    await _drive.uploadPdf(bytes, fileName);
  }

  /// Connect button: sign in, then automatically build + upload the
  /// full ledger PDF for the current business.
  Future<void> _connectGoogle(AppProvider p) async {
    final cur = _current(_businesses, p.businessId);
    if (cur?.id == null || _googleBusy) return;
    setState(() => _googleBusy = true);
    try {
      final account = await _drive.signIn();
      if (!mounted) return;
      if (account == null) {
        showSnack(
            context, '${p.t('googleSignInFailed')} — ${p.t('googleSetupNote')}');
        return;
      }
      setState(() => _googleAccount = account);
      try {
        await _doUploadLedger(cur!);
        if (!mounted) return;
        showSnack(context, p.t('driveUploadDone'));
      } catch (_) {
        if (!mounted) return;
        showSnack(context, p.t('driveUploadFailed'));
      }
    } catch (_) {
      if (!mounted) return;
      showSnack(
          context, '${p.t('googleSignInFailed')} — ${p.t('googleSetupNote')}');
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  /// Upload button (already connected): rebuild + upload the PDF.
  Future<void> _uploadToDrive(AppProvider p) async {
    final cur = _current(_businesses, p.businessId);
    if (cur?.id == null || _googleBusy) return;
    setState(() => _googleBusy = true);
    try {
      await _doUploadLedger(cur!);
      if (!mounted) return;
      showSnack(context, p.t('driveUploadDone'));
    } catch (_) {
      if (!mounted) return;
      showSnack(context, p.t('driveUploadFailed'));
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  Future<void> _disconnectGoogle() async {
    try {
      await _drive.signOut();
    } catch (_) {
      // Even if sign-out errors, drop the local connected state.
    }
    if (!mounted) return;
    setState(() => _googleAccount = null);
  }

  /// Restore test: verifies the newest Drive backup is complete and
  /// readable, without changing any live data.
  Future<void> _verifyDriveBackup(AppProvider p) async {
    setState(() => _googleBusy = true);
    try {
      final r = await _drive.verifyLatestBackup();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(p.t('testRestore')),
          content: Text('${p.t('restoreTestOk')}\n\n'
              '${r['file']}\n'
              '${r['tables']} tables - ${r['rows']} entries - ${r['sizeKb']} KB'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('OK')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        showSnack(
            context,
            e.toString().contains('no-backup')
                ? p.t('noDriveBackup')
                : p.t('restoreTestFailed'));
      }
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  /// One-tap fix for imported parties whose numbers never came with
  /// the statements: match parties with an empty phone against the
  /// phone's contacts BY NAME and fill the numbers in (with a
  /// confirmation first). Existing numbers are never overwritten,
  /// and a name with two different numbers in contacts is skipped.
  Future<void> _fillPhonesFromContacts(AppProvider p) async {
    try {
      final granted =
          await FlutterContacts.requestPermission(readonly: true);
      if (!granted) {
        if (mounted) showSnack(context, p.t('contactsPermissionDenied'));
        return;
      }
      final contacts =
          await FlutterContacts.getContacts(withProperties: true);
      final byKey = <String, String>{};
      final ambiguous = <String>{};
      for (final c in contacts) {
        final key = DatabaseHelper.contactNameKey(c.displayName);
        if (key.isEmpty) continue;
        for (final ph in c.phones) {
          final num = ph.number.replaceAll(RegExp(r'[\s-]'), '');
          if (num.isEmpty) continue;
          final prev = byKey[key];
          if (prev == null) {
            byKey[key] = num;
          } else if (prev != num) {
            ambiguous.add(key);
          }
        }
      }
      byKey.removeWhere((k, _) => ambiguous.contains(k));
      final missing = await _db.getPartiesMissingPhone(p.businessId);
      final matchable = missing
          .where((x) =>
              byKey.containsKey(DatabaseHelper.contactNameKey(x.name)))
          .toList();
      if (!mounted) return;
      if (matchable.isEmpty) {
        showSnack(context, p.t('noContactMatches'));
        return;
      }
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(p.t('fillPhonesFromContacts')),
          content: Text('${p.t('fillPhonesFound')}: ${matchable.length}\n\n'
              '${matchable.take(5).map((x) => x.name).join('\n')}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text(p.t('cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(p.t('fillNumbers'))),
          ],
        ),
      );
      if (go != true) return;
      final filled =
          await _db.fillPartyPhonesFromContacts(p.businessId, byKey);
      if (!mounted) return;
      p.bump();
      showSnack(context, '${p.t('contactsFilled')}: $filled');
    } catch (e) {
      if (mounted) showSnack(context, '${p.t('importFailed')}: $e');
    }
  }

  Future<void> _uploadBackupJsonToDrive(AppProvider p) async {
    if (_googleBusy) return;
    setState(() => _googleBusy = true);
    try {
      final json = await _db.exportJson();
      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final fileName = 'namat_backup_$todayStr.json';
      await _drive.uploadJson(json, fileName);
      if (!mounted) return;
      showSnack(context, p.t('driveBackupDone'));
    } catch (e) {
      if (!mounted) return;
      showSnack(context, '${p.t('driveUploadFailed')}: $e');
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  // ---------------- Account (per-user Firebase) ----------------

  /// Per-user cloud sync: uploads this user's business data to their
  /// own Firebase area (users/{username}/businesses/{id}).
  Future<void> _syncMyData(AppProvider p) async {
    if (_accountBusy) return;
    setState(() {
      _accountBusy = true;
      _syncBusy = true;
    });
    try {
      if (!_firebase.isConfigured) {
        showSnack(context, p.t('firebaseNotSetup'));
        return;
      }
      final count = await _firebase
          .syncUserData(p.sessionUsername, p.businessId)
          .timeout(const Duration(seconds: 45));
      if (!mounted) return;
      showSnack(context, '${p.t('syncDone')} ($count)');
    } on TimeoutException {
      if (!mounted) return;
      showSnack(context,
          'Taking too long. Check your internet and try again.');
    } on StateError catch (e) {
      if (!mounted) return;
      showSnack(
        context,
        e.message == 'firebase-not-configured'
            ? p.t('firebaseNotSetup')
            : 'Error: $e',
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'Error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _accountBusy = false;
          _syncBusy = false;
        });
      }
    }
  }

  /// Per-user cloud restore: downloads this user's cloud backup into
  /// the local database (asks for confirmation first).
  Future<void> _restoreMyData(AppProvider p) async {
    if (_accountBusy) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(p.t('restoreConfirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(p.t('cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Continue')),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() {
      _accountBusy = true;
      _restoreBusy = true;
    });
    try {
      if (!_firebase.isConfigured) {
        showSnack(context, p.t('firebaseNotSetup'));
        return;
      }
      final count = await _firebase
          .restoreUserData(p.sessionUsername, p.businessId)
          .timeout(const Duration(seconds: 45));
      if (!mounted) return;
      if (count == 0) {
        showSnack(
          context,
          p.isUrdu
              ? 'کلاؤڈ میں کوئی بیک اپ نہیں ملا۔'
              : 'No backup found in the cloud.',
        );
      } else {
        showSnack(context, '${p.t('restoreDone')} ($count)');
        p.bump();
      }
    } on TimeoutException {
      if (!mounted) return;
      showSnack(context,
          'Taking too long. Check your internet and try again.');
    } on StateError catch (e) {
      if (!mounted) return;
      showSnack(
        context,
        e.message == 'firebase-not-configured'
            ? p.t('firebaseNotSetup')
            : 'Error: $e',
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'Error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _accountBusy = false;
          _restoreBusy = false;
        });
      }
    }
  }

  /// Change-password dialog for the signed-in app user. The old
  /// password is verified against the Firebase app_users record.
  Future<void> _changeAccountPassword(AppProvider p) async {
    if (!_firebase.isConfigured) {
      showSnack(context, p.t('firebaseNotReady'));
      return;
    }
    final oldC = TextEditingController();
    final newC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(p.t('changePassword')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldC,
              obscureText: true,
              decoration: InputDecoration(labelText: p.t('oldPassword')),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: newC,
              obscureText: true,
              decoration: InputDecoration(labelText: p.t('newPassword')),
            ),
          ],
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
    final oldPw = oldC.text;
    final newPw = newC.text;
    oldC.dispose();
    newC.dispose();
    if (ok != true || !mounted) return;
    if (newPw.length < 6) {
      showSnack(context, p.t('passwordTooShort'));
      return;
    }
    setState(() => _accountBusy = true);
    try {
      await _firebase.changeOwnPassword(p.sessionUsername, oldPw, newPw);
      if (!mounted) return;
      showSnack(context, p.t('passwordChanged'));
    } on StateError catch (e) {
      if (!mounted) return;
      showSnack(
        context,
        e.message == 'wrong' ? p.t('wrongCredentials') : 'Firebase Error: $e',
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'Firebase Error: $e');
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  /// Signs out of Firebase (if any session) and clears the app-user
  /// session. RootGate watches the provider and returns to the login
  /// screen on its own — no manual navigation here.
  Future<void> _logoutSession(AppProvider p) async {
    try {
      await _firebase.signOut();
    } catch (_) {
      // Even if Firebase sign-out errors, clear the local session.
    }
    await p.signOutSession();
  }

  /// Fingerprint unlock can be enabled on its own (no PIN required):
  /// the phone must support biometrics and have a fingerprint enrolled;
  /// the user confirms with a live fingerprint scan before it turns ON.
  Future<void> _onFingerprintToggle(AppProvider p, bool v) async {
    if (!v) {
      await p.setFingerprintEnabled(false);
      return;
    }
    final auth = LocalAuthentication();
    var supported = false;
    try {
      supported =
          await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } catch (_) {}
    if (!supported) {
      if (mounted) {
        showSnack(context, 'This phone does not support fingerprint unlock.');
      }
      return;
    }
    List<BiometricType> enrolled = const [];
    try {
      enrolled = await auth.getAvailableBiometrics();
    } catch (_) {}
    if (enrolled.isEmpty) {
      if (mounted) {
        showSnack(context,
            'No fingerprint is set on this phone. Add one in phone Settings first.');
      }
      return;
    }
    try {
      final ok = await auth.authenticate(
        localizedReason: 'Confirm your fingerprint to turn ON fingerprint unlock',
        options: const AuthenticationOptions(biometricOnly: true),
      );
      if (ok) {
        await p.setFingerprintEnabled(true);
        if (mounted) showSnack(context, 'Fingerprint unlock is ON.');
      }
    } catch (_) {
      if (mounted) showSnack(context, 'Fingerprint check failed. Try again.');
    }
  }

  // ---------------- Build ----------------

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(p.t('settings'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final cur = _current(_businesses, p.businessId);
    return Scaffold(
      appBar: AppBar(title: Text(p.t('settings'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
        children: [
          _sectionTitle(p.t('profile')),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(controller: _nameC, decoration: InputDecoration(labelText: p.t('businessName'))),
                  const SizedBox(height: 10),
                  TextField(controller: _ownerC, decoration: InputDecoration(labelText: p.t('ownerName'))),
                  const SizedBox(height: 10),
                  TextField(controller: _phoneC, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: p.t('phone'))),
                  const SizedBox(height: 10),
                  TextField(controller: _addressC, decoration: InputDecoration(labelText: p.t('address'))),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: cur == null ? null : () => _saveProfile(p),
                    child: Text(p.t('save')),
                  ),
                ],
              ),
            ),
          ),
          if (p.sessionUsername.isNotEmpty) ...[
            _sectionTitle(p.t('accountSection')),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading:
                        const Icon(Icons.person, color: AppColors.primary),
                    title: Text('${p.t('loggedInAs')}: ${p.sessionUsername}'),
                    subtitle: cur != null ? Text(cur.name) : null,
                  ),
                  ListTile(
                    leading: const Icon(Icons.key, color: AppColors.primary),
                    title: Text(p.t('changePassword')),
                    onTap:
                        _accountBusy ? null : () => _changeAccountPassword(p),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cloud_upload,
                        color: AppColors.primary),
                    title: Text(p.t('syncMyData')),
                    trailing: _syncBusy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _accountBusy ? null : () => _syncMyData(p),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cloud_download,
                        color: AppColors.primary),
                    title: Text(p.t('restoreMyData')),
                    trailing: _restoreBusy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _accountBusy ? null : () => _restoreMyData(p),
                  ),
                  ListTile(
                    leading: const Icon(Icons.logout, color: Colors.red),
                    title: Text(
                      p.t('logoutBtn'),
                      style: const TextStyle(color: Colors.red),
                    ),
                    onTap: () => _logoutSession(p),
                  ),
                ],
              ),
            ),
          ],
          _sectionTitle(p.t('switchBusiness')),
          Card(
            child: Column(
              children: [
                for (final b in _businesses)
                  if (b.id != null &&
                      (p.sessionUsername.isEmpty ||
                          b.appUsername == p.sessionUsername))
                    RadioListTile<int>(
                      value: b.id!,
                      groupValue: p.businessId,
                      title: Text(b.name),
                      subtitle: Text(
                        [b.owner, b.phone].where((s) => s.isNotEmpty).join(' • '),
                      ),
                      onChanged: (v) async {
                        if (v == null) return;
                        await p.setBusiness(v);
                        if (!mounted) return;
                        _filled = false;
                        await _load();
                      },
                    ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _addBusiness(p),
                      icon: const Icon(Icons.add_business),
                      label: Text(p.t('addBusiness')),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _sectionTitle(p.t('language')),
          Card(
            child: Column(
              children: [
                RadioListTile<String>(
                  value: 'en',
                  groupValue: p.lang,
                  title: Text(p.t('english')),
                  onChanged: (v) => v == null ? null : p.setLang(v),
                ),
                RadioListTile<String>(
                  value: 'ur',
                  groupValue: p.lang,
                  title: const Text('اردو'),
                  onChanged: (v) => v == null ? null : p.setLang(v),
                ),
              ],
            ),
          ),
          _sectionTitle(p.t('security')),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.lock, color: AppColors.primary),
                  title: Text(p.t('pinLock')),
                  subtitle: Text(_pinSet ? '••••••' : p.t('setPin')),
                  trailing: _pinSet
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () => _changePin(p),
                              child: Text(p.t('changePin')),
                            ),
                            TextButton(
                              onPressed: () => _removePin(p),
                              child: Text(p.t('removePin')),
                            ),
                          ],
                        )
                      : ElevatedButton(
                          onPressed: () => _setPin(p),
                          child: Text(p.t('setPin')),
                        ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.fingerprint, color: AppColors.primary),
                  title: Text(p.t('fingerprint')),
                  value: p.fingerprintEnabled,
                  onChanged: (v) => _onFingerprintToggle(p, v),
                ),
              ],
            ),
          ),
          _sectionTitle(p.t('backup')),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.upload_file, color: AppColors.primary),
                  title: Text(p.t('exportBackup')),
                  onTap: _exportBackup,
                ),
                ListTile(
                  leading: const Icon(Icons.table_chart_outlined,
                      color: AppColors.primary),
                  title: Text(p.t('dataExport')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const DataExportScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.download, color: AppColors.primary),
                  title: Text(p.t('importBackup')),
                  onTap: () => _importBackup(p),
                ),
                ListTile(
                  leading: const Icon(Icons.move_to_inbox, color: AppColors.primary),
                  title: Text(p.t('importIntoAccount')),
                  onTap: () => _importIntoAccount(p),
                ),
              ],
            ),
          ),
          _sectionTitle(p.t('googleDrive')),
          Card(
            child: Column(
              children: [
                if (_googleAccount == null)
                  ListTile(
                    leading: const Icon(Icons.cloud, color: AppColors.primary),
                    title: Text(p.t('connectGoogle')),
                    subtitle: Text(p.t('googleSetupNote')),
                    trailing: _googleBusy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login, color: AppColors.primary),
                    onTap: _googleBusy ? null : () => _connectGoogle(p),
                  )
                else ...[
                  ListTile(
                    leading:
                        const Icon(Icons.cloud_done, color: AppColors.primary),
                    title: Text(p.t('googleConnected')),
                    subtitle: Text(_googleAccount!.email),
                  ),
                  ListTile(
                    leading:
                        const Icon(Icons.upload_file, color: AppColors.primary),
                    title: Text(p.t('uploadToDrive')),
                    subtitle: _googleBusy ? Text(p.t('uploading')) : null,
                    trailing: _googleBusy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _googleBusy ? null : () => _uploadToDrive(p),
                  ),
                  ListTile(
                    leading:
                        const Icon(Icons.backup, color: AppColors.primary),
                    title: Text(p.t('uploadBackupToDrive')),
                    trailing: _googleBusy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _googleBusy ? null : () => _uploadBackupJsonToDrive(p),
                  ),
                  ListTile(
                    leading: const Icon(Icons.contact_phone_outlined,
                        color: AppColors.primary),
                    title: Text(p.t('fillPhonesFromContacts')),
                    subtitle: Text(p.t('fillPhonesFromContactsSub')),
                    onTap: () => _fillPhonesFromContacts(p),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.alarm, color: AppColors.primary),
                    title: Text(p.t('autoDriveBackup')),
                    subtitle: Text(p.t('autoDriveBackupSub')),
                    value: _autoDriveBackup,
                    onChanged: (v) async {
                      setState(() => _autoDriveBackup = v);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('auto_drive_backup_enabled', v);
                    },
                  ),
                  ListTile(
                    leading: Icon(
                        _backupStatus == 'failed'
                            ? Icons.cloud_off
                            : Icons.cloud_done,
                        color: _backupStatus == 'failed'
                            ? AppColors.red
                            : AppColors.primary),
                    title: Text(p.t('lastBackup')),
                    subtitle: Text(_backupStatus == null
                        ? p.t('backupNever')
                        : '${_backupStatus == 'failed' ? p.t('backupStatusFailed') : p.t('backupStatusOk')}'
                            '${_backupWhen != null ? ' - ${DateFormat('dd MMM, hh:mm a').format(DateTime.parse(_backupWhen!))}' : ''}'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.fact_check,
                        color: AppColors.primary),
                    title: Text(p.t('testRestore')),
                    trailing: _googleBusy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _googleBusy ? null : () => _verifyDriveBackup(p),
                  ),
                  ListTile(
                    leading: const Icon(Icons.logout, color: AppColors.primary),
                    title: Text(p.t('disconnect')),
                    onTap: _googleBusy ? null : _disconnectGoogle,
                  ),
                ],
              ],
            ),
          ),
          _sectionTitle(p.t('firebaseSync')),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    _firebase.isConfigured ? Icons.cloud_done : Icons.cloud_queue,
                    color: _firebase.isConfigured ? Colors.green : Colors.grey,
                  ),
                  title: Text(p.t('firebaseSync')),
                  subtitle: Text(_firebase.isConfigured
                      ? (_firebase.currentUser != null
                          ? 'Logged in as: ${_firebase.currentUser!.email}'
                          : 'Firebase Active')
                      : p.t('firebaseNotSetup')),
                ),
              ],
            ),
          ),
          _sectionTitle(p.t('about')),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.t('appName'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text('${p.t('version')}: 1.0.0'),
                  const SizedBox(height: 10),
                  Text(p.t('permissionsNote'), style: const TextStyle(color: AppColors.textGrey, height: 1.4)),
                  const SizedBox(height: 8),
                  Text(p.t('cloudNote'), style: const TextStyle(color: AppColors.textGrey, height: 1.4)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
