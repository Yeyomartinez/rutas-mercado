import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

/// Una oferta encontrada en campo: la chincheta que se clava en el mapa.
/// El número es correlativo dentro del proyecto (mercado) y NO cambia nunca,
/// para que coincida con las fotos tomadas con la cámara con fecha/hora.
class Offer {
  final int number;
  final LatLng pos;
  final DateTime time;
  final String street;
  final double accuracyM;
  String note;

  Offer({
    required this.number,
    required this.pos,
    required this.time,
    required this.street,
    required this.accuracyM,
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
        'n': number,
        'lat': pos.latitude,
        'lon': pos.longitude,
        't': time.toIso8601String(),
        's': street,
        'a': accuracyM,
        'note': note,
      };

  factory Offer.fromJson(Map<String, dynamic> j) => Offer(
        number: j['n'] as int,
        pos: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
        time: DateTime.tryParse(j['t'] as String? ?? '') ?? DateTime.now(),
        street: (j['s'] ?? '') as String,
        accuracyM: ((j['a'] ?? 0) as num).toDouble(),
        note: (j['note'] ?? '') as String,
      );

  String get hora =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  String get fecha =>
      '${time.day.toString().padLeft(2, '0')}/${time.month.toString().padLeft(2, '0')}/${time.year}';
}

/// Exportadores de la capa de ofertas.
class OfferExport {
  /// CSV (separador ; para Excel en formato local).
  static String toCsv(List<Offer> offers) {
    final b = StringBuffer(
        'oferta;fecha;hora;latitud;longitud;precision_m;calle;nota\n');
    for (final o in offers) {
      final note = o.note.replaceAll(';', ',').replaceAll('\n', ' ');
      final street = o.street.replaceAll(';', ',');
      b.writeln('${o.number};${o.fecha};${o.hora};'
          '${o.pos.latitude.toStringAsFixed(6)};'
          '${o.pos.longitude.toStringAsFixed(6)};'
          '${o.accuracyM.toStringAsFixed(0)};$street;$note');
    }
    return b.toString();
  }

  /// GeoJSON de puntos (QGIS/ArcGIS lo abren directo).
  static String toGeoJson(List<Offer> offers, {String project = ''}) {
    final feats = offers
        .map((o) => {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [o.pos.longitude, o.pos.latitude],
              },
              'properties': {
                'numero': o.number,
                'fecha': o.fecha,
                'hora': o.hora,
                'calle': o.street,
                'precision': o.accuracyM.round(),
                'nota': o.note,
                'proyecto': project,
              },
            })
        .toList();
    return json.encode({'type': 'FeatureCollection', 'features': feats});
  }

  /// Shapefile de puntos como ZIP (.shp/.shx/.dbf/.prj/.cpg). Layout de bytes
  /// validado contra geopandas.
  static Uint8List toShapefileZip(List<Offer> offers) {
    final files = <String, Uint8List>{
      'ofertas.shp': _buildShp(offers),
      'ofertas.shx': _buildShx(offers),
      'ofertas.dbf': _buildDbf(offers),
      'ofertas.prj': Uint8List.fromList(utf8.encode(
          'GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",'
          '6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],'
          'UNIT["Degree",0.0174532925199433]]')),
      'ofertas.cpg': Uint8List.fromList(utf8.encode('UTF-8')),
    };
    return _zipStore(files);
  }

  // ---- .shp ----
  static Uint8List _buildShp(List<Offer> offers) {
    final body = BytesBuilder();
    for (var i = 0; i < offers.length; i++) {
      final o = offers[i];
      final content = ByteData(20);
      content.setInt32(0, 1, Endian.little); // point
      content.setFloat64(4, o.pos.longitude, Endian.little);
      content.setFloat64(12, o.pos.latitude, Endian.little);
      final head = ByteData(8);
      head.setInt32(0, i + 1, Endian.big); // record number
      head.setInt32(4, 10, Endian.big); // content length in words
      body.add(head.buffer.asUint8List());
      body.add(content.buffer.asUint8List());
    }
    final bodyBytes = body.toBytes();
    final out = BytesBuilder();
    out.add(_shpHeader(offers, 1, 100 + bodyBytes.length));
    out.add(bodyBytes);
    return out.toBytes();
  }

