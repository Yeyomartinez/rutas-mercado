import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const double _mPerDegLat = 110540.0;

/// Distancia en metros entre dos puntos (aproximación local, suficiente
/// para distancias urbanas cortas).
double distMeters(LatLng a, LatLng b) {
  final mPerDegLon = 111320.0 * math.cos(a.latitude * math.pi / 180);
  final dx = (b.longitude - a.longitude) * mPerDegLon;
  final dy = (b.latitude - a.latitude) * _mPerDegLat;
  return math.sqrt(dx * dx + dy * dy);
}

/// Distancia mínima en metros de un punto a una polilínea.
double distToPolyline(LatLng p, List<LatLng> line) {
  var best = double.infinity;
  for (var i = 0; i < line.length - 1; i++) {
    final d = _distToSegment(p, line[i], line[i + 1]);
    if (d < best) best = d;
  }
  return best;
}

double _distToSegment(LatLng p, LatLng a, LatLng b) {
  final mPerDegLon = 111320.0 * math.cos(p.latitude * math.pi / 180);
  final ax = (a.longitude - p.longitude) * mPerDegLon;
  final ay = (a.latitude - p.latitude) * _mPerDegLat;
  final bx = (b.longitude - p.longitude) * mPerDegLon;
  final by = (b.latitude - p.latitude) * _mPerDegLat;
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  double t = len2 == 0 ? 0 : (-(ax * dx + ay * dy)) / len2;
  t = t.clamp(0.0, 1.0);
  final cx = ax + t * dx, cy = ay + t * dy;
  return math.sqrt(cx * cx + cy * cy);
}

/// Rumbo geográfico en grados (0=Norte, 90=Este) de a hacia b.
double bearingDeg(LatLng a, LatLng b) {
  final mPerDegLon = 111320.0 * math.cos(a.latitude * math.pi / 180);
  final dx = (b.longitude - a.longitude) * mPerDegLon;
  final dy = (b.latitude - a.latitude) * _mPerDegLat;
  return (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
}

/// Punto de la polilínea más cercano a p.
LatLng nearestPointOnPolyline(LatLng p, List<LatLng> line) {
  var best = double.infinity;
  var bestPt = line.first;
  for (var i = 0; i < line.length - 1; i++) {
    final t = _projT(p, line[i], line[i + 1]);
    final pt = LatLng(
      line[i].latitude + t * (line[i + 1].latitude - line[i].latitude),
      line[i].longitude + t * (line[i + 1].longitude - line[i].longitude),
    );
    final d = distMeters(p, pt);
    if (d < best) {
      best = d;
      bestPt = pt;
    }
  }
  return bestPt;
}

/// Punto a una fracción f [0,1] del largo de la polilínea, y el rumbo local ahí.
(LatLng, double) pointAlong(List<LatLng> line, double f) {
  var total = 0.0;
  for (var i = 0; i < line.length - 1; i++) {
    total += distMeters(line[i], line[i + 1]);
  }
  if (total == 0) return (line.first, 0);
  var target = total * f.clamp(0.0, 1.0);
  for (var i = 0; i < line.length - 1; i++) {
    final seg = distMeters(line[i], line[i + 1]);
    if (target <= seg || i == line.length - 2) {
      final t = seg == 0 ? 0.0 : (target / seg).clamp(0.0, 1.0);
      final pt = LatLng(
        line[i].latitude + t * (line[i + 1].latitude - line[i].latitude),
        line[i].longitude + t * (line[i + 1].longitude - line[i].longitude),
      );
      return (pt, bearingDeg(line[i], line[i + 1]));
    }
    target -= seg;
  }
  return (line.last, bearingDeg(line[line.length - 2], line.last));
}

/// Fracción [0,1] del recorrido de la polilínea ya superada por el punto
/// (proyección del punto sobre la línea).
double fractionAlong(LatLng p, List<LatLng> line) {
  var bestDist = double.infinity;
  var bestAcc = 0.0;
  var acc = 0.0;
  var total = 0.0;
  for (var i = 0; i < line.length - 1; i++) {
    total += distMeters(line[i], line[i + 1]);
  }
  if (total == 0) return 1.0;
  for (var i = 0; i < line.length - 1; i++) {
    final segLen = distMeters(line[i], line[i + 1]);
    final d = _distToSegment(p, line[i], line[i + 1]);
    if (d < bestDist) {
      bestDist = d;
      final tProj = _projT(p, line[i], line[i + 1]);
      bestAcc = acc + segLen * tProj;
    }
    acc += segLen;
  }
  return (bestAcc / total).clamp(0.0, 1.0);
}

double _projT(LatLng p, LatLng a, LatLng b) {
  final mPerDegLon = 111320.0 * math.cos(p.latitude * math.pi / 180);
  final ax = (a.longitude - p.longitude) * mPerDegLon;
  final ay = (a.latitude - p.latitude) * _mPerDegLat;
  final bx = (b.longitude - p.longitude) * mPerDegLon;
  final by = (b.latitude - p.latitude) * _mPerDegLat;
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) return 0;
  return ((-(ax * dx + ay * dy)) / len2).clamp(0.0, 1.0);
}
