import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../db/database_helper.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/export_service.dart';
import '../utils/helpers.dart';

/// Data Export: pick a book, pick CSV or Excel, share the file —
/// made for sending the books to an accountant.
class DataExportScreen extends StatefulWidget {
  const DataExportScreen({super.key});

  @override
  State<DataExportScreen> createState() => _DataExportScreenState();
}

class _DataExportScreenState extends State<DataExportScreen> {
  bool _busy = false;

  Future<void> _export(String book, String titleKey, bool fullDb) async {
    final p = context.read<AppProvider>();
    final format = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(p.t('exportFormat'),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            if (!fullDb)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('CSV'),
                onTap: () => Navigator.pop(ctx, 'csv'),
              ),
            ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: const Text('Excel (.xlsx)'),
              onTap: () => Navigator.pop(ctx, 'xlsx'),
            ),
          ],
        ),
      ),
    );
    if (format == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final db = DatabaseHelper.instance;
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final File file;
      if (format == 'csv') {
        final data = await ExportService.book(db, p.businessId, book);
        file = File('${dir.path}/${book}_$stamp.csv');
        await file.writeAsString(
            ExportService.toCsv(data.headers, data.rows),
            encoding: utf8);
      } else if (fullDb) {
        final bytes = await ExportService.fullDatabaseExcel(db, p.businessId);
        file = File('${dir.path}/namat_full_database_$stamp.xlsx');
        await file.writeAsBytes(bytes);
      } else {
        final data = await ExportService.book(db, p.businessId, book);
        final bytes = ExportService.toExcel(book, data.headers, data.rows);
        file = File('${dir.path}/${book}_$stamp.xlsx');
        await file.writeAsBytes(bytes);
      }
      await Share.shareXFiles([XFile(file.path)]);
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    Widget tile(String titleKey, IconData icon, String book,
        {bool fullDb = false}) {
      return Card(
        child: ListTile(
          leading: Icon(icon, color: AppColors.primary),
          title: Text(p.t(titleKey)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : () => _export(book, titleKey, fullDb),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(p.t('dataExport'))),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(12),
            children: [
              tile('exportParties', Icons.groups, 'parties'),
              tile('exportLedger', Icons.menu_book, 'ledger'),
              tile('cashBook', Icons.payments, 'cash'),
              tile('stockBook', Icons.inventory_2, 'stock'),
              tile('billBook', Icons.receipt_long, 'bills'),
              tile('expenses', Icons.money_off, 'expenses'),
              const SizedBox(height: 10),
              tile('exportFullDatabase', Icons.storage, 'full',
                  fullDb: true),
            ],
          ),
          if (_busy) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
