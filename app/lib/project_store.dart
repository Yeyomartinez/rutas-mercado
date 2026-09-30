import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offers.dart';

/// Un proyecto = un mercado (p. ej. "Mercado 3"). Toda la jornada de ese
/// mercado se consolida aquí: ofertas con numeración continua y progreso de
/// calles cubiertas, compartido entre todos los sectores del mercado.
///
/// Antes esto se guardaba por RUTA (combinación de sectores), lo que hacía
/// que la numeración de ofertas "saltara" al cambiar de predio y que el
/// avance de un sector no se sumara al elegir uno aledaño. Ahora todo vive a
/// nivel de proyecto y esos dos bugs desaparecen.
class ProjectStore {
  final String projectId; // = id de zona/mercado ("1", "2", "3")
  ProjectStore(this.projectId);

  String get _offersKey => 'proj_${projectId}_offers';
  String get _counterKey => 'proj_${projectId}_counter';
  String get _coveredKey => 'proj_${projectId}_covered';
  String get _recheckKey => 'proj_${projectId}_recheck';
  String _idxKey(String routeKey) => 'proj_${projectId}_idx_$routeKey';

  // ---------------- Ofertas ----------------

  Future<List<Offer>> loadOffers() async {
    final prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(_offersKey));
  }

  Future<void> saveOffers(List<Offer> offers) async {
    final prefs = await SharedPreferences.getInstance();
    offers.sort((a, b) => a.number.compareTo(b.number));
    await prefs.setString(
        _offersKey, json.encode(offers.map((o) => o.toJson()).toList()));
  }

  /// Próximo número SIN consumirlo (para mostrar en el botón).
  Future<int> peekNextNumber() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_counterKey) ?? 0) + 1;
  }

  /// Consume y devuelve el próximo número (correlativo, nunca se reutiliza).
  Future<int> takeNextNumber() async {
    final prefs = await SharedPreferences.getInstance();
    final n = (prefs.getInt(_counterKey) ?? 0) + 1;
    await prefs.setInt(_counterKey, n);
    return n;
  }

  // ---------------- Progreso (calles cubiertas del mercado) ----------------

  Future<Set<String>> loadCovered() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeStrs(prefs.getString(_coveredKey));
  }

  Future<Set<String>> loadRecheckDone() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeStrs(prefs.getString(_recheckKey));
  }

  Future<void> saveProgress(Set<String> covered, Set<String> recheckDone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_coveredKey, json.encode(covered.toList()));
    await prefs.setString(_recheckKey, json.encode(recheckDone.toList()));
  }

  Future<int> loadStepIndex(String routeKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_idxKey(routeKey)) ?? 0;
  }

  Future<void> saveStepIndex(String routeKey, int idx) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_idxKey(routeKey), idx);
  }

  /// Borra SOLO el avance de recorrido (mantiene las ofertas).
  Future<void> clearProgress() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_coveredKey);
    await prefs.remove(_recheckKey);
    for (final k in prefs.getKeys().toList()) {
      if (k.startsWith('proj_${projectId}_idx_')) await prefs.remove(k);
    }
  }

  /// Borra TODO el proyecto (avance + ofertas + contador).
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().toList()) {
      if (k.startsWith('proj_${projectId}_')) await prefs.remove(k);
    }
  }

  static List<Offer> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (json.decode(raw) as List)
          .map((e) => Offer.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Set<String> _decodeStrs(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return (json.decode(raw) as List).cast<String>().toSet();
    } catch (_) {
      return {};
    }
  }
}

/// Índice de calles por sector (assets/sectors_streets.json), para calcular
/// el % de avance de cada sector y del mercado completo a partir del conjunto
/// de calles cubiertas del proyecto.
class SectorStreets {
  final Map<String, Set<String>> _byCode;
  SectorStreets(this._byCode);

  static SectorStreets fromJson(String raw) {
    final j = json.decode(raw) as Map<String, dynamic>;
    return SectorStreets(j.map((k, v) =>
        MapEntry(k, (v as List).cast<String>().toSet())));
  }

  Set<String> streetsOf(String code) => _byCode[code] ?? const {};

  /// % de un sector cubierto según el conjunto global del proyecto.
  double sectorPct(String code, Set<String> covered) {
    final s = _byCode[code];
    if (s == null || s.isEmpty) return 0;
    var n = 0;
    for (final id in s) {
      if (covered.contains(id)) n++;
    }
    return n / s.length;
  }

  /// Total de calles únicas de un conjunto de sectores.
  Set<String> union(Iterable<String> codes) {
    final u = <String>{};
    for (final c in codes) {
      u.addAll(_byCode[c] ?? const {});
    }
    return u;
  }
}

/// Punto más cercano de una lista de sectores a una posición (para etiquetar
/// una oferta con el sector donde se tomó, si hace falta).
String? nearestSectorCode(LatLng p, Map<String, List<List<LatLng>>> rings) {
  return null; // reservado; hoy no se usa
}
