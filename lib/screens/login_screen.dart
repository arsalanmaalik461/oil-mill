import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/firebase_service.dart';
import '../theme/app_theme.dart';
import '../utils/admin_config.dart';
import '../utils/helpers.dart';
import 'admin_panel_screen.dart';

/// Login screen — the app's entry point.
///
/// Sign-in is ONLY with an ID created by the app admin (User ID, Email or
/// Phone + password). User records live in Firestore (`app_users`) via
/// [FirebaseService]. There is no self-registration.
///
/// Hidden admin access: pressing and holding the "Welcome" heading for
/// 8 seconds opens the admin sign-in dialog.
class LoginScreen extends StatefulWidget {
  final bool isStandalone;
  const LoginScreen({super.key, this.isStandalone = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _busy = false;

  // --- 8-second hold on "Welcome" (hidden admin access) ---
  Timer? _holdTimer;

  final _firebase = FirebaseService.instance;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _idCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  // ---------------- Hidden admin hold ----------------

  void _startHold() {
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) _showAdminDialog();
    });
  }

  void _endHold() {
    // Released / cancelled before 8 seconds: cancel silently (no hint shown).
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  Future<void> _showAdminDialog() async {
    final p = context.read<AppProvider>();
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.isUrdu ? 'ایڈمن لاگ ان' : 'Admin Login'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: userCtrl,
              decoration: InputDecoration(
                labelText: p.t('usernameLbl'),
                prefixIcon: const Icon(Icons.person_outline),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: InputDecoration(
                labelText: p.t('passwordLbl'),
                prefixIcon: const Icon(Icons.lock_outline),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(p.isUrdu ? 'منسوخ' : 'Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              if (AdminConfig.verify(userCtrl.text, passCtrl.text)) {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const AdminPanelScreen()),
                );
              } else {
                showSnack(ctx, p.t('wrongCredentials'));
              }
            },
            child: Text(p.t('loginBtn')),
          ),
        ],
      ),
    );
    userCtrl.dispose();
    passCtrl.dispose();
  }

  // ---------------- User login ----------------

  Future<void> _handleLogin() async {
    if (_busy) return;
    final p = context.read<AppProvider>();
    final id = _idCtrl.text.trim();
    final pass = _passCtrl.text;

    if (id.isEmpty || pass.isEmpty) {
      showSnack(context, p.t('fillAllFields'));
      return;
    }
    if (pass.length < 6) {
      showSnack(context, p.t('passwordTooShort'));
      return;
    }

    setState(() => _busy = true);
    try {
      AppUserRecord? rec;
      var offline = false;

      // 1) Try online sign-in against Firestore.
      try {
        rec = await _firebase.loginUser(id, pass);
      } on StateError catch (e) {
        if (e.message == 'wrong') {
          if (mounted) showSnack(context, p.t('wrongCredentials'));
          return;
        }
        if (e.message == 'inactive') {
          if (mounted) showSnack(context, p.t('accountInactive'));
          return;
        }
        if (e.message == 'firebase-not-configured') {
          // 2) Offline fallback: this device's cached sign-in record.
          final cached = await _firebase.loginUserCached(id, pass);
          if (cached == null) {
            if (mounted) showSnack(context, p.t('firebaseNotReady'));
            return;
          }
          rec = cached;
          offline = true;
        } else {
          if (mounted) showSnack(context, p.t('wrongCredentials'));
          return;
        }
      } catch (_) {
        // Network / FirebaseException etc.: try the on-device cache.
        final cached = await _firebase.loginUserCached(id, pass);
        if (cached == null) {
          if (mounted) showSnack(context, p.t('wrongCredentials'));
          return;
        }
        rec = cached;
        offline = true;
      }

      if (offline && mounted) {
        showSnack(
          context,
          p.isUrdu
              ? 'آف لائن لاگ ان (اس موبائل کی محفوظ کاپی سے)'
              : 'Offline sign-in (saved copy on this device)',
        );
      }

      // 4) Bind (or create) the local business for this user.
      final db = DatabaseHelper.instance;
      var biz = await db.getBusinessByUsername(rec.username);
      var justCreated = false;
      int bizId;
      if (biz == null) {
        // First user on this device: bind the existing unbound business
        // (e.g. the owner's own data) instead of starting empty.
        final all = await db.getBusinesses();
        for (final b in all) {
          if (b.appUsername.isEmpty && b.id != null) {
            biz = b;
            break;
          }
        }
        if (biz != null) {
          await db.updateBusiness(Business(
            id: biz.id,
            name: rec.businessName.isEmpty ? biz.name : rec.businessName,
            owner: biz.owner,
            phone: biz.phone,
            address: biz.address,
            appUsername: rec.username,
          ));
        }
      }
      if (biz == null) {
        bizId = await db.insertBusiness(Business(
          name: rec.businessName.isEmpty ? rec.username : rec.businessName,
          appUsername: rec.username,
        ));
        justCreated = true;
      } else {
        bizId = biz.id!;
        if (rec.businessName.isNotEmpty && biz.name != rec.businessName) {
          await db.updateBusiness(Business(
            id: biz.id,
            name: rec.businessName,
            owner: biz.owner,
            phone: biz.phone,
            address: biz.address,
            appUsername:
                biz.appUsername.isEmpty ? rec.username : biz.appUsername,
          ));
        }
      }

      // 5) Cloud restore (fresh device) or push latest up (returning user).
      if (_firebase.isConfigured) {
        try {
          if (justCreated) {
            await _firebase.restoreUserData(rec.username, bizId);
          } else {
            final uname = rec.username;
            unawaited(() async {
              try {
                await _firebase.syncUserData(uname, bizId);
              } catch (_) {}
            }());
          }
        } catch (_) {
          // Sync problems must never block sign-in.
        }
      }

      // 6) Establish the session — RootGate swaps in the app shell.
      await p.signInSession(rec.username, bizId);
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: widget.isStandalone
          ? AppBar(title: Text(p.t('loginBtn')))
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(12),
                    child:
                        Image.asset('assets/icon/icon.png', fit: BoxFit.contain),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    p.t('appName'),
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),

                  // "Welcome" — hidden admin hold target (8 seconds).
                  Listener(
                    onPointerDown: (_) => _startHold(),
                    onPointerUp: (_) => _endHold(),
                    onPointerCancel: (_) => _endHold(),
                    child: Text(
                      p.t('welcome'),
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    p.t('loginSubtitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 24),

                  // Login card
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          TextField(
                            controller: _idCtrl,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.person_outline),
                              labelText: p.t('loginIdHint'),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _passCtrl,
                            obscureText: true,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _handleLogin(),
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.lock_outline),
                              labelText: p.t('passwordLbl'),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                            ),
                          ),
                          const SizedBox(height: 18),
                          ElevatedButton(
                            onPressed: _busy ? null : _handleLogin,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            child: _busy
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : Text(
                                    p.t('loginBtn'),
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