  // ---- .shx ----
  static Uint8List _buildShx(List<Offer> offers) {
    final recs = BytesBuilder();
    var offset = 50; // primer record en word 50 (byte 100)
    for (var i = 0; i < offers.length; i++) {
      final r = ByteData(8);
      r.setInt32(0, offset, Endian.big);
      r.setInt32(4, 10, Endian.big);
      recs.add(r.buffer.asUint8List());
      offset += 4 + 10;
    }
    final recBytes = recs.toBytes();
    final out = BytesBuilder();
    out.add(_shpHeader(offers, 1, 100 + recBytes.length));
    out.add(recBytes);
    return out.toBytes();
  }

  static Uint8List _shpHeader(List<Offer> offers, int shapeType, int totalBytes) {
    final lons = offers.isEmpty ? [0.0] : offers.map((o) => o.pos.longitude);
    final lats = offers.isEmpty ? [0.0] : offers.map((o) => o.pos.latitude);
    final h = ByteData(100);
    h.setInt32(0, 9994, Endian.big);
    h.setInt32(24, totalBytes ~/ 2, Endian.big);
    h.setInt32(28, 1000, Endian.little);
    h.setInt32(32, shapeType, Endian.little);
    h.setFloat64(36, lons.reduce((a, b) => a < b ? a : b), Endian.little);
    h.setFloat64(44, lats.reduce((a, b) => a < b ? a : b), Endian.little);
    h.setFloat64(52, lons.reduce((a, b) => a > b ? a : b), Endian.little);
    h.setFloat64(60, lats.reduce((a, b) => a > b ? a : b), Endian.little);
    // Z, M = 0 (bytes 68..99 quedan en cero)
    return h.buffer.asUint8List();
  }

  // ---- .dbf (dBASE III, texto UTF-8) ----
  static Uint8List _buildDbf(List<Offer> offers) {
    // [nombre, tipo, largo, decimales]. LAT/LON llevan 6 decimales: si se dejan
    // en 0, QGIS/ArcGIS truncan "4.700000" a 4 y se pierde toda la precisión.
    final fields = <List<Object>>[
      ['NUMERO', 'N', 10, 0],
      ['FECHA', 'C', 10, 0],
      ['HORA', 'C', 5, 0],
      ['CALLE', 'C', 60, 0],
      ['NOTA', 'C', 120, 0],
      ['PRECISION', 'N', 6, 0],
      ['LAT', 'N', 12, 6],
      ['LON', 'N', 12, 6],
    ];
    final headerLen = 32 + 32 * fields.length + 1;
    final recLen = 1 + fields.fold<int>(0, (s, f) => s + (f[2] as int));
    final now = DateTime.now();

    final out = BytesBuilder();
    final h = ByteData(32);
    h.setUint8(0, 0x03);
    h.setUint8(1, (now.year - 1900) & 0xFF);
    h.setUint8(2, now.month);
    h.setUint8(3, now.day);
    h.setInt32(4, offers.length, Endian.little);
    h.setInt16(8, headerLen, Endian.little);
    h.setInt16(10, recLen, Endian.little);
    out.add(h.buffer.asUint8List());

    for (final f in fields) {
      final fd = Uint8List(32);
      final name = ascii.encode(f[0] as String);
      for (var i = 0; i < name.length && i < 11; i++) {
        fd[i] = name[i];
      }
      fd[11] = (f[1] as String).codeUnitAt(0);
      fd[16] = f[2] as int; // largo
      fd[17] = f[3] as int; // decimales
      out.add(fd);
    }
    out.add(Uint8List.fromList([0x0D]));

    Uint8List field(String val, String type, int len) {
      final b = Uint8List(len)..fillRange(0, len, 0x20); // espacios
      final data = type == 'N'
          ? ascii.encode(val.length > len ? val.substring(0, len) : val)
          : utf8.encode(val);
      if (type == 'N') {
        // números: alineados a la derecha
        final start = len - data.length;
        for (var i = 0; i < data.length && start + i < len; i++) {
          b[start + i] = data[i];
        }
      } else {
        for (var i = 0; i < data.length && i < len; i++) {
          b[i] = data[i];
        }
      }
      return b;
    }

    for (final o in offers) {
      out.add(Uint8List.fromList([0x20])); // no borrado
      out.add(field('${o.number}', 'N', 10));
      out.add(field(o.fecha, 'C', 10));
      out.add(field(o.hora, 'C', 5));
      out.add(field(o.street, 'C', 60));
      out.add(field(o.note, 'C', 120));
      out.add(field('${o.accuracyM.round()}', 'N', 6));
      out.add(field(o.pos.latitude.toStringAsFixed(6), 'N', 12));
      out.add(field(o.pos.longitude.toStringAsFixed(6), 'N', 12));
    }
    out.add(Uint8List.fromList([0x1A])); // EOF
    return out.toBytes();
  }

