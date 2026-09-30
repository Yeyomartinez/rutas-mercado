import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// Ventana flotante que queda encima de otras apps (p. ej. la cámara con
/// fecha/hora): muestra la instrucción y permite marcar una oferta sin
/// salir de la cámara.
class OverlayBubble extends StatefulWidget {
  const OverlayBubble({super.key});

  @override
  State<OverlayBubble> createState() => _OverlayBubbleState();
}

class _OverlayBubbleState extends State<OverlayBubble> {
  int _count = 0;
  int _next = 1; // número continuo del proyecto (no se reinicia)
  String _instr = 'Rutas Mercado';
  String _sub = '';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is Map) {
        setState(() {
          _count = (event['count'] as num?)?.toInt() ?? _count;
          _next = (event['next'] as num?)?.toInt() ?? _next;
          _instr = (event['instr'] as String?) ?? _instr;
          _sub = (event['sub'] as String?) ?? _sub;
          if (event['saved'] == true) _sending = false;
        });
      }
    });
    FlutterOverlayWindow.shareData({'action': 'hello'});
  }

  Future<void> _addOffer() async {
    setState(() => _sending = true);
    await FlutterOverlayWindow.shareData({'action': 'offer'});
    // si la app principal no responde, liberar el botón igual
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _sending = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xF01565C0),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white24, width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => FlutterOverlayWindow.shareData({'action': 'open'}),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_instr,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14)),
                      Text(_sub.isEmpty ? 'Ofertas: $_count' : _sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _sending ? null : _addOffer,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: _sending ? Colors.grey : const Color(0xFFFF6D00),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.push_pin, color: Colors.white, size: 18),
                    const SizedBox(width: 4),
                    Text('$_next',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
