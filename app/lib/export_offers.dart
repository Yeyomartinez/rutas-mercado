import 'package:flutter/services.dart';

import 'offers.dart';
import 'platform_export.dart';

/// Comparte / descarga la capa de ofertas. En Android abre el menú de
/// compartir con el archivo; en el simulador web copia al portapapeles.
/// El acceso a archivos vive en platform_export_io.dart (condicional) para no
/// romper la compilación web al importar dart:io.
class OfferExporter {
  static String _safe(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// Shapefile (.zip con .shp/.shx/.dbf/.prj/.cpg).
  static Future<String> shareShapefile(
      List<Offer> offers, String projectName) async {
    final bytes = OfferExport.toShapefileZip(offers);
    final ok = await saveAndShareBytes(
      'ofertas_${_safe(projectName)}.zip',
      bytes,
      'application/zip',
      'Ofertas $projectName (shapefile)',
      '${offers.length} ofertas de $projectName',
    );
    return ok
        ? 'Shapefile compartido (${offers.length} ofertas)'
        : 'El shapefile solo se descarga desde el teléfono. Usa "GeoJSON" en '
            'el simulador.';
  }

  /// GeoJSON: en Android se comparte como archivo; en web va al portapapeles.
  static Future<String> shareGeoJson(
      List<Offer> offers, String projectName) async {
    final text = OfferExport.toGeoJson(offers, project: projectName);
    final ok = await saveAndShareText(
      'ofertas_${_safe(projectName)}.geojson',
      text,
      'application/geo+json',
      'Ofertas $projectName (GeoJSON)',
    );
    if (ok) return 'GeoJSON compartido (${offers.length} ofertas)';
    await Clipboard.setData(ClipboardData(text: text));
    return 'GeoJSON copiado al portapapeles (${offers.length} ofertas)';
  }

  /// CSV al portapapeles (siempre funciona, para pegar en Excel/WhatsApp).
  static Future<String> copyCsv(List<Offer> offers) async {
    await Clipboard.setData(ClipboardData(text: OfferExport.toCsv(offers)));
    return '${offers.length} ofertas copiadas al portapapeles (CSV)';
  }
}
