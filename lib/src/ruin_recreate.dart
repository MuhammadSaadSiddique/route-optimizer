import 'dart:math' as math;

import 'construction.dart';
import 'deadline.dart';
import 'local_search.dart';
import 'model.dart';
import 'neighbours.dart';
import 'schedule.dart';

/// Anytime improvement after local search reaches a local optimum.
///
/// Each iteration removes a cluster of nearby stops (seed + its neighbours),
/// reinserts them with the O(1) window-safe insertion, and polishes the
/// area with local search. Acceptance uses a threshold that shrinks to zero
/// over the budget: early on, slightly worse routes are accepted to escape
/// local optima; at the end only improvements are kept. The best route
/// ever seen is returned.
///
/// It runs until the [Deadline], so the app picks the budget (e.g. 1 s on a
/// mid-range phone) and always gets the best route found so far.
class RuinAndRecreate {
  RuinAndRecreate(
    this.problem,
    this.neighbours, {
    required this.random,
    this.minRemove = 5,
    this.maxRemove = 15,
    this.lockedPos = 0,
    this.startThreshold = 0.004,
  });

  final Problem problem;
  final NeighbourLists neighbours;
  final math.Random random;
  final int minRemove, maxRemove, lockedPos;

  /// Initial acceptance threshold as a fraction of the route's cost
  /// (measured from the shift start).
  final double startThreshold;

  int iterations = 0, accepted = 0, improvements = 0;

  /// Improves until [deadline], or after [maxIterations] iterations if given.
  /// With an iteration cap (and a generous deadline) the result is fully
  /// deterministic for a given seed, whatever the machine speed.
  Schedule improve(Schedule start, Deadline deadline, {int? maxIterations}) {
    var current = start;
    var best = start;
    final base = costOf(problem.shiftStart, 0);
    while (!deadline.expired && (maxIterations == null || iterations < maxIterations)) {
      final candidate = _iterate(current, deadline);
      iterations++;
      if (candidate == null) continue;
      final progress = maxIterations != null ? iterations / maxIterations : deadline.progress;
      final threshold = startThreshold * (best.cost - base) * (1 - progress);
      if (candidate.cost <= current.cost + threshold) {
        accepted++;
        current = candidate;
        if (candidate.cost < best.cost) {
          improvements++;
          best = candidate;
        }
      }
    }
    return best;
  }

  Schedule? _iterate(Schedule s, Deadline deadline) {
    final free = s.last - 1 - lockedPos;
    if (free < 2 * maxRemove) return null;
    final seed = s.route[lockedPos + 1 + random.nextInt(free)];
    final target = minRemove + random.nextInt(maxRemove - minRemove + 1);
    final removed = random.nextBool() ? _clusterRuin(s, seed, target) : _stringRuin(s, seed, target);

    final route = [
      for (final n in s.route)
        if (!removed.contains(n)) n
    ];
    var partial = Schedule.compute(problem, route);
    if (!partial.feasible) return null;

    final order = removed.toList()..shuffle(random);
    order.sort((a, b) {
      final ta = problem.hasWindow(a), tb = problem.hasWindow(b);
      if (ta != tb) return ta ? -1 : 1;
      return ta ? problem.latest[a].compareTo(problem.latest[b]) : 0;
    });
    for (final node in order) {
      final p = bestInsertionPosition(partial, node, minPos: lockedPos);
      if (p < 0) return null;
      route.insert(p + 1, node);
      partial = Schedule.compute(problem, route);
    }

    final ls = LocalSearch(problem, neighbours, lockedPos: lockedPos, deadline: deadline);
    final active = <int>{...removed};
    for (final n in removed) {
      for (var t = 0; t < 4 && t < neighbours.countOf(n); t++) {
        active.add(neighbours.neighbour(n, t));
      }
    }
    return ls.run(partial, activeNodes: active);
  }

  /// Removes the seed and its nearest neighbours (fixes local ordering).
  Set<int> _clusterRuin(Schedule s, int seed, int target) {
    final removed = <int>{seed};
    for (var t = 0; t < neighbours.countOf(seed) && removed.length < target; t++) {
      final v = neighbours.neighbour(seed, t);
      if (s.positionOf(v) > lockedPos) removed.add(v);
    }
    return removed;
  }

  /// Removes two stretches of consecutive stops: one around the seed and
  /// one around a nearby stop that is visited at a very different time.
  /// Reinserting them fixes "the route comes back to this street later",
  /// which single-stop moves cannot.
  Set<int> _stringRuin(Schedule s, int seed, int target) {
    final half = target ~/ 2;
    final ps = s.positionOf(seed);
    var pv = -1;
    for (var t = 0; t < neighbours.countOf(seed); t++) {
      final q = s.positionOf(neighbours.neighbour(seed, t));
      if (q > lockedPos && (q - ps).abs() > target) {
        pv = q;
        break;
      }
    }
    final removed = <int>{};
    void take(int centre, int len) {
      final from = math.max(lockedPos + 1, centre - len ~/ 2);
      final to = math.min(s.last - 1, from + len - 1);
      for (var q = from; q <= to; q++) {
        removed.add(s.route[q]);
      }
    }

    if (pv < 0) {
      take(ps, target);
    } else {
      take(ps, half);
      take(pv, target - half);
    }
    return removed;
  }
}
