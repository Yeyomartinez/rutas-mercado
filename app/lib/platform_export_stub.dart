import 'dart:typed_data';

/// Implementación web/por defecto: no hay sistema de archivos ni menú de
/// compartir nativo, así que devuelve false y el llamador cae a portapapeles.
Future<bool> saveAndShareBytes(String fileName, Uint8List bytes, String mimeType,
        String subject, String text) async =>
    false;

Future<bool> saveAndShareText(
        String fileName, String content, String mimeType, String subject) async =>
    false;
