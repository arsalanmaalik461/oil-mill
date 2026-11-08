import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:oilmill/main.dart';
import 'package:oilmill/providers/app_provider.dart';
import 'package:oilmill/theme/app_theme.dart';

void main() {
  // Smoke test: the real MainShell (Home / Money / More bottom navigation)
  // must build and show its three English tab labels.
  //
  // The tab screens query SQLite through sqflite, whose platform plugin is
  // NOT available in the flutter_test VM. Those futures complete with
  // MissingPluginException and the screens land in their FutureBuilder
  // error/empty states — that is acceptable here; this test only asserts
  // the shell + navigation chrome builds without throwing.
  //
  // tester.pump() with a bounded duration is used instead of
  // pumpAndSettle(), which can hang on pending futures/animations.
  testWidgets('MainShell renders Home / Money / More bottom navigation',
      (tester) async {
    final provider = AppProvider(); // defaults: lang 'en', no PIN gate
    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const MainShell(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    final nav = find.byType(BottomNavigationBar);
    expect(nav, findsOneWidget);
    expect(
      find.descendant(of: nav, matching: find.text('Home')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: nav, matching: find.text('Money')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: nav, matching: find.text('More')),
      findsOneWidget,
    );
  });
}
