import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_strings.dart';

/// Global app state: language, active business, lock settings.
class AppProvider extends ChangeNotifier {
  String _lang = 'en';
  int _businessId = 1;
  bool _pinEnabled = false;
  bool _fingerprintEnabled = false;
  int _tick = 0; // bump to force data screens to reload

  String get lang => _lang;
  bool get isUrdu => _lang == 'ur';
  int get businessId => _businessId;
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
    _fingerprintEnabled = prefs.getBool('fingerprint_enabled') ?? false;
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

  void refreshLockState(bool pinOn) {
    _pinEnabled = pinOn;
    notifyListeners();
  }

  void bump() {
    _tick++;
    notifyListeners();
  }
}
