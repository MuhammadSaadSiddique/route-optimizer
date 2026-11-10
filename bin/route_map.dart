// Draws docs/route_map.svg: the same 300-stop round planned by the simple
// planner and by this optimiser. Run: dart run bin/route_map.dart
import 'dart:io';

import 'package:route_optimizer/route_optimizer.dart';

const panel = 460.0, pad = 20.0, top = 64.0;
const scale = panel / CityInstance.side;

/// Interpolates from a light tint of [base] (f = 0) to [base] darkened (f = 1).
String shade(List<int> base, double f) {
  int mix(int c) {
    final light = c + (255 - c) * 0.65, dark = c * 0.55;
    return (light + (dark - light) * f).round().clamp(0, 255);
  }

  return 'rgb(${mix(base[0])},${mix(base[1])},${mix(base[2])})';
}

String panelSvg(Problem p, Schedule s, double ox, String heading, String sub, List<int> colour) {
  final b = StringBuffer();
  double x(double m) => ox + m * scale;
  double y(double m) => top + m * scale;
  b.writeln('<g>');
  b.writeln('<text x="$ox" y="${top - 30}" class="h">$heading</text>');
  b.writeln('<text x="$ox" y="${top - 12}" class="s">$sub</text>');
  b.writeln('<rect x="$ox" y="$top" width="$panel" height="$panel" class="frame"/>');
  const cell = CityInstance.side / CityInstance.zonesPerSide;
  for (var z = 0; z < 16; z++) {
    final cx = (z % 4) * cell, cy = (z ~/ 4) * cell;
    final cls = CityInstance.schoolZones.contains(z)
        ? 'school'
        : z == CityInstance.centreZone
            ? 'centre'
            : 'zone';
    b.writeln('<rect x="${x(cx)}" y="${y(cy)}" width="${cell * scale}" height="${cell * scale}" class="$cls"/>');
  }
  // Each leg coloured by time of day: light in the morning, dark later.
  final t0 = s.departure[0], t1 = s.finish;
  for (var k = 1; k < s.route.length; k++) {
    final a = p.stops[s.route[k - 1]], c = p.stops[s.route[k]];
    final f = ((s.departure[k - 1] - t0) / (t1 - t0)).clamp(0.0, 1.0);
    b.writeln('<line x1="${x(a.x).toStringAsFixed(1)}" y1="${y(a.y).toStringAsFixed(1)}" '
        'x2="${x(c.x).toStringAsFixed(1)}" y2="${y(c.y).toStringAsFixed(1)}" stroke="${shade(colour, f)}" stroke-width="1.1"/>');
  }
  for (var k = 1; k < s.last; k++) {
    final n = s.route[k];
    final px = x(p.stops[n].x), py = y(p.stops[n].y);
    if (!p.hasWindow(n)) {
      b.writeln('<circle cx="${px.toStringAsFixed(1)}" cy="${py.toStringAsFixed(1)}" r="1.4" class="stop"/>');
    } else if (s.start[k] <= p.latest[n]) {
      b.writeln('<circle cx="${px.toStringAsFixed(1)}" cy="${py.toStringAsFixed(1)}" r="4" class="ok"/>');
    } else {
      b.writeln(
          '<path d="M${px - 4.5},${py - 4.5}L${px + 4.5},${py + 4.5}M${px - 4.5},${py + 4.5}L${px + 4.5},${py - 4.5}" class="late"/>');
    }
  }
  final d = p.stops[0];
  b.writeln('<rect x="${x(d.x) - 6}" y="${y(d.y) - 6}" width="12" height="12" class="depot"/>');
  b.writeln('</g>');
  return b.toString();
}

void main() {
  final p = CityInstance.generate(stops: 300).problem;
  final simple = Schedule.compute(p, nearestNeighbourRoute(p, p.stopIds));
  final ours =
      Schedule.compute(p, planRound(p, budget: const Duration(seconds: 30), maxIterations: 1500).schedule.route);
  final windowed = p.stopIds.where(p.hasWindow).length;

  final width = pad * 3 + panel * 2, height = top + panel + 64;
  final svg = StringBuffer()
    ..writeln('<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" viewBox="0 0 $width $height" '
        'font-family="-apple-system, Segoe UI, Helvetica, Arial, sans-serif">')
    ..writeln('<style>'
        '.h{font-size:15px;font-weight:600;fill:#111827}.s{font-size:12px;fill:#4b5563}'
        '.frame{fill:#ffffff;stroke:#d1d5db}.zone{fill:none;stroke:#eef0f3}'
        '.school{fill:#fde68a;fill-opacity:.35;stroke:#eef0f3}.centre{fill:#bfdbfe;fill-opacity:.35;stroke:#eef0f3}'
        '.stop{fill:#374151}.ok{fill:none;stroke:#059669;stroke-width:2}'
        '.late{stroke:#dc2626;stroke-width:2.4}.depot{fill:#111827}.l{font-size:12px;fill:#374151}'
        '</style>')
    ..writeln('<rect width="100%" height="100%" fill="#ffffff"/>')
    ..write(panelSvg(
        p,
        simple,
        pad,
        'Simple planner (nearest neighbour)',
        '${simple.violations} of $windowed stops with time windows late · finishes ${clock(simple.finish)} · ${(simple.distanceMetres / 1000).toStringAsFixed(0)} km',
        [107, 114, 128]))
    ..write(panelSvg(
        p,
        ours,
        pad * 2 + panel,
        'This optimiser',
        '${ours.violations} of $windowed stops with time windows late · finishes ${clock(ours.finish)} · ${(ours.distanceMetres / 1000).toStringAsFixed(0)} km',
        [37, 99, 235]));
  final ly = top + panel + 28;
  svg
    ..writeln(
        '<circle cx="${pad + 6}" cy="$ly" r="4.5" class="ok"/><text x="${pad + 16}" y="${ly + 4}" class="l">time window kept</text>')
    ..writeln(
        '<path d="M${pad + 156},${ly - 4.5}L${pad + 165},${ly + 4.5}M${pad + 156},${ly + 4.5}L${pad + 165},${ly - 4.5}" class="late"/>'
        '<text x="${pad + 172}" y="${ly + 4}" class="l">time window broken</text>')
    ..writeln(
        '<rect x="${pad + 290}" y="${ly - 6}" width="14" height="12" class="school"/><text x="${pad + 310}" y="${ly + 4}" class="l">school-run zone</text>')
    ..writeln(
        '<rect x="${pad + 420}" y="${ly - 6}" width="14" height="12" class="centre"/><text x="${pad + 440}" y="${ly + 4}" class="l">town centre (lunch traffic)</text>')
    ..writeln(
        '<rect x="${pad + 610}" y="${ly - 6}" width="12" height="12" class="depot"/><text x="${pad + 628}" y="${ly + 4}" class="l">depot</text>')
    ..writeln(
        '<text x="$pad" y="${ly + 26}" class="s">300 stops, synthetic 6 x 6 km town. Lines join stops in visiting order, light (morning) to dark (afternoon).</text>')
    ..writeln('</svg>');
  Directory('docs').createSync();
  File('docs/route_map.svg').writeAsStringSync(svg.toString());
  print('Wrote docs/route_map.svg (simple: ${simple.violations} late, this: ${ours.violations} late)');
}
