# -*- coding: utf-8 -*-
"""
Pipeline de rutas de cobertura total por sectores catastrales.

Modelo de cobertura (v2):
  - Se cuenta por CALLE, no por sentido: una sola pasada la deja cubierta,
    vaya de ida o de vuelta.
  - En vías ANCHAS de doble sentido se agrega una segunda pasada marcada
    como "recheck": la ruta sí te guía por ella, pero NO cuenta para el 100%.
  - Los tramos de enlace entre calles son "link" y tampoco cuentan.

Legalidad (modo vehículo):
  - Respeta sentidos únicos, restricciones de giro de OSM y prohíbe la
    vuelta en U sobre vías principales (inserta el desvío legal).

Zonas empinadas:
  - Ruta ABIERTA de arriba hacia abajo, prefiriendo bajadas (ideal en moto).
"""
import argparse
import heapq
import itertools
import json
import math
import os
import time

import geopandas as gpd
import networkx as nx
import osmnx as ox
import requests
from shapely.geometry import Point, mapping
from shapely.ops import unary_union
from shapely.prepared import prep

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(BASE, "app_assets")
CACHE = os.path.join(BASE, "pipeline", "cache")

ZONES = [
    {"id": "1", "shp": "MERCADO_170726.shp", "name": "Engativá"},
    {"id": "2", "shp": "MERCADO_2_SHPS.shp", "name": "Bosque de Pinos"},
    {"id": "3", "shp": "MERCADO 3.shp", "name": "Suba / Casablanca"},
    # GeoPackage en vez de shapefile; trae las mismas columnas SCACODIGO/SCANOMBRE
    {"id": "4", "shp": "MERCADO_ZONAS_DURAS.gpkg", "layer": "sector",
     "name": "Zonas Duras"},
    # SECTOR.gpkg trae los 1230 sectores catastrales de Bogotá; "codes" toma
    # solo los de este mercado. PENDIENTE: cargar todos los sectores (ver
    # "Pendiente: todos los sectores catastrales" en el README).
    {"id": "5", "shp": "SECTOR.gpkg", "layer": "SECTOR",
     "codes": ["002205", "002308", "002401", "002406"],
     "name": "Tunal / Santa Lucía"},
]

ox.settings.use_cache = True
ox.settings.cache_folder = os.path.join(CACHE, "osmnx")
ox.settings.log_console = False

# margen del grafo base alrededor de los sectores. Con 800 m se cortaban los
# retornos de las calles de un solo sentido y en zonas dispersas (Suba) se
# perdían sectores enteros en vehículo; con 2500 m quedan en un solo componente.
BUFFER_M = 2500
RELIEF_OPEN_M = 25    # desnivel a partir del cual la ruta se hace abierta
CLIMB_PENALTY = 15    # peso por metro de subida al ordenar el recorrido
CLIMB_FACTOR = 2.5    # peso por metro de subida al elegir enlaces
RESTR = {}            # índice de restricciones de giro de la zona en curso

MAJOR_HW = {"motorway", "motorway_link", "trunk", "trunk_link",
            "primary", "primary_link", "secondary", "secondary_link"}
WIDE_HW = {"trunk", "trunk_link", "primary", "primary_link",
           "secondary", "secondary_link"}
SKIP_HW = {"motorway", "motorway_link", "trunk", "trunk_link"}


# ---------------------------------------------------------------------------
# Ingesta
# ---------------------------------------------------------------------------

def load_sectors(zone):
    path = os.path.join(BASE, zone["shp"])
    layer = zone.get("layer")   # los GeoPackage llevan capa; los shapefile no
    g = gpd.read_file(path, layer=layer) if layer else gpd.read_file(path)
    if zone.get("codes"):   # capa con más sectores que los del mercado
        g = g[g["SCACODIGO"].isin(zone["codes"])]
        missing = set(zone["codes"]) - set(g["SCACODIGO"])
        if missing:
            raise ValueError(f"zona {zone['id']}: códigos no encontrados en "
                             f"{zone['shp']}: {sorted(missing)}")
    g = g.to_crs(epsg=4326)
    g = g.sort_values("SCACODIGO").reset_index(drop=True)
    g["zone"] = zone["id"]
    g["zone_name"] = zone["name"]
    return g


def base_polygon(sectors):
    return unary_union(sectors.geometry.values).buffer(BUFFER_M / 111_000)


def download_graph(polygon):
    return ox.graph_from_polygon(
        polygon, network_type="drive", simplify=True,
        retain_all=True, truncate_by_edge=True,
    )


def largest_scc(G):
    """Componente fuertemente conexo mayor: universo válido para circular."""
    comp = max(nx.strongly_connected_components(G),
               key=lambda c: G.subgraph(c).size(weight="length"))
    return G.subgraph(comp).copy()


def scc_list(G):
    """Componentes fuertemente conexos (conjuntos de nodos), del mayor al menor.
    Se usan en vehículo: hace falta poder circular respetando sentidos."""
    return sorted((set(c) for c in nx.strongly_connected_components(G)),
                  key=len, reverse=True)


def wcc_list(G):
    """Componentes débilmente conexos. Se usan A PIE: al peatón no le importa el
    sentido, así que basta con que las calles estén unidas sin dirección. Rescata
    sectores con calles sin salida que el modo vehículo no puede enlazar."""
    return sorted((set(c) for c in nx.weakly_connected_components(G)),
                  key=len, reverse=True)


def component_for(arcs, G, sccs):
    """El SCC que cubre MÁS calle de estos arcos. Cada sector se resuelve dentro
    de su propio componente: en una zona dispersa (Suba, Torca, Guaymaral… a
    kilómetros) un sector aislado ya no se pierde por quedar fuera del componente
    mayor de toda la zona (que era el bug de 'sin calles')."""
    best, best_len = None, 0.0
    for comp in sccs:
        L = sum(G.edges[u, v, k].get("length", 0.0)
                for (u, v, k) in arcs if u in comp and v in comp)
        if L > best_len:
            best_len, best = L, comp
    return best


def clip_nodes(G, polygon):
    p = prep(polygon)
    return [n for n, d in G.nodes(data=True) if p.covers(Point(d["x"], d["y"]))]


