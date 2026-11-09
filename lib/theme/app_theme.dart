import 'package:flutter/material.dart';

/// Colour scheme taken from the reference screenshots:
/// strong orange-red headers, white cards, green = money in, red = money out,
/// amber/yellow module icons.
class AppColors {
  static const Color primary = Color(0xFFF05623); // orange-red
  static const Color primaryDark = Color(0xFFD63D0E);
  static const Color primaryLight = Color(0xFFFF7A45);
  static const Color accent = Color(0xFFF5A623); // amber icons
  static const Color green = Color(0xFF1DA851); // cash in / you will get
  static const Color red = Color(0xFFE03131); // cash out / you will give
  static const Color background = Color(0xFFF7F7F9);
  static const Color cardBorder = Color(0xFFE9E9EE);
  static const Color textGrey = Color(0xFF8A8A93);

  static const LinearGradient headerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF26722), Color(0xFFEE4023)],
  );
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      surface: Colors.white,
    ),
    fontFamily: 'Roboto',
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 19,
        fontWeight: FontWeight.w600,
      ),
      iconTheme: IconThemeData(color: Colors.white),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      extendedPadding: EdgeInsets.symmetric(horizontal: 20),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.cardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.cardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.cardBorder),
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.white,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.textGrey,
      type: BottomNavigationBarType.fixed,
      elevation: 8,
    ),
  );
}

/// Gradient header container used on Home / module screens.
class GradientHeader extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const GradientHeader({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: const BoxDecoration(gradient: AppColors.headerGradient),
      child: child,
    );
  }
}

/// Rs amount text with the standard in/out colours.
class AmountText extends StatelessWidget {
  final double amount;
  final bool positiveIsGreen;
  final double fontSize;
  final FontWeight fontWeight;
  const AmountText(
    this.amount, {
    super.key,
    this.positiveIsGreen = true,
    this.fontSize = 15,
    this.fontWeight = FontWeight.w700,
  });

  @override
  Widget build(BuildContext context) {
    final v = amount;
    final color = v == 0
        ? AppColors.textGrey
        : ((v > 0) == positiveIsGreen ? AppColors.green : AppColors.red);
    return Text(
      formatRs(v.abs()),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: fontSize, fontWeight: fontWeight),
    );
  }
}

final _rsFormat = _RsFormatter();
String formatRs(double v) => _rsFormat.format(v);

class _RsFormatter {
  String format(double v) {
    // Format the absolute value: the comma loop below counts characters, so
    // a leading '-' would shift the grouping (e.g. -120000 -> "-,120,000").
    final neg = v < 0;
    final a = v.abs();
    final isInt = a == a.roundToDouble();
    final s = isInt
        ? a.toStringAsFixed(0)
        : a.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    final parts = s.split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    final frac = parts.length > 1 ? '.${parts[1]}' : '';
    return neg ? 'Rs -$buf$frac' : 'Rs $buf$frac';
  }
}

String formatQty(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(3).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}
