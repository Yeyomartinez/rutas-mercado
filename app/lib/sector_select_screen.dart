import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'export_offers.dart';
import 'google_routing.dart';
import 'models.dart';
import 'navigation_screen.dart';
import 'offers_screen.dart';
import 'project_store.dart';

/// Pantalla inicial: elegir mercado y sectores, y arrancar el recorrido.
class SectorSelectScreen extends StatefulWidget {
  final bool forceSimulate;
  const SectorSelectScreen({super.key, this.forceSimulate = false});

  @override
  State<SectorSelectScreen> createState() => _SectorSelectScreenState();
}

class _SectorSelectScreenState extends State<SectorSelectScreen> {
  List<Sector>? _sectors;
  Map<String, RouteStats> _stats = {};
  SectorStreets? _ss;
  final Map<String, Set<String>> _covered = {}; // por proyecto (zona)
  final Map<String, int> _offerCount = {};
  final Set<String> _selected = {};
  String _mode = 'walk';
  bool _loadingRoute = false;
  bool _hasGoogleKey = false;
  bool _simulate = false;

  static const _colors = [
    Color(0xFFE53935), Color(0xFF8E24AA), Color(0xFF3949AB),
    Color(0xFF00897B), Color(0xFFF4511E), Color(0xFF7CB342),
    Color(0xFF00ACC1), Color(0xFFD81B60),
  ];

  @override
  void initState() {
    super.initState();
    _simulate = widget.forceSimulate;
    _load();
  }

  Future<void> _load() async {
    final raw = await rootBundle.loadString('assets/sectors.geojson');
    final idxRaw = await rootBundle.loadString('assets/routes_index.json');
    final gkey = await GoogleRouting.loadKey();
    SectorStreets? ss;
    try {
      ss = SectorStreets.fromJson(
          await rootBundle.loadString('assets/sectors_streets.json'));
    } catch (_) {}
    final sectors = Sector.listFromGeoJson(raw);
    // cargar progreso y ofertas de cada mercado (zona)
    for (final z in _zoneIds(sectors)) {
      _covered[z] = await ProjectStore(z).loadCovered();
      _offerCount[z] = (await ProjectStore(z).loadOffers()).length;
    }
    if (!mounted) return;
    setState(() {
      _sectors = sectors;
      _stats = RouteStats.mapFromJson(idxRaw);
      _ss = ss;
      _hasGoogleKey = gkey.isNotEmpty;
    });
  }

  List<String> _zoneIds(List<Sector> sectors) {
    final out = <String>[];
    for (final s in sectors) {
      if (!out.contains(s.zone)) out.add(s.zone);
    }
    return out;
  }

  String? get _activeZone {
    if (_selected.isEmpty) return null;
    return _sectors!.firstWhere((s) => s.code == _selected.first).zone;
  }

  Color _colorFor(String code) =>
      _colors[_sectors!.indexWhere((s) => s.code == code) % _colors.length];

  // ---- estadísticas combinadas de la selección ----
  ({double coverM, double totalM, double recheckM, int streets})? _selStats() {
    if (_selected.isEmpty) return null;
    var cover = 0.0, total = 0.0, recheck = 0.0, streets = 0;
    for (final c in _selected) {
      final st = _stats['route_${c}_$_mode.geojson'];
      if (st == null) continue;
      cover += st.coverM;
      total += st.totalM;
      recheck += st.recheckM;
      streets += st.streets;
    }
    return (coverM: cover, totalM: total, recheckM: recheck, streets: streets);
  }

  double _selProgress() {
    final z = _activeZone;
    if (z == null || _ss == null) return 0;
    final union = _ss!.union(_selected);
    if (union.isEmpty) return 0;
    final cov = _covered[z] ?? {};
    var n = 0;
    for (final id in union) {
      if (cov.contains(id)) n++;
    }
    return n / union.length;
  }

  Future<void> _start() async {
    if (_selected.isEmpty) return;
    final z = _activeZone!;
    setState(() => _loadingRoute = true);
    try {
      final codes = _selected.toList()..sort();
      final routes = <CoverageRoute>[];
      final missing = <String>[];
      for (final c in codes) {
        try {
          final raw = await rootBundle
              .loadString('assets/routes/route_${c}_$_mode.geojson');
          routes.add(CoverageRoute.fromGeoJson(raw));
        } catch (_) {
          // sector sin calles enrutables en este modo: se omite sin bloquear
          missing.add(c);
        }
      }
      if (routes.isEmpty) {
        _toast('Los sectores elegidos no tienen calles en modo '
            '${_mode == 'walk' ? 'a pie' : 'vehículo'}.');
        return;
      }
      if (missing.isNotEmpty) {
        _toast('${missing.length} sector(es) sin calles se omitieron.');
      }
      final route = CoverageRoute.merge(routes);
      if (!mounted) return;
      final selectedSectors =
          _sectors!.where((s) => _selected.contains(s.code)).toList();
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NavigationScreen(
          route: route,
          routeKey: '${z}_${codes.join('-')}_$_mode',
          projectId: z,
          projectName: _projectName(z),
          sectors: selectedSectors,
          simulate: _simulate,
        ),
      ));
      // refrescar progreso/ofertas al volver
      _covered[z] = await ProjectStore(z).loadCovered();
      _offerCount[z] = (await ProjectStore(z).loadOffers()).length;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo cargar la ruta: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  String _projectName(String zone) {
    final s = _sectors!.firstWhere((x) => x.zone == zone);
    return 'Mercado $zone · ${s.zoneName}';
  }