def edges_in_polygon(G, polygon):
    """Arcos cuya mitad cae dentro del sector. Mejor que exigir los dos
    extremos: incluye las calles del borde y no fragmenta la zona.
    Se excluyen autopistas y troncales: no tienen locales que verificar y
    recorrerlas cuesta kilómetros de retornos."""
    p = prep(polygon)
    out = []
    for u, v, k, d in G.edges(keys=True, data=True):
        hw = d.get("highway", "")
        hws = set(hw) if isinstance(hw, list) else {hw}
        if hws & SKIP_HW:
            continue
        coords = edge_geometry(G, u, v, k)
        mx = (coords[len(coords) // 2][0] + coords[(len(coords) - 1) // 2][0]) / 2
        my = (coords[len(coords) // 2][1] + coords[(len(coords) - 1) // 2][1]) / 2
        if p.covers(Point(mx, my)):
            out.append((u, v, k))
    return out


def add_climb_weights(G, elev, factor=CLIMB_FACTOR):
    """Peso de circulación que penaliza subir: los enlaces prefieren bajar."""
    for u, v, k, d in G.edges(keys=True, data=True):
        climb = max(0.0, elev.get(v, 0.0) - elev.get(u, 0.0))
        d["wclimb"] = d.get("length", 1.0) + factor * climb


# ---------------------------------------------------------------------------
# Elevación (OpenTopoData SRTM 30 m, con caché)
# ---------------------------------------------------------------------------

def fetch_elevations(G, zone_id):
    """Elevación por nodo. La caché se completa: si el grafo crece (más margen,
    calles nuevas en OSM) solo se piden los nodos que faltan. Antes se devolvía
    la caché tal cual y los nodos nuevos quedaban en 0 m, con subidas falsas
    de 2600 m que desviaban todos los enlaces."""
    cache_file = os.path.join(CACHE, f"elev_{zone_id}.json")
    elev = {}
    if os.path.exists(cache_file):
        with open(cache_file, encoding="utf-8") as f:
            elev = {int(k): v for k, v in json.load(f).items()}
    nodes = [n for n in G.nodes if n not in elev]
    if not nodes:
        return elev
    print(f"  descargando elevación de {len(nodes)} nodos...")
    unfilled = []
    for i in range(0, len(nodes), 100):
        chunk = nodes[i:i + 100]
        locs = "|".join(f"{G.nodes[n]['y']:.6f},{G.nodes[n]['x']:.6f}" for n in chunk)
        ok = False
        for attempt in range(3):
            try:
                r = requests.get("https://api.opentopodata.org/v1/srtm30m",
                                 params={"locations": locs}, timeout=40,
                                 headers={"User-Agent": "mercado-rutas/2.0"})
                j = r.json()
                if j.get("status") == "OK":
                    for n, res in zip(chunk, j["results"]):
                        e = res.get("elevation")
                        elev[n] = float(e) if e is not None else 0.0
                    ok = True
                    break
            except Exception as ex:
                print(f"    reintento elevación ({ex})")
            time.sleep(2)
        if not ok:
            unfilled.extend(chunk)
        time.sleep(1.1)  # límite de 1 llamada/segundo
    os.makedirs(CACHE, exist_ok=True)
    with open(cache_file, "w", encoding="utf-8") as f:
        json.dump({str(k): v for k, v in elev.items()}, f)
    if unfilled:
        # sin dato no se inventa 0 m (sería un cerro falso): se usa la media
        # de lo conocido, sin guardarla, para reintentar en la próxima corrida
        print(f"    [aviso] {len(unfilled)} nodos sin elevación (se usa la media)")
        fill = sum(elev.values()) / len(elev) if elev else 0.0
        for n in unfilled:
            elev[n] = fill
    return elev


# ---------------------------------------------------------------------------
# Restricciones de giro
# ---------------------------------------------------------------------------

def fetch_restrictions(polygon, zone_id):
    """Restricciones de giro de OSM. La caché guarda el recuadro pedido y se
    renueva si el grafo ya no cabe en él (p. ej. al ampliar BUFFER_M)."""
    cache_file = os.path.join(CACHE, f"restrictions_{zone_id}.json")
    minx, miny, maxx, maxy = polygon.bounds
    cached = None
    if os.path.exists(cache_file):
        with open(cache_file, encoding="utf-8") as f:
            cached = json.load(f)
        # formato viejo (lista sin recuadro): vale solo como respaldo
        if isinstance(cached, dict):
            bminx, bminy, bmaxx, bmaxy = cached["bounds"]
            if (bminx <= minx and bminy <= miny
                    and bmaxx >= maxx and bmaxy >= maxy):
                return cached["items"]
            cached = cached["items"]
    q = (f'[out:json][timeout:60];'
         f'relation["type"="restriction"]({miny},{minx},{maxy},{maxx});out body;')
    headers = {"User-Agent": "mercado-rutas-pipeline/2.0"}
    els = None
    # Overpass suele devolver 504 cuando está saturado: varias rondas con
    # espera antes de rendirse
    for attempt in range(3):
        if attempt:
            time.sleep(30)
        for url in ("https://lz4.overpass-api.de/api/interpreter",
                    "https://overpass-api.de/api/interpreter",
                    "https://overpass.kumi.systems/api/interpreter"):
            try:
                r = requests.post(url, data={"data": q}, timeout=90,
                                  headers=headers)
                if r.status_code != 200:
                    print(f"  [overpass] {url} respondió {r.status_code}")
                    continue
                els = r.json().get("elements", [])
                break
            except Exception as ex:
                print(f"  [overpass] {url} falló: {ex}")
        if els is not None:
            break
    if els is None:
        if cached is not None:
            print("  [aviso] sin Overpass: se usan las restricciones viejas "
                  "(pueden faltar las de las orillas del grafo)")
            return cached
        raise RuntimeError("No se pudieron descargar las restricciones de giro")
    out = []
    for rel in els:
        rtype = rel.get("tags", {}).get("restriction", "")
        if not rtype:
            continue
        frm = via = to = None
        for m in rel.get("members", []):
            if m.get("role") == "from" and m.get("type") == "way":
                frm = m["ref"]
            elif m.get("role") == "via" and m.get("type") == "node":
                via = m["ref"]
            elif m.get("role") == "to" and m.get("type") == "way":
                to = m["ref"]
        if frm is not None and via is not None and to is not None:
            out.append({"rtype": rtype, "from_way": frm,
                        "via_node": via, "to_way": to})
    os.makedirs(CACHE, exist_ok=True)
    with open(cache_file, "w", encoding="utf-8") as f:
        json.dump({"bounds": [minx, miny, maxx, maxy], "items": out}, f)
    return out


def build_restriction_index(restrictions):
    idx = {}
    for r in restrictions:
        idx.setdefault(r["via_node"], []).append(r)
    return idx


def major_nodes(G):
    out = set()
    for u, v, k, d in G.edges(keys=True, data=True):
        hw = d.get("highway", "")
        hws = set(hw) if isinstance(hw, list) else {hw}
        if hws & MAJOR_HW:
            out.add(u)
            out.add(v)
    return out


def edge_ways(G, u, v, k):
    osmid = G.edges[u, v, k].get("osmid", [])
    return set(osmid) if isinstance(osmid, list) else {osmid}


# ---------------------------------------------------------------------------
# Geometría y giros
# ---------------------------------------------------------------------------

def edge_geometry(G, u, v, k):
    data = G.edges[u, v, k]
    if "geometry" in data:
        return list(data["geometry"].coords)
    return [(G.nodes[u]["x"], G.nodes[u]["y"]), (G.nodes[v]["x"], G.nodes[v]["y"])]


def edge_name(G, u, v, k):
    name = G.edges[u, v, k].get("name", "")
    if isinstance(name, list):
        name = name[0]
    return name or ""


def bearing(p1, p2):
    lon1, lat1, lon2, lat2 = map(math.radians, (*p1, *p2))
    dlon = lon2 - lon1
    x = math.sin(dlon) * math.cos(lat2)
    y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def edge_bearings(G, u, v, k):
    coords = edge_geometry(G, u, v, k)
    if len(coords) < 2:
        return 0.0, 0.0
    return bearing(coords[0], coords[1]), bearing(coords[-2], coords[-1])


def _angdiff(a, b):
    return abs((b - a + 540) % 360 - 180)


def is_uturn(G, e1, e2):
    _, b_in = edge_bearings(G, *e1)
    b_out, _ = edge_bearings(G, *e2)
    return _angdiff(b_in, b_out) > 150


def turn_is_legal(G, e1, e2, restr_idx, major=frozenset()):
    n = e1[1]
    rules = restr_idx.get(n)
    if rules:
        w1 = edge_ways(G, *e1)
        w2 = edge_ways(G, *e2)
        for r in rules:
            if r["from_way"] not in w1:
                continue
            if r["rtype"].startswith("no_"):
                if r["to_way"] in w2:
                    return False
            elif r["rtype"].startswith("only_"):
                if r["to_way"] not in w2:
                    return False
    if n in major and G.out_degree(n) > 1 and is_uturn(G, e1, e2):
        return False
    return True


def turn_instruction(prev_coords, next_coords, next_name, mode="drive"):
    b_in = bearing(prev_coords[-2], prev_coords[-1])
    b_out = bearing(next_coords[0], next_coords[1])
    delta = (b_out - b_in + 540) % 360 - 180
    mag = abs(delta)
    calle = f" por {next_name}" if next_name else ""
    if mag < 25:
        return "continue", f"Continúa recto{calle}"
    if mag > 160:
        if mode == "walk":
            return "uturn", f"Regresa por la misma calle{calle}"
        return "uturn", f"Da la vuelta{calle}"
    side = "derecha" if delta > 0 else "izquierda"
    if mag < 60:
        return f"slight_{side}", f"Gira levemente a la {side}{calle}"
    if mag < 135:
        return side, f"Gira a la {side}{calle}"
    return f"sharp_{side}", f"Gira cerrado a la {side}{calle}"


# ---------------------------------------------------------------------------
# Calles (cobertura por calle, no por sentido)
# ---------------------------------------------------------------------------

def street_key(G, u, v, k):
    """Identidad de la CALLE: igual para los dos sentidos del mismo tramo."""
    L = G.edges[u, v, k].get("length", 0.0)
    return f"{min(u, v)}-{max(u, v)}-{round(L)}"


def is_wide(G, u, v, k):
    """¿Vía ancha? (amerita segunda pasada para ver el otro costado)"""
    d = G.edges[u, v, k]
    hw = d.get("highway", "")
    hws = set(hw) if isinstance(hw, list) else {hw}
    if hws & WIDE_HW:
        return True
    for key, thr in (("lanes", 4), ("width", 12)):
        val = d.get(key)
        if not val:
            continue
        vals = val if isinstance(val, list) else [val]
        for x in vals:
            try:
                if float(str(x).split()[0]) >= thr:
                    return True
            except (ValueError, IndexError):
                pass
    return False


# ---------------------------------------------------------------------------
# Cartero Chino dirigido con conjunto requerido (modo vehículo)
# ---------------------------------------------------------------------------

def build_required_drive(arcs_in, G, elev, both_ways=False):
    """Arcos a cubrir. La primera pasada de cada calle es "cover" (cuenta para
    el 100%); la segunda, cuando se incluye, es "recheck" (guía pero no cuenta).

    both_ways=False: una sola pasada por calle (+ segunda en vías anchas).
    both_ways=True : ida y vuelta en toda calle de doble sentido.
    """
    streets = {}
    for (u, v, k) in arcs_in:
        streets.setdefault(street_key(G, u, v, k), []).append((u, v, k))
    req = {}
    for skey, arcs in streets.items():
        if len(arcs) == 1:
            req[arcs[0]] = ("cover", skey)
            continue
        # doble sentido: se cubre bajando; la vuelta es revisión opcional
        arcs = sorted(arcs, key=lambda a: elev.get(a[0], 0) - elev.get(a[1], 0),
                      reverse=True)
        req[arcs[0]] = ("cover", skey)
        if both_ways or is_wide(G, *arcs[0]):
            for other in arcs[1:]:
                req[other] = ("recheck", skey)
    return req


def _sp_paths(G, sources, targets, weight="wclimb"):
    """Dijkstra desde cada fuente; devuelve (dist, path) hacia los objetivos."""
    dists, paths = {}, {}
    tset = set(targets)
    for s in sources:
        d, p = nx.single_source_dijkstra(G, s, weight=weight)
        dists[s] = {t: d[t] for t in tset if t in d}
        paths[s] = {t: p[t] for t in tset if t in p}
    return dists, paths


def _add_path_arcs(W, G, path, role="link"):
    for x, y in zip(path[:-1], path[1:]):
        for n in (x, y):
            if n not in W:
                W.add_node(n, **G.nodes[n])
        k = min(G[x][y], key=lambda kk: G[x][y][kk].get("length", 0))
        W.add_edge(x, y, orig=(x, y, k), role=role, skey=None,
                   length=G.edges[x, y, k].get("length", 0.0))


def connect_required(W, G):
    """Hace W fuertemente conexo agregando caminos legales de G como enlaces."""
    for _ in range(500):
        if len(W) == 0 or nx.is_strongly_connected(W):
            break
        comps = sorted(nx.strongly_connected_components(W), key=len, reverse=True)
        base, comp = set(comps[0]), set(comps[1])
        try:
            d1, p1 = nx.multi_source_dijkstra(G, sources=base, weight="wclimb")
            fwd = min(((d1[n], n) for n in comp if n in d1), default=None)
            d2, p2 = nx.multi_source_dijkstra(G, sources=comp, weight="wclimb")
            bwd = min(((d2[n], n) for n in base if n in d2), default=None)
        except Exception:
            fwd = bwd = None
        if fwd is None or bwd is None:
            lost = W.subgraph(comp).size(weight="length")
            print(f"    [aviso] componente inalcanzable: se omiten {lost:.0f} m")
            W.remove_nodes_from(comp)
            continue
        _add_path_arcs(W, G, p1[fwd[1]])
        _add_path_arcs(W, G, p2[bwd[1]])
    return W


def _path_length(G, path):
    total = 0.0
    for x, y in zip(path[:-1], path[1:]):
        k = min(G[x][y], key=lambda kk: G[x][y][kk].get("length", 0))
        total += G.edges[x, y, k].get("length", 0.0)
    return total


def _balance_shortest_paths(W, G, imb):
    """Equilibrado (a): caminos mínimos libres por todo el grafo."""
    supply = [n for n, d in imb.items() if d < 0]
    demand = [n for n, d in imb.items() if d > 0]
    dists, paths = _sp_paths(G, supply, demand)
    F = nx.DiGraph()
    for n in supply + demand:
        F.add_node(n, demand=imb[n])
    for a in supply:
        for b, d in dists.get(a, {}).items():
            F.add_edge(a, b, weight=max(1, int(round(d))))
    flow = nx.min_cost_flow(F)
    plan, cost = [], 0.0
    for a, targets in flow.items():
        for b, f in targets.items():
            if f <= 0:
                continue
            path = paths[a][b]
            plan.append((path, f))
            cost += f * _path_length(G, path)
    return plan, cost


def _balance_own_arcs(W, G, imb):
    """Equilibrado (b): repetir arcos del propio recorrido (CPP dirigido
    clásico). Suele ganar cuando hay que cubrir la malla completa."""
    F = nx.DiGraph()
    for n in W.nodes:
        F.add_node(n, demand=imb[n])
    for u, v, k, d in W.edges(keys=True, data=True):
        if d.get("orig") is None:
            # arco artificial fin->inicio de las rutas abiertas: no es calle,
            # repetirlo reventaba al buscarlo en G
            continue
        L = d.get("length", 1.0)
        w = max(1, int(round(L)))
        if not F.has_edge(u, v) or F[u][v]["weight"] > w:
            F.add_edge(u, v, weight=w, length=L)
    flow = nx.min_cost_flow(F)
    plan, cost = [], 0.0
    for a, targets in flow.items():
        for b, f in targets.items():
            if f <= 0:
                continue
            plan.append(([a, b], f))
            cost += f * F[a][b]["length"]
    return plan, cost


def balance_directed(W, G):
    """Equilibra grados (in==out) con la estrategia más barata de las dos."""
    imb = {n: W.out_degree(n) - W.in_degree(n) for n in W.nodes}
    if not any(d < 0 for d in imb.values()):
        return W
    best = None
    for fn in (_balance_shortest_paths, _balance_own_arcs):
        try:
            plan, cost = fn(W, G, imb)
        except (nx.NetworkXUnfeasible, nx.NodeNotFound, KeyError):
            continue
        if best is None or cost < best[0]:
            best = (cost, plan)
    if best is None:
        print("    [aviso] no se pudo equilibrar por completo")
        return W
    for path, f in best[1]:
        for _ in range(f):
            _add_path_arcs(W, G, path)
    return W


def turn_aware_circuit(W, G, major, elev, start=None, restr_idx=None):
    """Circuito euleriano que prefiere seguir derecho, evita giros prohibidos
    y vueltas en U en vías principales, y penaliza las subidas."""
    restr_idx = restr_idx or {}
    binfo, climb, orig = {}, {}, {}
    for u, v, k, d in W.edges(keys=True, data=True):
        o = d.get("orig")
        orig[(u, v, k)] = o
        binfo[(u, v, k)] = edge_bearings(G, *o) if o else (0.0, 0.0)
        climb[(u, v, k)] = max(0.0, elev.get(v, 0.0) - elev.get(u, 0.0))

    unused = {n: set() for n in W.nodes}
    for u, v, k in W.edges(keys=True):
        unused[u].add((u, v, k))

    def pick(n, b_in, e_prev):
        best, best_c = None, float("inf")
        for e in unused[n]:
            c = CLIMB_PENALTY * climb[e]
            if b_in is not None:
                delta = _angdiff(b_in, binfo[e][0])
                c += delta
                if delta > 150:
                    c += 800
                    if n in major:
                        c += 5000
            # giro prohibido: evitarlo aquí sale mucho más barato que
            # repararlo después con un desvío
            if e_prev is not None and orig[e_prev] and orig[e]:
                if not turn_is_legal(G, orig[e_prev], orig[e], restr_idx, major):
                    c += 100000
            if c < best_c:
                best_c, best = c, e
        return best

    def walk(n, b_in, e_prev=None):
        path, cur, b, prev = [], n, b_in, e_prev
        while unused[cur]:
            e = pick(cur, b, prev)
            unused[cur].discard(e)
            path.append(e)
            b = binfo[e][1]
            prev = e
            cur = e[1]
        return path

    if start is None or not unused.get(start):
        start = max((n for n in W.nodes if unused[n]),
                    key=lambda n: elev.get(n, 0.0), default=None)
    if start is None:
        return []
    circuit = walk(start, None, None)
    while True:
        spliced = False
        for idx in range(len(circuit)):
            n = circuit[idx][0]
            if unused[n]:
                prev = circuit[idx - 1] if idx > 0 else None
                b_in = binfo[prev][1] if prev else None
                sub = walk(n, b_in, prev)
                circuit = circuit[:idx] + sub + circuit[idx:]
                spliced = True
                break
        if not spliced:
            break
    return circuit


def path_link_steps(G, a, b):
    """Tramos de enlace (deadhead) de a hasta b por el camino más cómodo."""
    if a == b:
        return []
    try:
        p = nx.shortest_path(G, a, b, weight="wclimb")
    except (nx.NetworkXNoPath, nx.NodeNotFound):
        return []
    out = []
    for x, y in zip(p[:-1], p[1:]):
        k = min(G[x][y], key=lambda kk: G[x][y][kk].get("length", 0))
        out.append({"u": x, "v": y, "k": k, "role": "link",
                    "skey": None, "rev": False})
    return out


def solve_drive(req, G, major, elev, open_path, start_hint=None):
    """Devuelve la secuencia de pasos [{u,v,k,role,skey,rev}]."""
    W = nx.MultiDiGraph()
    for (u, v, k), (role, skey) in req.items():
        for n in (u, v):
            if n not in W:
                W.add_node(n, **G.nodes[n])
        W.add_edge(u, v, orig=(u, v, k), role=role, skey=skey,
                   length=G.edges[u, v, k].get("length", 0.0))
    W = connect_required(W, G)
    if len(W) == 0:
        return []

    art = top = None
    if open_path:
        if start_hint is not None and start_hint in W:
            top = start_hint
        elif start_hint is not None:
            try:
                d = nx.single_source_dijkstra_path_length(G, start_hint,
                                                          weight="wclimb")
                cand = [(d[n], n) for n in W.nodes if n in d]
                top = min(cand)[1] if cand else None
            except nx.NodeNotFound:
                top = None
        if top is None:
            top = max(W.nodes, key=lambda n: elev.get(n, 0.0))
        bottom = min(W.nodes, key=lambda n: elev.get(n, 0.0))
        if top != bottom:
            # arco artificial fin->inicio: convierte el circuito en ruta abierta
            key = W.add_edge(bottom, top, orig=None, role="artificial",
                             skey=None, length=0.0)
            art = (bottom, top, key)

    W = balance_directed(W, G)
    circuit = turn_aware_circuit(W, G, major, elev, start=top, restr_idx=RESTR)

    if art is not None:
        pos = next((i for i, e in enumerate(circuit)
                    if W.edges[e].get("role") == "artificial"), None)
        if pos is not None:
            circuit = circuit[pos + 1:] + circuit[:pos]
        circuit = [e for e in circuit if W.edges[e].get("role") != "artificial"]

    steps = []
    for e in circuit:
        d = W.edges[e]
        if d.get("orig") is None:
            continue
        u, v, k = d["orig"]
        steps.append({"u": u, "v": v, "k": k, "role": d["role"],
                      "skey": d["skey"], "rev": False})
    return steps


def solve_drive_banded(req, G, major, elev, n_bands):
    """Divide las calles en bandas de altura y las cubre de arriba hacia
    abajo: se agota la parte alta antes de bajar (ideal en moto)."""
    items = sorted(req.items(),
                   key=lambda it: (elev.get(it[0][0], 0.0) + elev.get(it[0][1], 0.0)) / 2,
                   reverse=True)
    total = sum(G.edges[a].get("length", 0.0) for a, _ in items)
    bands, cur, acc = [], [], 0.0
    for a, meta in items:
        cur.append((a, meta))
        acc += G.edges[a].get("length", 0.0)
        if acc >= total / n_bands and len(bands) < n_bands - 1:
            bands.append(cur)
            cur, acc = [], 0.0
    if cur:
        bands.append(cur)

    steps, prev_end = [], None
    for i, band in enumerate(bands):
        st = solve_drive(dict(band), G, major, elev, True, start_hint=prev_end)
        if not st:
            continue
        if prev_end is not None:
            steps.extend(path_link_steps(G, prev_end, st[0]["u"]))
        steps.extend(st)
        prev_end = st[-1]["v"]
        print(f"      banda {i+1}/{len(bands)}: {len(st)} tramos")
    return steps


class Coverage:
    """Avance mientras se arma la ruta: qué calles ya se pisaron (cuentan por
    calle, en cualquier sentido) y qué arcos de vías anchas ya se hicieron
    (esas piden pasar por los dos costados)."""

    def __init__(self, arc_skey, wide_skeys):
        self.arc_skey = arc_skey
        self.wide = wide_skeys
        self.streets, self.arcs = set(), set()

    def useful(self, e):
        sk = self.arc_skey.get(e)
        if sk is None:
            return False
        return sk not in self.streets or (sk in self.wide and e not in self.arcs)

    def take(self, e):
        """Marca el arco recorrido y devuelve (role, skey) para exportarlo."""
        sk = self.arc_skey.get(e)
        if sk is None:
            role = "link"
        elif sk not in self.streets:
            role = "cover"
        elif sk in self.wide and e not in self.arcs:
            role = "recheck"
        else:
            role, sk = "link", None
        self.arcs.add(e)
        if sk:
            self.streets.add(sk)
        return role, sk


def _step(e, role, skey):
    return {"u": e[0], "v": e[1], "k": e[2], "role": role, "skey": skey,
            "rev": False}


def turn_aware_path(G, restr_idx, major, e_from, is_goal, weight="wclimb"):
    """Dijkstra sobre ARCOS (no nodos), tomando solo giros legales. Devuelve
    los arcos que siguen a e_from hasta el primero que cumple is_goal
    (incluido), o None si no hay camino legal."""
    dist, prev = {e_from: 0.0}, {e_from: None}
    pq, cnt = [(0.0, 0, e_from)], 1
    while pq:
        d, _, e = heapq.heappop(pq)
        if d > dist[e]:
            continue
        if e != e_from and is_goal(e):
            path = []
            while e != e_from:
                path.append(e)
                e = prev[e]
            return path[::-1]
        for _, x, k in G.out_edges(e[1], keys=True):
            ne = (e[1], x, k)
            if not turn_is_legal(G, e, ne, restr_idx, major):
                continue
            nd = d + G.edges[ne].get(weight, G.edges[ne].get("length", 1.0))
            if nd < dist.get(ne, float("inf")):
                dist[ne], prev[ne] = nd, e
                heapq.heappush(pq, (nd, cnt, ne))
                cnt += 1
    return None


def relink_legal(steps, G, restr_idx, major, arc_skey, wide_skeys):
    """Rehace los enlaces de una ruta: conserva el ORDEN de sus calles
    requeridas y las une por el camino legal más corto (giros incluidos).
    Salta las calles que un enlace ya pisó de paso. Reemplaza al viejo
    parche de desvíos, que volvía al mismo cruce y sumaba ~1 km por giro."""
    cov = Coverage(arc_skey, wide_skeys)
    out, cur = [], None
    for s in steps:
        if s["role"] not in ("cover", "recheck"):
            continue
        e = (s["u"], s["v"], s["k"])
        if not cov.useful(e):
            continue
        if cur is not None:
            path = turn_aware_path(G, restr_idx, major, cur,
                                   lambda a, e=e: a == e)
            if path is None:
                # tramo sin entrada legal (p. ej. solo se llega con un giro
                # prohibido): se omite en vez de perder la ruta entera
                continue
            for a in path[:-1]:
                out.append(_step(a, *cov.take(a)))
        out.append(_step(e, *cov.take(e)))
        cur = e
    return out


def greedy_cover(G, restr_idx, major, arc_skey, wide_skeys, start):
    """Ruta voraz: desde donde vas, a la calle pendiente más cercana por
    camino legal. A veces le gana al orden del cartero chino."""
    cov = Coverage(arc_skey, wide_skeys)
    out, cur = [_step(start, *cov.take(start))], start
    while True:
        path = turn_aware_path(G, restr_idx, major, cur, cov.useful)
        if not path:
            return out
        for a in path:
            out.append(_step(a, *cov.take(a)))
        cur = path[-1]


class OrderOptimizer:
    """Mejora el ORDEN en que se visitan las calles (Or-opt): mueve calles o
    bloques de hasta 3 a otra posición y prueba el otro sentido en calles de
    doble sentido, con costos legales reales entre calles. Arregla casos como
    salir a la Autopista Norte, dar una vuelta de 9 km y volver al mismo
    cruce porque la calle siguiente quedó mal ordenada."""

    def __init__(self, G, restr_idx, major, arcs_in, arc_skey, wide_skeys,
                 weight="wclimb"):
        self.G, self.restr, self.major = G, restr_idx, major
        self.arc_skey, self.wide = arc_skey, wide_skeys
        # item = calle (se elige el sentido) o, en vías anchas, cada sentido
        # por separado (hay que pasar por los dos costados)
        by_street = {}
        for a in arcs_in:
            by_street.setdefault(arc_skey[a], []).append(a)
        self.options, self.item_of = {}, {}
        for sk, al in by_street.items():
            if sk in wide_skeys:
                for a in al:
                    self.options[(sk, a)] = [a]
                    self.item_of[a] = (sk, a)
            else:
                self.options[sk] = al
                for a in al:
                    self.item_of[a] = sk
        arcs = [a for al in self.options.values() for a in al]
        # float de Python: con numpy, inf - inf avisaba en cada comparación
        self.w = {a: float(G.edges[a].get(weight,
                                          G.edges[a].get("length", 1.0)))
                  for a in arcs}
        self.D = self._table(arcs, weight)

    def _table(self, arcs, weight):
        """D[a][b]: costo legal desde el final de a hasta empezar b. Un
        Dijkstra sobre arcos por cada a, que corta al alcanzar todos."""
        G = self.G
        targets = set(arcs)
        D = {}
        for a in arcs:
            dist, done, row = {a: 0.0}, set(), {}
            pq, cnt, left = [(0.0, 0, a)], 1, len(targets) - 1
            while pq and left > 0:
                d, _, e = heapq.heappop(pq)
                if e in done:
                    continue
                done.add(e)
                if e != a and e in targets:
                    row[e] = d - self.w[e]
                    left -= 1
                for _, x, k in G.out_edges(e[1], keys=True):
                    ne = (e[1], x, k)
                    if ne in done or not turn_is_legal(G, e, ne, self.restr,
                                                       self.major):
                        continue
                    nd = d + float(G.edges[ne].get(
                        weight, G.edges[ne].get("length", 1.0)))
                    if nd < dist.get(ne, float("inf")):
                        dist[ne] = nd
                        heapq.heappush(pq, (nd, cnt, ne))
                        cnt += 1
            D[a] = row
        return D

    def _c(self, a, b):
        # ruta abierta: inicio y fin libres
        if a is None or b is None:
            return 0.0
        return self.D[a].get(b, float("inf"))

    def _optimize(self, seq, budget_s=120):
        c, w, opts = self._c, self.w, self.options
        t0 = time.time()
        improved = True
        while improved and time.time() - t0 < budget_s:
            improved = False
            # 1) cambiar de sentido una calle sin moverla
            for i in range(len(seq)):
                it, cur = seq[i]
                p = seq[i - 1][1] if i > 0 else None
                q = seq[i + 1][1] if i + 1 < len(seq) else None
                base = c(p, cur) + c(cur, q) + w[cur]
                for alt in opts[it]:
                    val = c(p, alt) + c(alt, q) + w[alt]
                    if alt != cur and val < base - 1e-6:
                        seq[i] = (it, alt)
                        cur, base = alt, val
                        improved = True
            # 2) mover bloques de 1..3 calles a la mejor posición
            for L in (1, 2, 3):
                i = 0
                while i + L <= len(seq):
                    seg = seq[i:i + L]
                    p = seq[i - 1][1] if i > 0 else None
                    q = seq[i + L][1] if i + L < len(seq) else None
                    gain = c(p, seg[0][1]) + c(seg[-1][1], q) - c(p, q)
                    if not gain > 1e-6:   # también descarta nan (inf - inf)
                        i += 1
                        continue
                    rest = seq[:i] + seq[i + L:]
                    variants = ([[(seg[0][0], alt)] for alt in opts[seg[0][0]]]
                                if L == 1 else [seg])
                    best = None
                    for j in range(len(rest) + 1):
                        a = rest[j - 1][1] if j > 0 else None
                        b = rest[j][1] if j < len(rest) else None
                        ab = c(a, b)
                        for v in variants:
                            add = c(a, v[0][1]) + c(v[-1][1], b) - ab
                            if L == 1:
                                add += w[v[0][1]] - w[seg[0][1]]
                            if best is None or add < best[0]:
                                best = (add, j, v)
                    if best is not None and best[0] < gain - 1e-6:
                        _, j, v = best
                        seq = rest[:j] + v + rest[j:]
                        improved = True
                    else:
                        i += 1
        return seq

    def improve(self, steps):
        """Reordena las calles de una ruta ya armada y la vuelve a enlazar."""
        seq, seen = [], set()
        for s in steps:
            if s["role"] not in ("cover", "recheck"):
                continue
            a = (s["u"], s["v"], s["k"])
            it = self.item_of.get(a)
            if it is not None and it not in seen:
                seen.add(it)
                seq.append((it, a))
        # calles que la variante no visitó: el optimizador les busca lugar
        seq += [(it, al[0]) for it, al in self.options.items() if it not in seen]
        seq = self._optimize(seq)
        ordered = [_step(a, "cover", self.arc_skey[a]) for _, a in seq]
        return relink_legal(ordered, self.G, self.restr, self.major,
                            self.arc_skey, self.wide)


def steps_cost(steps, G, weight="length"):
    return sum(G.edges[s["u"], s["v"], s["k"]].get(
        weight, G.edges[s["u"], s["v"], s["k"]].get("length", 0.0))
        for s in steps)


def solve_drive_best(arcs_in, G, elev, open_path, major, bands):
    """Calcula la ruta en vehículo por varios caminos y se queda con la más
    corta: (a) sin fijar sentidos, posible cuando todas las calles del
    sector son de doble sentido; (b) fijando el sentido de cada calle;
    (c) ida y vuelta; (d) voraz. Todas pasan por relink_legal, que deja
    la ruta sin giros prohibidos."""
    req = build_required_drive(arcs_in, G, elev)
    need = {sk for (r, sk) in req.values() if r == "cover"}
    has_wide = any(r == "recheck" for r, _ in req.values())
    wide = {sk for (r, sk) in req.values() if r == "recheck"}
    arc_skey = {a: street_key(G, *a) for a in arcs_in}

    # calles a las que no se puede entrar sin un giro prohibido en ningún
    # sentido: no se exigen (casi siempre son tramos cortos mal cortados en OSM)
    def enterable(e):
        return any(turn_is_legal(G, i, e, RESTR, major)
                   for i in G.in_edges(e[0], keys=True))
    blocked = {sk for sk in need
               if not any(enterable(a) for a in arcs_in if arc_skey[a] == sk)}
    if blocked:
        L = sum(G.edges[a].get("length", 0.0) for a in arcs_in
                if arc_skey[a] in blocked) / 2
        print(f"    [aviso] {len(blocked)} calles sin entrada legal "
              f"(~{L:.0f} m): no se exigen")
        need = need - blocked
    raw = []

    def solve(r):
        if open_path and bands > 1:
            return solve_drive_banded(r, G, major, elev, bands)
        return solve_drive(r, G, major, elev, open_path)

    # (a) sin fijar sentidos: solo si toda calle del sector es de doble sentido
    if all_streets_two_way(arcs_in, G) and not has_wide:
        norm = normalize_directed(
            solve_walk(arcs_in, G, elev, open_path,
                       universe=two_way_undirected(G)), G)
        if norm:
            raw.append(("sentido libre", norm))

    # (b) una pasada por calle, con el sentido fijado
    st = solve(req)
    if st:
        raw.append(("una pasada", st))

    # (c) ida y vuelta: el grafo requerido queda mejor conectado y, tras
    #     relink_legal, las vueltas que sobran se descartan solas.
    req_both = build_required_drive(arcs_in, G, elev, both_ways=True)
    if len(req_both) > len(req):
        st = solve(req_both)
        if st:
            raw.append(("ida y vuelta", st))

    # (d) voraz, arrancando donde arranca la primera base (arriba si es cerro)
    if raw:
        s0 = raw[0][1][0]
        raw.append(("voraz", greedy_cover(G, RESTR, major, arc_skey, wide,
                                          (s0["u"], s0["v"], s0["k"]))))

    def complete(s):
        return s and need <= {x["skey"] for x in s if x["role"] == "cover"}

    linked = []
    for name, s in raw:
        if name != "voraz":
            s = relink_legal(s, G, RESTR, major, arc_skey, wide)
        if s:
            linked.append((name, s))
    if not linked:
        return []

    # (e) cada variante con el orden de sus calles optimizado
    opt = OrderOptimizer(G, RESTR, major, arcs_in, arc_skey, wide)
    for name, s in list(linked):
        st = opt.improve(s)
        if st:
            linked.append((name + " + orden", st))

    cands = [(n, s) for n, s in linked if complete(s)]
    if not cands:
        # ninguna llega al 100%: mejor la que más cubre que quedarse sin ruta
        def covered(s):
            return len(need & {x["skey"] for x in s if x["role"] == "cover"})
        top = max(covered(s) for _, s in linked)
        cands = [(n, s) for n, s in linked if covered(s) == top]
        print(f"    [aviso] ninguna variante cubre todo: quedan "
              f"{len(need) - top} calles sin cubrir")

    # en cerro se compara con el peso que castiga subir, para no cambiar la
    # bajada por unos metros menos; en plano, por largo
    metric = "wclimb" if open_path else "length"
    for name, s in cands:
        print(f"      variante {name}: {steps_length(s, G)/1000:.1f} km")
    best = min(cands, key=lambda c: steps_cost(c[1], G, metric))
    print(f"      -> elegida: {best[0]}")
    return best[1]


# ---------------------------------------------------------------------------
# Cartero Chino no dirigido (modo a pie)
# ---------------------------------------------------------------------------

def two_way_undirected(G):
    """Grafo no dirigido con SOLO las calles de doble sentido: recorrerlas en
    cualquier dirección es legal, así que sirve para enlazar en moto/carro."""
    U = nx.Graph()
    for u, v, k, d in G.edges(keys=True, data=True):
        if not G.has_edge(v, u):
            continue
        L = d.get("length", 0.0)
        if not U.has_edge(u, v) or U[u][v]["length"] > L:
            U.add_edge(u, v, length=L, k=k)
    return U


def all_streets_two_way(arcs_in, G):
    for (u, v, k) in arcs_in:
        if not G.has_edge(v, u):
            return False
    return True


def normalize_directed(steps, G):
    """Convierte pasos 'al revés' en el arco inverso real. None si alguno
    resultaría en contravía."""
    out = []
    for s in steps:
        if not s["rev"]:
            out.append(s)
            continue
        u, v, k = s["u"], s["v"], s["k"]
        if not G.has_edge(v, u):
            return None
        kk = min(G[v][u], key=lambda x: G[v][u][x].get("length", 0))
        out.append({**s, "u": v, "v": u, "k": kk, "rev": False})
    return out


def steps_length(steps, G):
    return sum(G.edges[s["u"], s["v"], s["k"]].get("length", 0.0) for s in steps)


def solve_walk(arcs_in, G, elev, open_path, universe=None):
    U = nx.MultiGraph()
    seen = set()
    for (u, v, k) in arcs_in:
        skey = street_key(G, u, v, k)
        if skey in seen:
            continue
        seen.add(skey)
        for n in (u, v):
            if n not in U:
                U.add_node(n, **G.nodes[n])
        U.add_edge(u, v, orig=(u, v, k), role="cover", skey=skey,
                   length=G.edges[u, v, k].get("length", 0.0))

    # grafo no dirigido para enlaces (todo el grafo a pie; solo doble
    # sentido cuando se va en vehículo)
    if universe is not None:
        Ufull = universe
    else:
        Ufull = nx.Graph()
        for u, v, k, d in G.edges(keys=True, data=True):
            L = d.get("length", 0.0)
            if not Ufull.has_edge(u, v) or Ufull[u][v]["length"] > L:
                Ufull.add_edge(u, v, length=L, k=k)

    # conectar componentes usando calles de fuera del sector
    while not nx.is_connected(U):
        comps = sorted(nx.connected_components(U), key=len, reverse=True)
        base, comp = set(comps[0]), set(comps[1])
        srcs = [n for n in base if n in Ufull]
        try:
            d1, p1 = nx.multi_source_dijkstra(Ufull, sources=srcs, weight="length")
            best = min(((d1[n], n) for n in comp if n in d1), default=None)
        except Exception:
            best = None
        if best is None:
            print(f"    [aviso] componente inalcanzable a pie: se omite")
            U.remove_nodes_from(comp)
            continue
        path = p1[best[1]]
        for x, y in zip(path[:-1], path[1:]):
            for n in (x, y):
                if n not in U:
                    U.add_node(n, **G.nodes[n])
            k = Ufull[x][y]["k"]
            orig = (x, y, k) if G.has_edge(x, y, k) else (y, x, k)
            U.add_edge(x, y, orig=orig, role="link", skey=None,
                       length=Ufull[x][y]["length"])

    art = None
    if open_path and len(U) > 1:
        top = max(U.nodes, key=lambda n: elev.get(n, 0.0))
        bottom = min(U.nodes, key=lambda n: elev.get(n, 0.0))
        if top != bottom:
            key = U.add_edge(bottom, top, orig=None, role="artificial",
                             skey=None, length=0.0)
            art = (bottom, top, key)

    # emparejar nodos impares por caminos mínimos
    odd = [n for n, deg in U.degree() if deg % 2 == 1 and n in Ufull]
    if odd:
        dist, paths = {}, {}
        for o in odd:
            d, p = nx.single_source_dijkstra(Ufull, o, weight="length")
            dist[o], paths[o] = d, p
        K = nx.Graph()
        for a, b in itertools.combinations(odd, 2):
            if b in dist[a]:
                K.add_edge(a, b, weight=dist[a][b])
        for a, b in nx.min_weight_matching(K):
            for x, y in zip(paths[a][b][:-1], paths[a][b][1:]):
                k = Ufull[x][y]["k"]
                orig = (x, y, k) if G.has_edge(x, y, k) else (y, x, k)
                U.add_edge(x, y, orig=orig, role="link", skey=None,
                           length=Ufull[x][y]["length"])

    start = max(U.nodes, key=lambda n: elev.get(n, 0.0))
    circuit = list(nx.eulerian_circuit(U, source=start, keys=True))
    flip = False
    if art is not None:
        pos = next((i for i, e in enumerate(circuit)
                    if U.edges[e].get("role") == "artificial"), None)
        if pos is not None:
            # el arco artificial va de "abajo" a "arriba": si el circuito lo
            # recorrió al revés, hay que invertir toda la ruta para bajar.
            flip = circuit[pos][0] != art[0]
            circuit = circuit[pos + 1:] + circuit[:pos]
        circuit = [e for e in circuit if U.edges[e].get("role") != "artificial"]

    steps = []
    for (a, b, k) in circuit:
        d = U.edges[a, b, k]
        if d.get("orig") is None:
            continue
        ou, ov, ok = d["orig"]
        rev = (a, b) != (ou, ov)
        steps.append({"u": ou, "v": ov, "k": ok, "role": d["role"],
                      "skey": d["skey"], "rev": rev})
    if flip:
        steps = [{**s, "rev": not s["rev"]} for s in reversed(steps)]
    return steps


# ---------------------------------------------------------------------------
# Reparación de giros ilegales (vehículo)
# ---------------------------------------------------------------------------

def legal_detour(G, restr_idx, major, e1, e2, max_len=4000):
    n = e1[1]
    pq, dist, prev = [], {}, {}
    for w, x, k in G.out_edges(n, keys=True):
        e = (w, x, k)
        if e == e2 or not turn_is_legal(G, e1, e, restr_idx, major):
            continue
        L = G.edges[e].get("length", 1.0)
        if L < dist.get(e, float("inf")):
            dist[e], prev[e] = L, None
            heapq.heappush(pq, (L, e))
    while pq:
        d, e = heapq.heappop(pq)
        if d > dist.get(e, float("inf")) or d > max_len:
            continue
        if e[1] == n and turn_is_legal(G, e, e2, restr_idx, major):
            path = [e]
            while prev[path[0]] is not None:
                path.insert(0, prev[path[0]])
            return path
        for w, x, k in G.out_edges(e[1], keys=True):
            ne = (w, x, k)
            if not turn_is_legal(G, e, ne, restr_idx, major):
                continue
            nd = d + G.edges[ne].get("length", 1.0)
            if nd < dist.get(ne, float("inf")):
                dist[ne], prev[ne] = nd, e
                heapq.heappush(pq, (nd, ne))
    return None


def repair_illegal_turns(steps, G, restr_idx, major):
    fixed, inserted, unfixable = [], 0, 0
    for i, cur in enumerate(steps):
        fixed.append(cur)
        if i + 1 >= len(steps):
            continue
        nxt = steps[i + 1]
        if cur["rev"] or nxt["rev"]:
            continue
        if cur["v"] != nxt["u"]:
            continue
        e1 = (cur["u"], cur["v"], cur["k"])
        e2 = (nxt["u"], nxt["v"], nxt["k"])
        if turn_is_legal(G, e1, e2, restr_idx, major):
            continue
        # primero un desvío corto; solo si no existe se acepta uno largo
        detour = (legal_detour(G, restr_idx, major, e1, e2, max_len=900)
                  or legal_detour(G, restr_idx, major, e1, e2, max_len=4000))
        if detour is None:
            unfixable += 1
            continue
        for (u, v, k) in detour:
            fixed.append({"u": u, "v": v, "k": k, "role": "link",
                          "skey": None, "rev": False})
        inserted += 1
    if inserted or unfixable:
        print(f"    giros prohibidos/vueltas en U corregidos: {inserted}"
              + (f" (sin solución: {unfixable})" if unfixable else ""))
    return fixed


# ---------------------------------------------------------------------------
# Exportación
# ---------------------------------------------------------------------------

def steps_to_geojson(G, steps, sectors_codes, mode, zone, elev):
    features = []
    prev_coords = None
    total = 0.0
    cover_len, recheck_len = 0.0, 0.0
    cover_streets, recheck_streets = set(), set()
    for seq, s in enumerate(steps):
        u, v, k = s["u"], s["v"], s["k"]
        coords = edge_geometry(G, u, v, k)
        if s["rev"]:
            coords = list(reversed(coords))
        name = edge_name(G, u, v, k)
        length = G.edges[u, v, k].get("length", 0.0)
        total += length
        role, skey = s["role"], s["skey"]
        if role == "cover" and skey not in cover_streets:
            cover_streets.add(skey)
            cover_len += length
        elif role == "recheck" and skey not in recheck_streets:
            recheck_streets.add(skey)
            recheck_len += length
        if prev_coords is not None and len(prev_coords) >= 2 and len(coords) >= 2:
            code, text = turn_instruction(prev_coords, coords, name, mode)
        else:
            code, text = "depart", (f"Inicia el recorrido por {name}"
                                    if name else "Inicia el recorrido")
        if role == "recheck":
            text = f"{text} — segunda pasada recomendada (vía ancha)"
        features.append({
            "type": "Feature",
            "geometry": {"type": "LineString",
                         "coordinates": [[round(x, 6), round(y, 6)] for x, y in coords]},
            "properties": {
                "seq": seq, "street_id": skey or f"link-{seq}", "name": name,
                "length_m": round(length, 1), "role": role,
                "maneuver": code, "instruction": text,
                "elev_start": round(elev.get(u, 0.0)),
                "elev_end": round(elev.get(v, 0.0)),
            },
        })
        prev_coords = coords
    return {
        "type": "FeatureCollection",
        "properties": {
            "sectors": sectors_codes, "mode": mode, "zone": zone["id"],
            "zone_name": zone["name"],
            "total_length_m": round(total),
            "cover_length_m": round(cover_len),
            "recheck_length_m": round(recheck_len),
            "n_steps": len(steps),
            "n_cover_streets": len(cover_streets),
            "n_recheck_streets": len(recheck_streets),
        },
        "features": features,
    }


def combo_key(codes):
    return "-".join(sorted(codes))


def sector_cover_streets(fc):
    """Conjunto de street_id (skey) que cuentan para el 100% en una ruta."""
    return {f["properties"]["street_id"]
            for f in fc["features"]
            if f["properties"].get("role") == "cover"}


def write_sectors_geojson(zone_ids):
    """Escribe app_assets/sectors.geojson con los sectores de las zonas dadas.
    Solo lee shapefiles; no baja grafos ni elevación (operación barata)."""
    fc = {"type": "FeatureCollection", "features": []}
    for zone in ZONES:
        if zone["id"] not in zone_ids:
            continue
        sectors = load_sectors(zone)
        for _, row in sectors.iterrows():
            fc["features"].append({
                "type": "Feature",
                "geometry": mapping(row.geometry.simplify(0.00001)),
                "properties": {"code": row["SCACODIGO"], "name": row["SCANOMBRE"],
                               "zone": row["zone"], "zone_name": row["zone_name"]},
            })
    path = os.path.join(OUT, "sectors.geojson")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(fc, f, ensure_ascii=False)
    print(f"sectores -> {path} ({len(fc['features'])} sectores de zonas "
          f"{','.join(sorted(zone_ids))})")


def rebuild_street_index():
    """Reconstruye routes_index.json y sectors_streets.json leyendo las rutas
    por-sector ya existentes en disco (sin red ni recálculo). Sirve para poner
    al día las zonas viejas después de agregar el modo por-sector."""
    routes_dir = os.path.join(OUT, "routes")
    index, streets = {}, {}
    for fname in sorted(os.listdir(routes_dir)):
        if not fname.startswith("route_") or not fname.endswith(".geojson"):
            continue
        core = fname[len("route_"):-len(".geojson")]
        code_part, _, mode = core.rpartition("_")
        if "-" in code_part:  # solo rutas de un sector
            continue
        with open(os.path.join(routes_dir, fname), encoding="utf-8") as f:
            fc = json.load(f)
        p = fc["properties"]
        index[fname] = {
            "sectors": [code_part], "mode": mode, "zone": p.get("zone", "1"),
            "total_m": p["total_length_m"], "cover_m": p["cover_length_m"],
            "recheck_m": p.get("recheck_length_m", 0),
            "steps": p["n_steps"], "streets": p["n_cover_streets"],
        }
        streets.setdefault(code_part, set()).update(sector_cover_streets(fc))
    with open(os.path.join(OUT, "routes_index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False)
    with open(os.path.join(OUT, "sectors_streets.json"), "w", encoding="utf-8") as f:
        json.dump({k: sorted(v) for k, v in streets.items()}, f, ensure_ascii=False)
    print(f"índices reconstruidos: {len(index)} rutas por-sector, "
          f"{len(streets)} sectores con calles")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    global CLIMB_PENALTY, RESTR
    ap = argparse.ArgumentParser()
    ap.add_argument("--modes", default="walk,drive")
    ap.add_argument("--zones", default=",".join(z["id"] for z in ZONES))
    ap.add_argument("--only", default=None, help="códigos de sector separados por coma")
    ap.add_argument("--all-combos", action="store_true",
                    help="todas las combinaciones (inviable con muchos sectores)")
    ap.add_argument("--per-sector", action="store_true",
                    help="solo rutas de un sector; la app las une al vuelo")
    ap.add_argument("--sectors-only", action="store_true",
                    help="solo regenerar sectors.geojson (sin red) y salir")
    ap.add_argument("--rebuild-index", action="store_true",
                    help="reconstruir índices desde las rutas en disco y salir")
    ap.add_argument("--climb-factor", type=float, default=CLIMB_FACTOR)
    ap.add_argument("--climb-penalty", type=float, default=CLIMB_PENALTY)
    ap.add_argument("--bands", type=int, default=0, help="0 = automático")
    args = ap.parse_args()
    CLIMB_PENALTY = args.climb_penalty

    os.makedirs(os.path.join(OUT, "routes"), exist_ok=True)
    want_zones = set(args.zones.split(","))

    # atajos baratos (sin bajar grafos ni elevación)
    if args.sectors_only:
        write_sectors_geojson(want_zones)
        return
    if args.rebuild_index:
        rebuild_street_index()
        return

    modes = args.modes.split(",")
    all_sectors = []
    index = {}
    sectors_streets = {}  # code -> set(street_id) que cuentan para el 100%

    for zone in ZONES:
        if zone["id"] not in want_zones:
            continue
        sectors = load_sectors(zone)
        all_sectors.append(sectors)
        codes = list(sectors["SCACODIGO"])
        print(f"\n=== ZONA {zone['id']} ({zone['name']}): "
              + ", ".join(f"{r.SCACODIGO}={r.SCANOMBRE}" for r in sectors.itertuples()))

        poly_base = base_polygon(sectors)
        # se trabaja sobre el grafo COMPLETO (todos los componentes): cada
        # sector elige después su propio componente fuertemente conexo. Antes se
        # reducía a un solo largest_scc global y los sectores lejanos de una zona
        # dispersa perdían todas sus calles.
        G = download_graph(poly_base)
        sccs = scc_list(G)   # vehículo (fuertes)
        wccs = wcc_list(G)   # a pie (débiles)
        print(f"  grafo: {len(G.nodes)} nodos, {len(G.edges)} aristas, "
              f"{len(sccs)} comp. fuertes (mayor: {len(sccs[0]) if sccs else 0} nodos)")
        restr_idx = build_restriction_index(fetch_restrictions(poly_base, zone["id"]))
        RESTR = restr_idx
        major = major_nodes(G)
        elev = fetch_elevations(G, zone["id"])

        sec_nodes = clip_nodes(G, unary_union(sectors.geometry.values))
        evals = [elev.get(n, 0.0) for n in sec_nodes] or [0.0]
        relief = max(evals) - min(evals)
        open_path = relief >= RELIEF_OPEN_M
        n_bands = max(1, min(4, round(relief / 100))) if open_path else 1
        add_climb_weights(G, elev, args.climb_factor)
        print(f"  restricciones: {len(restr_idx)} nodos | desnivel: {relief:.0f} m"
              f" -> ruta {'ABIERTA cerro-abajo' if open_path else 'circular'}"
              + (f", {n_bands} bandas de altura" if n_bands > 1 else ""))

        if args.only:
            combos = [tuple(c for c in args.only.split(",") if c in codes)]
            combos = [c for c in combos if c]
        elif args.all_combos:
            combos = [c for r in range(1, len(codes) + 1)
                      for c in itertools.combinations(codes, r)]
        elif args.per_sector:
            # solo un sector por ruta: la app une los sectores elegidos al
            # vuelo. Es lo único viable con muchos sectores (2^20 combos = ∞).
            combos = [(c,) for c in codes]
        else:
            combos = [(c,) for c in codes] + ([tuple(codes)] if len(codes) > 1 else [])

        for combo in combos:
            sel = sectors[sectors["SCACODIGO"].isin(combo)]
            poly = unary_union(sel.geometry.values).buffer(15 / 111_000)
            arcs_all = edges_in_polygon(G, poly)
            if not arcs_all:
                print(f"[{combo_key(combo)}] sin calles enrutables, se omite")
                continue
            for mode in modes:
                # a pie basta un componente débil; en vehículo hace falta uno
                # fuerte (poder circular respetando sentidos)
                comp = component_for(arcs_all, G, wccs if mode == "walk" else sccs)
                if not comp:
                    print(f"[{combo_key(combo)}] {mode}: sin componente "
                          f"enrutable, se omite")
                    continue
                # copia real, no vista: los Dijkstra sobre la vista filtrada
                # eran 4x más lentos con el grafo de 2500 m de margen
                Gsec = G.subgraph(comp).copy()
                arcs_in = [a for a in arcs_all if a[0] in comp and a[1] in comp]
                dropped = len(arcs_all) - len(arcs_in)
                print(f"[{combo_key(combo)}] {mode} ({len(arcs_in)} arcos en zona"
                      + (f", {dropped} sueltos fuera del componente" if dropped else "")
                      + ")")
                if mode == "walk":
                    steps = solve_walk(arcs_in, Gsec, elev, open_path)
                else:
                    cover_km = sum(Gsec.edges[a].get("length", 0.0)
                                   for a in arcs_in) / 2000
                    bands = args.bands or max(1, min(n_bands, int(cover_km / 2.5)))
                    steps = solve_drive_best(arcs_in, Gsec, elev, open_path,
                                             major, bands)
                    steps = repair_illegal_turns(steps, Gsec, restr_idx, major)
                if not steps:
                    # una ruta vacía hacía fallar la app al abrir el sector
                    print(f"    sin ruta en {mode}, no se escribe")
                    continue
                fc = steps_to_geojson(Gsec, steps, list(combo), mode, zone, elev)
                p = fc["properties"]
                print(f"    {p['n_steps']} tramos, {p['total_length_m']/1000:.1f} km | "
                      f"cubre {p['n_cover_streets']} calles "
                      f"({p['cover_length_m']/1000:.1f} km)"
                      + (f" | revisiones opcionales: {p['n_recheck_streets']}"
                         if p['n_recheck_streets'] else ""))
                fname = f"route_{combo_key(combo)}_{mode}.geojson"
                with open(os.path.join(OUT, "routes", fname), "w", encoding="utf-8") as f:
                    json.dump(fc, f, ensure_ascii=False)
                index[fname] = {
                    "sectors": list(combo), "mode": mode, "zone": zone["id"],
                    "total_m": p["total_length_m"],
                    "cover_m": p["cover_length_m"],
                    "recheck_m": p["recheck_length_m"],
                    "steps": p["n_steps"],
                    "streets": p["n_cover_streets"],
                }
                # calles del sector (para el % por sector y por mercado en la
                # app); solo de rutas de UN sector, unión de todos los modos
                if len(combo) == 1:
                    sectors_streets.setdefault(combo[0], set()).update(
                        sector_cover_streets(fc))

    # sectores: siempre se escribe el archivo COMPLETO (todas las zonas), aunque
    # solo se hayan recalculado rutas de una, para no perder las demás.
    if all_sectors:
        print()
        write_sectors_geojson({z["id"] for z in ZONES})

    idx_path = os.path.join(OUT, "routes_index.json")
    if index:
        old = {}
        if os.path.exists(idx_path):
            with open(idx_path, encoding="utf-8") as f:
                old = json.load(f)
        old.update(index)
        with open(idx_path, "w", encoding="utf-8") as f:
            json.dump(old, f, ensure_ascii=False)
        print(f"índice -> {idx_path} ({len(old)} rutas)")

    ss_path = os.path.join(OUT, "sectors_streets.json")
    if sectors_streets:
        old = {}
        if os.path.exists(ss_path):
            try:
                with open(ss_path, encoding="utf-8") as f:
                    old = json.load(f)
            except (json.JSONDecodeError, ValueError):
                old = {}
        old.update({k: sorted(v) for k, v in sectors_streets.items()})
        with open(ss_path, "w", encoding="utf-8") as f:
            json.dump(old, f, ensure_ascii=False)
        print(f"calles por sector -> {ss_path} ({len(old)} sectores)")
    print("Listo.")


if __name__ == "__main__":
    main()
