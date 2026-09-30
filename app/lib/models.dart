import 'dart:convert';

import 'package:latlong2/latlong.dart';

import 'geo.dart';

/// Papel de un tramo dentro de la ruta.
///  - cover  : calle a verificar; cuenta para el 100%
///  - recheck: segunda pasada recomendada (vía ancha de doble sentido);
///             guía, pero NO cuenta para el 100%
///  - link   : tramo de enlace entre calles; no cuenta
enum StepRole { cover, recheck, link }

StepRole _roleFrom(String? s) {
  switch (s) {
    case 'recheck':
      return StepRole.recheck;
    case 'link':
      return StepRole.link;
    default:
      return StepRole.cover;
  }
}

/// Un tramo de la ruta: una calle (o parte) que se recorre en orden.
class RouteStep {
  final int seq;
  final String streetId;
  final String name;
  final double lengthM;
  final StepRole role;
  final String maneuver;
  final String instruction;
  final int elevStart;
  final int elevEnd;
  final List<LatLng> coords;

  RouteStep({
    required this.seq,
    required this.streetId,
    required this.name,
    required this.lengthM,
    required this.role,
    required this.maneuver,
    required this.instruction,
    required this.elevStart,
    required this.elevEnd,
    required this.coords,
  });

  factory RouteStep.fromFeature(Map<String, dynamic> f) {
    final p = f['properties'] as Map<String, dynamic>;
    final geom = (f['geometry']['coordinates'] as List)
        .map<LatLng>((c) =>
            LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
    return RouteStep(
      seq: p['seq'] as int,
      streetId: (p['street_id'] ?? '') as String,
      name: (p['name'] ?? '') as String,
      lengthM: (p['length_m'] as num).toDouble(),
      role: _roleFrom(p['role'] as String?),
      maneuver: (p['maneuver'] ?? '') as String,
      instruction: (p['instruction'] ?? '') as String,
      elevStart: ((p['elev_start'] ?? 0) as num).toInt(),
      elevEnd: ((p['elev_end'] ?? 0) as num).toInt(),
      coords: geom,
    );
  }

  LatLng get start => coords.first;
  LatLng get end => coords.last;
  bool get counts => role == StepRole.cover;
}

/// Ruta de cobertura completa para una combinación de sectores.
class CoverageRoute {
  final List<String> sectorCodes;
  final String mode;
  final String zone;
  final double totalLengthM;
  final double coverLengthM;
  final double recheckLengthM;
  final List<RouteStep> steps;

  CoverageRoute({
    required this.sectorCodes,
    required this.mode,
    required this.zone,
    required this.totalLengthM,
    required this.coverLengthM,
    required this.recheckLengthM,
    required this.steps,
  });