  double _zoneProgress(String zone) {
    if (_ss == null) return 0;
    final codes = _sectors!.where((s) => s.zone == zone).map((s) => s.code);
    final union = _ss!.union(codes);
    if (union.isEmpty) return 0;
    final cov = _covered[zone] ?? {};
    var n = 0;
    for (final id in union) {
      if (cov.contains(id)) n++;
    }
    return n / union.length;
  }

  @override
  Widget build(BuildContext context) {
    final sectors = _sectors;
    final st = _selStats();
    final prog = _selProgress();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rutas Mercado'),
        actions: [
          IconButton(
            tooltip: _simulate ? 'Simulación ACTIVA' : 'Modo simulación',
            icon: Icon(Icons.science,
                color: _simulate ? Colors.amber : Colors.grey),
            onPressed: () {
              setState(() => _simulate = !_simulate);
              _toast(_simulate
                  ? 'Simulación ACTIVA: conductor virtual, sin GPS.'
                  : 'Simulación desactivada: GPS real.');
            },
          ),
          IconButton(
            tooltip: 'Clave de Google',
            icon: Icon(Icons.vpn_key,
                color: _hasGoogleKey ? Colors.green : Colors.grey),
            onPressed: _googleKeyDialog,
          ),
          IconButton(
              icon: const Icon(Icons.help_outline), onPressed: _showHelp),
        ],
      ),
      body: sectors == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  flex: 5,
                  child: FlutterMap(
                    options: MapOptions(
                        initialCenter: _centerOf(sectors), initialZoom: 12.5),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.mercado.rutas',
                      ),
                      PolygonLayer(polygons: [
                        for (final s in sectors)
                          for (final ring in s.rings)
                            Polygon(
                              points: ring,
                              color: _colorFor(s.code).withValues(
                                  alpha:
                                      _selected.contains(s.code) ? 0.4 : 0.08),
                              borderColor: _colorFor(s.code),
                              borderStrokeWidth:
                                  _selected.contains(s.code) ? 3.5 : 1.2,
                            ),
                      ]),
                    ],
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final z in _zoneIds(sectors)) ...[
                        _projectHeader(z),
                        for (final s
                            in sectors.where((x) => x.zone == z))
                          _sectorTile(s),
                      ],
                    ],
                  ),
                ),
                if (st != null) _summary(st, prog),
                _bottomBar(),
              ],
            ),
    );
  }

  Widget _projectHeader(String z) {
    final s = _sectors!.firstWhere((x) => x.zone == z);
    final prog = _zoneProgress(z);
    final offers = _offerCount[z] ?? 0;
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mercado $z · ${s.zoneName}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                Text(
                    '${(prog * 100).toStringAsFixed(0)}% del mercado cubierto · '
                    '📌 $offers ofertas',
                    style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _projectAction(z, v),
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'offers',
                  child: Text('Ver / borrar ofertas ($offers)')),
              const PopupMenuItem(
                  value: 'export', child: Text('Exportar ofertas')),
              const PopupMenuItem(
                  value: 'reset', child: Text('Reiniciar avance del mercado')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _projectAction(String z, String action) async {
    switch (action) {
      case 'offers':
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                OffersScreen(projectId: z, projectName: _projectName(z))));
        _offerCount[z] = (await ProjectStore(z).loadOffers()).length;
        if (mounted) setState(() {});
        break;
      case 'export':
        final offers = await ProjectStore(z).loadOffers();
        if (offers.isEmpty) {
          _toast('Mercado $z sin ofertas todavía');
          return;
        }
        _toast(await OfferExporter.shareShapefile(offers, _projectName(z)));
        break;
      case 'reset':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Reiniciar Mercado $z'),
            content: const Text(
                'Se borra el avance de recorrido de todo el mercado. '
                'Las ofertas registradas NO se borran.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Reiniciar')),
            ],
          ),
        );
        if (ok == true) {
          await ProjectStore(z).clearProgress();
          _covered[z] = {};
          if (mounted) setState(() {});
        }
        break;
    }
  }

  Widget _sectorTile(Sector s) {
    final st = _stats['route_${s.code}_$_mode.geojson'];
    final hasRoute = st != null;
    final pct = _ss?.sectorPct(s.code, _covered[s.zone] ?? {}) ?? 0;
    final parts = <String>[
      if (hasRoute)
        '${(st.coverM / 1000).toStringAsFixed(1)} km · ~${formatDuration(st.estimate(_mode))}',
      if (pct > 0.001) '${(pct * 100).toStringAsFixed(0)}% hecho',
    ];
    return CheckboxListTile(
      dense: true,
      enabled: hasRoute,
      title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
          !hasRoute
              ? 'Sin calles para recorrer'
              : (parts.isEmpty ? 'Sector ${s.code}' : parts.join(' · ')),
          style: TextStyle(
              fontSize: 11,
              color: !hasRoute
                  ? Colors.grey
                  : (pct >= 0.999 ? Colors.green : null))),
      secondary: Stack(alignment: Alignment.center, children: [
        CircleAvatar(
            radius: 12,
            backgroundColor:
                hasRoute ? _colorFor(s.code) : Colors.grey.shade400),
        if (pct >= 0.999)
          const Icon(Icons.check, size: 15, color: Colors.white),
      ]),
      value: _selected.contains(s.code),
      onChanged: !hasRoute
          ? null
          : (v) => setState(() {
                if (v == true) {
                  _selected.removeWhere((c) =>
                      _sectors!.firstWhere((x) => x.code == c).zone != s.zone);
                  _selected.add(s.code);
                } else {
                  _selected.remove(s.code);
                }
              }),
    );
  }

  Widget _summary(
      ({double coverM, double totalM, double recheckM, int streets}) st,
      double prog) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.route, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                  '${(st.coverM / 1000).toStringAsFixed(1)} km de calles (${st.streets}) · '
                  'recorrido ${(st.totalM / 1000).toStringAsFixed(1)} km',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 12)),
            ),
          ]),
          if (prog > 0.001)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Icon(Icons.play_circle, size: 18, color: Colors.green),
                const SizedBox(width: 6),
                Text(
                    'Avance guardado: ${(prog * 100).toStringAsFixed(0)}% — continúa donde ibas',
                    style: const TextStyle(
                        color: Colors.green, fontWeight: FontWeight.w600)),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'walk',
                    label: Text('A pie'),
                    icon: Icon(Icons.directions_walk)),
                ButtonSegment(
                    value: 'drive',
                    label: Text('Vehículo'),
                    icon: Icon(Icons.directions_car)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const Spacer(),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
              onPressed: _selected.isEmpty || _loadingRoute ? null : _start,
              icon: _loadingRoute
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.navigation),
              label: Text(_selected.isEmpty
                  ? 'Elige sectores'
                  : (_simulate ? 'Simular' : 'Iniciar')),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 4), content: Text(m)));
    }
  }

  Future<void> _googleKeyDialog() async {
    final current = await GoogleRouting.loadKey();
    if (!mounted) return;
    final ctrl = TextEditingController(text: current);
    var testing = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Clave de Google'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                  'Pega la clave de API del proyecto MERCADO. Con ella, las '
                  'reconexiones al salir de la zona las calcula Google Maps.',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                    labelText: 'Clave (AIza...)',
                    border: OutlineInputBorder()),
                maxLines: 2,
                minLines: 1,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            FilledButton.icon(
              icon: testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: const Text('Probar y guardar'),
              onPressed: testing
                  ? null
                  : () async {
                      setLocal(() => testing = true);
                      final err = await GoogleRouting.testKey(ctrl.text);
                      setLocal(() => testing = false);
                      if (err == null) {
                        await GoogleRouting.saveKey(ctrl.text);
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          setState(() =>
                              _hasGoogleKey = ctrl.text.trim().isNotEmpty);
                          _toast('✔ Clave de Google activa');
                        }
                      } else if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx)
                            .showSnackBar(SnackBar(content: Text(err)));
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Cómo se usa?'),
        content: const SingleChildScrollView(
          child: Text(
              '1. Cada mercado (1, 2, 3…) es un proyecto aparte: sus ofertas y '
              'su avance se guardan juntos.\n\n'
              '2. Marca uno o varios sectores del mismo mercado. El avance de '
              'cada sector se suma y queda guardado, aunque agregues otro '
              'sector aledaño después.\n\n'
              '3. Elige a pie o en vehículo (respeta sentidos). Toca INICIAR.\n\n'
              '4. La app te guía con voz. Las calles recorridas se pintan gris. '
              'El botón rojo OFERTA clava una chincheta numerada.\n\n'
              '5. La numeración de ofertas es continua para todo el mercado y '
              'no se reinicia al cambiar de sector.\n\n'
              '6. En el menú (⋮) de cada mercado exportas las ofertas como '
              'shapefile para QGIS, o las borras.'),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Entendido')),
        ],
      ),
    );
  }

  LatLng _centerOf(List<Sector> sectors) {
    var lat = 0.0, lon = 0.0, n = 0;
    for (final s in sectors) {
      for (final ring in s.rings) {
        for (final p in ring) {
          lat += p.latitude;
          lon += p.longitude;
          n++;
        }
      }
    }
    return n == 0 ? const LatLng(4.7, -74.1) : LatLng(lat / n, lon / n);
  }
}
