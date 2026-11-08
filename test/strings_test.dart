import 'package:flutter_test/flutter_test.dart';
import 'package:oilmill/l10n/app_strings.dart';
import 'package:oilmill/utils/helpers.dart';

/// Every key present in the 'en' table of AppStrings (extracted from
/// lib/l10n/app_strings.dart). AppStrings._table is private, so parity is
/// verified through the public AppStrings.get() API: a key missing from a
/// language falls back to the English value, and a key missing from both
/// falls back to the key itself — both failure modes are caught below
/// (Urdu values are Urdu script, so a silent English fallback also fails
/// the ur != en check).
const List<String> kKnownKeys = [
  'about', 'absent', 'accountNo', 'accountTitle', 'addBank', 'addBusiness',
  'addCustomer', 'addEntry', 'addExpense', 'addItem', 'addParty', 'addStaff',
  'addSupplier', 'addToBill', 'addTransaction', 'address', 'advance', 'all',
  'allItems', 'amount', 'appName', 'apply', 'attachBill', 'attendance',
  'backup', 'balance', 'bank', 'bankBalance', 'bankBook', 'bankName', 'banks',
  'billBook', 'billNo', 'billTotal', 'bonus', 'business', 'businessName',
  'callNow', 'cancel', 'cashBook', 'cashIn', 'cashInHand', 'cashOut',
  'cashReport', 'category', 'channel', 'cloudNote', 'commission',
  'confirmDelete', 'createBill', 'currentStock', 'customer', 'customers',
  'dailyReport', 'date', 'delete', 'deleteForever', 'deleted', 'digiCash',
  'downloadPdf', 'dueDate', 'easypaisa', 'edit', 'editParty', 'english',
  'enterPin', 'entries', 'expenseBook', 'expenseCategories', 'expenses',
  'exportBackup', 'fingerprint', 'from', 'generateBill', 'halfDay',
  'hideBalance', 'history', 'home', 'hours', 'importBackup', 'in', 'income',
  'invalidAmount', 'jazzcash', 'language', 'ledger', 'lowStock',
  'lowStockLimit', 'markAllPresent', 'mobileNumber', 'money', 'moneyIn',
  'moneyOut', 'monthlyReport', 'monthlySalary', 'more', 'name', 'netCashFlow',
  'noData', 'noPhone', 'note', 'openingBalance', 'openingQty', 'out',
  'outstanding', 'overtime', 'ownerName', 'package', 'paid', 'partyReport',
  'paySalary', 'paymentHistory', 'paymentReminder', 'pending',
  'permissionsNote', 'phone', 'pinLock', 'present', 'profile', 'profitNote',
  'quantity', 'rate', 'recentTransactions', 'recharge', 'recycleBin',
  'reminders', 'reports', 'request', 'requestMoney', 'requiredField',
  'restore', 'restoreBackup', 'restored', 'salary', 'save',
  'savedSuccessfully', 'search', 'security', 'selectCustomer', 'selectDate',
  'selectItem', 'selectSupplier', 'send', 'sendMoney', 'sendReminder',
  'setPin', 'settings', 'share', 'shareWhatsapp', 'showBalance',
  'smsReminder', 'staffBook', 'staffPayments', 'status', 'stockBook',
  'stockIn', 'stockOut', 'stockReport', 'supplier', 'suppliers',
  'switchBusiness', 'thisMonth', 'to', 'today', 'todayBalance', 'total',
  'totalAbsent', 'totalPresent', 'totalSale', 'udhaar', 'unit', 'urdu',
  'version', 'viewAll', 'walletBalance', 'wasool', 'whatsappReminder',
  'youWillGet', 'youWillGive',
];

/// Keys whose value is legitimately identical in English and Urdu
/// ('english' is the English name of the language in both tables).
const Set<String> kIdenticalInBothLanguages = {'english'};

void main() {
  group('AppStrings parity (en <-> ur)', () {
    test('every known key resolves to a real English string', () {
      for (final key in kKnownKeys) {
        final v = AppStrings.get('en', key);
        expect(v, isNotEmpty, reason: 'en[$key] is empty');
        expect(v, isNot(key),
            reason: 'en[$key] fell back to the key itself (missing entry)');
      }
    });

    test('every known key resolves to a real Urdu string', () {
      for (final key in kKnownKeys) {
        final v = AppStrings.get('ur', key);
        expect(v, isNotEmpty, reason: 'ur[$key] is empty');
        expect(v, isNot(key),
            reason: 'ur[$key] fell back to the key itself (missing entry)');
      }
    });

    test('Urdu values are genuine translations, not English fallbacks', () {
      for (final key in kKnownKeys) {
        if (kIdenticalInBothLanguages.contains(key)) continue;
        expect(AppStrings.get('ur', key), isNot(AppStrings.get('en', key)),
            reason: 'ur[$key] equals the English value — missing translation '
                'would silently fall back to English');
      }
    });

    test('unknown keys fall back to the key itself', () {
      expect(AppStrings.get('en', 'no_such_key_xyz'), 'no_such_key_xyz');
      expect(AppStrings.get('ur', 'no_such_key_xyz'), 'no_such_key_xyz');
    });

    // The ur table previously had an orphan key 'currentStockUr' with no
    // 'en' counterpart; it was removed from app_strings.dart, so the key
    // now falls back to itself in both languages (full table parity).
    test('removed orphan key currentStockUr falls back in both languages', () {
      expect(AppStrings.get('ur', 'currentStockUr'), 'currentStockUr');
      expect(AppStrings.get('en', 'currentStockUr'), 'currentStockUr');
      expect(AppStrings.get('ur', 'currentStock'), isNot('currentStock'));
      expect(AppStrings.get('en', 'currentStock'), 'Current Stock');
    });

    test('spot-check core labels', () {
      expect(AppStrings.get('en', 'home'), 'Home');
      expect(AppStrings.get('en', 'money'), 'Money');
      expect(AppStrings.get('en', 'more'), 'More');
      expect(AppStrings.get('en', 'appName'), 'Namat Oil Mill');
      expect(AppStrings.get('en', 'cashBook'), 'Cash Book');
    });
  });

  group('intlPhone normalization (wa.me / sms links)', () {
    test('local format 03xx becomes 92xx', () {
      expect(intlPhone('03001234567'), '923001234567');
      expect(intlPhone('03219876543'), '923219876543');
    });

    test('spaces, dashes and parentheses are stripped', () {
      expect(intlPhone('0300 1234567'), '923001234567');
      expect(intlPhone('0300-1234567'), '923001234567');
      expect(intlPhone('(0300) 123-4567'), '923001234567');
    });

    test('already-international numbers pass through unchanged', () {
      expect(intlPhone('923001234567'), '923001234567');
      expect(intlPhone('+92 300 1234567'), '923001234567');
      expect(intlPhone('+923001234567'), '923001234567');
    });

    test('00 international prefix is converted', () {
      expect(intlPhone('00923001234567'), '923001234567');
    });

    test('bare 10-digit number gets the 92 prefix', () {
      expect(intlPhone('3001234567'), '923001234567');
    });

    test('empty input stays empty', () {
      expect(intlPhone(''), '');
    });
  });
}
