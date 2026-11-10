import 'dart:typed_data';

import 'model.dart';

/// Returned by O(1) checks when a change would break a time window.
const int kInfeasible = 1 << 40;

/// Objective: route finish time first, driving time second.
/// `4 * finish + driving` = working day + 0.25 x driving (fuel, wear).
int costOf(int finish, int drivingSeconds) => 4 * finish + drivingSeconds;

/// A fully timed route: `[0, s1, s2, ..., 0]` (depot at both ends).
///
/// Besides the forward times it stores, for every position, the latest
/// start time that keeps the whole rest of the route feasible. With
/// FIFO travel times, a change ahead of position k is feasible iff the
/// new start at k is no later than [latestStart]\[k]. That is one comparison,
/// with no re-simulation of the round.
class Schedule {
  Schedule._(this.problem, this.route, int n)
      : arrival = Int32List(n),
        start = Int32List(n),
        departure = Int32List(n),
        latestStart = Int32List(n),
        drivingCum = Int32List(n),
        freeFlowFwd = Int32List(n),
        freeFlowRev = Int32List(n),
        _posOf = Int32List(problem.capacity)..fillRange(0, problem.capacity, -1);

  factory Schedule.compute(Problem problem, List<int> route) {
    if (route.length < 2 || route.first != 0 || route.last != 0) {
      throw ArgumentError('Route must start and end at the depot (node 0).');
    }
    final n = route.length;
    final s = Schedule._(problem, List<int>.unmodifiable(route), n);
    final tm = problem.travel;
    final e = problem.earliest, l = problem.latest, svc = problem.service;

    s.arrival[0] = problem.shiftStart;
    s.start[0] = problem.shiftStart;
    s.departure[0] = problem.shiftStart;
    s._posOf[0] = 0;
    var violations = 0, late = 0, wait = 0, dist = 0;
    for (var k = 1; k < n; k++) {
      final prev = route[k - 1], node = route[k];
      final arr = tm.arrive(prev, node, s.departure[k - 1]);
      final st = arr < e[node] ? e[node] : arr;
      if (st > l[node]) {
        violations++;
        late += st - l[node];
      }
      s.arrival[k] = arr;
      s.start[k] = st;
      s.departure[k] = st + svc[node];
      s.drivingCum[k] = s.drivingCum[k - 1] + (arr - s.departure[k - 1]);
      s.freeFlowFwd[k] = s.freeFlowFwd[k - 1] + tm.freeFlow(prev, node);
      s.freeFlowRev[k] = s.freeFlowRev[k - 1] + tm.freeFlow(node, prev);
      wait += st - arr;
      dist += tm.distance(prev, node);
      if (k < n - 1) s._posOf[node] = k;
    }
    s.violations = violations;
    s.lateSeconds = late;
    s.waitSeconds = wait;
    s.distanceMetres = dist;

    // Backward pass: latest feasible start at every position.
    s.latestStart[n - 1] = l[0];
    for (var k = n - 2; k >= 0; k--) {
      final node = route[k];
      final ld = tm.latestDeparture(node, route[k + 1], s.latestStart[k + 1]) - svc[node];
      final lk = k == 0 ? l[0] : l[node];
      s.latestStart[k] = ld < lk ? ld : lk;
    }
    return s;
  }

  final Problem problem;

  /// Node ids, depot at both ends. Unmodifiable.
  final List<int> route;

  final Int32List arrival, start, departure, latestStart;

  /// Cumulative driving seconds up to (arriving at) each position.
  final Int32List drivingCum;

  /// Cumulative free-flow time along the route, forward and reversed
  /// arc direction. Used for O(1) 2-opt screening.
  final Int32List freeFlowFwd, freeFlowRev;

  final Int32List _posOf;

  late final int violations, lateSeconds, waitSeconds, distanceMetres;

  int get last => route.length - 1;
  int get stopCount => route.length - 2;
  int get finish => arrival[last];
  int get drivingSeconds => drivingCum[last];
  int get cost => costOf(finish, drivingSeconds);
  bool get feasible => violations == 0;

  /// Position of [node] in the route, or -1.
  int positionOf(int node) => node == 0 ? 0 : _posOf[node];

  /// O(1) exact check for inserting [node] between positions p and p+1.
  ///
  /// Returns how much later the successor would start (the "push" on the
  /// rest of the round), or [kInfeasible] if any window would break.
  int insertionShift(int p, int node) {
    final tm = problem.travel;
    final e = problem.earliest;
    final arrS = tm.arrive(route[p], node, departure[p]);
    final stS = arrS < e[node] ? e[node] : arrS;
    if (stS > problem.latest[node]) return kInfeasible;
    final next = route[p + 1];
    final arrN = tm.arrive(node, next, stS + problem.service[node]);
    final stN = arrN < e[next] ? e[next] : arrN;
    if (stN > latestStart[p + 1]) return kInfeasible;
    return stN - start[p + 1];
  }

  /// Exact cost of `route[0..p] + middle[0..midLen) + route[k..]`, or -1
  /// if any time window would break.
  ///
  /// Only the changed part is simulated. Feasibility of the untouched tail is
  /// one comparison against [latestStart], and simulation stops as soon as
  /// the new schedule rejoins the old one (waiting time absorbed the change).
  int spliceCost(int p, Int32List middle, int midLen, int k) {
    final tm = problem.travel;
    final e = problem.earliest, l = problem.latest, svc = problem.service;
    var prev = route[p];
    var dep = departure[p];
    var driving = drivingCum[p];
    for (var m = 0; m < midLen; m++) {
      final node = middle[m];
      final arr = tm.arrive(prev, node, dep);
      driving += arr - dep;
      final st = arr < e[node] ? e[node] : arr;
      if (st > l[node]) return -1;
      dep = st + svc[node];
      prev = node;
    }
    final lastPos = last;
    for (var q = k; q <= lastPos; q++) {
      final node = route[q];
      final arr = tm.arrive(prev, node, dep);
      driving += arr - dep;
      final st = arr < e[node] ? e[node] : arr;
      if (q == k && st > latestStart[k]) return -1;
      if (st == start[q]) {
        return costOf(finish, driving + (drivingCum[lastPos] - drivingCum[q]));
      }
      if (q == lastPos) return costOf(arr, driving);
      dep = st + svc[node];
      prev = node;
    }
    return -1;
  }
}