  factory CoverageRoute.fromGeoJson(String raw) {
    final j = json.decode(raw) as Map<String, dynamic>;
    final props = j['properties'] as Map<String, dynamic>;
    final steps = (j['features'] as List)
        .map<RouteStep>((f) => RouteStep.fromFeature(f as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return CoverageRoute(
      sectorCodes: (props['sectors'] as List).cast<String>(),
      mode: props['mode'] as String,
      zone: (props['zone'] ?? '1') as String,
      totalLengthM: (props['total_length_m'] as num).toDouble(),
      coverLengthM: (props['cover_length_m'] as num).toDouble(),
      recheckLengthM: ((props['recheck_length_m'] ?? 0) as num).toDouble(),
      steps: steps,
    );
  }

  /// Largo de cada CALLE que cuenta para el 100% (una pasada la cubre).
  Map<String, double> get coverStreetLengths {
    final m = <String, double>{};
    for (final s in steps) {
      if (s.counts) m.putIfAbsent(s.streetId, () => s.lengthM);
    }
    return m;
  }

  /// Calles con segunda pasada recomendada (no cuentan).
  Set<String> get recheckStreets =>
      {for (final s in steps) if (s.role == StepRole.recheck) s.streetId};

  double _elevMax() {
    var m = -99999.0;
    for (final s in steps) {
      if (s.elevStart > m) m = s.elevStart.toDouble();
      if (s.elevEnd > m) m = s.elevEnd.toDouble();
    }
    return m;
  }

  double _elevMin() {
    var m = 99999.0;
    for (final s in steps) {
      if (s.elevStart < m) m = s.elevStart.toDouble();
      if (s.elevEnd < m) m = s.elevEnd.toDouble();
    }
    return m;
  }

  /// Une varias rutas por-sector en una sola, en un orden razonable. En zonas
  /// con desnivel arranca por el sector más alto (para ir cerro-abajo); si no,
  /// encadena por cercanía. Entre sectores mete un enlace recto (la app, al
  /// verse lejos de ese enlace, recalcula el trayecto real por calles).
  static CoverageRoute merge(List<CoverageRoute> parts) {
    parts = parts.where((p) => p.steps.isNotEmpty).toList();
    if (parts.isEmpty) {
      throw StateError('sin rutas para unir');
    }
    if (parts.length == 1) return parts.first;

    final relief = parts.map((p) => p._elevMax()).reduce((a, b) => a > b ? a : b) -
        parts.map((p) => p._elevMin()).reduce((a, b) => a < b ? a : b);
    final downhill = relief > 25;

    var ordered = <CoverageRoute>[];
    if (downhill) {
      ordered = [...parts]
        ..sort((a, b) => b._elevMax().compareTo(a._elevMax()));
    } else {
      // vecino más cercano, probando cada sector como arranque: antes se
      // arrancaba siempre por el de código menor y los enlaces entre
      // sectores salían más largos de lo necesario
      var bestLen = double.infinity;
      for (var s = 0; s < parts.length; s++) {
        final pool = [...parts];
        final cand = [pool.removeAt(s)];
        var len = 0.0;
        while (pool.isNotEmpty) {
          final end = cand.last.steps.last.end;
          var bi = 0;
          var bd = double.infinity;
          for (var i = 0; i < pool.length; i++) {
            final d = distMeters(end, pool[i].steps.first.start);
            if (d < bd) {
              bd = d;
              bi = i;
            }
          }
          len += bd;
          cand.add(pool.removeAt(bi));
        }
        if (len < bestLen) {
          bestLen = len;
          ordered = cand;
        }
      }
    }

    final merged = <RouteStep>[];
    var seq = 0;
    var total = 0.0, cover = 0.0, recheck = 0.0;
    final coverSeen = <String>{}, recheckSeen = <String>{};
    for (var pi = 0; pi < ordered.length; pi++) {
      final part = ordered[pi];
      if (pi > 0) {
        final from = merged.last.end;
        final to = part.steps.first.start;
        final d = distMeters(from, to);
        if (d > 5) {
          merged.add(RouteStep(
            seq: seq++,
            streetId: 'xlink-$pi',
            name: '',
            lengthM: d,
            role: StepRole.link,
            maneuver: 'continue',
            instruction: 'Avanza al siguiente sector',
            elevStart: merged.last.elevEnd,
            elevEnd: part.steps.first.elevStart,
            coords: [from, to],
          ));
          total += d;
        }
      }
      for (final s in part.steps) {
        merged.add(RouteStep(
          seq: seq++,
          streetId: s.streetId,
          name: s.name,
          lengthM: s.lengthM,
          role: s.role,
          maneuver: s.maneuver,
          instruction: s.instruction,
          elevStart: s.elevStart,
          elevEnd: s.elevEnd,
          coords: s.coords,
        ));
        total += s.lengthM;
        if (s.role == StepRole.cover && coverSeen.add(s.streetId)) {
          cover += s.lengthM;
        } else if (s.role == StepRole.recheck && recheckSeen.add(s.streetId)) {
          recheck += s.lengthM;
        }
      }
    }

    final codes = <String>[for (final p in parts) ...p.sectorCodes];
    return CoverageRoute(
      sectorCodes: codes,
      mode: parts.first.mode,
      zone: parts.first.zone,
      totalLengthM: total,
      coverLengthM: cover,
      recheckLengthM: recheck,
      steps: merged,
    );
  }
}

/// Sector catastral (polígono para la UI de selección).
class Sector {
  final String code;
  final String name;
  final String zone;
  final String zoneName;
  final List<List<LatLng>> rings;

  Sector({
    required this.code,
    required this.name,
    required this.zone,
    required this.zoneName,
    required this.rings,
  });

  static List<Sector> listFromGeoJson(String raw) {
    final j = json.decode(raw) as Map<String, dynamic>;
    final out = <Sector>[];
    for (final f in (j['features'] as List)) {
      final p = f['properties'] as Map<String, dynamic>;
      final g = f['geometry'] as Map<String, dynamic>;
      final rings = <List<LatLng>>[];
      final polys =
          g['type'] == 'MultiPolygon' ? g['coordinates'] as List : [g['coordinates']];
      for (final poly in polys) {
        for (final ring in (poly as List)) {
          rings.add((ring as List)
              .map<LatLng>((c) =>
                  LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
              .toList());
        }
      }
      out.add(Sector(
        code: p['code'] as String,
        name: p['name'] as String,
        zone: (p['zone'] ?? '1') as String,
        zoneName: (p['zone_name'] ?? 'Zona') as String,
        rings: rings,
      ));
    }
    out.sort((a, b) => a.code.compareTo(b.code));
    return out;
  }
}

/// Nombre de archivo de ruta para una combinación de sectores y modo.
String routeAssetName(List<String> codes, String mode) {
  final sorted = [...codes]..sort();
  return 'assets/routes/route_${sorted.join('-')}_$mode.geojson';
}

/// Estadísticas precalculadas de cada ruta (assets/routes_index.json).
class RouteStats {
  final double totalM;
  final double coverM;
  final double recheckM;
  final int steps;
  final int streets;

  RouteStats({
    required this.totalM,
    required this.coverM,
    required this.recheckM,
    required this.steps,
    required this.streets,
  });

  Duration estimate(String mode) {
    final kmh = mode == 'walk' ? 4.0 : 12.0;
    return Duration(minutes: (totalM / 1000 / kmh * 60).round());
  }

  static Map<String, RouteStats> mapFromJson(String raw) {
    final j = json.decode(raw) as Map<String, dynamic>;
    return j.map((k, v) => MapEntry(
        k,
        RouteStats(
          totalM: ((v['total_m'] ?? 0) as num).toDouble(),
          coverM: ((v['cover_m'] ?? v['unique_m'] ?? 0) as num).toDouble(),
          recheckM: ((v['recheck_m'] ?? 0) as num).toDouble(),
          steps: ((v['steps'] ?? 0) as num).toInt(),
          streets: ((v['streets'] ?? 0) as num).toInt(),
        )));
  }
}

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '${h}h ${m}min' : '${m}min';
}
