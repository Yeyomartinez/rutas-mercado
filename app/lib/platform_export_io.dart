import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Implementación móvil/escritorio: guarda el archivo y abre el menú de
/// compartir de Android para mandarlo por WhatsApp, correo, Drive, etc.
Future<Directory> _dir() async =>
    await getExternalStorageDirectory() ??
    await getApplicationDocumentsDirectory();

Future<bool> saveAndShareBytes(String fileName, Uint8List bytes, String mimeType,
    String subject, String text) async {
  final dir = await _dir();
  final path = '${dir.path}/$fileName';
  await File(path).writeAsBytes(bytes, flush: true);
  await Share.shareXFiles([XFile(path, mimeType: mimeType)],
      subject: subject, text: text);
  return true;
}

Future<bool> saveAndShareText(
    String fileName, String content, String mimeType, String subject) async {
  final dir = await _dir();
  final path = '${dir.path}/$fileName';
  await File(path).writeAsString(content, flush: true);
  await Share.shareXFiles([XFile(path, mimeType: mimeType)], subject: subject);
  return true;
}
