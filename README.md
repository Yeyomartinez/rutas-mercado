# Rutas Mercado — cobertura calle por calle

App Android + pipeline de rutas para verificar ofertas comerciales cubriendo el
100% de las calles de uno o varios sectores catastrales, con navegación guiada
por voz, marcado del avance y registro de ofertas con chinchetas numeradas.

## Estructura

| Carpeta | Contenido |
|---|---|
| `MERCADO_170726.*` | Sectores zona 1 — Engativá (6 sectores, plano) |
| `MERCADO_2_SHPS.*` | Sectores zona 2 — Bosque de Pinos (2 sectores, empinado) |
| `MERCADO 3.*` | Sectores zona 3 — Suba / Casablanca (20 sectores, dispersa) |
| `MERCADO_ZONAS_DURAS.gpkg` | Sectores zona 4 — Zonas Duras (4 sectores, plano) |
| `SECTOR.gpkg` | Los 1230 sectores catastrales de Bogotá. Hoy solo se usa la zona 5 — Tunal / Santa Lucía (Santa Lucía, Claret, Tunal Oriental, Samoré) |
| `pipeline/` | Script Python que genera las rutas de cobertura |
| `app_assets/` | Salida del pipeline: sectores, rutas e índice |
| `app/` | App Flutter (Android) |
| `RutasMercado.apk` | APK listo para instalar |
| `DEMO.bat` | Doble clic para abrir la demo en el navegador (ver abajo) |
| `demo_web/` | Build web de la demo que usa `DEMO.bat` |

## Modelo de cobertura

- **Se cuenta por calle, no por sentido.** Pasar una vez por una calle la deja
  cubierta, vaya de ida o de vuelta. La línea se pinta gris.
- **`recheck` (amarillo).** En vías anchas de doble sentido la ruta te guía por
  la segunda pasada para ver el otro costado, pero **no cuenta** para el 100%.
- **`link` (morado punteado).** Tramos de enlace entre calles; no cuentan.
- El barredor de la app marca cualquier calle que recorras de verdad, aunque no
  sea el tramo que la ruta indicaba en ese momento.

## Legalidad de la ruta (modo vehículo)

- Respeta sentidos únicos de OpenStreetMap.
- Respeta las restricciones de giro mapeadas (prohibido girar a la izquierda,
  giro en U, etc.) e inserta el desvío legal cuando hace falta.
- Prohíbe la vuelta en U sobre vías principales.
- Nunca genera contravía.
- Excluye autopistas y troncales (no tienen locales y cuestan kilómetros de
  retornos).

## Zonas empinadas

Si el desnivel del sector supera 25 m, la ruta se genera **abierta de arriba
hacia abajo**: empieza en el punto más alto, agota la parte alta en bandas de
altura y termina abajo. Los enlaces prefieren bajar. Ideal para recorrer en moto.

La elevación se descarga de OpenTopoData (SRTM 30 m) y queda en caché.

## Pipeline (PC)

Requiere Python con `geopandas`, `osmnx` y `requests`.

```
python pipeline/build_routes.py --per-sector        # lo que usa la app
python pipeline/build_routes.py --per-sector --zones 2   # solo una zona
python pipeline/build_routes.py --only 005610       # una combinación
python pipeline/build_routes.py --bands 2 --climb-factor 2.5   # calibración
```

Para cada combinación en vehículo calcula hasta cuatro variantes y se queda con
la más corta: *sentido libre* (cuando todas las calles del sector son de doble
sentido), *una pasada por calle*, *ida y vuelta* y *voraz* (siempre a la calle
pendiente más cercana).

Todas pasan por un re-enlace que conoce los giros: conserva el orden de las
calles y las une por el camino legal más corto (Dijkstra sobre arcos, con
restricciones de giro y sin vueltas en U en vías principales). Las calles que
un enlace pisa de paso quedan cubiertas y no se repiten. Después, a cada
variante se le optimiza el orden (Or-opt: mover calles o bloques de hasta 3 y
probar el otro sentido en calles de doble sentido) con distancias legales
reales. Se elige la más corta; en zonas empinadas, la que menos sube.

Frente a la versión anterior (parche de desvíos de ~1 km por giro prohibido),
las rutas en vehículo salen ~44 % más cortas en total y sin giros prohibidos.

El grafo se baja con 2500 m de margen alrededor de los sectores: con menos, las
calles de un solo sentido perdían su retorno y en Suba se caían sectores
enteros en vehículo. Las cachés de elevación y restricciones se completan solas
si el grafo crece.

La app solo usa las rutas **por sector** (`--per-sector`) y las une al vuelo.
Después de regenerar, copiar a la app sin espejar la carpeta completa (en
`app_assets/routes` quedan combinaciones viejas que inflarían el APK):

