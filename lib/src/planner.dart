import 'dart:math' as math;

import 'construction.dart';
import 'deadline.dart';
import 'local_search.dart';
import 'model.dart';
import 'neighbours.dart';
import 'ruin_recreate.dart';
import 'schedule.dart';

/// Timings and quality at each stage of planning.
class PlanReport {
  PlanReport(this.schedule, this.unassigned, this.stages);

  final Schedule schedule;
  final List<int> unassigned;

  /// Stage name -> (elapsed ms at end of stage, schedule after stage).
  final List<(String, int, Schedule)> stages;
}

/// The full planning pipeline for one round:
///
///   construct (window-aware insertion)  ->  local search
///   -> retry any unplaced stops  ->  ruin & recreate until [budget]
///
/// Designed to run in a background isolate (`Isolate.run`) so the UI never
/// blocks. It returns within the time budget with the best route found.
/// Pass [maxIterations] (with a generous budget) for reproducible results.
PlanReport planRound(
  Problem problem, {
  Duration budget = const Duration(seconds: 1),
  int seed = 7,
  int? maxIterations,
  NeighbourLists? neighbours,
}) {
  final deadline = Deadline(budget);
  final watch = Stopwatch()..start();
  final nb = neighbours ?? NeighbourLists(problem);
  final stages = <(String, int, Schedule)>[];

  final built = buildInitialRoute(problem, problem.stopIds);
  var s = built.schedule;
  stages.add(('construct', watch.elapsedMilliseconds, s));

  s = LocalSearch(problem, nb, deadline: deadline).run(s);
  stages.add(('local search', watch.elapsedMilliseconds, s));

  final unassigned = <int>[];
  for (final node in built.unassigned) {
    final p = bestInsertionPosition(s, node);
    if (p < 0) {
      unassigned.add(node);
      continue;
    }
    s = Schedule.compute(problem, List<int>.of(s.route)..insert(p + 1, node));
  }
  if (built.unassigned.isNotEmpty) {
    s = LocalSearch(problem, nb, deadline: deadline).run(s);
  }

  final maxRemove = math.max(15, problem.size ~/ 20);
  s = RuinAndRecreate(problem, nb, random: math.Random(seed), maxRemove: maxRemove)
      .improve(s, deadline, maxIterations: maxIterations);
  stages.add(('ruin & recreate', watch.elapsedMilliseconds, s));
  return PlanReport(s, unassigned, stages);
}
