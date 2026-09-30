import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'export_offers.dart';
import 'geo.dart';
import 'google_routing.dart';
import 'models.dart';
import 'offers.dart';
import 'offers_screen.dart';
import 'project_store.dart';
import 'reconnect.dart';
import 'simulator.dart';

/// Paleta del mapa: tonos suaves y translúcidos para no tapar las calles.
const _kOrange = Color(0x99FFA726);      // tramo actual
const _kOrangeArrow = Color(0xCCFF9800); // flechas del tramo actual
const _kPending = Color(0x801E88E5);     // calles por cubrir
const _kDone = Color(0x409E9E9E);        // calles ya cubiertas
const _kLink = Color(0x669C8FA8);        // enlaces entre calles

/// El canal de la ventana flotante admite UN solo oyente en toda la app: si
/// cada pantalla de navegación se suscribía, al entrar por segunda vez
/// reventaba con "Stream has already been listened to".
class OverlayBus {
  static StreamSubscription? _sub;
  static void Function(Map event)? onEvent;

  static void ensureListening() {
    if (_sub != null) return;
    try {
      _sub = FlutterOverlayWindow.overlayListener.listen((e) {
        if (e is Map) onEvent?.call(e);
      });
    } catch (_) {
      _sub = null; // plataforma sin ventana flotante (navegador)
    }
  }
}

/// Calle vigilada por el barredor de cobertura.
class _SweepEdge {
  final String streetId;
  final List<LatLng> coords;
  final double lengthM;
  final double minLat, maxLat, minLon, maxLon;

  _SweepEdge(this.streetId, this.coords, this.lengthM)
      : minLat = coords.map((p) => p.latitude).reduce(math.min),
        maxLat = coords.map((p) => p.latitude).reduce(math.max),
        minLon = coords.map((p) => p.longitude).reduce(math.min),
        maxLon = coords.map((p) => p.longitude).reduce(math.max);
}

class _EdgeTrack {
  double minF = 1.0, maxF = 0.0;
  int fixes = 0;
  DateTime last = DateTime.now();
}

class NavigationScreen extends StatefulWidget {
  final CoverageRoute route;
  final String routeKey;
  final String projectId;   // = mercado/zona; agrupa ofertas y progreso
  final String projectName;
  final List<Sector> sectors;

  /// Modo simulación: en vez del GPS real, un conductor virtual recorre la
  /// ruta. Sirve para probar toda la app sin salir a la calle.
  final bool simulate;

  const NavigationScreen({
    super.key,
    required this.route,
    required this.routeKey,
    required this.projectId,
    required this.projectName,
    required this.sectors,
    this.simulate = false,
  });

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final MapController _map = MapController();
  final FlutterTts _tts = FlutterTts();
  late final ProjectStore _store = ProjectStore(widget.projectId);
  late final ReconnectService _reconnectSvc = ReconnectService(widget.route);

  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;
  Timer? _simTimer;
  RouteSimulator? _sim;

  // Capas cacheadas: reconstruirlas en cada fix del GPS congelaba la app
  // en rutas grandes (hasta 2500 tramos).
  List<Polyline<Object>>? _cachedLines;
  List<Marker>? _cachedArrows;
  String _layerKey = '';
  LatLng? _pos;
  double _gpsHeading = 0;
  double? _compassHeading;
  double _speedKmh = 0;
  double _accuracy = 0;
  bool _firstFix = true;

  int _idx = 0;
  final Set<String> _covered = {};      // calles del mercado ya cubiertas
  final Set<String> _recheckDone = {};  // segundas pasadas hechas
  final List<Offer> _offers = [];       // ofertas del mercado (todas)
  int _nextOfferNum = 1;                // número continuo del proyecto

  late final Map<String, double> _coverLengths = widget.route.coverStreetLengths;
  late final List<_SweepEdge> _sweepEdges = _buildSweepEdges();
  final Map<String, _EdgeTrack> _tracks = {};

  bool _follow = true;
  bool _headingUp = true;
  bool _voiceOn = true;
  bool _announcedNext = false;
  bool _overlayOn = false;
  bool _showAllRoute = false;
  int _offRouteCount = 0;
  int _onStepFixes = 0;
  DateTime _lastSave = DateTime.now();
  DateTime _lastOffRouteAlert = DateTime.fromMillisecondsSinceEpoch(0);
  String _gpsStatus = 'Esperando señal GPS…';

  List<LatLng>? _reconnectLine;
  /// true solo cuando la línea sirve para REGRESAR al sector (línea verde).
  /// Dentro del sector la app replanifica sola y el enlace va discreto.
  bool _reconnectIsReturn = false;
  bool _reconnecting = false;
  DateTime _lastReconnectCalc = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastReconnectVoice = DateTime.fromMillisecondsSinceEpoch(0);
  int _reconnectDriftCount = 0;

  double get _arriveThreshold => widget.route.mode == 'walk' ? 18 : 25;
  double get _baseZoom => widget.route.mode == 'walk' ? 18 : 17;

  List<RouteStep> get _steps => widget.route.steps;
  RouteStep? get _current => _idx < _steps.length ? _steps[_idx] : null;

  double get _heading =>
      (_speedKmh < 4 && _compassHeading != null) ? _compassHeading! : _gpsHeading;

