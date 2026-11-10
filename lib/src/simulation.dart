import 'dart:math' as math;
import 'dart:typed_data';

import 'model.dart';
import 'speed_learning.dart';

/// What actually happened when a route was driven.
class DrivenRound {
  DrivenRound(this.route, this.arrival, this.start, this.legs, this.brokenWindows);

  final List<int> route;
  final Int32List arrival, start;

  /// GPS legs as the app would record them (input for [SpeedProfileLearner]).
  final List<TravelObservation> legs;

  final int brokenWindows;

  int get finish => arrival[route.length - 1];
}

/// Replays a route on the "real road": [truth]'s travel times, plus random
/// variation per leg (traffic lights, a slow van ahead) and per day.
///
/// Used to measure ETA accuracy, and to generate GPS history for the
/// speed learner. With real data, the same comparison runs on past rounds:
/// planned ETAs vs scanned arrival times.
class RoadSimulator {
  RoadSimulator(this.truth, {required this.random, this.legNoise = 0.12, this.dayNoise = 0.05});

  final Problem truth;
  final math.Random random;

  /// Standard deviation of the log travel-time multiplier per leg.
  final double legNoise;

  /// Standard deviation of the log multiplier shared by a whole day.
  final double dayNoise;

  double _gauss() {
    final u1 = random.nextDouble() + 1e-12, u2 = random.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  DrivenRound drive(List<int> route) {
    final n = route.length;
    final arrival = Int32List(n), start = Int32List(n);
    final tm = truth.travel;
    final day = math.exp(_gauss() * dayNoise);
    final legs = <TravelObservation>[];
    var dep = truth.shiftStart;
    arrival[0] = dep;
    start[0] = dep;
    var broken = 0;
    for (var k = 1; k < n; k++) {
      final a = route[k - 1], b = route[k];
      final ideal = tm.arrive(a, b, dep) - dep;
      final actual = (ideal * day * math.exp(_gauss() * legNoise)).round();
      legs.add(TravelObservation(
        fromZone: tm.zoneOf[a],
        toZone: tm.zoneOf[b],
        departAt: dep,
        freeFlowSeconds: tm.freeFlow(a, b),
        observedSeconds: actual,
      ));
      final arr = dep + actual;
      arrival[k] = arr;
      final st = math.max(arr, truth.earliest[b]);
      start[k] = st;
      if (b != 0 && st > truth.latest[b]) broken++;
      dep = st + truth.service[b];
    }
    return DrivenRound(route, arrival, start, legs, broken);
  }
}
