import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/app_provider.dart';
import 'services/firebase_service.dart';
import 'theme/app_theme.dart';
import 'utils/google_drive_service.dart';
import 'screens/lock_screen.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/digicash_screen.dart';
import 'screens/more_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FirebaseService.instance.initialize();
  GoogleDriveService.instance.startAutoBackupScheduler();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppProvider()..load(),
      child: const NamatApp(),
    ),
  );
}

class NamatApp extends StatelessWidget {
  const NamatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    return MaterialApp(
      title: 'Namat Oil Mill',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      builder: (context, child) => Directionality(
        textDirection: provider.direction,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const RootGate(),
    );
  }
}

/// Shows the PIN/fingerprint lock first when a PIN is set.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  bool _unlocked = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    // 1) App-user sign-in (Firebase app_users) comes first.
    if (!provider.isLoggedIn) {
      return const LoginScreen();
    }
    // 2) Then the optional device PIN / fingerprint lock.
    if (provider.pinEnabled && !_unlocked) {
      return LockScreen(onUnlocked: () => setState(() => _unlocked = true));
    }
    return const MainShell();
  }
}

/// Bottom navigation exactly like the reference: Home • Money • More.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final pages = const [HomeScreen(), DigiCashScreen(), MoreScreen()];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.home), label: p.t('home')),
          BottomNavigationBarItem(icon: const Icon(Icons.account_balance_wallet), label: p.t('money')),
          BottomNavigationBarItem(icon: const Icon(Icons.grid_view), label: p.t('more')),
        ],
      ),
    );
  }
}
