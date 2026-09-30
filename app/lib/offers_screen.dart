import 'package:flutter/material.dart';

import 'export_offers.dart';
import 'offers.dart';
import 'project_store.dart';

/// Gestor de ofertas de un mercado: lista, edición, borrado múltiple fácil
/// (mantener presionado para seleccionar) y exportación a shapefile/GeoJSON/CSV.
class OffersScreen extends StatefulWidget {
  final String projectId;
  final String projectName;

  const OffersScreen(
      {super.key, required this.projectId, required this.projectName});

  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen> {
  late final ProjectStore _store = ProjectStore(widget.projectId);
  List<Offer> _offers = [];
  final Set<int> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _store.loadOffers();
    list.sort((a, b) => b.number.compareTo(a.number)); // recientes arriba
    setState(() {
      _offers = list;
      _loading = false;
    });
  }

  bool get _selectMode => _selected.isNotEmpty;

  Future<void> _deleteSelected() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Borrar ${_selected.length} ofertas'),
        content: const Text('Se eliminan del mercado. No se puede deshacer.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    _offers.removeWhere((o) => _selected.contains(o.number));
    await _store.saveOffers(_offers);
    setState(() => _selected.clear());
  }

  Future<void> _editNote(Offer o) async {
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
              onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (res == null) return;
    setState(() => o.note = res);
    await _store.saveOffers(_offers);
  }

  Future<void> _export() async {
    if (_offers.isEmpty) {
      _toast('No hay ofertas para exportar');
      return;
    }
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Exportar ofertas',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.map, color: Colors.teal),
              title: const Text('Shapefile (.zip)'),
              subtitle: const Text('Capa de puntos para QGIS/ArcGIS'),
              onTap: () async {
                Navigator.pop(ctx);
                _toast(await OfferExporter.shareShapefile(
                    _offers, widget.projectName));
              },
            ),
            ListTile(
              leading: const Icon(Icons.data_object, color: Colors.indigo),
              title: const Text('GeoJSON'),
              subtitle: const Text('Abrible directo en QGIS'),
              onTap: () async {
                Navigator.pop(ctx);
                _toast(await OfferExporter.shareGeoJson(
                    _offers, widget.projectName));
              },
            ),
            ListTile(
              leading: const Icon(Icons.table_chart, color: Colors.green),
              title: const Text('CSV al portapapeles'),
              subtitle: const Text('Pegar en Excel o WhatsApp'),
              onTap: () async {
                Navigator.pop(ctx);
                _toast(await OfferExporter.copyCsv(_offers));
              },
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode
            ? '${_selected.length} seleccionadas'
            : 'Ofertas · ${widget.projectName}'),
        leading: _selectMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _selected.clear()))
            : null,
        actions: _selectMode
            ? [
                IconButton(
                  tooltip: 'Seleccionar todas',
                  icon: const Icon(Icons.select_all),
                  onPressed: () => setState(() =>
                      _selected.addAll(_offers.map((o) => o.number))),
                ),
                IconButton(
                  tooltip: 'Borrar',
                  icon: const Icon(Icons.delete),
                  onPressed: _deleteSelected,
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Exportar',
                  icon: const Icon(Icons.ios_share),
                  onPressed: _export,
                ),
              ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _offers.isEmpty
              ? const Center(
                  child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'Todavía no hay ofertas en este mercado.\n\n'
                      'Durante la navegación, toca el botón rojo OFERTA para '
                      'clavar una chincheta donde estés.',
                      textAlign: TextAlign.center),
                ))
              : Column(
                  children: [
                    if (!_selectMode)
                      Container(
                        width: double.infinity,
                        color: Theme.of(context).colorScheme.surfaceContainerHigh,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Text(
                            '${_offers.length} ofertas · numeración continua del '
                            'mercado · mantén presionada una para seleccionar y '
                            'borrar en grupo',
                            style: const TextStyle(fontSize: 12)),
                      ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _offers.length,
                        itemBuilder: (_, i) {
                          final o = _offers[i];
                          final sel = _selected.contains(o.number);
                          return ListTile(
                            selected: sel,
                            selectedTileColor:
                                Colors.red.withValues(alpha: 0.08),
                            leading: CircleAvatar(
                              backgroundColor:
                                  sel ? Colors.red : const Color(0xFFD84315),
                              child: Icon(sel ? Icons.check : null,
                                  color: Colors.white,
                                  size: sel ? 20 : null),
                            ),
                            title: Row(children: [
                              Text('#${o.number}  ',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              Expanded(
                                child: Text(
                                    o.note.isEmpty
                                        ? (o.street.isEmpty
                                            ? 'Sin nota'
                                            : o.street)
                                        : o.note,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ]),
                            subtitle: Text(
                                '${o.fecha} ${o.hora} · ±${o.accuracyM.toStringAsFixed(0)} m'),
                            onTap: () {
                              if (_selectMode) {
                                setState(() => sel
                                    ? _selected.remove(o.number)
                                    : _selected.add(o.number));
                              } else {
                                _editNote(o);
                              }
                            },
                            onLongPress: () =>
                                setState(() => _selected.add(o.number)),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
