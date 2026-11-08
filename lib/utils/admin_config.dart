import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Hidden app-admin access (owner only).
///
/// On the login screen, pressing and holding the "Welcome" heading for
/// 15 seconds opens the admin sign-in. The admin can create app users
/// (each bound to a business name); user records live in Firestore
/// (collection `app_users`). The admin password is stored here only as a
/// salted SHA-256 hash, never in plain text.
class AdminConfig {
  static const String adminUsername = 'arsu';
  static const String _salt = 'namat-admin';
  static const String adminPasswordHash =
      '0f826c6d42eb67703c4beec263e45af905420a659746e5e667b9db060b259717';

  static bool verify(String username, String password) {
    if (username.trim().toLowerCase() != adminUsername) return false;
    final hash = sha256.convert(utf8.encode('$_salt:$password')).toString();
    return hash == adminPasswordHash;
  }
}
