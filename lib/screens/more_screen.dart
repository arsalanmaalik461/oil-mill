import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import 'cash_book_screen.dart';
import 'stock_book_screen.dart';
import 'bill_book_screen.dart';
import 'staff_book_screen.dart';
import 'bank_book_screen.dart';
import 'expense_book_screen.dart';
import 'digicash_screen.dart';
import 'qr_payment_screen.dart';
import 'production_hub_screen.dart';
import 'reports_screen.dart';
import 'reminders_screen.dart';
import 'recycle_bin_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';

class _Module {
  final String labelKey;
  final IconData icon;
  final Widget screen;
  const _Module(this.labelKey, this.icon, this.screen);
}

/// Bottom-nav 'More' tab: business header, language quick toggle and the
/// grid of all modules.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  Future<Business?> _currentBusiness(int bizId) async {
    final list = await DatabaseHelper.instance.getBusinesses();
    for (final b in list) {
      if (b.id == bizId) return b;
    }
    return list.isNotEmpty ? list.first : null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final modules = <_Module>[
      _Module('cashBook', Icons.book, CashBookScreen()),
      _Module('stockBook', Icons.inventory_2, StockBookScreen()),
      _Module('billBook', Icons.receipt_long, BillBookScreen()),
      _Module('staffBook', Icons.groups, StaffBookScreen()),
      _Module('bankBook', Icons.account_balance, BankBookScreen()),
      _Module('expenseBook', Icons.money_off, ExpenseBookScreen()),
      _Module('digiCash', Icons.account_balance_wallet, DigiCashScreen()),
      _Module('qrPayments', Icons.qr_code_2, QrPaymentScreen()),
      _Module('production', Icons.factory, ProductionHubScreen()),
      _Module('accountLogin', Icons.cloud_sync, const LoginScreen(isStandalone: true)),
      _Module('reports', Icons.bar_chart, ReportsScreen()),
      _Module('reminders', Icons.notifications_active, RemindersScreen()),
      _Module('recycleBin', Icons.restore_from_trash, RecycleBinScreen()),
      _Module('settings', Icons.settings, SettingsScreen()),
    ];
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GradientHeader(
              padding: const EdgeInsets.fromLTRB(16, 44, 16, 18),
              child: FutureBuilder<Business?>(
                future: _currentBusiness(p.businessId),
                builder: (context, snap) {
                  final biz = snap.data;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        biz?.name ?? p.t('appName'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (biz != null && biz.owner.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.person, size: 15, color: Colors.white70),
                            const SizedBox(width: 6),
                            Text(biz.owner, style: const TextStyle(color: Colors.white)),
                          ],
                        ),
                      ],
                      if (biz != null && biz.phone.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            const Icon(Icons.phone, size: 15, color: Colors.white70),
                            const SizedBox(width: 6),
                            Text(biz.phone, style: const TextStyle(color: Colors.white)),
                          ],
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.language, color: AppColors.primary),
                          const SizedBox(width: 10),
                          Text(
                            p.t('language'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const Spacer(),
                          ChoiceChip(
                            label: Text(p.t('english')),
                            selected: p.lang == 'en',
                            onSelected: (_) => p.setLang('en'),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('اردو'),
                            selected: p.lang == 'ur',
                            onSelected: (_) => p.setLang('ur'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.92,
                    ),
                    itemCount: modules.length,
                    itemBuilder: (context, i) {
                      final m = modules[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => m.screen),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.cardBorder),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(m.icon, color: AppColors.accent, size: 26),
                              ),
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Text(
                                  p.t(m.labelKey),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.logout, color: Colors.red),
                      title: Text(
                        p.t('logoutBtn'),
                        style: const TextStyle(
                            color: Colors.red, fontWeight: FontWeight.w600),
                      ),
                      onTap: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            content: Text(p.t('logoutConfirm')),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: Text(p.t('cancel'))),
                              TextButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: Text(p.t('logoutBtn'))),
                            ],
                          ),
                        );
                        if (ok == true) await p.signOutSession();
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  _NoteCard(icon: Icons.people_alt, text: p.t('permissionsNote')),
                  const SizedBox(height: 10),
                  _NoteCard(icon: Icons.cloud_outlined, text: p.t('cloudNote')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final IconData icon;
  final String text;
  const _NoteCard({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: AppColors.textGrey),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(fontSize: 12.5, color: AppColors.textGrey, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
