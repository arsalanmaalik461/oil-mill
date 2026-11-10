import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

final dateFmt = DateFormat('EEE, dd MMM yyyy');
final dateTimeFmt = DateFormat('dd MMM yyyy • hh:mm a');
final dayKeyFmt = DateFormat('yyyy-MM-dd');

/// How many KG one unit of [unit] weighs, for production cost conversions
/// (cost per KG / per 40 KG / per ton). Unknown units count as 1.
double unitToKgFactor(String unit, {double? densityKgPerLitre}) {
  final u = unit.toLowerCase();
  if (u.contains('ton')) return 1000;
  if (u.contains('mann') || u.contains('maund') || u.contains('mun')) {
    return 40;
  }
  if (u.contains('litre') || u.contains('liter') || u.contains('ltr')) {
    // 1 litre of oil is NOT 1 kg; use the item's density when known.
    return densityKgPerLitre ?? 1;
  }
  if (u.contains('40')) return 40;
  if (u.contains('kg')) return 1;
  return 1;
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, parts.first.length >= 2 ? 2 : 1).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

/// Normalize a Pakistani phone number to international format for wa.me links.
String intlPhone(String phone) {
  var d = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.startsWith('00')) d = d.substring(2);
  if (d.startsWith('0')) d = '92${d.substring(1)}';
  if (!d.startsWith('92') && d.length == 10) d = '92$d';
  return d;
}

Future<void> openWhatsApp(String phone, String message) async {
  final uri = Uri.parse('https://wa.me/${intlPhone(phone)}?text=${Uri.encodeComponent(message)}');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> openSms(String phone, String message) async {
  final uri = Uri.parse('sms:${intlPhone(phone)}?body=${Uri.encodeComponent(message)}');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> callPhone(String phone) async {
  final uri = Uri.parse('tel:${phone.replaceAll(' ', '')}');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> shareText(String text) async {
  await Share.share(text);
}

Future<void> shareFilePath(String path, {String? text}) async {
  await Share.shareXFiles([XFile(path)], text: text);
}

/// Pick a bill photo from camera or gallery; returns saved local path.
Future<String?> pickAttachment(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: const Text('Camera'),
            onTap: () => Navigator.pop(c, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Gallery'),
            onTap: () => Navigator.pop(c, ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null) return null;
  final picked = await ImagePicker().pickImage(source: source, imageQuality: 70);
  if (picked == null) return null;
  final dir = await getApplicationDocumentsDirectory();
  final dest = p.join(dir.path, 'attachments',
      '${DateTime.now().millisecondsSinceEpoch}${p.extension(picked.path)}');
  await Directory(p.dirname(dest)).create(recursive: true);
  await File(picked.path).copy(dest);
  return dest;
}

/// Thumbnail of an entry's attached bill image. Tap opens it full-screen.
class AttachmentThumb extends StatelessWidget {
  final String path;
  final double size;
  const AttachmentThumb({super.key, required this.path, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showAttachmentViewer(context, path),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: size,
            height: size,
            color: Colors.black12,
            child: const Icon(Icons.broken_image_outlined, size: 20),
          ),
        ),
      ),
    );
  }
}

/// Full-screen view of an attached bill image (pinch to zoom).
void showAttachmentViewer(BuildContext context, String path) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Bill Image')),
        backgroundColor: Colors.black,
        body: Center(
          child: InteractiveViewer(
            child: Image.file(
              File(path),
              errorBuilder: (_, __, ___) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white,
                  size: 48),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<bool> confirmDelete(BuildContext context, String message) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Delete', style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );
  return r ?? false;
}

void showSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Bottom-sheet date+time picker returning the chosen moment.
Future<DateTime?> pickDateTime(BuildContext context, DateTime initial) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2020),
    lastDate: DateTime(2100),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
  if (time == null) return DateTime(date.year, date.month, date.day, initial.hour, initial.minute);
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// Date-only picker. Uses the ROOT navigator's context: called from a
/// page or dialog this always finds a MaterialLocalizations ancestor,
/// which is where the old in-sheet calls could fail.
Future<DateTime?> pickDateOnly(BuildContext context, DateTime initial) {
  final root = Navigator.of(context, rootNavigator: true).context;
  return showDatePicker(
    context: root,
    initialDate: initial,
    firstDate: DateTime(2020),
    lastDate: DateTime(2100),
  );
}

/// Time-only picker (root navigator context, see [pickDateOnly]).
Future<TimeOfDay?> pickTimeOnly(BuildContext context, DateTime initial) {
  final root = Navigator.of(context, rootNavigator: true).context;
  return showTimePicker(
    context: root,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
}

/// True when [dt] falls inside the optional day range [start]..[end]
/// (both inclusive, compared by calendar day).
bool inDateRange(DateTime dt, DateTime? start, DateTime? end) {
  final day = DateTime(dt.year, dt.month, dt.day);
  if (start != null && day.isBefore(DateTime(start.year, start.month, start.day))) {
    return false;
  }
  if (end != null && day.isAfter(DateTime(end.year, end.month, end.day))) {
    return false;
  }
  return true;
}

/// Asks the user for a date range (All Time / Today / This Week / This
/// Month / Last Month / Custom calendar range). Returns null when the
/// dialog is dismissed. `start`/`end` are null for All Time.
Future<({DateTime? start, DateTime? end, String label})?> pickDateRange(
  BuildContext context,
  String Function(String key) t,
) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(t('dateRange')),
      children: [
        for (final entry in const [
          ('all', 'rangeAll'),
          ('today', 'rangeToday'),
          ('week', 'rangeThisWeek'),
          ('month', 'rangeThisMonth'),
          ('lastMonth', 'rangeLastMonth'),
          ('custom', 'rangeCustom'),
        ])
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, entry.$1),
            child: Text(t(entry.$2)),
          ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return null;
  final now = DateTime.now();
  DateTime day(DateTime x) => DateTime(x.year, x.month, x.day);
  switch (choice) {
    case 'all':
      return (start: null, end: null, label: t('rangeAll'));
    case 'today':
      return (start: day(now), end: day(now), label: t('rangeToday'));
    case 'week':
      return (
        start: day(now).subtract(Duration(days: now.weekday - 1)),
        end: day(now),
        label: t('rangeThisWeek')
      );
    case 'month':
      return (
        start: DateTime(now.year, now.month, 1),
        end: day(now),
        label: t('rangeThisMonth')
      );
    case 'lastMonth':
      return (
        start: DateTime(now.year, now.month - 1, 1),
        end: DateTime(now.year, now.month, 0),
        label: t('rangeLastMonth')
      );
    case 'custom':
      final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );
      if (r == null) return null;
      final f = DateFormat('dd MMM yy');
      return (
        start: day(r.start),
        end: day(r.end),
        label: '${f.format(r.start)} – ${f.format(r.end)}'
      );
  }
  return null;
}
