import 'dart:math' as math;

import 'model.dart';

/// Cost model for parking and walking.
class ParkOnceSettings {
  const ParkOnceSettings({
    this.parkSeconds = 45,
    this.walkSpeed = 1.3,
    this.walkCircuity = 1.25,
    this.maxWalkMetres = 80,
    this.maxGroupSize = 6,
    this.doorstepMetres = 8,
    this.tightWindowSeconds = 4 * 3600,
  });

  /// Finding a space, parking, getting out and back in: paid once per van stop.
  final int parkSeconds;

  /// Metres per second on foot, and footpath distance / straight line.
  final double walkSpeed, walkCircuity;

  /// No door in a group is further than this (straight line) from the van.
  final double maxWalkMetres;

  final int maxGroupSize;

  /// Van to the door of the address it is parked at.
  final double doorstepMetres;

  /// Stops with a window shorter than this (timed collections, slots) are
  /// never grouped: they keep their own van stop.
  final int tightWindowSeconds;

  /// The baseline: every door is its own van stop, in the same cost model.
  ParkOnceSettings get everyDoor => ParkOnceSettings(
        parkSeconds: parkSeconds,
        walkSpeed: walkSpeed,
        walkCircuity: walkCircuity,
        maxWalkMetres: maxWalkMetres,
        maxGroupSize: 1,
        doorstepMetres: doorstepMetres,
        tightWindowSeconds: tightWindowSeconds,
      );
}

/// One van stop: park once, walk to every door in order, walk back.
class ParkGroup {
  ParkGroup._(
      this.stops, this.offsets, this.walkMetres, this.walkSeconds, this.serviceSeconds, this.earliest, this.latest);

  /// Stop ids in walking order. The van parks at the first.
  final List<int> stops;

  /// Seconds from starting this van stop to starting service at each door.
  final List<int> offsets;

  final int walkMetres, walkSeconds;

  /// Parking + walking + doorstep time: the van stop's service time.
  final int serviceSeconds;

  /// Window for starting the van stop that keeps every door inside its own
  /// window (no waiting at doors).
  final int earliest, latest;

  int get parkAt => stops.first;
  int get size => stops.length;
}

/// Groups a round's stops into Park Once van stops.
///
/// Greedy and cost-based. Starting from the densest spots, a door joins a
/// group only if serving it on foot is cheaper than driving and parking for
/// it separately, and only if every door's time window still holds. Each
/// group's walking order and parking spot are optimal: brute force over at
/// most 6 doors, at most 720 orders.
///
/// The group's walking order doubles as the driver's guidance: "park at 14,
/// walk to 16, 18 and 21, back to the van".
List<ParkGroup> groupForParkOnce(Problem problem, {ParkOnceSettings settings = const ParkOnceSettings()}) {
  final n = problem.size;
  final st = problem.stops;
  double dist(int a, int b) => math.sqrt(math.pow(st[a].x - st[b].x, 2) + math.pow(st[a].y - st[b].y, 2));
  bool groupable(int i) => problem.latest[i] - problem.earliest[i] >= settings.tightWindowSeconds;

  final near = List<List<int>>.generate(n, (_) => <int>[]);
  if (settings.maxGroupSize > 1) {
    for (var i = 1; i < n; i++) {
      if (!groupable(i)) continue;
      for (var j = i + 1; j < n; j++) {
        if (groupable(j) && dist(i, j) <= settings.maxWalkMetres) {
          near[i].add(j);
          near[j].add(i);
        }
      }
    }
    for (var i = 1; i < n; i++) {
      near[i].sort((a, b) => dist(i, a).compareTo(dist(i, b)));
    }
  }

  final seeds = [for (var i = 1; i < n; i++) i]
    ..sort((a, b) => near[b].length != near[a].length ? near[b].length - near[a].length : a - b);
  final assigned = List<bool>.filled(n, false);
  final groups = <ParkGroup>[];
  for (final seed in seeds) {
    if (assigned[seed]) continue;
    var members = [seed];
    var best = _bestLoop(problem, members, settings, dist)!;
    var saving = 0;
    for (final c in near[seed]) {
      if (members.length >= settings.maxGroupSize) break;
      if (assigned[c]) continue;
      final trial = [...members, c];
      final loop = _bestLoop(problem, trial, settings, dist);
      if (loop == null) continue;
      final s = _separateCost(problem, trial, settings) - loop.serviceSeconds;
      if (s > saving) {
        members = trial;
        best = loop;
        saving = s;
      }
    }
    for (final m in members) {
      assigned[m] = true;
    }
    groups.add(best);
  }
  return groups;
}

int _walk(double metres, ParkOnceSettings s) => (metres * s.walkCircuity / s.walkSpeed).ceil();

/// Cost of serving [members] as separate van stops: parking and doorstep
/// walk for each, service, and the short drives between them.
int _separateCost(Problem p, List<int> members, ParkOnceSettings s) {
  var cost = 0;
  for (final m in members) {
    cost += s.parkSeconds + 2 * _walk(s.doorstepMetres, s) + p.service[m];
  }
  final left = members.sublist(1).toSet();
  var cur = members.first;
  while (left.isNotEmpty) {
    final next = left.reduce((a, b) => p.travel.freeFlow(cur, a) <= p.travel.freeFlow(cur, b) ? a : b);
    cost += p.travel.freeFlow(cur, next);
    left.remove(next);
    cur = next;
  }
  return cost;
}

/// Best parking spot and walking order for [members], or null if no order
/// keeps every door inside its window (or within walking distance).
ParkGroup? _bestLoop(Problem p, List<int> members, ParkOnceSettings s, double Function(int, int) dist) {
  ParkGroup? best;
  for (final park in members) {
    final others = [
      for (final m in members)
        if (m != park) m
    ];
    if (others.any((m) => dist(park, m) > s.maxWalkMetres)) continue;
    for (final order in _permutations(others)) {
      final doors = [park, ...order];
      final offsets = <int>[];
      var t = s.parkSeconds + _walk(s.doorstepMetres, s);
      var metres = s.doorstepMetres;
      var e = -1 << 30, l = 1 << 30;
      for (var k = 0; k < doors.length; k++) {
        final d = doors[k];
        if (k > 0) {
          final leg = dist(doors[k - 1], d);
          t += _walk(leg, s);
          metres += leg;
        }
        offsets.add(t);
        e = math.max(e, p.earliest[d] - t);
        l = math.min(l, p.latest[d] - t);
        t += p.service[d];
      }
      final back = doors.length > 1 ? dist(doors.last, park) : 0.0;
      t += _walk(back + s.doorstepMetres, s);
      metres += back + s.doorstepMetres;
      if (e > l) continue;
      final walkSeconds = t - s.parkSeconds - [for (final d in doors) p.service[d]].reduce((a, b) => a + b);
      if (best == null || walkSeconds < best.walkSeconds) {
        best = ParkGroup._(doors, offsets, metres.round(), walkSeconds, t, e, l);
      }
    }
  }
  return best;
}

Iterable<List<int>> _permutations(List<int> items) sync* {
  if (items.length <= 1) {
    yield List.of(items);
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final rest = [...items.sublist(0, i), ...items.sublist(i + 1)];
    for (final p in _permutations(rest)) {
      yield [items[i], ...p];
    }
  }
}
