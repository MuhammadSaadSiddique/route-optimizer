import 'dart:collection';
import 'dart:typed_data';

import 'deadline.dart';
import 'model.dart';
import 'neighbours.dart';
import 'schedule.dart';

/// An improving change: route' = route[0..p] + middle + route[k..].
class _Move {
  _Move(this.p, this.middle, this.k, this.touched);
  final int p, k;
  final List<int> middle;
  final List<int> touched;
}

/// Statistics from a local search run.
class SearchStats {
  int candidates = 0;
  int exactChecks = 0;
  int movesApplied = 0;

  @override
  String toString() => 'candidates=$candidates exact=$exactChecks applied=$movesApplied';
}

/// Time-dependent local search: relocate / Or-opt (segments of 1-3 stops)
/// and 2-opt, restricted to neighbour lists, with don't-look bits.
///
/// Every candidate goes through two stages:
///  1. **O(1) time-aware screen**: the change in driving time of the arcs
///     that are added and removed, each priced at its current departure
///     time (so "serve the school zone before the school run" shows up as
///     a saving). Most candidates stop here.
///  2. **Exact check** with [Schedule.spliceCost]: simulates only the changed
///     part, checks the untouched tail in O(1) with latest-start times, and
///     stops early when the schedule rejoins the old one.
///
/// Only moves that are exactly feasible and exactly better are applied, so
/// the route never gets worse and never breaks a window.
class LocalSearch {
  LocalSearch(
    this.problem,
    this.neighbours, {
    this.lockedPos = 0,
    this.minGain = 1,
    this.maxSegment = 3,
    Deadline? deadline,
  }) : deadline = deadline ?? Deadline.none();

  final Problem problem;
  final NeighbourLists neighbours;

  /// Positions `0..lockedPos` are fixed (already driven / current stop).
  final int lockedPos;

  /// Minimum exact cost improvement to accept a move. A higher value keeps
  /// the driver's route stable during live re-optimisation.
  final int minGain;

  final int maxSegment;
  final Deadline deadline;
  final SearchStats stats = SearchStats();

  late Int32List _buf;

  Schedule run(Schedule initial, {Iterable<int>? activeNodes}) {
    var s = initial;
    _buf = Int32List(problem.capacity + 8);
    final inQueue = Uint8List(problem.capacity);
    final queue = ListQueue<int>();
    void push(int node) {
      if (node == 0 || inQueue[node] == 1) return;
      final pos = s.positionOf(node);
      if (pos <= lockedPos || pos >= s.last) return;
      inQueue[node] = 1;
      queue.add(node);
    }

    for (final node in activeNodes ?? s.route) {
      push(node);
    }
    while (queue.isNotEmpty && !deadline.expired) {
      final u = queue.removeFirst();
      inQueue[u] = 0;
      final move = _findImprovingMove(s, u);
      if (move == null) continue;
      final r = s.route;
      final next = <int>[...r.sublist(0, move.p + 1), ...move.middle, ...r.sublist(move.k)];
      s = Schedule.compute(problem, next);
      stats.movesApplied++;
      for (final t in move.touched) {
        push(t);
      }
      push(u);
    }
    return s;
  }

  int _tt(int a, int b, int depart) => problem.travel.arrive(a, b, depart) - depart;

  _Move? _findImprovingMove(Schedule s, int u) {
    final i = s.positionOf(u);
    if (i <= lockedPos || i >= s.last) return null;
    final r = s.route;
    final target = s.cost - minGain;
    final nb = neighbours;
    final count = nb.countOf(u);

    // Relocate / Or-opt: move segment r[i..segEnd] next to a neighbour.
    for (var len = 1; len <= maxSegment; len++) {
      final segEnd = i + len - 1;
      if (segEnd >= s.last) break;
      final a = r[i - 1], b = r[segEnd + 1], s1 = r[i], sL = r[segEnd];
      final removedSeg = (s.arrival[i] - s.departure[i - 1]) + (s.arrival[segEnd + 1] - s.departure[segEnd]);
      final gapGain = _tt(a, b, s.departure[i - 1]);
      final segInner = s.departure[segEnd] - s.arrival[i];
      for (var t = 0; t < count; t++) {
        final jv = s.positionOf(nb.neighbour(u, t));
        if (jv < 0) continue;
        for (var opt = 0; opt < 2; opt++) {
          final j = opt == 0 ? jv : jv - 1; // insert after v, or before v
          if (j < 0 || j >= s.last || j == i - 1 || (j >= i && j <= segEnd)) continue;
          if (j < i - 1 && j < lockedPos) continue;
          stats.candidates++;
          final c = r[j], d = r[j + 1];
          final toSeg = _tt(c, s1, s.departure[j]);
          final segDep = s.departure[j] + toSeg + segInner;
          final added = gapGain + toSeg + _tt(sL, d, segDep);
          final removed = removedSeg + (s.arrival[j + 1] - s.departure[j]);
          if (added - removed >= 0) continue;

          var m = 0;
          final int p, k;
          if (j < i - 1) {
            for (var q = i; q <= segEnd; q++) {
              _buf[m++] = r[q];
            }
            for (var q = j + 1; q <= i - 1; q++) {
              _buf[m++] = r[q];
            }
            p = j;
            k = segEnd + 1;
          } else {
            for (var q = segEnd + 1; q <= j; q++) {
              _buf[m++] = r[q];
            }
            for (var q = i; q <= segEnd; q++) {
              _buf[m++] = r[q];
            }
            p = i - 1;
            k = j + 1;
          }
          stats.exactChecks++;
          final cost = s.spliceCost(p, _buf, m, k);
          if (cost >= 0 && cost < target) {
            return _Move(p, List<int>.of(_buf.sublist(0, m)), k, [a, b, s1, sL, c, d]);
          }
        }
      }
    }

    // 2-opt: reverse r[x+1..y] so that u and its neighbour become adjacent.
    for (var t = 0; t < count; t++) {
      final jv = s.positionOf(nb.neighbour(u, t));
      if (jv < 0) continue;
      final x = i < jv ? i : jv, y = i < jv ? jv : i;
      if (x < lockedPos || y >= s.last || y < x + 2) continue;
      stats.candidates++;
      final ax = r[x], bx = r[x + 1], cy = r[y], dy = r[y + 1];
      final added = _tt(ax, cy, s.departure[x]) + _tt(bx, dy, s.departure[y]);
      final removed = (s.arrival[x + 1] - s.departure[x]) + (s.arrival[y + 1] - s.departure[y]);
      final interior = (s.freeFlowRev[y] - s.freeFlowRev[x + 1]) - (s.freeFlowFwd[y] - s.freeFlowFwd[x + 1]);
      if (added - removed + interior >= 0) continue;
      var m = 0;
      for (var q = y; q > x; q--) {
        _buf[m++] = r[q];
      }
      stats.exactChecks++;
      final cost = s.spliceCost(x, _buf, m, y + 1);
      if (cost >= 0 && cost < target) {
        return _Move(x, List<int>.of(_buf.sublist(0, m)), y + 1, [ax, bx, cy, dy]);
      }
    }
    return null;
  }
}
