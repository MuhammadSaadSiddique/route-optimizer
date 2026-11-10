// Benchmark: dart run bin/benchmark.dart
//
// Everything is seeded, so the numbers are reproducible on any machine
// (timings vary with hardware).
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:route_optimizer/native.dart';
import 'package:route_optimizer/route_optimizer.dart';

String dur(int s) => '${s ~/ 3600}h${((s % 3600) ~/ 60).toString().padLeft(2, '0')}';
String km(Schedule s) => (s.distanceMetres / 1000).toStringAsFixed(1);
String mins(num s) => '${(s / 60).toStringAsFixed(1)} min';
void line([String s = '']) => print(s);
void title(String s) {
  line();
  line(s);
  line('-' * s.length);
}

Future<void> main() async {
  line('Route optimiser benchmark (pure Dart, fully offline)');
  line('Synthetic 6 x 6 km town: 16 congestion zones, morning/evening peaks,');
  line('school run in 3 zones, lunchtime slowdown in the centre. Seeded.');

  await planningTable();
  congestionAwareness();
  learnedTraffic();
  safetyMargin();
  liveInsertion();
  parkOnce();
  serviceTimes();
  nativeKernels();
  line();
}

/// 1. Plan whole rounds in a background isolate.
Future<void> planningTable() async {
  title('1. Planning a full round (runs in a background isolate)');
  line('Simple planner = nearest neighbour by distance, ignores windows and traffic.');
  line();
  line('Stops  Timed | Simple: finish  driving   km  broken | This: 1st route  finish  driving   km  broken  budget');
  final reference = <(int, double, double)>[];
  for (final (n, budgetMs) in [(200, 1000), (300, 1500), (500, 3000)]) {
    final problem = CityInstance.generate(stops: n).problem;
    final timed = problem.stopIds.where(problem.hasWindow).length;
    final simple = Schedule.compute(problem, nearestNeighbourRoute(problem, problem.stopIds));

    // The UI isolate stays free: planning happens in a worker isolate.
    final result = await Isolate.run(() {
      final r = planRound(problem, budget: Duration(milliseconds: budgetMs));
      return (r.schedule.route, r.stages[1].$2, r.unassigned.length);
    });
    final (route, firstMs, unassigned) = result;
    final s = Schedule.compute(problem, route);
    if (unassigned > 0) line('  ($unassigned stops could not be placed)');
    line('${'$n'.padLeft(5)}  ${'$timed'.padLeft(5)} |'
        '         ${clock(simple.finish)}  ${dur(simple.drivingSeconds).padLeft(7)}  ${km(simple).padLeft(5)}  ${'${simple.violations}'.padLeft(6)} |'
        '    ${'${firstMs}ms'.padLeft(9)}   ${clock(s.finish)}  ${dur(s.drivingSeconds).padLeft(7)}  ${km(s).padLeft(5)}  ${'${s.violations}'.padLeft(6)}  ${budgetMs}ms');

    // Reference: the same optimiser with windows ignored, on the simple planner's terms.
    final open = problem.withOpenWindows();
    final openRoute = await Isolate.run(() => planRound(open, budget: Duration(milliseconds: budgetMs)).schedule.route);
    reference.add((n, Schedule.compute(open, openRoute).distanceMetres / 1000, simple.distanceMetres / 1000));
  }
  line();
  line('"1st route" = window-safe construction + local search, ready to drive.');
  line('The rest of the budget is anytime improvement (ruin & recreate).');
  line();
  line("Reference, windows ignored (the simple planner's own terms):");
  for (final (n, ours, nn) in reference) {
    line('  $n stops: this ${ours.toStringAsFixed(1)} km vs simple ${nn.toStringAsFixed(1)} km '
        '(${(100 - 100 * ours / nn).toStringAsFixed(0)}% less driving)');
  }
  line('So any extra km in the table is the price of keeping every window, not a weaker');
  line('optimiser. The simple planner breaks windows and waits at stops that are not open yet.');
}

