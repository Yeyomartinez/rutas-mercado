import 'package:flutter/material.dart';

import 'sector_select_screen.dart';

/// Punto de entrada del SIMULADOR de escritorio: la misma app, pero con el
/// modo simulación siempre activo y sin GPS. Se ejecuta con:
///   flutter run -d chrome -t lib/main_sim.dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (details) => Material(
        color: Colors.white,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Error en el simulador',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.red)),
              const SizedBox(height: 10),
              Text('${details.exception}'),
              const SizedBox(height: 10),
              Text(details.stack.toString().split('\n').take(15).join('\n'),
                  style: const TextStyle(fontSize: 10, color: Colors.black54)),
            ],
          ),
        ),
      );
  runApp(const SimulatorApp());
}

class SimulatorApp extends StatelessWidget {
  const SimulatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rutas Mercado — Simulador',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      // Encuadre tipo teléfono para que se vea como en el celular
      home: Scaffold(
        backgroundColor: const Color(0xFF263238),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430, maxHeight: 920),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: const SectorSelectScreen(forceSimulate: true),
            ),
          ),
        ),
      ),
    );
  }
}
