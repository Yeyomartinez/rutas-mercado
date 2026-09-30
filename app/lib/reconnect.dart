import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'google_routing.dart';
import 'models.dart';

/// Calcula caminos de reconexión LEGALES desde la posición del usuario
/// hasta el inicio del tramo objetivo, cuando se desvía de la ruta.
///
/// Estrategia:
///  1. OSRM online (respeta sentidos y restricciones de giro, cubre calles
///     fuera del sector). Siempre hay internet en campo.
///  2. Grafo interno construido con los propios tramos de la ruta (dirigido
///     en modo vehículo) — funciona sin red.
///  3. Línea recta como último recurso (solo indicativa).
class ReconnectService {
  final CoverageRoute route;

  /// Clave de Google Routes API (si el usuario la configuró):
  /// se usa como enrutador principal.
  String googleApiKey = '';

  /// Grafo interno: nodo (clave cuantizada) -> lista de (nodoDestino, largo, coords)
  final Map<String, List<(String, double, List<LatLng>)>> _adj = {};
  final Map<String, LatLng> _nodePos = {};

  ReconnectService(this.route) {
    _buildGraph();
  }

  static String _key(LatLng p) =>
      '${(p.latitude * 1e5).round()},${(p.longitude * 1e5).round()}';

  void _buildGraph() {
    for (final s in route.steps) {
      final a = _key(s.start), b = _key(s.end);
      _nodePos[a] = s.start;
      _nodePos[b] = s.end;
      _adj.putIfAbsent(a, () => []).add((b, s.lengthM, s.coords));
      if (route.mode == 'walk') {
        _adj
            .putIfAbsent(b, () => [])
            .add((a, s.lengthM, s.coords.reversed.toList()));
      }
    }
  }

  /// Camino de reconexión hasta el inicio de [target].
  /// Devuelve la polilínea a seguir, o null si no se pudo calcular
  /// (el llamador dibuja línea recta).
  ///
  /// Orden de preferencia:
  ///  1. Google Routes API (si hay clave) — calidad Google Maps/Waze.
  ///  2. A pie: grafo interno. En vehículo: OSRM y luego grafo interno.
  ///  3. Línea recta (el llamador la dibuja al recibir null).
  Future<List<LatLng>?> reconnect(LatLng from, RouteStep target) async {
    final google = await GoogleRouting.computeRoute(
        from, target.start, route.mode, googleApiKey);
    if (google != null && _sane(from, target.start, google)) {
      return google;
    }
    if (route.mode == 'walk') {
      return _tryInternal(from, target.start);
    }
    final osrm = await _tryOsrm(from, target.start);
    if (osrm != null && osrm.length >= 2 && _sane(from, target.start, osrm)) {
      return osrm;
    }
    return _tryInternal(from, target.start);
  }

  /// Rechaza rutas de reconexión absurdas (p. ej. el enrutador se fue
  /// a dar una vuelta gigante por datos raros).
  bool _sane(LatLng from, LatLng to, List<LatLng> line) {
    final straight = distMeters(from, to);
    var len = 0.0;
    for (var i = 0; i < line.length - 1; i++) {
      len += distMeters(line[i], line[i + 1]);
    }
    final cap = math.max(4000.0, straight * 5);
    return len <= cap;
  }

  Future<List<LatLng>?> _tryOsrm(LatLng from, LatLng to) async {
    final profile = route.mode == 'walk' ? 'foot' : 'driving';
    final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/$profile/'
        '${from.longitude},${from.latitude};${to.longitude},${to.latitude}'
        '?overview=full&geometries=geojson&steps=false');
    // se cierra en finally: antes una respuesta != 200 o un timeout dejaban
    // la conexión abierta
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(url);
      req.headers.set('User-Agent', 'mercado-rutas/1.2');
      final res = await req.close().timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final j = json.decode(body) as Map<String, dynamic>;
      if (j['code'] != 'Ok') return null;
      final coords =
          (((j['routes'] as List).first)['geometry']['coordinates'] as List);
      final line = coords
          .map<LatLng>((c) =>
              LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();
      // sanity: si OSRM devuelve algo absurdo (>6x la distancia recta), descartar
      final straight = distMeters(from, to);
      var len = 0.0;
      for (var i = 0; i < line.length - 1; i++) {
        len += distMeters(line[i], line[i + 1]);
      }
      if (straight > 100 && len > straight * 8) return null;
      return line;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  List<LatLng>? _tryInternal(LatLng from, LatLng to) {
    if (_adj.isEmpty) return null;
    // nodo de arranque: el más cercano a la posición (máx 80 m)
    String? startKey;
    var bestD = 80.0;
    for (final e in _nodePos.entries) {
      final d = distMeters(from, e.value);
      if (d < bestD) {
        bestD = d;
        startKey = e.key;
      }
    }
    final goalKey = _key(to);
    if (startKey == null || !_nodePos.containsKey(goalKey)) return null;

    // Dijkstra
    final dist = <String, double>{startKey: 0};
    final prevEdge = <String, (String, List<LatLng>)>{};
    final visited = <String>{};
    final queue = <(double, String)>[(0.0, startKey)];
    while (queue.isNotEmpty) {
      queue.sort((a, b) => a.$1.compareTo(b.$1));
      final (d, u) = queue.removeAt(0);
      if (visited.contains(u)) continue;
      visited.add(u);
      if (u == goalKey) break;
      for (final (v, w, coords)
          in _adj[u] ?? const <(String, double, List<LatLng>)>[]) {
        final nd = d + w;
        if (nd < (dist[v] ?? double.infinity)) {
          dist[v] = nd;
          prevEdge[v] = (u, coords);
          queue.add((nd, v));
        }
      }
    }
    if (!dist.containsKey(goalKey)) return null;
    // reconstruir polilínea
    final segs = <List<LatLng>>[];
    var cur = goalKey;
    while (cur != startKey) {
      final pe = prevEdge[cur];
      if (pe == null) return null;
      segs.insert(0, pe.$2);
      cur = pe.$1;
    }
    final line = <LatLng>[from];
    for (final s in segs) {
      line.addAll(s);
    }
    return line;
  }
}

/// Distancia restante a lo largo de una polilínea desde el punto más cercano
/// al usuario hasta el final.
double remainingOnLine(LatLng p, List<LatLng> line) {
  if (line.length < 2) return 0;
  final f = fractionAlong(p, line);
  var total = 0.0;
  for (var i = 0; i < line.length - 1; i++) {
    total += distMeters(line[i], line[i + 1]);
  }
  return math.max(0, total * (1 - f));
}