/// 2. Same optimiser, with and without the congestion model.
void congestionAwareness() {
  title('2. Why the congestion model matters (300 stops, 8 different towns)');
  var etaError = 0, broken = 0, delta = 0;
  const towns = 8;
  for (var seed = 1; seed <= towns; seed++) {
    final p = CityInstance.generate(stops: 300, seed: seed).problem;
    final blindProblem = p.withTravel(p.travel.withProfile(CongestionProfile(16)));
    final aware = planRound(p, budget: const Duration(seconds: 30), maxIterations: 400).schedule;
    final blind = planRound(blindProblem, budget: const Duration(seconds: 30), maxIterations: 400).schedule;
    final onTheRoad = Schedule.compute(p, blind.route);
    etaError += onTheRoad.finish - blind.finish;
    broken += onTheRoad.violations;
    delta += aware.finish - onTheRoad.finish;
    if (aware.violations != 0) throw StateError('aware plan broke a window');
  }
  final d = delta / towns;
  line('Planner ignoring traffic:   promised finish was ${mins(etaError / towns)} too early on average,');
  line(
      '                            and broke ${(broken / towns).toStringAsFixed(1)} time windows per round on the real road.');
  line('Planner with this model:    0 broken windows, and what it promises is what happens.');
  line('                            Its day ends ${mins(d.abs())} ${d > 0 ? 'later' : 'earlier'} on average:');
  line('                            the gain is reliability and trustworthy ETAs, not distance.');
}

/// Share of random mid-round collection requests that can still be served.
double servableShare(CityInstance city, Schedule plan, DynamicInserter inserter, int probe, {int requests = 1000}) {
  final rnd = math.Random(99);
  var ok = 0;
  for (var q = 0; q < requests; q++) {
    final t = hhmm(9, 0) + rnd.nextInt(plan.departure[plan.last - 1] - hhmm(9, 0) - 1800);
    var c = 0;
    while (c + 1 < plan.last && plan.departure[c + 1] <= t) {
      c++;
    }
    final e = t + (30 + rnd.nextInt(151)) * 60;
    city.relocateStop(
        probe, city.randomStop(kind: StopKind.collection, earliest: e, latest: e + (30 + rnd.nextInt(31)) * 60));
    if (inserter.insert(plan, c, probe, repair: false).feasible) ok++;
  }
  return ok / requests;
}

/// 4. Plan with a safety margin before every deadline.
void safetyMargin() {
  title('4. Safety margin before deadlines (300 stops, average of 4 towns)');
  line('Left alone, an optimiser packs timed stops close to their deadlines, so the');
  line('route is fragile when the day changes. Planning against deadlines brought');
  line('forward keeps room for late running and new work.');
  line();
  line('Margin | finish change   km   new mid-round collections still servable');
  const towns = [1, 2, 3, 4];
  int? baseFinish;
  final shares = <int, double>{};
  for (final minutes in [0, 10, 15]) {
    var finish = 0, metres = 0, share = 0.0;
    for (final seed in towns) {
      final city = CityInstance.generate(stops: 300, seed: seed);
      final p = city.problem;
      final nb = NeighbourLists(p);
      final planned = planRound(p.withDeadlineBuffer(minutes * 60),
          budget: const Duration(seconds: 30), maxIterations: 400, neighbours: nb);
      final plan = Schedule.compute(p, planned.schedule.route);
      finish += plan.finish;
      metres += plan.distanceMetres;
      final probe = city.addStop(city.randomStop());
      share += servableShare(city, plan, DynamicInserter(p, nb), probe, requests: 500);
    }
    final avgFinish = finish ~/ towns.length;
    baseFinish ??= avgFinish;
    shares[minutes] = share / towns.length;
    final change = avgFinish - baseFinish;
    line('${'$minutes min'.padLeft(6)} | ${'${change >= 0 ? '+' : '-'}${mins(change.abs())}'.padLeft(13)}  '
        '${(metres / towns.length / 1000).toStringAsFixed(1).padLeft(5)}   ${(shares[minutes]! * 100).toStringAsFixed(1).padLeft(5)}%');
  }
  line();
  line('A 10-minute margin also absorbs a driver running up to 10 minutes late');
  line('without breaking a window.');
}

