import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../services/firebase_service.dart';
import '../theme/app_theme.dart';
import '../utils/helpers.dart';

/// Hidden admin panel — reached only after the admin signs in via the
/// login screen's secret hold on the Welcome text.
///
/// The admin's only job here is managing app users (Firestore collection
/// `app_users`): create users, change their passwords, activate /
/// deactivate them, and delete them. Each user only ever sees the data
/// of the business they were created for.
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final _bizCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  List<AppUserRecord> _users = const [];
  bool _loadingList = false;
  bool _creating = false;
  String? _busyUser; // username currently being acted on

  @override
  void initState() {
    super.initState();
    if (FirebaseService.instance.isConfigured) {
      _loadUsers();
    }
  }

  @override
  void dispose() {
    _bizCtrl.dispose();
    _userCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    if (_loadingList) return;
    setState(() => _loadingList = true);
    try {
      final users = await FirebaseService.instance.listUsers();
      if (!mounted) return;
      setState(() => _users = users);
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  Future<void> _createUser(AppProvider p) async {
    final business = _bizCtrl.text.trim();
    final username = _userCtrl.text.trim().toLowerCase();
    final password = _passCtrl.text;
    if (business.isEmpty || username.isEmpty || password.isEmpty) {
      showSnack(context, p.t('fillAllFields'));
      return;
    }
    if (password.length < 6) {
      showSnack(context, p.t('passwordTooShort'));
      return;
    }
    setState(() => _creating = true);
    try {
      await FirebaseService.instance.createUser(
        username: username,
        businessName: business,
        email: _emailCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        password: password,
      );
      if (!mounted) return;
      showSnack(context, p.t('userCreated'));
      _bizCtrl.clear();
      _userCtrl.clear();
      _emailCtrl.clear();
      _phoneCtrl.clear();
      _passCtrl.clear();
      await _loadUsers();
    } on StateError catch (e) {
      if (!mounted) return;
      showSnack(
          context, e.message == 'user-exists' ? p.t('userExists') : e.message);
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _changePassword(AppProvider p, AppUserRecord user) async {
    final ctrl = TextEditingController();
    final newPass = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${p.t('changePassword')} — ${user.username}'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(labelText: p.t('newPassword')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(p.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(p.t('save')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newPass == null || !mounted) return;
    if (newPass.length < 6) {
      showSnack(context, p.t('passwordTooShort'));
      return;
    }
    setState(() => _busyUser = user.username);
    try {
      await FirebaseService.instance.setUserPassword(user.username, newPass);
      if (mounted) showSnack(context, p.t('passwordChanged'));
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busyUser = null);
    }
  }

  Future<void> _toggleActive(AppUserRecord user) async {
    setState(() => _busyUser = user.username);
    try {
      await FirebaseService.instance
          .setUserActive(user.username, !user.active);
      await _loadUsers();
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busyUser = null);
    }
  }

  Future<void> _deleteUser(AppProvider p, AppUserRecord user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.t('deleteUser')),
        content: Text('${user.businessName} (${user.username})'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(p.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(p.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busyUser = user.username);
    try {
      await FirebaseService.instance.deleteUser(user.username);
      await _loadUsers();
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busyUser = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();

    if (!FirebaseService.instance.isConfigured) {
      return Scaffold(
        appBar: AppBar(title: Text(p.t('adminPanel'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              p.t('firebaseNotReady'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
    }

    final emailLabel =
        p.isUrdu ? 'ای میل (اختیاری)' : 'Email (optional)';
    final phoneLabel =
        p.isUrdu ? 'فون نمبر (اختیاری)' : 'Phone (optional)';

    return Scaffold(
      appBar: AppBar(
        title: Text(p.t('adminPanel')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadingList ? null : _loadUsers,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- Create user form ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    p.t('createUser'),
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _bizCtrl,
                    decoration:
                        InputDecoration(labelText: p.t('businessName')),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _userCtrl,
                    autocorrect: false,
                    decoration:
                        InputDecoration(labelText: p.t('usernameLbl')),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: InputDecoration(labelText: emailLabel),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(labelText: phoneLabel),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    decoration:
                        InputDecoration(labelText: p.t('passwordLbl')),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _creating ? null : () => _createUser(p),
                    icon: _creating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.person_add),
                    label: Text(p.t('createUser')),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ---- Users list ----
          Row(
            children: [
              Text(
                p.t('usersList'),
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              if (_loadingList) ...[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (!_loadingList && _users.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(p.t('noUsersYet')),
            ),
          for (final user in _users)
            Card(
              child: ListTile(
                title: Text(
                  user.businessName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  [
                    user.username,
                    if (user.email.isNotEmpty) user.email,
                    if (user.phone.isNotEmpty) user.phone,
                  ].join('\n'),
                ),
                trailing: _busyUser == user.username
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Chip(
                            label: Text(
                              user.active
                                  ? (p.isUrdu ? 'فعال' : 'Active')
                                  : (p.isUrdu ? 'غیر فعال' : 'Inactive'),
                              style: const TextStyle(fontSize: 11),
                            ),
                            backgroundColor: user.active
                                ? AppColors.green.withValues(alpha: 0.15)
                                : AppColors.red.withValues(alpha: 0.15),
                            visualDensity: VisualDensity.compact,
                          ),
                          PopupMenuButton<String>(
                            onSelected: (v) {
                              switch (v) {
                                case 'password':
                                  _changePassword(p, user);
                                case 'toggle':
                                  _toggleActive(user);
                                case 'delete':
                                  _deleteUser(p, user);
                              }
                            },
                            itemBuilder: (ctx) => [
                              PopupMenuItem(
                                value: 'password',
                                child: Text(p.t('changePassword')),
                              ),
                              PopupMenuItem(
                                value: 'toggle',
                                child: Text(user.active
                                    ? p.t('deactivate')
                                    : p.t('activate')),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(p.t('deleteUser')),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
            ),
        ],
      ),
    );
  }
}