  List<_SweepEdge> _buildSweepEdges() {
    final seen = <String>{};
    final out = <_SweepEdge>[];
    for (final s in widget.route.steps) {
      if (!s.counts || seen.contains(s.streetId)) continue;
      seen.add(s.streetId);
      out.add(_SweepEdge(s.streetId, s.coords, s.lengthM));
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    try {
      WakelockPlus.enable();
    } catch (_) {}
    _initTts();
    _restoreProgress();
    _initGps();
    _initCompass();
    _initOverlayChannel();
    GoogleRouting.loadKey().then((k) => _reconnectSvc.googleApiKey = k);
  }

  @override
  void dispose() {
    _simTimer?.cancel();
    _posSub?.cancel();
    _compassSub?.cancel();
    // el oyente de la burbuja es global y se deja vivo; solo se suelta el
    // manejador de esta pantalla
    if (OverlayBus.onEvent == _onOverlayEvent) OverlayBus.onEvent = null;
    try {
      FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
    try {
      _tts.stop();
      WakelockPlus.disable();
    } catch (_) {}
    _persist(force: true);
    super.dispose();
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('es-CO');
    } catch (_) {
      try {
        await _tts.setLanguage('es-ES');
      } catch (_) {}
    }
    await _tts.setSpeechRate(0.55);
  }

  // -------------------------------------------------------------------
  // Ventana flotante
  // -------------------------------------------------------------------

  void _initOverlayChannel() {
    OverlayBus.onEvent = _onOverlayEvent;
    OverlayBus.ensureListening();
  }

  Future<void> _onOverlayEvent(Map event) async {
    if (!mounted) return;
    switch (event['action']) {
      case 'offer':
        await _addOffer(fromOverlay: true);
        break;
      case 'open':
      case 'hello':
        _pushOverlayState();
        break;
    }
  }

  Future<void> _toggleOverlay() async {
    try {
      await _toggleOverlayImpl();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('La ventana flotante solo funciona en el teléfono')));
      }
    }
  }

  Future<void> _toggleOverlayImpl() async {
    if (_overlayOn) {
      await FlutterOverlayWindow.closeOverlay();
      setState(() => _overlayOn = false);
      return;
    }
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!granted) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Permiso de ventana flotante'),
          content: const Text(
              'Para marcar ofertas sin salir de la cámara, Android pedirá el '
              'permiso "Mostrar sobre otras aplicaciones". Actívalo para '
              'Rutas Mercado y vuelve.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Ir a Ajustes')),
          ],
        ),
      );
      if (ok != true) return;
      await FlutterOverlayWindow.requestPermission();
      if (!await FlutterOverlayWindow.isPermissionGranted()) return;
    }
    await FlutterOverlayWindow.showOverlay(
      enableDrag: true,
      overlayTitle: 'Rutas Mercado',
      overlayContent: 'Marcando ofertas',
      flag: OverlayFlag.defaultFlag,
      alignment: OverlayAlignment.topCenter,
      visibility: NotificationVisibility.visibilityPublic,
      height: 190,
      width: WindowSize.matchParent,
    );
    if (mounted) setState(() => _overlayOn = true);
    _pushOverlayState();
  }

  void _pushOverlayState() {
    if (!_overlayOn) return;
    try {
      _pushOverlayStateImpl();
    } catch (_) {}
  }

  void _pushOverlayStateImpl() {
    final cur = _current;
    final pct = (_progress * 100).toStringAsFixed(0);
    FlutterOverlayWindow.shareData({
      'count': _offers.length,
      'next': _nextOfferNum,
      'instr': cur == null ? 'Recorrido completo' : cur.instruction,
      'sub': 'Ofertas: ${_offers.length} · $pct% cubierto',
      'saved': true,
    });
  }

  // -------------------------------------------------------------------
  // Ofertas (chinchetas)
  // -------------------------------------------------------------------

  Future<void> _addOffer({bool fromOverlay = false}) async {
    final here = _pos;
    if (here == null) {
      if (!fromOverlay && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Sin señal GPS todavía: espera unos segundos')));
      }
      return;
    }
    final n = await _store.takeNextNumber();
    final offer = Offer(
      number: n,
      pos: here,
      time: DateTime.now(),
      street: _current?.name ?? '',
      accuracyM: _accuracy,
    );
    setState(() {
      _offers.add(offer);
      _nextOfferNum = n + 1;
    });
    await _store.saveOffers(_offers);
    HapticFeedback.mediumImpact();
    _speak('Oferta $n registrada');
    _pushOverlayState();
    if (!fromOverlay && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 3),
        content: Text('Oferta $n guardada  ·  ${offer.hora}'),
        action: SnackBarAction(
            label: 'NOTA', onPressed: () => _editOffer(offer)),
      ));
    }
  }

  Future<void> _editOffer(Offer o) async {
    final ctrl = TextEditingController(text: o.note);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Oferta ${o.number}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${o.fecha} ${o.hora}  ·  ±${o.accuracyM.toStringAsFixed(0)} m',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            if (o.street.isNotEmpty)
              Text(o.street, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Nota (local, producto, etc.)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, '__del__'),
            child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (res == null) return;
    if (res == '__del__') {
      setState(() => _offers.removeWhere((x) => x.number == o.number));
    } else {
      setState(() => o.note = res);
    }
    await _store.saveOffers(_offers);
    _pushOverlayState();
  }

  Future<void> _exportOffers() async {
    if (_offers.isEmpty) {
      _toast('Aún no hay ofertas en ${widget.projectName}');
      return;
    }
    _toast(await OfferExporter.shareShapefile(_offers, widget.projectName));
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
  }

  // -------------------------------------------------------------------
  // GPS / brújula
  // -------------------------------------------------------------------

  void _initCompass() {
    if (widget.simulate) return; // el rumbo lo da el conductor virtual
    Stream<CompassEvent>? stream;
    try {
      stream = FlutterCompass.events;
    } catch (_) {
      return;
    }
    if (stream == null) return;
    _compassSub = stream.listen((e) {
      if (e.heading == null) return;
      final h = (e.heading! + 360) % 360;
      final prev = _compassHeading ?? h;
      final delta = ((h - prev + 540) % 360) - 180;
      final smoothed = (prev + delta * 0.25 + 360) % 360;
      _compassHeading = smoothed;
      if (_follow && _headingUp && _speedKmh < 4 && _pos != null) {
        _map.moveAndRotate(_map.camera.center, _map.camera.zoom, -smoothed);
      }
      if (mounted) setState(() {});
    });
  }

  /// Carga el estado del MERCADO (proyecto): las ofertas y el avance de calles
  /// son compartidos por todos los sectores del mercado, así que al agregar un
  /// sector aledaño el progreso anterior ya viene cargado. No se pregunta nada:
  /// el avance persiste hasta que el usuario lo reinicie desde el menú.
  Future<void> _restoreProgress() async {
    _offers.addAll(await _store.loadOffers());
    _covered.addAll(await _store.loadCovered());
    _recheckDone.addAll(await _store.loadRecheckDone());
    _idx = (await _store.loadStepIndex(widget.routeKey))
        .clamp(0, _steps.length);
    _nextOfferNum = await _store.peekNextNumber();
    if (mounted) setState(() {});
  }

  // -------------------------------------------------------------------
  // Simulación
  // -------------------------------------------------------------------

  void _startSimulation() {
    _sim = RouteSimulator(_steps,
        speedKmh: widget.route.mode == 'walk' ? 5 : 20);
    setState(() => _gpsStatus = '');
    _simTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final s = _sim;
      if (s == null) return;
      s.advance(0.25);
      _handleFix(s.position, s.running ? s.speedKmh : 0, s.heading, 5);
    });
  }

  Widget _simPanel() {
    final s = _sim!;
    return Card(
      color: Colors.black87,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.science, color: Colors.amber, size: 18),
                const SizedBox(width: 6),
                Text(
                    'SIMULACIÓN  ${(s.progress * 100).toStringAsFixed(0)}%  ·  '
                    '${(s.cursorM / 1000).toStringAsFixed(2)}/'
                    '${(s.totalM / 1000).toStringAsFixed(1)} km',
                    style: const TextStyle(
                        color: Colors.amber,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(s.running ? Icons.pause : Icons.play_arrow,
                      color: Colors.white),
                  onPressed: () => setState(() => s.running = !s.running),
                ),
                for (final v in [10.0, 20.0, 60.0, 150.0])
                  TextButton(
                    style: TextButton.styleFrom(
                        minimumSize: const Size(34, 30),
                        padding: EdgeInsets.zero),
                    onPressed: () => setState(() => s.speedKmh = v),
                    child: Text('${v.toInt()}',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: s.speedKmh == v
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: s.speedKmh == v
                                ? Colors.amber
                                : Colors.white70)),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Desviarme 150 m',
                  icon: Icon(Icons.call_split,
                      color: s.lateralM != 0 ? Colors.redAccent : Colors.white),
                  onPressed: () =>
                      setState(() => s.lateralM = s.lateralM == 0 ? 150 : 0),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Adelantar 500 m',
                  icon: const Icon(Icons.fast_forward, color: Colors.white),
                  onPressed: () => setState(() => s.jump(500)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _initGps() async {
    if (widget.simulate) {
      _startSimulation();
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      setState(() =>
          _gpsStatus = 'Permiso de ubicación denegado. Actívalo en Ajustes.');
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _gpsStatus = 'Activa la ubicación (GPS) del teléfono');
      return;
    }
    _posSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        // mantiene el GPS vivo con la app en segundo plano (ventana flotante)
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Rutas Mercado',
          notificationText: 'Registrando el recorrido',
          enableWakeLock: true,
        ),
      ),
    ).listen(_onPosition);
    setState(() => _gpsStatus = 'Esperando señal GPS…');
  }

  void _onPosition(Position p) {
    _handleFix(
      LatLng(p.latitude, p.longitude),
      (p.speed.isFinite ? p.speed : 0) * 3.6,
      p.heading.isFinite && p.speed > 0.7 ? p.heading : null,
      p.accuracy.isFinite ? p.accuracy : 0,
    );
  }

  void _handleFix(LatLng here, double speedKmh, double? heading,
      double accuracy) {
    _speedKmh = speedKmh;
    _accuracy = accuracy;
    setState(() {
      _pos = here;
      if (heading != null) _gpsHeading = heading;
      _gpsStatus = '';
    });

    if (_firstFix) {
      _firstFix = false;
      _relocate(here, announce: false, force: true);
      final c = _current;
      if (c != null) {
        if (distToPolyline(here, c.coords) > 60) {
          _startReconnect(here, speakIntro: true);
        } else {
          _speak('Navegación iniciada. ${c.instruction}');
        }
      }
    }

    _moveCamera(here);
    _sweepCoverage(here);
    _updateNavigation(here);
  }

  void _moveCamera(LatLng here) {
    if (!_follow) return;
    var zoom = _baseZoom;
    if (_speedKmh > 25) {
      zoom -= 1.0;
    } else if (_speedKmh > 12) {
      zoom -= 0.5;
    }
    _map.moveAndRotate(here, zoom, _headingUp ? -_heading : 0);
  }

  /// Marca como cubierta cualquier calle que el usuario recorra de verdad,
  /// en el sentido que sea y sin importar el orden de la ruta.
  void _sweepCoverage(LatLng here) {
    const latPad = 30 / 110540.0;
    final lonPad = 30 / (111320.0 * math.cos(here.latitude * math.pi / 180));
    final now = DateTime.now();
    var changed = false;
    for (final e in _sweepEdges) {
      if (_covered.contains(e.streetId)) continue;
      if (here.latitude < e.minLat - latPad ||
          here.latitude > e.maxLat + latPad ||
          here.longitude < e.minLon - lonPad ||
          here.longitude > e.maxLon + lonPad) {
        continue;
      }
      if (distToPolyline(here, e.coords) > 15) continue;
      var t = _tracks[e.streetId];
      if (t == null || now.difference(t.last).inSeconds > 45) {
        t = _EdgeTrack();
        _tracks[e.streetId] = t;
      }
      final f = fractionAlong(here, e.coords);
      t.minF = math.min(t.minF, f);
      t.maxF = math.max(t.maxF, f);
      t.fixes++;
      t.last = now;

      final short = e.lengthM < 45;
      final enoughSpan = (t.maxF - t.minF) > (short ? 0.5 : 0.7);
      final enoughFixes = t.fixes >= (short ? 2 : 3);
      if (enoughSpan && enoughFixes) {
        _covered.add(e.streetId);
        _tracks.remove(e.streetId);
        changed = true;
      }
    }
    if (changed) {
      _persist();
      _pushOverlayState();
      setState(() {});
    }
  }

  // -------------------------------------------------------------------
  // Navegación
  // -------------------------------------------------------------------

  /// ¿La posición está dentro de la zona de estudio (los sectores elegidos)?
  bool _insideZone(LatLng p) {
    for (final s in widget.sectors) {
      for (final ring in s.rings) {
        if (_pointInRing(p, ring)) return true;
        // margen: las calles del borde cuentan como dentro
        if (distToPolyline(p, ring) < 90) return true;
      }
    }
    return false;
  }

  bool _pointInRing(LatLng p, List<LatLng> ring) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i].longitude, yi = ring[i].latitude;
      final xj = ring[j].longitude, yj = ring[j].latitude;
      if (((yi > p.latitude) != (yj > p.latitude)) &&
          (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
  }

  double get _progress {
    final total = _coverLengths.values.fold<double>(0, (a, b) => a + b);
    if (total == 0) return 0;
    var done = 0.0;
    for (final id in _covered) {
      done += _coverLengths[id] ?? 0;
    }
    return (done / total).clamp(0.0, 1.0);
  }

  double get _coveredLen {
    var done = 0.0;
    for (final id in _covered) {
      done += _coverLengths[id] ?? 0;
    }
    return done;
  }

  bool get _fullyCovered => _covered.length >= _coverLengths.length;

  int get _pendingRechecks => _steps
      .where((s) => s.role == StepRole.recheck && !_recheckDone.contains(s.streetId))
      .map((s) => s.streetId)
      .toSet()
      .length;

  int? _nearestPendingIdx(LatLng? here) {
    int? best;
    var bestD = double.infinity;
    for (var i = 0; i < _steps.length; i++) {
      final s = _steps[i];
      if (!s.counts || _covered.contains(s.streetId)) continue;
      final d = here == null ? i.toDouble() : distToPolyline(here, s.coords);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  bool _handleEndOfSequence(LatLng? here) {
    if (_fullyCovered) return false;
    final j = _nearestPendingIdx(here);
    if (j == null) return false;
    setState(() {
      _idx = j;
      _announcedNext = false;
    });
    _speak('Aún faltan calles por cubrir. Llevas '
        '${(_progress * 100).toStringAsFixed(0)} por ciento. '
        'Te llevo a la más cercana.');
    if (here != null && distToPolyline(here, _steps[j].coords) > 60) {
      _startReconnect(here, speakIntro: false);
    }
    _persist(force: true);
    return true;
  }

  void _updateNavigation(LatLng here) {
    final cur = _current;
    if (cur == null) {
      if (_reconnectLine != null) setState(() => _reconnectLine = null);
      _handleEndOfSequence(here);
      return;
    }

    final dToStep = distToPolyline(here, cur.coords);

    if (_reconnectLine != null) {
      if (dToStep < 30 || distMeters(here, cur.start) < _arriveThreshold) {
        setState(() => _reconnectLine = null);
        _reconnectDriftCount = 0;
        _onStepFixes = 0;
        _speak('Estás en la ruta. ${cur.instruction}');
      } else {
        final dLine = distToPolyline(here, _reconnectLine!);
        if (dLine > 50) {
          _reconnectDriftCount++;
          if (_reconnectDriftCount >= 3) {
            _reconnectDriftCount = 0;
            _startReconnect(here, speakIntro: false);
          }
        } else {
          _reconnectDriftCount = 0;
          if (_reconnectIsReturn &&
              DateTime.now().difference(_lastReconnectVoice).inSeconds > 45) {
            _lastReconnectVoice = DateTime.now();
            _speak('Sigue la línea verde. Faltan '
                '${_fmtDist(remainingOnLine(here, _reconnectLine!))} '
                'para volver a la zona.');
          }
        }
        setState(() {});
        return;
      }
    }

    if (dToStep < 30) _onStepFixes++;
    var advanced = false;
    var guard = 0;
    while (_current != null && guard < 20) {
      final c = _current!;
      final dEnd = distMeters(here, c.end);
      final along = fractionAlong(here, c.coords);
      final nearLine = distToPolyline(here, c.coords) < 40;
      final traversed = _onStepFixes >= 2 || c.lengthM < 40;
      if (dEnd < _arriveThreshold &&
          traversed &&
          (along > 0.6 || c.lengthM < 40 || !nearLine)) {
        if (c.role == StepRole.recheck) _recheckDone.add(c.streetId);
        _idx++;
        _onStepFixes = 3;
        advanced = true;
        guard++;
      } else {
        break;
      }
    }
    if (advanced) {
      _onStepFixes = 0;
      _announcedNext = false;
      if (_skipCoveredRun(here)) {
        _persist(force: true);
        _pushOverlayState();
        setState(() {});
        return;
      }
      final nxt = _current;
      if (nxt != null) {
        _speak(nxt.role == StepRole.recheck
            ? 'Segunda pasada recomendada por vía ancha. No cuenta para el '
                'avance. ${nxt.instruction}'
            : nxt.instruction);
      } else if (!_handleEndOfSequence(here)) {
        HapticFeedback.heavyImpact();
        _speak('¡Recorrido completado! Cubriste todas las calles de la zona.');
      }
      _persist(force: true);
      _pushOverlayState();
      setState(() {});
      return;
    }

    final c = _current!;
    final dEnd = distMeters(here, c.end);
    if (!_announcedNext && dEnd < 80 && dEnd > _arriveThreshold) {
      final nxt = _idx + 1 < _steps.length ? _steps[_idx + 1] : null;
      if (nxt != null && nxt.maneuver != 'continue') {
        _announcedNext = true;
        _speak('En ${(dEnd / 10).round() * 10} metros, '
            '${_lowerFirst(nxt.instruction)}');
      }
    }

    if (dToStep > 60) {
      _offRouteCount++;
      if (_offRouteCount == 2 &&
          DateTime.now().difference(_lastOffRouteAlert).inSeconds > 20 &&
          !_insideZone(here)) {
        // solo alarma si de verdad se salió de la zona de estudio
        _lastOffRouteAlert = DateTime.now();
        HapticFeedback.heavyImpact();
        _speak('Saliste de la zona de estudio.');
      }
      if (_offRouteCount >= 4 && !_reconnecting) {
        _offRouteCount = 0;
        // dentro del sector se replanifica sin preguntar: se toma la calle
        // pendiente más cercana y se sigue cubriendo desde ahí
        _relocate(here, announce: false, force: _insideZone(here));
        final t = _current;
        if (t != null && distToPolyline(here, t.coords) > 60) {
          _startReconnect(here, speakIntro: true);
        } else if (t != null) {
          _speak('Continúa aquí. ${t.instruction}');
        }
      }
    } else {
      _offRouteCount = 0;
    }
    _persist();
    setState(() {});
  }

  /// Si lo que sigue son calles que ya hiciste (otro día, o desde un sector
  /// aledaño), salta a la siguiente pendiente en vez de hacértelas repasar.
  /// Solo actúa con al menos 200 m de calle ya cubierta por delante y si la
  /// pendiente queda claramente más cerca en línea recta; los enlaces
  /// normales de la ruta (vueltas por sentidos únicos) no lo disparan.
  bool _skipCoveredRun(LatLng here) {
    var runM = 0.0, doneM = 0.0;
    int? j;
    for (var i = _idx; i < _steps.length; i++) {
      final s = _steps[i];
      if (s.counts && !_covered.contains(s.streetId)) {
        j = i;
        break;
      }
      if (s.role == StepRole.recheck && !_recheckDone.contains(s.streetId)) {
        j = i;
        break;
      }
      if (s.counts) doneM += s.lengthM;
      runM += s.lengthM;
    }
    if (doneM < 200 || j == _idx) return false;
    if (j == null) {
      // nada pendiente por delante: al final de la secuencia se decide si
      // quedan calles atrás o si ya terminó
      _idx = _steps.length;
      _reconnectLine = null;
      if (!_handleEndOfSequence(here)) {
        HapticFeedback.heavyImpact();
        _speak('¡Recorrido completado! Cubriste todas las calles de la zona.');
      }
      return true;
    }
    if (distMeters(here, _steps[j].start) > runM * 0.5) return false;
    _idx = j;
    _reconnectLine = null;
    final t = _steps[j];
    if (distToPolyline(here, t.coords) > 60) {
      _speak('Salto ${_fmtDist(runM)} de calles que ya hiciste.');
      _startReconnect(here, speakIntro: false);
    } else {
      _speak(t.instruction);
    }
    return true;
  }

  Future<void> _startReconnect(LatLng here, {required bool speakIntro}) async {
    final target = _current;
    if (target == null || _reconnecting) return;
    if (DateTime.now().difference(_lastReconnectCalc).inSeconds < 8) return;
    _lastReconnectCalc = DateTime.now();
    _reconnecting = true;
    final isReturn = !_insideZone(here);
    if (speakIntro) {
      _speak(isReturn
          ? 'Saliste de la zona. Calculando el regreso…'
          : 'Replanificando la ruta…');
    }
    setState(() {});
    try {
      final line = await _reconnectSvc.reconnect(here, target);
      if (!mounted || !identical(_current, target)) return;
      setState(() {
        _reconnectLine = line ?? [here, target.start];
        _reconnectIsReturn = isReturn;
      });
      _lastReconnectVoice = DateTime.now();
      final dist = _fmtDist(remainingOnLine(here, _reconnectLine!));
      _speak(isReturn
          ? 'Sigue la línea verde, $dist para volver a la zona.'
          : 'Continúa por ${target.name.isEmpty ? "la siguiente calle" : target.name},'
              ' a $dist.');
    } finally {
      _reconnecting = false;
    }
  }

  void _relocate(LatLng here, {bool announce = false, bool force = false}) {
    _offRouteCount = 0;
    var bestIdx = -1;
    var bestScore = double.infinity;
    for (var i = 0; i < _steps.length; i++) {
      final s = _steps[i];
      final done = s.counts && _covered.contains(s.streetId);
      final d = distToPolyline(here, s.coords);
      final penalty = (done ? 400.0 : 0.0) +
          (s.role == StepRole.recheck ? 250.0 : 0.0) +
          (i < _idx ? 150.0 : 0.0);
      final score = d + penalty;
      if (score < bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    if (bestIdx < 0) return;
    if (!force && bestIdx != _idx && _idx < _steps.length) {
      final s = _steps[_idx];
      final done = s.counts && _covered.contains(s.streetId);
      final curScore = distToPolyline(here, s.coords) + (done ? 400.0 : 0.0);
      if (curScore <= bestScore + 80) return;
    }
    final changed = bestIdx != _idx;
    setState(() {
      _idx = bestIdx;
      _announcedNext = false;
      _onStepFixes = 0;
      if (changed) _reconnectLine = null;
    });
    if (announce && changed) {
      _speak('Listo, continúa aquí. ${_steps[bestIdx].instruction}');
    }
    _persist(force: true);
  }

  Future<void> _skipStep() async {
    final c = _current;
    if (c == null) return;
    var markCovered = true;
    if (c.counts && !_covered.contains(c.streetId)) {
      final r = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Omitir tramo'),
          content: const Text('¿Qué hacemos con esta calle?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Dejarla para después')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Darla por cubierta')),
          ],
        ),
      );
      if (r == null) return;
      markCovered = r;
    }
    if (markCovered && c.counts) _covered.add(c.streetId);
    if (c.role == StepRole.recheck) _recheckDone.add(c.streetId);
    _idx++;
    _announcedNext = false;
    _onStepFixes = 0;
    setState(() {});
    final nxt = _current;
    if (nxt != null) {
      _speak(nxt.instruction);
    } else if (!_handleEndOfSequence(_pos)) {
      _speak('¡Recorrido completado!');
    }
    _persist(force: true);
  }

  void _persist({bool force = false}) {
    if (force || DateTime.now().difference(_lastSave).inSeconds > 15) {
      _lastSave = DateTime.now();
      _store.saveProgress(_covered, _recheckDone);
      _store.saveStepIndex(widget.routeKey, _idx);
    }
  }

  Future<void> _speak(String text) async {
    if (!_voiceOn || text.isEmpty) return;
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  String _lowerFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  String _fmtDist(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(1)} kilómetros'
      : '${m.round()} metros';

  String _fmtShort(double m) =>
      m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

  Future<void> _openInGoogleMaps() async {
    final target = _current?.start;
    if (target == null) return;
    final mode = widget.route.mode == 'walk' ? 'w' : 'd';
    final appUri = Uri.parse(
        'google.navigation:q=${target.latitude},${target.longitude}&mode=$mode');
    final webUri = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=${target.latitude},'
        '${target.longitude}&travelmode=${mode == 'w' ? 'walking' : 'driving'}');
    try {
      if (await canLaunchUrl(appUri)) {
        await launchUrl(appUri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      try {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _refreshLayersIfNeeded();
    final route = widget.route;
    final progress = _progress;
    final cur = _current;
    final next = _idx + 1 < _steps.length ? _steps[_idx + 1] : null;
    final dEnd =
        (_pos != null && cur != null) ? distMeters(_pos!, cur.end) : null;
    final remainingM = _remainingRouteM();
    final etaMin = (remainingM / 1000 / _speedEstimateKmh() * 60).round();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final exit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('¿Salir de la navegación?'),
            content: Text('Tu avance y las ${_offers.length} ofertas quedan '
                'guardados; puedes continuar luego.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Seguir navegando')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Salir')),
            ],
          ),
        );
        if (exit == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        body: Stack(
          children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: cur?.start ?? _steps.first.start,
                initialZoom: _baseZoom,
                onPositionChanged: (pos, hasGesture) {
                  if (hasGesture && _follow) setState(() => _follow = false);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.mercado.rutas',
                ),
                PolygonLayer(
                  polygons: [
                    for (final s in widget.sectors)
                      for (final ring in s.rings)
                        Polygon(
                          points: ring,
                          color: Colors.transparent,
                          borderColor: Colors.black45,
                          borderStrokeWidth: 2,
                        ),
                  ],
                ),
                PolylineLayer(
                    polylines: _cachedLines ?? const <Polyline<Object>>[]),
                MarkerLayer(markers: _cachedArrows ?? const []),
                MarkerLayer(markers: _buildOfferMarkers()),
                MarkerLayer(markers: _buildMainMarkers(cur)),
              ],
            ),

            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    _instructionBanner(cur, next, dEnd),
                    if (_sim != null) _simPanel(),
                    if (_gpsStatus.isNotEmpty)
                      Card(
                        color: Colors.amber.shade100,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(children: [
                            const Icon(Icons.gps_off),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_gpsStatus)),
                          ]),
                        ),
                      ),
                    if (_reconnectIsReturn &&
                        _reconnectLine != null &&
                        _pos != null &&
                        cur != null)
                      Card(
                        color: Colors.green.shade100,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(children: [
                            _reconnecting
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child:
                                        CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.alt_route,
                                    color: Colors.green),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(
                                    'Sigue la línea verde hasta la ruta '
                                    '(${_fmtShort(remainingOnLine(_pos!, _reconnectLine!))})',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600))),
                            TextButton.icon(
                              onPressed: _openInGoogleMaps,
                              icon: const Icon(Icons.map, size: 18),
                              label: const Text('Maps'),
                            ),
                          ]),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Botón grande de OFERTA
            Positioned(
              right: 14,
              bottom: 150,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_follow)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: FloatingActionButton.small(
                        heroTag: 'recenter',
                        onPressed: () {
                          setState(() => _follow = true);
                          if (_pos != null) _moveCamera(_pos!);
                        },
                        child: const Icon(Icons.my_location),
                      ),
                    ),
                  FloatingActionButton.large(
                    heroTag: 'offer',
                    backgroundColor: const Color(0xFFD84315),
                    foregroundColor: Colors.white,
                    onPressed: () => _addOffer(),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.push_pin, size: 26),
                        Text('OFERTA $_nextOfferNum',
                            style: const TextStyle(
                                fontSize: 9, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: Card(
                  margin: const EdgeInsets.all(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 12,
                                    color: progress >= 1 ? Colors.green : null),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('${(progress * 100).toStringAsFixed(1)}%',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                                '${(_coveredLen / 1000).toStringAsFixed(1)} de '
                                '${(route.coverLengthM / 1000).toStringAsFixed(1)} km',
                                style: const TextStyle(fontSize: 12)),
                            Text('📌 ${_offers.length}',
                                style: const TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.bold)),
                            if (_pendingRechecks > 0)
                              Text('2ª: $_pendingRechecks',
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFFF9A825))),
                            Text('${_speedKmh.toStringAsFixed(0)} km/h',
                                style: const TextStyle(fontSize: 12)),
                            Text(
                                'faltan ~${etaMin >= 60 ? "${etaMin ~/ 60}h ${etaMin % 60}m" : "$etaMin min"}',
                                style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                        const Divider(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _actionBtn(
                              icon: _overlayOn
                                  ? Icons.picture_in_picture_alt
                                  : Icons.picture_in_picture,
                              label: 'Flotante',
                              color: _overlayOn ? Colors.green : null,
                              onTap: _toggleOverlay,
                            ),
                            _actionBtn(
                              icon: _headingUp ? Icons.explore : Icons.north,
                              label: _headingUp ? 'Rumbo' : 'Norte',
                              onTap: () {
                                setState(() => _headingUp = !_headingUp);
                                if (_pos != null && _follow) _moveCamera(_pos!);
                              },
                            ),
                            _actionBtn(
                              icon:
                                  _voiceOn ? Icons.volume_up : Icons.volume_off,
                              label: 'Voz',
                              onTap: () => setState(() => _voiceOn = !_voiceOn),
                            ),
                            _actionBtn(
                              icon: Icons.skip_next,
                              label: 'Omitir',
                              onTap: cur == null ? null : _skipStep,
                            ),
                            _actionBtn(
                              icon: Icons.more_vert,
                              label: 'Más',
                              onTap: _showMoreMenu,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _instructionBanner(RouteStep? cur, RouteStep? next, double? dEnd) {
    final done = cur == null && _fullyCovered;
    final isRecheck = cur?.role == StepRole.recheck;
    final showNext = next != null && dEnd != null && dEnd < 120;
    final icon = cur == null
        ? (done ? Icons.celebration : Icons.assignment_late)
        : (showNext
            ? _maneuverIcon(next.maneuver)
            : _maneuverIcon(cur.maneuver));
    final mainText = cur == null
        ? (done ? '¡Recorrido completado!' : 'Aún faltan calles')
        : (showNext
            ? _shortManeuver(next)
            : (dEnd != null ? 'Sigue por esta calle' : cur.instruction));
    final subText = cur == null
        ? (done
            ? (_pendingRechecks > 0
                ? '100% cubierto · $_pendingRechecks revisiones opcionales'
                : 'Cubriste todas las calles de la zona')
            : 'Te llevo a la calle pendiente más cercana')
        : [
            if (dEnd != null) _fmtShort(dEnd),
            if (cur.name.isNotEmpty) cur.name,
            'tramo ${_idx + 1}/${_steps.length}',
          ].join(' · ');

    return Card(
      color: done
          ? Colors.green.shade700
          : cur == null
              ? Colors.orange.shade800
              : isRecheck
                  ? const Color(0xF0F9A825)
                  : const Color(0xF01565C0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          children: [
            Row(
              children: [
                Icon(icon,
                    color: isRecheck ? Colors.black87 : Colors.white, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(mainText,
                          style: TextStyle(
                              color: isRecheck ? Colors.black : Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.bold),
                          maxLines: 2),
                      const SizedBox(height: 2),
                      Text(subText,
                          style: TextStyle(
                              color: isRecheck
                                  ? Colors.black87
                                  : Colors.white70,
                              fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
            if (isRecheck)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.black87),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        'Vía ancha de doble sentido: segunda pasada '
                        'recomendada. NO cuenta para el 100%.',
                        style: TextStyle(fontSize: 12, color: Colors.black87)),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _actionBtn(
      {required IconData icon,
      required String label,
      Color? color,
      VoidCallback? onTap}) {
    final c = onTap == null ? Colors.grey : (color ?? Colors.black87);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 26, color: c),
          Text(label, style: TextStyle(fontSize: 11, color: c)),
        ]),
      ),
    );
  }

  Future<void> _showMoreMenu() async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.list_alt),
              title: Text('Gestionar ofertas (${_offers.length})'),
              subtitle: const Text('Ver, editar notas, seleccionar y borrar'),
              onTap: () {
                Navigator.pop(ctx);
                _openOffersManager();
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Exportar ofertas (shapefile)'),
              subtitle: const Text('Capa de puntos para QGIS/ArcGIS'),
              onTap: () {
                Navigator.pop(ctx);
                _exportOffers();
              },
            ),
            ListTile(
              leading: const Icon(Icons.my_location),
              title: const Text('Reubicarme en la ruta'),
              onTap: () {
                Navigator.pop(ctx);
                final here = _pos;
                if (here != null) {
                  _relocate(here, announce: true, force: true);
                  final t = _current;
                  if (t != null && distToPolyline(here, t.coords) > 60) {
                    _startReconnect(here, speakIntro: true);
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.directions),
              title: const Text('Llevarme con Google Maps'),
              onTap: () {
                Navigator.pop(ctx);
                _openInGoogleMaps();
              },
            ),
            ListTile(
              leading: const Icon(Icons.map),
              title: const Text('Ver toda la ruta'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _follow = false;
                  _showAllRoute = true;
                });
                _map.rotate(0);
                _map.fitCamera(CameraFit.bounds(
                    bounds: _routeBounds(),
                    padding: const EdgeInsets.all(40)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt, color: Colors.red),
              title: const Text('Reiniciar avance',
                  style: TextStyle(color: Colors.red)),
              subtitle: const Text('No borra las ofertas registradas'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmReset();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Abre el gestor completo de ofertas (lista, editar, seleccionar y borrar
  /// en grupo). Al volver recarga las ofertas por si se borraron algunas.
  Future<void> _openOffersManager() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OffersScreen(
        projectId: widget.projectId,
        projectName: widget.projectName,
      ),
    ));
    if (!mounted) return;
    final fresh = await _store.loadOffers();
    setState(() {
      _offers
        ..clear()
        ..addAll(fresh);
    });
    _pushOverlayState();
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reiniciar avance'),
        content: const Text(
            'Se borra el avance del recorrido de esta ruta. Las ofertas '
            'registradas NO se borran.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sí, reiniciar')),
        ],
      ),
    );
    if (ok == true) {
      await _store.clearProgress();
      setState(() {
        _covered.clear();
        _recheckDone.clear();
        _tracks.clear();
        _idx = 0;
        _announcedNext = false;
        _reconnectLine = null;
      });
      if (_pos != null) _relocate(_pos!, force: true);
    }
  }

  LatLngBounds _routeBounds() =>
      LatLngBounds.fromPoints([for (final s in _steps) ...s.coords]);

  double _remainingRouteM() {
    var sum = 0.0;
    for (var i = _idx; i < _steps.length; i++) {
      sum += _steps[i].lengthM;
    }
    return sum;
  }

  double _speedEstimateKmh() {
    if (_speedKmh > 2) return _speedKmh;
    return widget.route.mode == 'walk' ? 4.0 : 12.0;
  }

  // -------------------------------------------------------------------
  // Capas del mapa
  // -------------------------------------------------------------------

  /// Las capas de ruta solo cambian cuando cambia el tramo actual, lo
  /// cubierto o la línea de reconexión: no hay que rehacerlas en cada fix.
  void _refreshLayersIfNeeded() {
    final key = '$_idx|${_covered.length}|${_recheckDone.length}|'
        '${_reconnectLine?.length ?? 0}|$_showAllRoute';
    if (key == _layerKey && _cachedLines != null) return;
    _layerKey = key;
    _cachedLines = _buildPolylines();
    _cachedArrows = _buildArrowMarkers();
  }

  List<Polyline<Object>> _buildPolylines() {
    final lines = <Polyline<Object>>[];
    // En rutas muy largas solo se dibuja el entorno del tramo actual: pintar
    // 2500 polilíneas a la vez traba el mapa.
    var lo = 0, hi = _steps.length - 1;
    if (!_showAllRoute && _steps.length > 900) {
      lo = math.max(0, _idx - 300);
      hi = math.min(_steps.length - 1, _idx + 600);
    }
    for (var i = hi; i >= lo; i--) {
      if (i == _idx) continue;
      final s = _steps[i];
      switch (s.role) {
        case StepRole.link:
          lines.add(Polyline(
            points: s.coords,
            strokeWidth: 2.5,
            color: _kLink,
            pattern: const StrokePattern.dotted(),
          ));
          break;
        case StepRole.recheck:
          // No se dibuja: va encima de la misma calle que ya está pintada y
          // solo ensuciaba el mapa. Se avisa en el letrero y en el contador.
          break;
        case StepRole.cover:
          final hecho = _covered.contains(s.streetId);
          lines.add(Polyline(
            points: s.coords,
            strokeWidth: hecho ? 3 : 5,
            color: hecho ? _kDone : _kPending,
          ));
          break;
      }
    }
    if (_reconnectLine != null) {
      // verde solo para volver a la zona; dentro del sector el enlace es
      // parte del recorrido y va discreto
      lines.add(Polyline(
        points: _reconnectLine!,
        strokeWidth: _reconnectIsReturn ? 6 : 4,
        color: _reconnectIsReturn
            ? Colors.green.shade600
            : Colors.blueGrey.withValues(alpha: 0.6),
        pattern: StrokePattern.dashed(
            segments: _reconnectIsReturn ? const [18, 10] : const [10, 8]),
      ));
    }
    final cur = _current;
    if (cur != null) {
      lines.add(Polyline(
        points: cur.coords,
        strokeWidth: 6,
        color: cur.role == StepRole.recheck
            ? const Color(0x99F9A825)
            : _kOrange,
      ));
    }
    return lines;
  }

  List<Marker> _buildArrowMarkers() {
    final markers = <Marker>[];
    if (_steps.isEmpty) return markers;

    void chevrons(List<LatLng> line, Color color, double size,
        {double spacing = 45, int maxN = 12}) {
      var total = 0.0;
      for (var i = 0; i < line.length - 1; i++) {
        total += distMeters(line[i], line[i + 1]);
      }
      if (total < 18) return;
      final n = math.min(maxN, math.max(1, (total / spacing).floor()));
      for (var j = 1; j <= n; j++) {
        final (pt, brg) = pointAlong(line, j / (n + 1));
        markers.add(Marker(
          point: pt,
          width: size,
          height: size,
          child: Transform.rotate(
            angle: brg * math.pi / 180,
            child: Stack(alignment: Alignment.center, children: [
              Icon(Icons.navigation, color: Colors.white, size: size),
              Icon(Icons.navigation, color: color, size: size - 7),
            ]),
          ),
        ));
      }
    }

    final cur = _current;
    if (cur != null) {
      chevrons(
          cur.coords,
          cur.role == StepRole.recheck
              ? const Color(0xCCF9A825)
              : _kOrangeArrow,
          30,
          spacing: 70,
          maxN: 4);
    }
    // solo una flecha por tramo y hasta 250 m adelante: más allá estorba
    var acc = 0.0;
    for (var i = _idx + 1; i < _steps.length && acc < 250; i++) {
      final s = _steps[i];
      acc += s.lengthM;
      if (s.role == StepRole.recheck || s.lengthM < 30) continue;
      chevrons(s.coords, const Color(0x991E88E5), 20, spacing: 999, maxN: 1);
    }
    if (_reconnectLine != null) {
      chevrons(_reconnectLine!, Colors.green.shade700, 30,
          spacing: 60, maxN: 10);
    }
    return markers;
  }

  List<Marker> _buildOfferMarkers() {
    return [
      for (final o in _offers)
        Marker(
          point: o.pos,
          width: 34,
          height: 42,
          rotate: true,
          alignment: Alignment.topCenter,
          child: GestureDetector(
            onTap: () => _editOffer(o),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD84315),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white, width: 1.5),
                    boxShadow: const [
                      BoxShadow(color: Colors.black38, blurRadius: 3)
                    ],
                  ),
                  child: Text('${o.number}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                ),
                const Icon(Icons.arrow_drop_down,
                    color: Color(0xFFD84315), size: 18),
              ],
            ),
          ),
        ),
    ];
  }

  List<Marker> _buildMainMarkers(RouteStep? cur) {
    return [
      if (cur != null)
        Marker(
          point: cur.end,
          width: 30,
          height: 30,
          rotate: true,
          child: const Icon(Icons.flag_circle, color: _kOrangeArrow, size: 28),
        ),
      if (_pos != null)
        Marker(
          point: _pos!,
          width: 44,
          height: 44,
          child: Transform.rotate(
            angle: _heading * math.pi / 180,
            child: const Icon(Icons.navigation,
                color: Color(0xFF1565C0),
                size: 40,
                shadows: [Shadow(color: Colors.black38, blurRadius: 4)]),
          ),
        ),
    ];
  }

  IconData _maneuverIcon(String? m) {
    switch (m) {
      case 'izquierda':
        return Icons.turn_left;
      case 'derecha':
        return Icons.turn_right;
      case 'slight_izquierda':
        return Icons.turn_slight_left;
      case 'slight_derecha':
        return Icons.turn_slight_right;
      case 'sharp_izquierda':
        return Icons.turn_sharp_left;
      case 'sharp_derecha':
        return Icons.turn_sharp_right;
      case 'uturn':
        return Icons.u_turn_left;
      case 'continue':
        return Icons.straight;
      case 'depart':
        return Icons.play_arrow;
      default:
        return Icons.navigation;
    }
  }

  String _shortManeuver(RouteStep s) {
    switch (s.maneuver) {
      case 'izquierda':
        return 'Gira a la izquierda';
      case 'derecha':
        return 'Gira a la derecha';
      case 'slight_izquierda':
        return 'Levemente a la izquierda';
      case 'slight_derecha':
        return 'Levemente a la derecha';
      case 'sharp_izquierda':
        return 'Giro cerrado a la izquierda';
      case 'sharp_derecha':
        return 'Giro cerrado a la derecha';
      case 'uturn':
        return 'Da la vuelta';
      case 'continue':
        return 'Continúa recto';
      default:
        return s.instruction;
    }
  }
}