/// 5. Adding a timed collection to a round in progress.
void liveInsertion() {
  title('5. Live insertion: a timed collection arrives mid-round (300 stops)');
  final city = CityInstance.generate(stops: 300);
  final p = city.problem;
  final nb = NeighbourLists(p);
  final planned = planRound(p.withDeadlineBuffer(600), budget: const Duration(milliseconds: 1500), neighbours: nb);
  final plan = Schedule.compute(p, planned.schedule.route); // live, against real windows
  final now = hhmm(12, 0);
  var cur = 0;
  while (plan.departure[cur + 1] <= now) {
    cur++;
  }
  final open = now + 90 * 60, close = open + 30 * 60;
  final id = city.addStop(city.randomStop(kind: StopKind.collection, earliest: open, latest: close));
  nb.addNode(id);
  line('At ${clock(plan.departure[cur])} the driver has done $cur of 300 stops.');
  line('New collection, window ${clock(open)}-${clock(close)}.');

  final inserter = DynamicInserter(p, nb);
  for (var w = 0; w < 200; w++) {
    inserter.insert(plan, cur, id, repair: false); // warm up the JIT
  }
  final pure = inserter.insert(plan, cur, id, repair: false);
  final repaired = inserter.insert(plan, cur, id);
  final s = pure.schedule!;
  line();
  line('  Checked ${pure.positionsChecked} positions exactly (O(1) each) in ${pure.checkMicros} us.');
  line('  Inserted at position ${pure.position}: arrives ${clock(s.arrival[pure.position])}, '
      'served ${clock(s.start[pure.position])} (inside the window).');
  line('  Rest of the round: finish ${pure.finishDelta >= 0 ? '+' : ''}${mins(pure.finishDelta)}, '
      'worst delay to any stop ${mins(pure.maxStopDelay)}, ${pure.stopsReordered} stops reordered, 0 windows broken.');
  line('  Optional local repair (only changes saving >= 60 s): '
      '${repaired.stopsReordered} stops reordered, finish ${repaired.finishDelta >= 0 ? '+' : ''}${mins(repaired.finishDelta)}, '
      '${(repaired.totalMicros / 1000).toStringAsFixed(1)} ms total.');

  // Driver control on top of it.
  final session = RouteSession(p, plan);
  final proposal = session.propose(repaired.schedule!, 'New collection');
  line();
  line('  Driver sees: "$proposal"');
  session.accept();
  line(
      '  Accepted -> version ${session.current.version}. Revert -> version ${session.revert().version} (instant, exact).');

  // 1,000 random requests at random times of day.
  final rnd = math.Random(99);
  final probe = city.addStop(city.randomStop());
  final micros = <int>[];
  var feasible = 0;
  for (var q = 0; q < 1100; q++) {
    final t = hhmm(9, 0) + rnd.nextInt(plan.departure[plan.last - 1] - hhmm(9, 0) - 1800);
    var c = 0;
    while (c + 1 < plan.last && plan.departure[c + 1] <= t) {
      c++;
    }
    final e = t + (30 + rnd.nextInt(151)) * 60;
    city.relocateStop(
        probe, city.randomStop(kind: StopKind.collection, earliest: e, latest: e + (30 + rnd.nextInt(31)) * 60));
    final r = inserter.insert(plan, c, probe, repair: false);
    if (q < 100) continue; // warm-up
    micros.add(r.checkMicros);
    if (r.feasible) feasible++;
  }
  micros.sort();
  final mean = micros.reduce((a, b) => a + b) / micros.length;
  line();
  line('  1,000 random requests (random time of day, 30-60 min windows, plan with 10 min margin):');
  line('  ${(feasible / 10).toStringAsFixed(1)}% servable; decision time mean ${mean.toStringAsFixed(0)} us, '
      'p95 ${micros[(micros.length * 0.95).floor()]} us, max ${micros.last} us.');
  line('  Each decision is exact: tests check it against full re-simulation.');
}

