import 'package:flutter/material.dart';

import 'overlay_ui.dart';
import 'sector_select_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Si algo falla, mostrar el error en pantalla en vez de quedar en gris.
  ErrorWidget.builder = (details) => Material(
        color: Colors.white,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Ocurrió un error en la app',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.red)),
                const SizedBox(height: 10),
                Text('${details.exception}',
                    style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 10),
                Text(details.stack.toString().split('\n').take(12).join('\n'),
                    style: const TextStyle(fontSize: 10, color: Colors.black54)),
              ],
            ),
          ),
        ),
      );
  runApp(const MercadoRutasApp());
}

/// Punto de entrada de la ventana flotante (la invoca Android, no la app).
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayBubble());
}

class MercadoRutasApp extends StatelessWidget {
  const MercadoRutasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rutas Mercado',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: const SectorSelectScreen(),
    );
  }
}
