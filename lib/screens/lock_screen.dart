import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';

/// App lock: numeric PIN pad with optional fingerprint unlock.
/// When no PIN is stored it unlocks immediately (post-frame).
class LockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const LockScreen({super.key, required this.onUnlocked});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String? _pinHash;
  bool _fingerprintOn = false;
  bool _ready = false;
  String _entered = '';
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final hash = prefs.getString('pin_hash');
    final fp = prefs.getBool('fingerprint_enabled') ?? false;
    if (!mounted) return;
    if (hash == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onUnlocked();
      });
      return;
    }
    setState(() {
      _pinHash = hash;
      _fingerprintOn = fp;
      _ready = true;
    });
    if (fp) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    try {
      final p = context.read<AppProvider>();
      final auth = LocalAuthentication();
      final ok = await auth.authenticate(
        localizedReason: '${p.t('unlock')} ${p.t('appName')}',
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
      if (ok && mounted) widget.onUnlocked();
    } catch (_) {
      // Biometrics unavailable or failed — the PIN pad stays available.
    }
  }

  void _digit(String d) {
    if (_entered.length >= 6) return;
    setState(() {
      _entered += d;
      _error = false;
    });
  }

  void _backspace() {
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  void _confirm() {
    if (_pinHash == null || _entered.length < 4) return;
    final hash = sha256.convert(utf8.encode(_entered)).toString();
    if (hash == _pinHash) {
      widget.onUnlocked();
    } else {
      setState(() {
        _error = true;
        _entered = '';
      });
    }
  }

  Widget _padKey(Widget child, VoidCallback? onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(40),
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', 'back'];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 92,
                  height: 92,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AppColors.headerGradient,
                  ),
                  child: const Icon(Icons.storefront, size: 46, color: Colors.white),
                ),
                const SizedBox(height: 14),
                Text(
                  p.t('appName'),
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 22),
                Text(
                  p.t('enterPin'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 6; i++)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 5),
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < _entered.length
                              ? AppColors.primary
                              : Colors.transparent,
                          border: Border.all(
                            color: _error ? AppColors.red : AppColors.primary,
                            width: 1.6,
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(
                  height: 26,
                  child: _error
                      ? Text(
                          p.t('wrongPin'),
                          style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w600),
                        )
                      : null,
                ),
                SizedBox(
                  width: 260,
                  child: GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    children: [
                      for (final k in keys)
                        if (k == '')
                          const SizedBox.shrink()
                        else if (k == 'back')
                          _padKey(
                            const Icon(Icons.backspace_outlined),
                            _entered.isEmpty ? null : _backspace,
                          )
                        else
                          _padKey(
                            Text(
                              k,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            () => _digit(k),
                          ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                ElevatedButton.icon(
                  onPressed: _entered.length >= 4 ? _confirm : null,
                  icon: const Icon(Icons.check),
                  label: Text(p.t('unlock')),
                ),
                if (_fingerprintOn) ...[
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: _tryBiometric,
                    icon: const Icon(Icons.fingerprint),
                    label: Text(p.t('fingerprint')),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