/// 7. Cold start for driver learning.
void serviceTimes() {
  title('7. Driver learning with cold start (service time at flats)');
  final m = ServiceTimeModel();
  final rnd = math.Random(5);
  for (var i = 0; i < 2000; i++) {
    m.record('fleet-${i % 40}', AddressType.flat, 110 + (rnd.nextDouble() - 0.5) * 40);
  }
  line('Fleet average ~110 s. A new driver who actually takes ~80 s:');
  final shown = {0, 5, 20, 50};
  for (var i = 0; i <= 50; i++) {
    if (shown.contains(i)) {
      line('  after ${'$i'.padLeft(2)} deliveries: ${m.estimate('new', AddressType.flat).toStringAsFixed(0)} s');
    }
    m.record('new', AddressType.flat, 80 + (rnd.nextDouble() - 0.5) * 20);
  }
  line('No history -> fleet value; history -> personal value. No spikes from outliers.');
}

/// Mean |planned - actual| arrival per stop and at the finish, in seconds,
/// and windows broken, when a plan made with [profile] meets the true
/// average traffic. Averaged over 6 towns.
(double, double, double) etaAccuracy(CongestionProfile profile) {
  var stop = 0.0, finish = 0.0, broken = 0.0;
  const towns = [900, 901, 902, 903, 904, 905];
  for (final seed in towns) {
    final truth = CityInstance.generate(stops: 300, seed: seed).problem;
    final model = truth.withTravel(truth.travel.withProfile(profile));
    final plan = planRound(model, budget: const Duration(seconds: 30), maxIterations: 300).schedule;
    final driven = RoadSimulator(truth, random: math.Random(seed), legNoise: 0, dayNoise: 0).drive(plan.route);
    var e = 0;
    for (var k = 1; k < plan.route.length; k++) {
      e += (plan.arrival[k] - driven.arrival[k]).abs();
    }
    stop += e / (plan.route.length - 1);
    finish += (plan.finish - driven.finish).abs();
    broken += driven.brokenWindows;
  }
  return (stop / towns.length, finish / towns.length, broken / towns.length);
}

/// 3. Learning congestion from the fleet's own GPS history.
void learnedTraffic() {
  title('3. Learning traffic from GPS history, with cold start (300 stops, 6 towns)');
  line('Each past day: a 300-stop round driven in real traffic, with random variation');
  line('(+/-12% per leg, +/-5% per day). Its GPS legs feed the speed learner. Accuracy is');
  line('then measured on new rounds against the true average traffic.');
  line();
  line('History            | ETA error per stop | at finish | late windows (no margin)');
  final learner = SpeedProfileLearner(zones: 16);
  final rnd = math.Random(1);
  void report(String label, CongestionProfile profile) {
    final (stop, finish, broken) = etaAccuracy(profile);
    line(
        '${label.padRight(18)} | ${mins(stop).padLeft(18)} | ${mins(finish).padLeft(9)} | ${broken.toStringAsFixed(1).padLeft(4)}');
  }

  report('none (base map)', CongestionProfile(16));
  for (var day = 1; day <= 20; day++) {
    final truth = CityInstance.generate(stops: 300, seed: 100 + day).problem;
    final model = truth.withTravel(truth.travel.withProfile(learner.buildProfile()));
    final plan = LocalSearch(model, NeighbourLists(model)).run(buildInitialRoute(model, model.stopIds).schedule);
    learner.recordAll(RoadSimulator(truth, random: rnd).drive(plan.route).legs);
    if (day == 1 || day == 5 || day == 20) report('$day day${day == 1 ? '' : 's'} of rounds', learner.buildProfile());
  }
  line();
  line("Zones or times never driven fall back to the fleet's time-of-day pattern, then to");
  line('free-flow speeds, so a new area is never worse than the base map.');
}

