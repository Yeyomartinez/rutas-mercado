import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Enrutamiento con Google Routes API (calidad Google Maps/Waze) para las
/// reconexiones a la ruta. La clave la pone el usuario una sola vez en la
/// pantalla inicial (o se empaqueta en assets/google_api_key.txt).
class GoogleRouting {
  static const _prefsKey = 'google_api_key';

  static Future<String> loadKey() async {
    final prefs = await SharedPreferences.getInstance();
    final k = (prefs.getString(_prefsKey) ?? '').trim();
    if (k.isNotEmpty) return k;
    try {
      final a = (await rootBundle.loadString('assets/google_api_key.txt')).trim();
      if (a.startsWith('AIza')) return a;
    } catch (_) {}
    return '';
  }

  static Future<void> saveKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, key.trim());
  }

  /// Ruta legal de [from] a [to]. mode: 'walk' o 'drive'.
  /// Devuelve la polilínea o null si falla (clave vacía, sin red, error).
  static Future<List<LatLng>?> computeRoute(
      LatLng from, LatLng to, String mode, String key) async {
    if (key.isEmpty) return null;
    final body = json.encode({
      'origin': {
        'location': {
          'latLng': {'latitude': from.latitude, 'longitude': from.longitude}
        }
      },
      'destination': {
        'location': {
          'latLng': {'latitude': to.latitude, 'longitude': to.longitude}
        }
      },
      'travelMode': mode == 'walk' ? 'WALK' : 'DRIVE',
    });
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client
          .postUrl(Uri.parse(
              'https://routes.googleapis.com/directions/v2:computeRoutes'))
          .timeout(const Duration(seconds: 6));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('X-Goog-Api-Key', key);
      req.headers.set('X-Goog-FieldMask',
          'routes.polyline.encodedPolyline,routes.distanceMeters');
      req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      final j = json.decode(text) as Map<String, dynamic>;
      final routes = j['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;
      final enc = routes.first['polyline']?['encodedPolyline'] as String?;
      if (enc == null) return null;
      final line = decodePolyline(enc);
      return line.length >= 2 ? line : null;
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }

  /// Prueba rápida de la clave (una ruta corta fija en la zona).
  /// Devuelve null si funciona, o el mensaje de error.
  static Future<String?> testKey(String key) async {
    if (!key.trim().startsWith('AIza')) {
      return 'La clave no parece válida (debe empezar por AIza...)';
    }
    final r = await computeRoute(const LatLng(4.7000, -74.1000),
        const LatLng(4.7050, -74.0950), 'drive', key.trim());
    if (r == null) {
      return 'Google rechazó la clave o falta habilitar "Routes API" en el proyecto';
    }
    return null;
  }

  /// Decodifica el formato de polilínea codificada de Google.
  static List<LatLng> decodePolyline(String encoded) {
    final points = <LatLng>[];
    var index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      int shift = 0, result = 0, b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }
}
