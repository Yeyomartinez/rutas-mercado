import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mercado_rutas/geo.dart';
import 'package:mercado_rutas/models.dart';

/// Revisa las rutas empaquetadas en assets/ después de correr el pipeline:
/// que la app las lea, que no tengan saltos y que cuadren con los índices.
void main() {
  final index = json.decode(File('assets/routes_index.json').readAsStringSync())
      as Map<String, dynamic>;
  final streets =
      json.decode(File('assets/sectors_streets.json').readAsStringSync())
          as Map<String, dynamic>;

  CoverageRoute load(String name) => CoverageRoute.fromGeoJson(
      File('assets/routes/$name').readAsStringSync());

  test('cada ruta del índice existe, se lee y no tiene saltos', () {
    for (final name in index.keys) {
      final r = load(name);
      expect(r.steps, isNotEmpty, reason: name);
      for (var i = 0; i + 1 < r.steps.length; i++) {
        final gap = distMeters(r.steps[i].end, r.steps[i + 1].start);
        expect(gap, lessThan(3), reason: '$name, tramo ${r.steps[i].seq}');
      }
      final st = index[name] as Map<String, dynamic>;
      expect(r.steps.length, st['steps'], reason: name);
    }
  });

  test('las calles que cuentan son las del sector', () {
    for (final name in index.keys) {
      final st = index[name] as Map<String, dynamic>;
      final code = (st['sectors'] as List).single as String;
      final known = (streets[code] as List).cast<String>().toSet();
      final cover = load(name).coverStreetLengths.keys.toSet();
      expect(known.containsAll(cover), isTrue, reason: name);
    }
  });

  test('unir sectores de una zona no pierde calles', () {
    final byZone = <String, List<String>>{};
    index.forEach((name, v) {
      if ((v as Map)['mode'] == 'drive') {
        byZone.putIfAbsent(v['zone'] as String, () => []).add(name);
      }
    });
    for (final names in byZone.values) {
      final parts = names.map(load).toList();
      final merged = CoverageRoute.merge(parts);
      final expected = <String>{
        for (final p in parts) ...p.coverStreetLengths.keys
      };
      expect(merged.coverStreetLengths.keys.toSet(), expected);
    }
  });
}
