"""The KiddNet logo: the AK mark over a globe, meridians, parallels and
coastlines, as an orthographic view centred off West Africa (Britain, Europe
and Africa in the middle). Coastlines are Natural Earth's 1:110m land
(public domain).

    curl -sLo land.geojson https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_land.geojson
    python3 make-logo.py land.geojson ../public/brand

Writes kiddnet-logo.svg (fixed colour, for <img>: Dex's bar) and
kiddnet-globe.svg (the globe alone in currentColor, to sit under the AK where
the mark is drawn inline: the Homepages' header, ainur/homepage/logo.yaml).
The favicon and small marks stay the plain AK: the globe is fuzz at 32px.
"""
import json, math, sys

LAT0, LON0, R, C = math.radians(28), math.radians(-12), 84.0, 100.0
COLOUR = "#c0caf5"   # Tokyo Night Storm's foreground, on #222436


def project(lon, lat):
    lon, lat = math.radians(lon), math.radians(lat)
    cosc = math.sin(LAT0) * math.sin(lat) + math.cos(LAT0) * math.cos(lat) * math.cos(lon - LON0)
    x = R * math.cos(lat) * math.sin(lon - LON0)
    y = R * (math.cos(LAT0) * math.sin(lat) - math.sin(LAT0) * math.cos(lat) * math.cos(lon - LON0))
    return C + x, C - y, cosc >= 0


def path(lines):
    """Visible stretches of each line, as one SVG path."""
    out = []
    for line in lines:
        seg = []
        for lon, lat in line:
            x, y, visible = project(lon, lat)
            if visible:
                seg.append((x, y))
            else:
                if len(seg) > 1:
                    out.append(seg)
                seg = []
        if len(seg) > 1:
            out.append(seg)
    return "".join("M" + "L".join(f"{x:.1f},{y:.1f}" for x, y in s) for s in out)


def densify(ring, step=2.0):
    """Extra points on long edges, so they curve with the globe."""
    out = []
    for (a, b), (c, d) in zip(ring, ring[1:]):
        n = max(1, int(max(abs(c - a), abs(d - b)) / step))
        out += [(a + (c - a) * i / n, b + (d - b) * i / n) for i in range(n)]
    return out + [ring[-1]]


def main(geojson, outdir):
    rings = []
    for feature in json.load(open(geojson))["features"]:
        g = feature["geometry"]
        for polygon in g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]:
            rings += [densify(r) for r in polygon]
    graticule = [[(lon, lat) for lat in range(-90, 91, 2)] for lon in range(-180, 180, 30)]
    graticule += [[(lon, lat) for lon in range(-180, 181, 2)] for lat in range(-60, 61, 30)]

    def globe(colour):
        return (f'<path d="{path(graticule)}" fill="none" stroke="{colour}" stroke-width="0.9" stroke-opacity="0.3"/>'
                f'<path d="{path(rings)}" fill="none" stroke="{colour}" stroke-width="1.3" '
                f'stroke-linejoin="round" stroke-opacity="0.5"/>')

    ak = (f'<circle cx="100" cy="100" r="90" fill="none" stroke="{COLOUR}" stroke-width="8"/>'
          f'<g stroke="{COLOUR}" stroke-width="6.4" stroke-linecap="round">'
          '<line x1="163.6" y1="36.4" x2="36.4" y2="163.6"/><line x1="36.4" y1="163.6" x2="100" y2="10"/>'
          '<line x1="100" y1="100" x2="163.6" y2="163.6"/><line x1="100" y1="10" x2="100" y2="190"/></g>')
    svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">{}</svg>\n'
    open(f"{outdir}/kiddnet-logo.svg", "w").write(svg.format(globe(COLOUR) + ak))
    open(f"{outdir}/kiddnet-globe.svg", "w").write(svg.format(globe("currentColor")))


if __name__ == "__main__":
    main(*sys.argv[1:3])
