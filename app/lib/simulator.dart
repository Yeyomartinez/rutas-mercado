import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'models.dart';

/// Conductor virtual: recorre la ruta como si fuera una persona en la calle,
/// para poder probar la app sin salir (modo simulación).
class RouteSimulator {
  final List<LatLng> path = [];
  final List<double> cum = [0];
  double cursorM = 0;
  double lateralM = 0; // desviación lateral forzada (para probar recálculo)
  double speedKmh;
  bool running = true;

  RouteSimulator(List<RouteStep> steps, {this.speedKmh = 20}) {
    for (final s in steps) {
      for (final p in s.coords) {
        if (path.isEmpty || distMeters(path.last, p) > 0.5) {
          if (path.isNotEmpty) {
            cum.add(cum.last + distMeters(path.last, p));
          }
          path.add(p);
        }
      }
    }
  }

  double get totalM => cum.isEmpty ? 0 : cum.last;
  bool get finished => cursorM >= totalM;
  double get progress => totalM == 0 ? 0 : (cursorM / totalM).clamp(0.0, 1.0);

  void advance(double seconds) {
    if (!running || path.length < 2) return;
    cursorM = (cursorM + speedKmh / 3.6 * seconds).clamp(0.0, totalM);
  }

  /// Salta hacia adelante o atrás (metros).
  void jump(double meters) {
    cursorM = (cursorM + meters).clamp(0.0, totalM);
  }

  int _segmentAt(double m) {
    var lo = 0, hi = cum.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (cum[mid] < m) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return (lo - 1).clamp(0, path.length - 2);
  }

  LatLng get position {
    if (path.isEmpty) return const LatLng(0, 0);
    if (path.length == 1) return path.first;
    final i = _segmentAt(cursorM);
    final segLen = cum[i + 1] - cum[i];
    final t = segLen == 0 ? 0.0 : ((cursorM - cum[i]) / segLen).clamp(0.0, 1.0);
    final base = LatLng(
      path[i].latitude + (path[i + 1].latitude - path[i].latitude) * t,
      path[i].longitude + (path[i + 1].longitude - path[i].longitude) * t,
    );
    if (lateralM == 0) return base;
    // desplazar perpendicular al rumbo para simular que te saliste de la ruta
    final perp = (heading + 90) * math.pi / 180;
    const mPerDegLat = 110540.0;
    final mPerDegLon = 111320.0 * math.cos(base.latitude * math.pi / 180);
    return LatLng(
      base.latitude + lateralM * math.cos(perp) / mPerDegLat,
      base.longitude + lateralM * math.sin(perp) / mPerDegLon,
    );
  }

  double get heading {
    if (path.length < 2) return 0;
    final i = _segmentAt(cursorM);
    return bearingDeg(path[i], path[i + 1]);
  }
}
