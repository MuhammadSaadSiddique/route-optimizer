import 'dart:math' as math;
import 'dart:typed_data';

/// A source of travel times between nodes (stops and depot).
///
/// Times are seconds since midnight. Implementations must be FIFO: leaving
/// later never gets you there earlier. Local search and the O(1) feasibility
/// checks rely on that property.
abstract interface class TravelModel {
  /// Arrival time at [to] when leaving [from] at [departAt].
  int arrive(int from, int to, int departAt);

  /// Latest departure from [from] that still arrives at [to] by [arriveBy].
  /// Exact inverse of [arrive]: `arrive(f, t, d) <= a` iff `d <= latestDeparture(f, t, a)`.
  int latestDeparture(int from, int to, int arriveBy);

  /// Free-flow (uncongested) driving time in seconds.
  int freeFlow(int from, int to);

  /// Driving distance in metres.
  int distance(int from, int to);
}

/// Free-flow travel times and distances in flat typed arrays.
///
/// In production this is filled from Valhalla's `sources_to_targets` matrix
/// and cached locally (e.g. in Drift). Times are 16-bit seconds, so a
/// 500-stop matrix takes about 0.5 MB.
///
/// The matrix is allocated with spare capacity, so a stop added mid-round
/// costs one row and one column (one one-to-many call), never a full rebuild.
class TravelMatrix {
  TravelMatrix(this.capacity)
      : _time = Uint16List(capacity * capacity),
        _dist = Int32List(capacity * capacity);

  /// A matrix over existing buffers, e.g. memory owned by native code
  /// (see `NativeKernels.allocateMatrix`). Valhalla writes into the same
  /// buffer that Dart reads, with no copy in between.
  TravelMatrix.view(this.capacity, Uint16List time, Int32List distance)
      : _time = time,
        _dist = distance {
    if (time.length < capacity * capacity || distance.length < capacity * capacity) {
      throw ArgumentError('Buffers are smaller than capacity x capacity.');
    }
  }

  final int capacity;
  final Uint16List _time;
  final Int32List _dist;
  int _size = 0;

  /// Number of nodes currently in the matrix.
  int get size => _size;

  /// Bytes used by the travel-time table.
  int get timeTableBytes => _time.lengthInBytes;

  int time(int from, int to) => _time[from * capacity + to];

  /// The raw row-major travel-time table (capacity x capacity).
  Uint16List get timeTable => _time;

  int distance(int from, int to) => _dist[from * capacity + to];

  /// Appends a node. [timeTo]\[j] is the time from the new node to node j,
  /// [timeFrom]\[j] from node j to the new node (same for distances).
  int addNode({
    required List<int> timeTo,
    required List<int> timeFrom,
    required List<int> distTo,
    required List<int> distFrom,
  }) {
    if (_size >= capacity) {
      throw StateError('TravelMatrix is full (capacity $capacity).');
    }
    final id = _size++;
    setNode(id, timeTo: timeTo, timeFrom: timeFrom, distTo: distTo, distFrom: distFrom);
    return id;
  }

  /// Overwrites the row and column of an existing node in O(n).
  void setNode(
    int id, {
    required List<int> timeTo,
    required List<int> timeFrom,
    required List<int> distTo,
    required List<int> distFrom,
  }) {
    for (var j = 0; j < _size; j++) {
      if (j == id) continue;
      _time[id * capacity + j] = math.min(timeTo[j], 65535);
      _time[j * capacity + id] = math.min(timeFrom[j], 65535);
      _dist[id * capacity + j] = distTo[j];
      _dist[j * capacity + id] = distFrom[j];
    }
    _time[id * capacity + id] = 0;
    _dist[id * capacity + id] = 0;
  }
}

/// Speed factors per zone and 15-minute time bucket (1.0 = free flow).
///
/// In production these come from map-matched GPS history (Meili): observed
/// speed / free-flow speed per zone and bucket, blended with fleet data.
/// They are a small overlay (zones x 96 floats) that syncs as data, with no
/// rebuild of offline map packages.
class CongestionProfile {
  CongestionProfile(this.zones) : _speed = Float32List(zones * buckets)..fillRange(0, zones * buckets, 1.0);

  static const int bucketSeconds = 900;
  static const int buckets = 24 * 3600 ~/ bucketSeconds;

  final int zones;
  final Float32List _speed;

  bool _freeFlow = true;

  /// True when no slowdown has been set (enables a fast path).
  bool get isFreeFlow => _freeFlow;

