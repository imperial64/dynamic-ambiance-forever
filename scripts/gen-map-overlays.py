"""Generate addons/DynamicAmbiance/UI/MapOverlays.lua from wago.tools.

The world map's discovered areas are overlay textures drawn over the base art.
The client only hands back the ones the player has explored, so the editor
ships the whole set itself, read from the client's own WorldMapOverlay and
WorldMapOverlayTile tables for one build.

Usage (on Windows the interpreter is `python`, not `python3`):

    python scripts/gen-map-overlays.py 1.60.1.69977

Rerun it with the client's build whenever the editor says in chat that the
overlay data is from another build. The output is committed; nothing here runs
in the game.
"""

import csv
import datetime
import io
import os
import re
import sys
import urllib.request
from collections import defaultdict

URL = "https://wago.tools/db2/{table}/csv?build={build}"
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "addons", "DynamicAmbiance", "UI", "MapOverlays.lua")


def fetch(table, build):
    url = URL.format(table=table, build=build)
    req = urllib.request.Request(url, headers={"User-Agent": "gen-map-overlays/1"})
    with urllib.request.urlopen(req, timeout=60) as r:
        text = r.read().decode("utf-8-sig")
    rows = list(csv.DictReader(io.StringIO(text)))
    if not rows:
        sys.exit("no rows from " + url)
    return url, rows


def need(row, *cols):
    for c in cols:
        if c not in row:
            sys.exit("column %s missing - has the table's layout changed?" % c)


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", sys.argv[1]):
        sys.exit("usage: python scripts/gen-map-overlays.py <build, e.g. 1.60.1.69977>")
    build = sys.argv[1]

    wmo_url, overlays = fetch("WorldMapOverlay", build)
    tile_url, tiles = fetch("WorldMapOverlayTile", build)
    need(overlays[0], "ID", "UiMapArtID", "TextureWidth", "TextureHeight", "OffsetX", "OffsetY")
    need(tiles[0], "RowIndex", "ColIndex", "LayerIndex", "FileDataID", "WorldMapOverlayID")

    # overlay ID -> layer -> [(row, col, fileDataID)]
    by_overlay = defaultdict(lambda: defaultdict(list))
    for t in tiles:
        by_overlay[int(t["WorldMapOverlayID"])][int(t["LayerIndex"])].append(
            (int(t["RowIndex"]), int(t["ColIndex"]), int(t["FileDataID"])))

    by_art = defaultdict(list)
    n_overlays = n_tiles = n_empty = n_layered = 0
    for o in sorted(overlays, key=lambda o: int(o["ID"])):
        oid = int(o["ID"])
        layers = by_overlay.get(oid)
        if not layers:
            n_empty += 1
            continue
        head = [int(o["OffsetX"]), int(o["OffsetY"]), int(o["TextureWidth"]),
                int(o["TextureHeight"])]
        if len(layers) == 1:
            (only,) = layers.values()
            flat = [v for tile in sorted(only) for v in tile]
            body = ",".join(str(v) for v in head + flat)
            n_tiles += len(only)
        else:
            n_layered += 1
            parts = []
            for li in sorted(layers):
                flat = [v for tile in sorted(layers[li]) for v in tile]
                parts.append("[%d]={%s}" % (li, ",".join(str(v) for v in flat)))
                n_tiles += len(layers[li])
            body = ",".join(str(v) for v in head) + ",layers={" + ",".join(parts) + "}"
        by_art[int(o["UiMapArtID"])].append("{" + body + "}")
        n_overlays += 1

    today = datetime.date.today().isoformat()
    lines = [
        "-- Dynamic Ambiance - the world map's discovered-area overlays ------------------------",
        "--",
        "-- Generated, do not hand-edit. Rerun: python scripts/gen-map-overlays.py " + build,
        "--",
        "-- Source:    " + wmo_url,
        "--            " + tile_url,
        "-- Build:     " + build,
        "-- Generated: " + today,
        "--",
        "-- Keyed by UiMapArtID (C_Map.GetMapArtID). One overlay is",
        "--   { offsetX, offsetY, textureWidth, textureHeight, row, col, fileDataID, ... }",
        "-- in art pixels, one row, col, fileDataID triple per 256 px tile. An overlay",
        "-- whose tiles span more than one LayerIndex has no triples inline and carries",
        "-- layers = { [layerIndex] = { row, col, fileDataID, ... } } instead.",
        "-- %d art IDs, %d overlays, %d tiles." % (len(by_art), n_overlays, n_tiles),
        "",
        "local ADDON, ns = ...",
        "if not ns then return end",
        "",
        "ns.MapOverlays = {",
        'build = "%s",' % build,
        "art = {",
    ]
    for art in sorted(by_art):
        lines.append("[%d]={" % art)
        lines.extend(entry + "," for entry in by_art[art])
        lines.append("},")
    lines += ["},", "}", ""]

    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))

    size = os.path.getsize(OUT)
    print("wrote %s: %d bytes, %d art IDs, %d overlays, %d tiles"
          % (os.path.relpath(OUT), size, len(by_art), n_overlays, n_tiles))
    if n_empty:
        print("skipped %d overlay(s) with no tiles" % n_empty)
    if n_layered:
        print("%d overlay(s) span more than one layer" % n_layered)


if __name__ == "__main__":
    main()