  // ---- ZIP (método store, sin compresión) ----
  static Uint8List _zipStore(Map<String, Uint8List> files) {
    final out = BytesBuilder();
    final central = BytesBuilder();
    var offset = 0;
    files.forEach((name, data) {
      final nameBytes = ascii.encode(name);
      final crc = _crc32(data);
      final lfh = ByteData(30);
      lfh.setUint32(0, 0x04034b50, Endian.little);
      lfh.setUint16(4, 20, Endian.little);
      lfh.setUint16(6, 0, Endian.little);
      lfh.setUint16(8, 0, Endian.little); // store
      lfh.setUint16(10, 0, Endian.little);
      lfh.setUint16(12, 0, Endian.little);
      lfh.setUint32(14, crc, Endian.little);
      lfh.setUint32(18, data.length, Endian.little);
      lfh.setUint32(22, data.length, Endian.little);
      lfh.setUint16(26, nameBytes.length, Endian.little);
      lfh.setUint16(28, 0, Endian.little);
      out.add(lfh.buffer.asUint8List());
      out.add(nameBytes);
      out.add(data);

      final cdh = ByteData(46);
      cdh.setUint32(0, 0x02014b50, Endian.little);
      cdh.setUint16(4, 20, Endian.little);
      cdh.setUint16(6, 20, Endian.little);
      cdh.setUint16(8, 0, Endian.little);
      cdh.setUint16(10, 0, Endian.little);
      cdh.setUint16(12, 0, Endian.little);
      cdh.setUint16(14, 0, Endian.little);
      cdh.setUint32(16, crc, Endian.little);
      cdh.setUint32(20, data.length, Endian.little);
      cdh.setUint32(24, data.length, Endian.little);
      cdh.setUint16(28, nameBytes.length, Endian.little);
      cdh.setUint32(42, offset, Endian.little);
      central.add(cdh.buffer.asUint8List());
      central.add(nameBytes);

      offset += 30 + nameBytes.length + data.length;
    });
    final centralBytes = central.toBytes();
    final centralOffset = offset;
    out.add(centralBytes);
    final end = ByteData(22);
    end.setUint32(0, 0x06054b50, Endian.little);
    end.setUint16(8, files.length, Endian.little);
    end.setUint16(10, files.length, Endian.little);
    end.setUint32(12, centralBytes.length, Endian.little);
    end.setUint32(16, centralOffset, Endian.little);
    out.add(end.buffer.asUint8List());
    return out.toBytes();
  }

  static int _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc ^= b;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