  /// Speed factor for [zone] during [bucket]; outside the day it is free flow.
  double speed(int zone, int bucket) => (bucket < 0 || bucket >= buckets) ? 1.0 : _speed[zone * buckets + bucket];

  /// Sets the speed factor to at most [factor] in `[fromSeconds, toSeconds)`.
  void slowDown(int zone, int fromSeconds, int toSeconds, double factor) {
    if (factor <= 0.05 || factor > 1.0) {
      throw ArgumentError.value(factor, 'factor', 'must be in (0.05, 1]');
    }
    final b0 = fromSeconds ~/ bucketSeconds;
    final b1 = (toSeconds + bucketSeconds - 1) ~/ bucketSeconds;
    for (var b = math.max(0, b0); b < math.min(buckets, b1); b++) {
      final i = zone * buckets + b;
      if (factor < _speed[i]) _speed[i] = factor;
    }
    if (factor < 1.0) _freeFlow = false;
  }

  /// Sets one zone/bucket speed factor directly (used by the learner).
  void setSpeed(int zone, int bucket, double factor) {
    if (factor <= 0.05 || factor > 2.0) {
      throw ArgumentError.value(factor, 'factor', 'must be in (0.05, 2]');
    }
    _speed[zone * buckets + bucket] = factor;
    if (factor != 1.0) _freeFlow = false;
  }

  /// Read-only view of all factors, zone-major (zones x [buckets]).
  Float32List get table => _speed.asUnmodifiableView();

  /// Applies [slowDown] to every zone.
  void slowDownEverywhere(int fromSeconds, int toSeconds, double factor) {
    for (var z = 0; z < zones; z++) {
      slowDown(z, fromSeconds, toSeconds, factor);
    }
  }
}

/// Time-dependent travel times using the Ichoua-Gendreau-Potvin model.
///
/// Speed is constant within each time bucket, and travel time is found by
/// integrating distance over the buckets the trip crosses. This is FIFO by
/// construction. The naive alternative, `freeFlow / speed(departure bucket)`,
/// breaks FIFO at bucket edges: leaving a few seconds later can arrive
/// minutes earlier, which makes local search accept moves that are not real
/// improvements.
class TimeDependentTravel implements TravelModel {
  TimeDependentTravel(this.matrix, this.profile, this.zoneOf);

  final TravelMatrix matrix;
  final CongestionProfile profile;

  /// Zone of each node (capacity-sized, shared with the problem).
  final Uint8List zoneOf;

  static const int _bs = CongestionProfile.bucketSeconds;
  static const double _eps = 1e-6;

  /// Same matrix and zones with a different congestion profile.
  TimeDependentTravel withProfile(CongestionProfile p) => TimeDependentTravel(matrix, p, zoneOf);

  double _arcSpeed(int zi, int zj, int b) => 0.5 * (profile.speed(zi, b) + profile.speed(zj, b));

  static int _bucketOf(int t) => t >= 0 ? t ~/ _bs : -((-t + _bs - 1) ~/ _bs);

  @override
  int freeFlow(int from, int to) => matrix.time(from, to);

  @override
  int distance(int from, int to) => matrix.distance(from, to);

  @override
  int arrive(int from, int to, int departAt) {
    final work = matrix.time(from, to);
    if (work == 0) return departAt;
    if (profile.isFreeFlow) return departAt + work;
    final zi = zoneOf[from], zj = zoneOf[to];
    var remaining = work.toDouble();
    var t = departAt.toDouble();
    var b = _bucketOf(departAt);
    while (true) {
      final v = _arcSpeed(zi, zj, b);
      final bucketEnd = (b + 1) * _bs;
      final reachable = (bucketEnd - t) * v;
      if (reachable >= remaining) {
        t += remaining / v;
        break;
      }
      remaining -= reachable;
      t = bucketEnd.toDouble();
      b++;
    }
    return (t - _eps).ceil();
  }

  @override
  int latestDeparture(int from, int to, int arriveBy) {
    final work = matrix.time(from, to);
    if (work == 0) return arriveBy;
    if (profile.isFreeFlow) return arriveBy - work;
    final zi = zoneOf[from], zj = zoneOf[to];
    var remaining = work.toDouble();
    var t = arriveBy.toDouble();
    var b = _bucketOf(arriveBy - 1);
    while (true) {
      final v = _arcSpeed(zi, zj, b);
      final bucketStart = b * _bs;
      final reachable = (t - bucketStart) * v;
      if (reachable >= remaining) {
        t -= remaining / v;
        break;
      }
      remaining -= reachable;
      t = bucketStart.toDouble();
      b--;
    }
    return (t + _eps).floor();
  }
}