```
robocopy app_assets app\assets routes_index.json sectors_streets.json sectors.geojson
robocopy app_assets\routes app\assets\routes route_??????_*.geojson
cd app
flutter test      # comprueba que las rutas se leen, sin saltos y con índices al día
```

## App (Android)

- Selección de sectores combinables por zona + modo (a pie / vehículo).
- Navegación giro a giro con voz, flechas sobre la ruta y mapa que gira con la
  brújula.
- Recálculo con **Google Routes API** cuando te desvías (clave embebida en
  `app/assets/google_api_key.txt`, no está en el repo — copiar
  `google_api_key.txt.example` a `google_api_key.txt` y pegar ahí tu clave;
  sin ella la app cae directo a OSRM y grafo interno); OSRM y grafo interno
  como respaldo.
- **Chinchetas de ofertas**: botón rojo grande, numeración correlativa que nunca
  se reutiliza, nota editable, exportación en CSV al portapapeles.
- **Ventana flotante**: burbuja encima de otras apps (p. ej. la cámara con
  fecha/hora) para marcar ofertas sin salir de la cámara. Requiere el permiso
  "Mostrar sobre otras aplicaciones".
- El avance y las ofertas se guardan en el teléfono y sobreviven cierres.

Compilar:

```
cd app
flutter build apk --release
```

El APK queda en `app/build/app/outputs/flutter-apk/app-release.apk`.

## Demo rápida (para mostrar la app sin instalar nada)

Doble clic en **`DEMO.bat`**: abre la app en el navegador (Chrome) usando un
servidor local ligero (Python, puerto 8765). Sirve para hacer demostraciones
o vender la app en un PC sin Android — cualquiera con esta carpeta la puede
correr. Para cerrar, cerrar la ventana de consola que abre el `.bat`.

Es un build web (`demo_web/`) hecho con `flutter build web --release`. No
tiene la ventana flotante sobre otras apps (es un plugin solo de Android) ni
brújula/GPS reales — para eso se necesita el APK en un teléfono. Sirve para
mostrar cobertura de calles, navegación, chinchetas de ofertas y el resto de
la interfaz.

Si cambia el código y hay que actualizar la demo:

```
cd app
flutter build web --release
robocopy build\web ..\demo_web /MIR
```

## Pendiente: todos los sectores catastrales

**Objetivo (a futuro, sin prisa):** cargar los 1230 sectores de `SECTOR.gpkg`,
no solo los de los mercados actuales. Por ahora la zona 5 toma 4 sectores con
el filtro `"codes"` de `ZONES` en `pipeline/build_routes.py`. Para ampliar a
otros sectores basta con sumar códigos ahí o crear otra zona.

Qué hay que resolver antes de cargarlos todos:

1. **Agrupar en mercados.** No sirve una sola zona con toda Bogotá: el grafo
   con 2500 m de margen sería enorme. Conviene una zona por localidad o por
   grupo de barrios vecinos, con su propio `codes`. Cada zona es además un
   proyecto aparte en la app (sus ofertas y su avance).
2. **Tiempo de cómputo.** En vehículo cada sector tarda de 10 a 60 s
   (sobre todo la tabla de distancias del optimizador), más el modo a pie.
   Para 1230 sectores hablamos de horas: correr por zonas
   (`--per-sector --zones N`) en varias sesiones.
3. **Sectores rurales.** 139 sectores son de tipo 1 (rurales, mediana de
   226 ha y hasta 10 600 ha), más 91 de tipo 2 (mezcla urbano-rural: Tibaque,
   Pasquilla…). Decidir si se incluyen; en vehículo pueden salir rutas muy
   largas o sin componente enrutable.
4. **Peso del APK.** Hoy las rutas pesan ~114 KB por sector (a pie + vehículo):
   1230 sectores serían ~140 MB. Con gzip bajan a ~15 MB. Hay que comprimir
   los assets, o descargar las rutas bajo demanda en vez de empaquetarlas.
5. **Pantalla de selección.** La lista y el mapa de inicio dibujan todos los
   sectores. Con 1230 hacen falta un buscador por nombre o código, elegir
   tocando el mapa, y mostrar solo los polígonos de la zona activa.
6. **Descargas externas.** Cada zona nueva baja el grafo de OSM, la elevación
   (OpenTopoData, 1 llamada por segundo) y las restricciones (Overpass, que
   a veces responde 504). Todo queda en `pipeline/cache`, así que se puede
   reanudar.

## Si los sectores cambian

Reemplazar el shapefile (o agregar una zona nueva en `ZONES` dentro de
`pipeline/build_routes.py`), correr el pipeline, copiar `app_assets` a
`app/assets` y recompilar.
