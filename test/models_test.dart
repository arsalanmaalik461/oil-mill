import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oilmill/models/models.dart';

void main() {
  group('Party', () {
    test('toMap/fromMap roundtrip', () {
      final p = Party(
        id: 7,
        businessId: 2,
        type: 'supplier',
        name: 'Akhtar',
        phone: '03001234567',
        address: 'Lahore',
        openingBalance: -1500.5,
        deleted: 0,
      );
      final back = Party.fromMap(p.toMap());
      expect(back.id, 7);
      expect(back.businessId, 2);
      expect(back.type, 'supplier');
      expect(back.name, 'Akhtar');
      expect(back.phone, '03001234567');
      expect(back.address, 'Lahore');
      expect(back.openingBalance, -1500.5);
      expect(back.deleted, 0);
    });

    test('null id is omitted from toMap (autoincrement insert)', () {
      final p = Party(businessId: 1, type: 'customer', name: 'Aarif');
      expect(p.toMap().containsKey('id'), isFalse);
    });

    test('fromMap tolerates int for the REAL opening_balance column', () {
      // SQLite / decoded JSON can hand back an int for a REAL field.
      final back = Party.fromMap({
        'id': 3,
        'business_id': 1,
        'type': 'customer',
        'name': 'Tariq 32',
        'phone': '',
        'address': '',
        'opening_balance': 12000, // int, not double
        'deleted': 0,
      });
      expect(back.openingBalance, 12000.0);
      expect(back.openingBalance, isA<double>());
    });

    test('fromMap applies defaults for missing optional fields', () {
      final back = Party.fromMap({'id': 1, 'name': 'X'});
      expect(back.businessId, 1);
      expect(back.type, 'customer');
      expect(back.openingBalance, 0.0);
    });
  });

  group('PartyTransaction', () {
    test('toMap/fromMap roundtrip incl. DateTime and attachment', () {
      final dt = DateTime(2024, 3, 22, 12, 53);
      final t = PartyTransaction(
        id: 11,
        partyId: 7,
        type: 'udhaar',
        amount: 5000,
        note: 'mustard oil 10L',
        dateTime: dt,
        attachmentPath: '/tmp/bill.jpg',
      );
      final back = PartyTransaction.fromMap(t.toMap());
      expect(back.id, 11);
      expect(back.partyId, 7);
      expect(back.type, 'udhaar');
      expect(back.amount, 5000.0);
      expect(back.note, 'mustard oil 10L');
      expect(back.dateTime, dt);
      expect(back.attachmentPath, '/tmp/bill.jpg');
    });

    test('fromMap tolerates int amount', () {
      final back = PartyTransaction.fromMap({
        'id': 1,
        'party_id': 2,
        'type': 'wasool',
        'amount': 820, // int
        'note': '',
        'date_time': '2022-03-08T18:12:00.000',
        'attachment_path': null,
      });
      expect(back.amount, 820.0);
      expect(back.dateTime, DateTime(2022, 3, 8, 18, 12));
      expect(back.attachmentPath, isNull);
    });
  });

  group('Bill + BillItem', () {
    test('BillItem.amount is qty * rate', () {
      expect(BillItem(billId: 1, name: 'Oil', qty: 10, rate: 550).amount, 5500.0);
      expect(BillItem(billId: 1, name: 'Cake', qty: 2.5, rate: 120).amount, 300.0);
      expect(BillItem(billId: 1, name: 'Free', qty: 0, rate: 999).amount, 0.0);
    });

    test('Bill toMap/fromMap roundtrip', () {
      final dt = DateTime(2024, 3, 22, 12, 52);
      final b = Bill(
        id: 5,
        businessId: 1,
        billNo: 42,
        partyId: 7,
        partyName: 'Akhtar',
        total: 76521,
        status: 'pending',
        dateTime: dt,
        deleted: 0,
      );
      final back = Bill.fromMap(b.toMap());
      expect(back.id, 5);
      expect(back.billNo, 42);
      expect(back.partyId, 7);
      expect(back.partyName, 'Akhtar');
      expect(back.total, 76521.0);
      expect(back.status, 'pending');
      expect(back.dateTime, dt);
    });

    test('BillItem roundtrip through real JSON (backup export/import path)', () {
      final item = BillItem(id: 9, billId: 5, itemId: 3, name: 'Sarson Oil', qty: 4, rate: 610);
      final decoded = jsonDecode(jsonEncode(item.toMap())) as Map<String, dynamic>;
      final back = BillItem.fromMap(decoded);
      expect(back.id, 9);
      expect(back.billId, 5);
      expect(back.itemId, 3);
      expect(back.name, 'Sarson Oil');
      expect(back.qty, 4.0);
      expect(back.rate, 610.0);
      expect(back.amount, 2440.0);
    });

    test('Bill fromMap tolerates int total (as decoded JSON would give)', () {
      final back = Bill.fromMap({
        'id': 2,
        'business_id': 1,
        'bill_no': 1,
        'party_id': null,
        'party_name': 'Cash',
        'total': 2000, // int
        'status': 'paid',
        'date_time': '2023-12-12T12:03:00.000',
        'deleted': 0,
      });
      expect(back.total, 2000.0);
      expect(back.partyId, isNull);
    });
  });

  group('WalletTransaction', () {
    test('toMap/fromMap roundtrip', () {
      final dt = DateTime(2026, 11, 7, 10, 30);
      final w = WalletTransaction(
        id: 4,
        businessId: 1,
        channel: 'jazzcash',
        type: 'recharge',
        amount: 500,
        phone: '03001234567',
        note: 'Zong package',
        commission: 12.5,
        dateTime: dt,
      );
      final back = WalletTransaction.fromMap(w.toMap());
      expect(back.id, 4);
      expect(back.channel, 'jazzcash');
      expect(back.type, 'recharge');
      expect(back.amount, 500.0);
      expect(back.phone, '03001234567');
      expect(back.commission, 12.5);
      expect(back.dateTime, dt);
    });

    test('fromMap tolerates int amount and int commission', () {
      final back = WalletTransaction.fromMap({
        'id': 1,
        'business_id': 1,
        'channel': 'easypaisa',
        'type': 'in',
        'amount': 10000, // int
        'phone': '',
        'note': '',
        'commission': 0, // int
        'date_time': '2026-11-01T09:00:00.000',
      });
      expect(back.amount, 10000.0);
      expect(back.commission, 0.0);
    });
  });

  group('Attendance', () {
    test('date stays a yyyy-mm-dd string through the roundtrip', () {
      final a = Attendance(
        id: 6,
        staffId: 3,
        date: '2023-05-22',
        status: 'present',
        overtimeHours: 2,
      );
      final map = a.toMap();
      expect(map['date'], '2023-05-22');
      final back = Attendance.fromMap(map);
      expect(back.id, 6);
      expect(back.staffId, 3);
      expect(back.date, '2023-05-22');
      expect(back.status, 'present');
      expect(back.overtimeHours, 2.0);
    });

    test('fromMap tolerates int overtime_hours and defaults status', () {
      final back = Attendance.fromMap({
        'id': 2,
        'staff_id': 8,
        'date': '2023-05-23',
        'overtime_hours': 3, // int
      });
      expect(back.overtimeHours, 3.0);
      expect(back.status, 'absent'); // documented default
    });
  });
}
