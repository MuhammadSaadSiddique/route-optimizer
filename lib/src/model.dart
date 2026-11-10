import 'dart:typed_data';

import 'travel_time.dart';

enum StopKind { depot, delivery, collection }

enum AddressType { depot, house, flat, business }

/// A stop on the round. Node 0 is always the depot.
class Stop {
  const Stop({
    required this.id,
    required this.x,
    required this.y,
    required this.zone,
    required this.kind,
    required this.addressType,
    required this.earliest,
    required this.latest,
    required this.serviceSeconds,
  });

  /// Node index in the travel matrix.
  final int id;

  /// Position in metres on a local plane (lat/lon in a real app).
  final double x, y;

  /// Congestion zone.
  final int zone;

  final StopKind kind;
  final AddressType addressType;

  /// Time window for the *start* of service, seconds since midnight.
  final int earliest, latest;

  final int serviceSeconds;

  Stop copyWith({int? id, double? x, double? y, int? zone, int? earliest, int? latest, int? serviceSeconds}) => Stop(
        id: id ?? this.id,
        x: x ?? this.x,
        y: y ?? this.y,
        zone: zone ?? this.zone,
        kind: kind,
        addressType: addressType,
        earliest: earliest ?? this.earliest,
        latest: latest ?? this.latest,
        serviceSeconds: serviceSeconds ?? this.serviceSeconds,
      );
}

/// A single-driver round: depot, stops, travel model and shift limits.
///
/// Hot data (windows, service times) is kept in typed arrays indexed by node,
/// so the inner loops of the optimiser never touch objects.
class Problem {
  Problem._(this.travel, this.shiftStart, this.shiftEnd, this.stops, this.earliest, this.latest, this.service);

  /// [stops] must be indexed by id, with the depot at index 0. The travel
  /// matrix must already contain every stop.
  factory Problem.create({
    required TimeDependentTravel travel,
    required List<Stop> stops,
    required int shiftStart,
    required int shiftEnd,
  }) {
    final cap = travel.matrix.capacity;
    final p = Problem._(
      travel,
      shiftStart,
      shiftEnd,
      <Stop>[],
      Int32List(cap),
      Int32List(cap),
      Int32List(cap),
    );
    for (final s in stops) {
      p._register(s);
    }
    return p;
  }

  final TimeDependentTravel travel;
  final int shiftStart, shiftEnd;
  final List<Stop> stops;
  final Int32List earliest, latest, service;

  int get size => stops.length;
  int get capacity => travel.matrix.capacity;

  /// Ids of all non-depot stops.
  Iterable<int> get stopIds => Iterable<int>.generate(size - 1, (i) => i + 1);

  bool hasWindow(int node) => node != 0 && (earliest[node] > shiftStart || latest[node] < shiftEnd);

  void _register(Stop s) {
    if (s.id != stops.length) {
      throw ArgumentError('Stop ids must be consecutive: expected ${stops.length}, got ${s.id}.');
    }
    stops.add(s);
    travel.zoneOf[s.id] = s.zone;
    if (s.id == 0) {
      earliest[0] = shiftStart;
      latest[0] = shiftEnd;
      service[0] = 0;
    } else {
      earliest[s.id] = s.earliest < shiftStart ? shiftStart : s.earliest;
      latest[s.id] = s.latest > shiftEnd ? shiftEnd : s.latest;
      service[s.id] = s.serviceSeconds;
    }
  }

  /// Adds a stop mid-round. Only its own matrix row and column are computed
  /// (in production: one Valhalla one-to-many / many-to-one request).
  int addStop(
    Stop draft, {
    required List<int> timeTo,
    required List<int> timeFrom,
    required List<int> distTo,
    required List<int> distFrom,
  }) {
    final id = travel.matrix.addNode(timeTo: timeTo, timeFrom: timeFrom, distTo: distTo, distFrom: distFrom);
    _register(draft.copyWith(id: id));
    return id;
  }

  /// Replaces stop [node]'s data (e.g. a corrected location or a new window).
  void updateStop(Stop s) {
    stops[s.id] = s;
    travel.zoneOf[s.id] = s.zone;
    earliest[s.id] = s.earliest < shiftStart ? shiftStart : s.earliest;
    latest[s.id] = s.latest > shiftEnd ? shiftEnd : s.latest;
    service[s.id] = s.serviceSeconds;
  }

  /// The same round planned with a different travel model (e.g. a planner
  /// that ignores congestion). Windows and stops are shared.
  Problem withTravel(TimeDependentTravel t) => Problem._(t, shiftStart, shiftEnd, stops, earliest, latest, service);

  /// The same round with every deadline brought forward by [seconds]
  /// (never before the window opens).
  ///
  /// Plan against this, run against the real problem: the route keeps a
  /// safety margin before every timed stop, so a driver running late or a
  /// collection added mid-round does not break a window. Without it, an
  /// optimiser packs timed stops right up to their deadlines and the route
  /// becomes brittle.
  Problem withDeadlineBuffer(int seconds) {
    final l = Int32List.fromList(latest);
    for (final i in stopIds) {
      if (latest[i] < shiftEnd) {
        final b = latest[i] - seconds;
        l[i] = b > earliest[i] ? b : earliest[i];
      }
    }
    return Problem._(travel, shiftStart, shiftEnd, stops, earliest, l, service);
  }

  /// The same round with every time window opened to the full shift.
  Problem withOpenWindows() {
    final e = Int32List(capacity)..fillRange(0, capacity, shiftStart);
    final l = Int32List(capacity)..fillRange(0, capacity, shiftEnd);
    return Problem._(travel, shiftStart, shiftEnd, stops, e, l, service);
  }
}
