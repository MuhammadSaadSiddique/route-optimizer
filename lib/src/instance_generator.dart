import 'dart:math' as math;
import 'dart:typed_data';

import 'model.dart';
import 'park_once.dart';
import 'travel_time.dart';

int hhmm(int h, int m) => h * 3600 + m * 60;

String clock(int t) {
  final h = t ~/ 3600, m = (t % 3600) ~/ 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// A synthetic but realistic town for benchmarks and tests.
///
///  * 6 km x 6 km, 4 x 4 congestion zones, depot on the west edge.
///  * 70% of stops in housing estates (clusters), 30% scattered. About half
///    the houses are neighbours on the same street (8-25 m apart) and about
///    half the flats share a block with another delivery, as on real rounds.
///  * Houses, flats (slower) and businesses (open 09:00-17:00).
///  * ~3% timed collections (1 h windows), ~3% customer slots (2 h).
///  * Road distance = straight line x 1.35, with +/-6% asymmetry for
///    one-way streets; free-flow 32 km/h.
///  * Congestion: morning and evening peaks everywhere, a school run
///    (08:15-09:15, 14:45-15:45) in three zones, a lunchtime slowdown in the
///    town centre.
///
/// In the real app the matrix comes from Valhalla and the profile from
/// learned GPS speeds. Only these inputs change; the optimiser stays the same.
class CityInstance {
  CityInstance._(this.problem, this.random, this._clusters,
      [List<(double, double)>? houses, List<(double, double)>? flats])
      : _houses = houses ?? [],
        _flatBlocks = flats ?? [];

  static const double side = 6000;
  static const int zonesPerSide = 4;
  static const double circuity = 1.35;
  static const double speedMs = 9.0;
  static const List<int> schoolZones = [5, 10, 14];
  static const int centreZone = 9;

  final Problem problem;
  final math.Random random;
  final List<(double, double)> _clusters;
  final List<(double, double)> _houses, _flatBlocks;

  /// Builds a round with [stops] stops plus room for [spare] stops added later.
  ///
  /// [matrixFactory] chooses where the travel matrix lives, e.g.
  /// `(cap) => kernels.allocateMatrix(cap).matrix` for native memory.
  factory CityInstance.generate({
    required int stops,
    int seed = 42,
    int spare = 64,
    TravelMatrix Function(int capacity)? matrixFactory,
  }) {
    final rnd = math.Random(seed);
    final clusters = [for (var i = 0; i < 14; i++) (800 + rnd.nextDouble() * 5000, 800 + rnd.nextDouble() * 5000)];
    final cap = stops + 1 + spare;
    final matrix = matrixFactory?.call(cap) ?? TravelMatrix(cap);
    final zoneOf = Uint8List(cap);
    final profile = CongestionProfile(zonesPerSide * zonesPerSide)
      ..slowDownEverywhere(hhmm(7, 45), hhmm(9, 15), 0.8)
      ..slowDownEverywhere(hhmm(16, 30), hhmm(18, 30), 0.8);
    for (final z in schoolZones) {
      profile
        ..slowDown(z, hhmm(8, 15), hhmm(9, 15), 0.45)
        ..slowDown(z, hhmm(14, 45), hhmm(15, 45), 0.5);
    }
    profile.slowDown(centreZone, hhmm(11, 45), hhmm(13, 45), 0.7);

    final travel = TimeDependentTravel(matrix, profile, zoneOf);
    final shiftStart = hhmm(7, 30), shiftEnd = hhmm(21, 0);
    final problem = Problem.create(travel: travel, stops: const [], shiftStart: shiftStart, shiftEnd: shiftEnd);
    final city = CityInstance._(problem, rnd, clusters);

    city._add(Stop(
      id: 0,
      x: 300,
      y: 3000,
      zone: zoneAt(300, 3000),
      kind: StopKind.depot,
      addressType: AddressType.depot,
      earliest: shiftStart,
      latest: shiftEnd,
      serviceSeconds: 0,
    ));
    for (var i = 0; i < stops; i++) {
      city._add(city.randomStop());
    }
    return city;
  }

  static int zoneAt(double x, double y) {
    final cell = side / zonesPerSide;
    final cx = (x ~/ cell).clamp(0, zonesPerSide - 1);
    final cy = (y ~/ cell).clamp(0, zonesPerSide - 1);
    return cy * zonesPerSide + cx;
  }

  (double, double) _anywhere() {
    final rnd = random;
    if (rnd.nextDouble() < 0.7) {
      final c = _clusters[rnd.nextInt(_clusters.length)];
      return (c.$1 + _gauss() * 220, c.$2 + _gauss() * 220);
    }
    return (rnd.nextDouble() * side, rnd.nextDouble() * side);
  }

  /// A random stop (id is assigned when added).
  Stop randomStop({StopKind? kind, int? earliest, int? latest}) {
    final rnd = random;
    final r = rnd.nextDouble();
    final type = r < 0.12
        ? AddressType.business
        : r < 0.37
            ? AddressType.flat
            : AddressType.house;

    double x, y;
    if (type == AddressType.flat && _flatBlocks.isNotEmpty && rnd.nextDouble() < 0.55) {
      final b = _flatBlocks[rnd.nextInt(_flatBlocks.length)]; // same block, another flat
      (x, y) = (b.$1 + (rnd.nextDouble() - 0.5) * 4, b.$2 + (rnd.nextDouble() - 0.5) * 4);
    } else if (type == AddressType.house && _houses.isNotEmpty && rnd.nextDouble() < 0.5) {
      final h = _houses[rnd.nextInt(_houses.length)]; // a neighbour on the same street
      final a = rnd.nextDouble() * 2 * math.pi, d = 8 + rnd.nextDouble() * 17;
      (x, y) = (h.$1 + d * math.cos(a), h.$2 + d * math.sin(a));
    } else {
      (x, y) = _anywhere();
    }
    x = x.clamp(0, side).toDouble();
    y = y.clamp(0, side).toDouble();
    if (type == AddressType.flat) _flatBlocks.add((x, y));
    if (type == AddressType.house) _houses.add((x, y));

    final service = switch (type) {
      AddressType.house => 25 + rnd.nextInt(16),
      AddressType.flat => 50 + rnd.nextInt(31),
      _ => 40 + rnd.nextInt(21),
    };

    var k = kind ?? StopKind.delivery;
    var e = problem.shiftStart, l = problem.shiftEnd;
    final w = rnd.nextDouble();
    if (earliest != null && latest != null) {
      e = earliest;
      l = latest;
    } else if (kind == null && w < 0.03) {
      k = StopKind.collection;
      e = hhmm(10, 0) + rnd.nextInt(15) * 900; // 10:00 .. 13:30
      l = e + 3600;
    } else if (kind == null && w < 0.06) {
      e = hhmm(9, 0) + rnd.nextInt(17) * 900; // 09:00 .. 13:00
      l = e + 7200;
    } else if (type == AddressType.business) {
      e = hhmm(9, 0);
      l = hhmm(17, 0);
    }
    return Stop(
      id: -1,
      x: x,
      y: y,
      zone: zoneAt(x, y),
      kind: k,
      addressType: type,
      earliest: e,
      latest: l,
      serviceSeconds: service,
    );
  }

  double _gauss() {
    final u1 = random.nextDouble() + 1e-12, u2 = random.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  /// +/-6% one-way-street asymmetry, fixed per pair of locations, so any
  /// two rounds over the same addresses see the same roads.
  static double _asym(Stop a, Stop b) {
    final h = ((a.x * 10).round() * 73856093) ^
        ((a.y * 10).round() * 19349663) ^
        ((b.x * 10).round() * 83492791) ^
        ((b.y * 10).round() * 50331653);
    return 1 + 0.06 * ((h & 0xffff) / 0xffff * 2 - 1);
  }

  static (int, int) _arc(Stop a, Stop b) {
    final d = math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)) * circuity * _asym(a, b);
    return ((d / speedMs).ceil(), d.round());
  }

  ({List<int> timeTo, List<int> timeFrom, List<int> distTo, List<int> distFrom}) _rows(Stop s, int id) {
    final n = problem.size;
    final timeTo = List<int>.filled(n, 0), timeFrom = List<int>.filled(n, 0);
    final distTo = List<int>.filled(n, 0), distFrom = List<int>.filled(n, 0);
    for (var j = 0; j < n; j++) {
      if (j == id) continue;
      final o = problem.stops[j];
      final (t1, d1) = _arc(s, o);
      final (t2, d2) = _arc(o, s);
      timeTo[j] = t1;
      distTo[j] = d1;
      timeFrom[j] = t2;
      distFrom[j] = d2;
    }
    return (timeTo: timeTo, timeFrom: timeFrom, distTo: distTo, distFrom: distFrom);
  }

  int _add(Stop draft) {
    final id = problem.size;
    final r = _rows(draft, id);
    return problem.addStop(draft, timeTo: r.timeTo, timeFrom: r.timeFrom, distTo: r.distTo, distFrom: r.distFrom);
  }

  /// Adds a stop mid-round: computes only its row and column.
  int addStop(Stop draft) => _add(draft);

  /// Moves an existing stop (e.g. to reuse one node for many test queries).
  void relocateStop(int id, Stop draft) {
    final s = draft.copyWith(id: id);
    problem.updateStop(s);
    final r = _rows(s, id);
    problem.travel.matrix.setNode(id, timeTo: r.timeTo, timeFrom: r.timeFrom, distTo: r.distTo, distFrom: r.distFrom);
  }

  /// The same round with each van stop being a Park Once group: node `i`
  /// is `groups[i - 1]`, located at its parking spot, with the group's
  /// parking + walking + doorstep time as service and the group's window.
  /// In production the matrix between parking spots is one Valhalla call.
  CityInstance parkOnceRound(List<ParkGroup> groups) {
    final cap = groups.length + 65;
    final travel = TimeDependentTravel(TravelMatrix(cap), problem.travel.profile, Uint8List(cap));
    final p =
        Problem.create(travel: travel, stops: const [], shiftStart: problem.shiftStart, shiftEnd: problem.shiftEnd);
    final city = CityInstance._(p, random, _clusters, _houses, _flatBlocks);
    city._add(problem.stops[0]);
    for (final g in groups) {
      final park = problem.stops[g.parkAt];
      final collects = g.stops.any((d) => problem.stops[d].kind == StopKind.collection);
      city._add(Stop(
        id: -1,
        x: park.x,
        y: park.y,
        zone: park.zone,
        kind: collects ? StopKind.collection : StopKind.delivery,
        addressType: park.addressType,
        earliest: g.earliest,
        latest: g.latest,
        serviceSeconds: g.serviceSeconds,
      ));
    }
    return city;
  }
}