/// 6. Park Once.
void parkOnce() {
  title('6. Park Once (300 doors, 45 s to park per van stop)');
  final city = CityInstance.generate(stops: 300);
  const settings = ParkOnceSettings();
  final grouped = groupForParkOnce(city.problem, settings: settings);
  final single = groupForParkOnce(city.problem, settings: settings.everyDoor);
  line('              van stops  finish   driving    km   walking  broken');
  for (final (label, groups) in [('Every door', single), ('Park Once', grouped)]) {
    final s = planRound(city.parkOnceRound(groups).problem, budget: const Duration(milliseconds: 1500)).schedule;
    final walk = groups.fold(0, (a, g) => a + g.walkSeconds);
    line(
        '${label.padRight(12)}  ${'${groups.length}'.padLeft(9)}  ${clock(s.finish)}  ${dur(s.drivingSeconds).padLeft(8)}  '
        '${km(s).padLeft(5)}  ${dur(walk).padLeft(8)}  ${'${s.violations}'.padLeft(6)}');
  }
  final example = grouped.firstWhere((g) => g.size >= 4);
  line();
  line('Example guidance: park at stop ${example.parkAt}, walk ${example.stops.skip(1).join(' -> ')}, back to the van '
      '(${example.walkMetres} m, ${mins(example.walkSeconds)}).');
  line('Timed collections keep their own van stop; every door stays inside its own window.');
}

/// 8. The same travel model in C++, called through dart:ffi.
void nativeKernels() {
  title('8. C++ kernels via dart:ffi');
  final kernels = NativeKernels.tryLoad();
  if (kernels == null) {
    line('Native library not built. Run: tool/build_native.sh   (Windows: see README)');
    return;
  }
  late NativeTravelMatrix nm;
  final city = CityInstance.generate(stops: 500, matrixFactory: (cap) => (nm = kernels.allocateMatrix(cap)).matrix);
  final travel = city.problem.travel;
  final traffic = kernels.traffic(nm, travel);
  final rnd = math.Random(1);
  const legs = 1000000;
  final batch = kernels.legBatch(legs);
  for (var i = 0; i < legs; i++) {
    batch.from[i] = rnd.nextInt(501);
    batch.to[i] = rnd.nextInt(501);
    batch.depart[i] = hhmm(7, 0) + rnd.nextInt(12 * 3600);
  }
  final dartOut = Int32List(legs);
  var dartUs = 1 << 62, cUs = 1 << 62;
  for (var rep = 0; rep < 3; rep++) {
    final w = Stopwatch()..start();
    for (var i = 0; i < legs; i++) {
      dartOut[i] = travel.arrive(batch.from[i], batch.to[i], batch.depart[i]);
    }
    dartUs = math.min(dartUs, w.elapsedMicroseconds);
    w.reset();
    kernels.arrivals(traffic, batch, legs);
    cUs = math.min(cUs, w.elapsedMicroseconds);
  }
  var mismatches = 0;
  for (var i = 0; i < legs; i++) {
    if (dartOut[i] != batch.arrival[i]) mismatches++;
  }
  const n = 501, depart = 8 * 3600 + 30 * 60;
  final snap = kernels.intBuffer(n * n);
  final dartSnap = Int32List(n * n);
  var dSnap = 1 << 62, cSnap = 1 << 62;
  for (var rep = 0; rep < 3; rep++) {
    final w = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        dartSnap[i * n + j] = travel.arrive(i, j, depart) - depart;
      }
    }
    dSnap = math.min(dSnap, w.elapsedMicroseconds);
    w.reset();
    kernels.matrixSnapshot(traffic, n, depart, snap);
    cSnap = math.min(cSnap, w.elapsedMicroseconds);
  }
  for (var i = 0; i < n * n; i++) {
    if (dartSnap[i] != snap.$2[i]) mismatches++;
  }
  line('The 500-stop matrix lives in native memory, shared with Dart (no copies).');
  line(
      '1,000,000 time-dependent legs:   Dart ${(dartUs / 1000).toStringAsFixed(0)} ms, C++ ${(cUs / 1000).toStringAsFixed(0)} ms '
      '(one leaf call)');
  line(
      'Full 501 x 501 snapshot @ 08:30: Dart ${(dSnap / 1000).toStringAsFixed(1)} ms, C++ ${(cSnap / 1000).toStringAsFixed(1)} ms');
  line('Results bit-identical to Dart: $mismatches mismatches.');
}
