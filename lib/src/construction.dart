import 'model.dart';
import 'neighbours.dart';
import 'schedule.dart';

/// Result of building an initial route.
class ConstructionResult {
  ConstructionResult(this.schedule, this.unassigned);

  final Schedule schedule;

  /// Stops that could not be placed without breaking a window.
  final List<int> unassigned;
}

/// Insertion score: how much the rest of the round is pushed, plus half
/// the extra free-flow driving (so waiting time is not treated as free).
int insertionScore(Schedule s, int p, int node, int shift) {
  final tm = s.problem.travel;
  final a = s.route[p], b = s.route[p + 1];
  final extra = tm.freeFlow(a, node) + tm.freeFlow(node, b) - tm.freeFlow(a, b);
  return shift + (extra >> 1);
}

/// Best feasible insertion position for [node] after [minPos], or -1.
int bestInsertionPosition(Schedule s, int node, {int minPos = 0}) {
  var bestP = -1;
  var bestScore = kInfeasible;
  for (var p = minPos; p < s.last; p++) {
    final shift = s.insertionShift(p, node);
    if (shift == kInfeasible) continue;
    final score = insertionScore(s, p, node, shift);
    if (score < bestScore) {
      bestScore = score;
      bestP = p;
    }
  }
  return bestP;
}

/// Like [bestInsertionPosition], but only tries the gaps next to the
/// node's nearest neighbours (O(K) instead of O(n)). Falls back to a full
/// scan if none of those gaps is feasible.
int bestInsertionNearNeighbours(Schedule s, int node, NeighbourLists nb, {int minPos = 0}) {
  var bestP = -1;
  var bestScore = kInfeasible;
  for (var t = 0; t < nb.countOf(node); t++) {
    final pv = s.positionOf(nb.neighbour(node, t));
    if (pv < 0) continue;
    for (var p = pv - 1; p <= pv; p++) {
      if (p < minPos || p >= s.last) continue;
      final shift = s.insertionShift(p, node);
      if (shift == kInfeasible) continue;
      final score = insertionScore(s, p, node, shift);
      if (score < bestScore) {
        bestScore = score;
        bestP = p;
      }
    }
  }
  return bestP >= 0 ? bestP : bestInsertionPosition(s, node, minPos: minPos);
}

/// Time-window-aware cheapest insertion.
///
/// Stops go in by how constrained they are: tight windows (under 4 h)
/// earliest deadline first, so they shape the route; then wide windows
/// such as business hours; then open stops. Within the last two groups the
/// order is farthest-first. Every candidate position is checked in O(1)
/// against the latest-start times, so a window can never be broken by a
/// later insertion.
ConstructionResult buildInitialRoute(Problem problem, Iterable<int> stops) {
  final tight = <int>[], wide = <int>[], open = <int>[];
  for (final s in stops) {
    if (!problem.hasWindow(s)) {
      open.add(s);
    } else if (problem.latest[s] - problem.earliest[s] < 4 * 3600) {
      tight.add(s);
    } else {
      wide.add(s);
    }
  }
  tight.sort((a, b) => problem.latest[a].compareTo(problem.latest[b]));
  final tm = problem.travel;
  int farthestFirst(int a, int b) => tm.freeFlow(0, b).compareTo(tm.freeFlow(0, a));
  wide.sort(farthestFirst);
  open.sort(farthestFirst);

  final route = <int>[0, 0];
  var schedule = Schedule.compute(problem, route);
  final unassigned = <int>[];
  for (final node in [...tight, ...wide, ...open]) {
    final p = bestInsertionPosition(schedule, node);
    if (p < 0) {
      unassigned.add(node);
      continue;
    }
    route.insert(p + 1, node);
    schedule = Schedule.compute(problem, route);
  }
  return ConstructionResult(schedule, unassigned);
}

/// Baseline used for comparison: greedy nearest-neighbour on distance,
/// ignoring traffic and time windows (what simple planners do).
List<int> nearestNeighbourRoute(Problem problem, Iterable<int> stops) {
  final tm = problem.travel;
  final remaining = stops.toSet();
  final route = <int>[0];
  var current = 0;
  while (remaining.isNotEmpty) {
    var best = -1, bestD = 1 << 30;
    for (final s in remaining) {
      final d = tm.distance(current, s);
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    route.add(best);
    remaining.remove(best);
    current = best;
  }
  route.add(0);
  return route;
}
