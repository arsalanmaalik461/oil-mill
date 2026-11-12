import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_strings.dart';
import '../services/firebase_service.dart';
import '../utils/google_drive_service.dart';

/// Global app state: language, active business, lock settings.
class AppProvider extends ChangeNotifier {
  String _lang = 'en';
  int _businessId = 1;
  String _sessionUsername = '';
  bool _pinEnabled = false;
  bool _fingerprintEnabled = false;
  int _tick = 0; // bump to force data screens to reload
  bool _loaded = false;

  String get lang => _lang;
  bool get isUrdu => _lang == 'ur';
  int get businessId => _businessId;
  String get sessionUsername => _sessionUsername;
  bool get isLoggedIn => _sessionUsername.isNotEmpty;
  bool get loaded => _loaded;
  bool _biometricAuthed = false;
  bool get biometricAuthed => _biometricAuthed;
  bool get pinEnabled => _pinEnabled;
  bool get fingerprintEnabled => _fingerprintEnabled;
  int get tick => _tick;
  TextDirection get direction => isUrdu ? TextDirection.rtl : TextDirection.ltr;

  String t(String key) => AppStrings.get(_lang, key);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _lang = prefs.getString('lang') ?? 'en';
    _businessId = prefs.getInt('business_id') ?? 1;
    _pinEnabled = prefs.getString('pin_hash') != null;
    _sessionUsername = prefs.getString('session_username') ?? '';
    _fingerprintEnabled = prefs.getBool('fingerprint_enabled') ?? false;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setLang(String lang) async {
    _lang = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lang', lang);
    notifyListeners();
  }

  Future<void> setBusiness(int id) async {
    _businessId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('business_id', id);
    notifyListeners();
  }

  Future<void> setFingerprintEnabled(bool v) async {
    _fingerprintEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('fingerprint_enabled', v);
    notifyListeners();
  }

  /// Records the logged-in app user (Firebase app_users username) and the
  /// local business that user's data belongs to.
  Future<void> signInSession(String username, int businessId) async {
    _sessionUsername = username;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session_username', username);
    await setBusiness(businessId);
    notifyListeners();
  }

  void setBiometricAuthed(bool v) {
    _biometricAuthed = v;
    notifyListeners();
  }

  Future<void> signOutSession() async {
    _cloudTimer?.cancel();
    _driveTimer?.cancel();
    _biometricAuthed = false;
    _sessionUsername = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_username');
    notifyListeners();
  }

  void refreshLockState(bool pinOn) {
    _pinEnabled = pinOn;
    notifyListeners();
  }

  void bump() {
    _tick++;
    notifyListeners();
    _scheduleAutoSync();
  }

  // ---- Immediate cloud sync (owner's rule: as soon as an entry is
  // saved, it must reach Firebase AND Google Drive on its own, so any
  // other phone shows it right away and a broken phone loses nothing).
  // bump() is the funnel every data-changing screen already calls, so
  // the syncs are scheduled here, debounced: a burst of entries
  // coalesces into one upload a few seconds after the last change.
  Timer? _cloudTimer;
  Timer? _driveTimer;
  bool _cloudSyncRunning = false;
  bool _driveSyncRunning = false;

  void _scheduleAutoSync() {
    if (_sessionUsername.isEmpty) return;
    _cloudTimer?.cancel();
    _cloudTimer = Timer(const Duration(seconds: 10), _runCloudSync);
    _driveTimer?.cancel();
    _driveTimer = Timer(const Duration(seconds: 45), _runDriveSync);
  }

  Future<void> _runCloudSync() async {
    if (_cloudSyncRunning || _sessionUsername.isEmpty) return;
    if (!FirebaseService.instance.isConfigured) return;
    _cloudSyncRunning = true;
    try {
      await FirebaseService.instance
          .syncUserData(_sessionUsername, _businessId);
    } catch (_) {
      // Offline or cloud hiccup: the app-open and login syncs catch up.
    } finally {
      _cloudSyncRunning = false;
    }
  }

  Future<void> _runDriveSync() async {
    if (_driveSyncRunning || _sessionUsername.isEmpty) return;
    _driveSyncRunning = true;
    try {
      await GoogleDriveService.instance.uploadCurrentBackupNow();
    } catch (_) {
      // Not connected to Drive yet: the daily backup remains the net.
    } finally {
      _driveSyncRunning = false;
    }
  }
}
