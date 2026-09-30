// Selector de implementación según plataforma: en móvil/escritorio usa el
// sistema de archivos + menú de compartir (dart:io); en web usa el stub que
// avisa que no se puede (el llamador cae a portapapeles). Importar dart:io
// directo rompería la compilación web aunque haya guardas kIsWeb en runtime.
export 'platform_export_stub.dart'
    if (dart.library.io) 'platform_export_io.dart';
