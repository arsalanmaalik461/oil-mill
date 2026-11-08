import 'package:flutter_test/flutter_test.dart';
import 'package:oilmill/theme/app_theme.dart';

void main() {
  group('formatRs', () {
    test('zero', () {
      expect(formatRs(0), 'Rs 0');
    });

    test('small whole amounts have no separators', () {
      expect(formatRs(65), 'Rs 65');
      expect(formatRs(105), 'Rs 105');
      expect(formatRs(820), 'Rs 820');
      expect(formatRs(952), 'Rs 952');
    });

    test('thousands separators (reference screenshot values)', () {
      expect(formatRs(5420), 'Rs 5,420');
      expect(formatRs(80000), 'Rs 80,000');
      expect(formatRs(101705), 'Rs 101,705');
      expect(formatRs(99000), 'Rs 99,000');
      expect(formatRs(12000), 'Rs 12,000');
    });

    test('lakhs and millions', () {
      expect(formatRs(100000), 'Rs 100,000');
      expect(formatRs(1000000), 'Rs 1,000,000');
      expect(formatRs(12345678), 'Rs 12,345,678');
    });

    test('decimals keep up to 2 places, trailing zeros trimmed', () {
      expect(formatRs(99.25), 'Rs 99.25');
      expect(formatRs(99.2), 'Rs 99.2');
      expect(formatRs(0.5), 'Rs 0.5');
      expect(formatRs(1500.75), 'Rs 1,500.75');
      expect(formatRs(100.10), 'Rs 100.1');
    });

    test('whole doubles render without a decimal part', () {
      expect(formatRs(500.0), 'Rs 500');
      expect(formatRs(140.0), 'Rs 140');
    });

    test('negative amounts with 4+ digits format correctly', () {
      expect(formatRs(-1500), 'Rs -1,500');
      expect(formatRs(-1500000), 'Rs -1,500,000');
    });

    // Regression test: _RsFormatter previously counted the '-' sign when
    // placing commas, so negatives with 3/6/9 digits rendered 'Rs -,500'.
    // Fixed in app_theme.dart (sign formatted separately from digit grouping).
    test('negative 3-digit amount', () {
      expect(formatRs(-500), 'Rs -500');
      expect(formatRs(-100000), 'Rs -100,000');
    });
  });

  group('formatQty', () {
    test('whole quantities render as integers, no separators', () {
      expect(formatQty(0), '0');
      expect(formatQty(50), '50');
      expect(formatQty(87), '87');
      expect(formatQty(1698), '1698'); // no thousands separator by design
    });

    test('fractional quantities keep up to 3 decimals', () {
      expect(formatQty(257.004), '257.004'); // reference screenshot value
      expect(formatQty(1.5), '1.5');
      expect(formatQty(2.25), '2.25');
      expect(formatQty(0.125), '0.125');
    });

    test('trailing zeros are trimmed', () {
      expect(formatQty(3.0), '3');
      expect(formatQty(3.50), '3.5');
      expect(formatQty(10.100), '10.1');
    });
  });
}
