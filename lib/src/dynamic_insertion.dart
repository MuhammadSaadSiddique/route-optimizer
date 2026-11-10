import 'dart:typed_data';

import 'local_search.dart';
import 'model.dart';
import 'neighbours.dart';
import 'schedule.dart';

/// Outcome of adding a stop to a live round.
class InsertionResult {
  InsertionResult._({
    required this.feasible,
    required this.before,
    this.schedule,
    this.position = -1,
    this.positionsChecked = 0,
    this.checkMicros = 0,
    this.totalMicros = 0,
    this.finishDelta = 0,
    this.maxStopDelay = 0,
    this.stopsReordered = 0,
    this.reason,
  });

  final bool feasible;
  final Schedule before;

  /// New route, or null if the stop cannot be served without breaking a window.
  final Schedule? schedule;

  /// Position of the new stop in the new route.
  final int position;

  final int positionsChecked;

  /// Time to evaluate every position (O(1) each) and pick the best.
  final int checkMicros;

  /// Including the optional local repair.
  final int totalMicros;

  /// Change in route finish time, seconds.
  final int finishDelta;

  /// Largest delay to any remaining existing stop, seconds.
  final int maxStopDelay;

  /// Minimum number of existing stops that moved in the sequence
  /// (n minus the longest unchanged subsequence). 0 = pure insertion.
  final int stopsReordered;

  final String? reason;
}

/// Adds a new stop (e.g. a timed collection) to a round in progress.
///
/// 1. Positions already driven are locked.
/// 2. Every remaining gap is checked with [Schedule.insertionShift]:
///    O(1) and exact, using latest-start times. No re-simulation.
/// 3. The best few candidates are re-scored exactly.
/// 4. Optional local repair around the new stop, but only for changes that
///    save at least [stabilityGainSeconds]. The driver's route stays
///    recognisable rather than reshuffled.
class DynamicInserter {
  DynamicInserter(this.problem, this.neighbours, {this.stabilityGainSeconds = 60, this.shortlist = 3});

  final Problem problem;
  final NeighbourLists neighbours;
  final int stabilityGainSeconds;
  final int shortlist;

  InsertionResult insert(Schedule current, int currentPos, int node, {bool repair = true}) {
    final watch = Stopwatch()..start();
    final picks = <int>[], scores = <int>[];
    var checked = 0;
    for (var p = currentPos; p < current.last; p++) {
      checked++;
      final shift = current.insertionShift(p, node);
      if (shift == kInfeasible) continue;
      _keepBest(picks, scores, p, shift);
    }
    if (picks.isEmpty) {
      return InsertionResult._(
        feasible: false,
        before: current,
        positionsChecked: checked,
        checkMicros: watch.elapsedMicroseconds,
        totalMicros: watch.elapsedMicroseconds,
        reason: _explainFailure(current, currentPos, node),
      );
    }
    final mid = Int32List(1)..[0] = node;
    var bestP = picks.first, bestCost = -1;
    for (final p in picks) {
      final c = current.spliceCost(p, mid, 1, p + 1);
      if (c >= 0 && (bestCost < 0 || c < bestCost)) {
        bestCost = c;
        bestP = p;
      }
    }
    final checkMicros = watch.elapsedMicroseconds;

    final route = List<int>.of(current.route)..insert(bestP + 1, node);
    var next = Schedule.compute(problem, route);
    if (repair) {
      final active = <int>{node};
      for (var t = 0; t < neighbours.countOf(node); t++) {
        active.add(neighbours.neighbour(node, t));
      }
      next = LocalSearch(problem, neighbours, lockedPos: currentPos, minGain: 4 * stabilityGainSeconds)
          .run(next, activeNodes: active);
    }
    final total = watch.elapsedMicroseconds;

    var maxDelay = 0;
    for (var q = currentPos + 1; q < current.last; q++) {
      final d = next.start[next.positionOf(current.route[q])] - current.start[q];
      if (d > maxDelay) maxDelay = d;
    }
    return InsertionResult._(
      feasible: true,
      before: current,
      schedule: next,
      position: next.positionOf(node),
      positionsChecked: checked,
      checkMicros: checkMicros,
      totalMicros: total,
      finishDelta: next.finish - current.finish,
      maxStopDelay: maxDelay,
      stopsReordered: stopsReordered(current.route, next.route),
    );
  }

  void _keepBest(List<int> picks, List<int> scores, int p, int score) {
    var i = scores.length;
    while (i > 0 && scores[i - 1] > score) {
      i--;
    }
    if (i >= shortlist) return;
    picks.insert(i, p);
    scores.insert(i, score);
    if (picks.length > shortlist) {
      picks.removeLast();
      scores.removeLast();
    }
  }

  String _explainFailure(Schedule s, int currentPos, int node) {
    final direct = problem.travel.arrive(s.route[currentPos], node, s.departure[currentPos]);
    if (direct > problem.latest[node]) {
      return 'Cannot be reached before its window closes, even driving there directly now.';
    }
    return 'Every position would make a later timed stop late.';
  }
}

/// Minimum number of stops of [before] that changed relative order in
/// [after]: n minus the longest increasing subsequence of old positions.
int stopsReordered(List<int> before, List<int> after) {
  final oldPos = <int, int>{};
  for (var i = 1; i < before.length - 1; i++) {
    oldPos[before[i]] = i;
  }
  final seq = [
    for (final n in after)
      if (oldPos.containsKey(n)) oldPos[n]!
  ];
  final tails = <int>[];
  for (final x in seq) {
    var lo = 0, hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (tails[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == tails.length) {
      tails.add(x);
    } else {
      tails[lo] = x;
    }
  }
  return seq.length - tails.length;
}
