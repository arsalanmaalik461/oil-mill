import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../services/firebase_service.dart';
import '../theme/app_theme.dart';
import '../utils/google_drive_service.dart';
import '../utils/helpers.dart';

class LoginScreen extends StatefulWidget {
  final bool isStandalone;
  const LoginScreen({super.key, this.isStandalone = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isRegister = false;
  bool _busy = false;

  final _firebase = FirebaseService.instance;
  final _drive = GoogleDriveService.instance;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _proceedToApp() {
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  Future<void> _handleGoogleSignIn(AppProvider p) async {
    setState(() => _busy = true);
    try {
      final account = await _drive.signIn();
      if (account != null && mounted) {
        showSnack(context, '${p.t('googleConnected')}: ${account.email}');
        _proceedToApp();
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'Google Sign-In: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleEmailAuth(AppProvider p) async {
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text.trim();

    if (email.isEmpty || pass.isEmpty) {
      showSnack(context, p.isUrdu ? 'براہ کرم ای میل اور پاس ورڈ درج کریں۔' : 'Please enter email and password.');
      return;
    }

    if (pass.length < 6) {
      showSnack(context, p.isUrdu ? 'پاس ورڈ کم از کم 6 ہندسوں کا ہونا چاہیے۔' : 'Password must be at least 6 characters.');
      return;
    }

    setState(() => _busy = true);
    try {
      if (!_firebase.isConfigured) {
        // Safe offline simulated login if Firebase google-services.json not yet placed
        showSnack(context, p.isUrdu ? 'کامیابی سے لاگ ان ہو گئے۔' : 'Signed in successfully.');
        _proceedToApp();
        return;
      }

      if (_isRegister) {
        await _firebase.registerWithEmail(email, pass);
        if (mounted) {
          showSnack(context, p.isUrdu ? 'نیا اکاؤنٹ بن گیا۔' : 'Account created successfully.');
          _proceedToApp();
        }
      } else {
        await _firebase.signInWithEmail(email, pass);
        if (mounted) {
          showSnack(context, p.isUrdu ? 'کامیابی سے لاگ ان ہو گئے۔' : 'Signed in successfully.');
          _proceedToApp();
        }
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'Error: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final isUrdu = p.isUrdu;
    final primaryColor = Theme.of(context).primaryColor;

    final currentGoogleUser = _drive.currentAccount;
    final currentFirebaseUser = _firebase.currentUser;

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: widget.isStandalone
          ? AppBar(title: Text(isUrdu ? 'اکاؤنٹ اور لاگ ان' : 'Account & Login'))
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
                  // App Brand Logo & Title
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: primaryColor.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Image.asset('assets/icon/icon.png', fit: BoxFit.contain),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isUrdu ? 'نعمت آئل مل' : 'Namat Oil Mill',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  Text(
                    isUrdu
                        ? 'محفوظ کھاتہ و پروڈکشن کلاؤڈ سنک'
                        : 'Business Khata & Production Management',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 28),

                  // If user is already logged in, show status card
                  if (currentGoogleUser != null || currentFirebaseUser != null) ...[
                    Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            const Icon(Icons.check_circle,
                                color: Colors.green, size: 48),
                            const SizedBox(height: 8),
                            Text(
                              isUrdu ? 'لاگ ان فعال ہے' : 'Logged In',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              currentGoogleUser?.email ??
                                  currentFirebaseUser?.email ??
                                  '',
                              style: TextStyle(
                                  color: Colors.grey.shade700, fontSize: 13),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _proceedToApp,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primaryColor,
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(44),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              child: Text(
                                isUrdu ? 'کھاتہ کھولیں' : 'Open Khata',
                                style: const TextStyle(fontSize: 15),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () async {
                                await _drive.signOut();
                                await _firebase.signOut();
                                setState(() {});
                              },
                              icon: const Icon(Icons.logout, size: 18),
                              label: Text(isUrdu ? 'لاگ آؤٹ' : 'Log Out'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ] else ...[
                    // Google Sign-In 1-Tap Button
                    Card(
                      elevation: 1,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      child: InkWell(
                        onTap: _busy ? null : () => _handleGoogleSignIn(p),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Image.network(
                                'https://www.gstatic.com/firebasejs/ui/2.0.0/images/auth/google.svg',
                                height: 22,
                                width: 22,
                                errorBuilder: (_, __, ___) => const Icon(
                                    Icons.g_mobiledata,
                                    size: 26,
                                    color: Colors.blue),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                isUrdu
                                    ? 'Google اکاؤنٹ سے لاگ ان کریں'
                                    : 'Sign in with Google',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black87,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),

                    // Divider
                    Row(
                      children: [
                        Expanded(child: Divider(color: Colors.grey.shade300)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            isUrdu ? 'یا ای میل سے' : 'or with Email',
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 12),
                          ),
                        ),
                        Expanded(child: Divider(color: Colors.grey.shade300)),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // Email & Password Fields Card
                    Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            TextField(
                              controller: _emailCtrl,
                              keyboardType: TextInputType.emailAddress,
                              decoration: InputDecoration(
                                prefixIcon: const Icon(Icons.email_outlined),
                                labelText: isUrdu ? 'ای میل ایڈریس' : 'Email Address',
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
                              decoration: InputDecoration(
                                prefixIcon: const Icon(Icons.lock_outline),
                                labelText: isUrdu ? 'پاس ورڈ' : 'Password',
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10)),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 18),
                            ElevatedButton(
                              onPressed:
                                  _busy ? null : () => _handleEmailAuth(p),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primaryColor,
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(46),
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
                                      _isRegister
                                          ? (isUrdu
                                              ? 'نیا اکاؤنٹ بنائیں'
                                              : 'Create Account')
                                          : (isUrdu
                                              ? 'لاگ ان کریں'
                                              : 'Sign In'),
                                      style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold),
                                    ),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _isRegister = !_isRegister),
                              child: Text(
                                _isRegister
                                    ? (isUrdu
                                        ? 'پہلے سے اکاؤنٹ ہے؟ لاگ ان کریں'
                                        : 'Already have an account? Sign In')
                                    : (isUrdu
                                        ? 'نیا اکاؤنٹ رجسٹر کریں'
                                        : 'Need an account? Register'),
                                style: TextStyle(
                                    fontSize: 13, color: primaryColor),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),

                  // Big Reassuring Offline Access Button
                  OutlinedButton.icon(
                    onPressed: _proceedToApp,
                    icon: const Icon(Icons.offline_bolt_outlined, size: 20),
                    label: Text(
                      isUrdu
                          ? 'بغیر انٹرنیٹ کھاتہ کھولیں (Offline)'
                          : 'Continue Offline (No Internet Needed)',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green.shade800,
                      side: BorderSide(color: Colors.green.shade400, width: 1.5),
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      backgroundColor: Colors.green.shade50,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isUrdu
                        ? 'آف لائن ڈیٹا ہمیشہ آپ کے موبائل میں محفوظ رہتا ہے۔'
                        : 'Offline data is always safely stored on this device.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
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

