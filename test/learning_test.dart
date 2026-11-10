import 'dart:math' as math;

import 'package:route_optimizer/route_optimizer.dart';
import 'package:test/test.dart';

TravelObservation leg(int zone, int departAt, int freeFlow, int observed, {int? toZone}) => TravelObservation(
      fromZone: zone,
      toZone: toZone ?? zone,
      departAt: departAt,
      freeFlowSeconds: freeFlow,
      observedSeconds: observed,
    );

/// Mean |predicted - actual| arrival (seconds) when the plan's model is
/// compared with the true average traffic.
double modelEtaError(CongestionProfile profile, int seed) {
  final truth = CityInstance.generate(stops: 200, seed: seed).problem;
  final model = truth.withTravel(truth.travel.withProfile(profile));
  final plan = LocalSearch(model, NeighbourLists(model)).run(buildInitialRoute(model, model.stopIds).schedule);
  final driven = RoadSimulator(truth, random: math.Random(seed), legNoise: 0, dayNoise: 0).drive(plan.route);
  var e = 0;
  for (var k = 1; k < plan.route.length; k++) {
    e += (plan.arrival[k] - driven.arrival[k]).abs();
  }
  return e / (plan.route.length - 1);
}

void main() {
  const b830 = 34; // 08:30 bucket

  group('speed profile learning', () {
    test('no data: free-flow speeds (never worse than the base map)', () {
      final l = SpeedProfileLearner(zones: 16);
      expect(l.estimate(5, b830), equals(1.0));
      expect(l.buildProfile().isFreeFlow, isTrue);
    });

    test('recovers a zone\'s real speed from enough driven legs', () {
      final l = SpeedProfileLearner(zones: 16);
      for (var i = 0; i < 100; i++) {
        l.record(leg(5, hhmm(8, 30), 60, 120)); // half speed
      }
      expect(l.estimate(5, b830), closeTo(0.5, 0.02));
      expect(l.confidence(5, b830), greaterThan(0.9));
    });

    test('cold start: an area never driven uses the fleet\'s time-of-day pattern', () {
      final l = SpeedProfileLearner(zones: 16);
      for (var z = 0; z < 8; z++) {
        for (var i = 0; i < 30; i++) {
          l.record(leg(z, hhmm(8, 30), 60, 75)); // 0.8 everywhere at 08:30
        }
      }
      expect(l.confidence(12, b830), equals(0.0));
      expect(l.estimate(12, b830), closeTo(l.fleetEstimate(b830), 1e-9));
      expect(l.estimate(12, b830), closeTo(0.8, 0.03));
    });

    test('a GPS glitch on one leg cannot distort a zone', () {
      final l = SpeedProfileLearner(zones: 16);
      for (var i = 0; i < 20; i++) {
        l.record(leg(3, hhmm(11, 0), 60, 60));
      }
      final before = l.estimate(3, 44);
      l.record(leg(3, hhmm(11, 0), 60, 6000)); // 100 minutes for a 1-minute leg
      expect(before - l.estimate(3, 44), lessThan(0.08));
    });

    test('ten days of driving cut ETA error by at least 40% (average of 6 towns)', () {
      final learner = SpeedProfileLearner(zones: 16);
      final rnd = math.Random(3);
      for (var day = 0; day < 10; day++) {
        final truth = CityInstance.generate(stops: 250, seed: 500 + day).problem;
        final s = LocalSearch(truth, NeighbourLists(truth)).run(buildInitialRoute(truth, truth.stopIds).schedule);
        learner.recordAll(RoadSimulator(truth, random: rnd).drive(s.route).legs);
      }
      final learnedProfile = learner.buildProfile();
      var cold = 0.0, learned = 0.0;
      for (final seed in [900, 901, 902, 903, 904, 905]) {
        cold += modelEtaError(CongestionProfile(16), seed);
        learned += modelEtaError(learnedProfile, seed);
      }
      expect(learned, lessThan(0.6 * cold));
    });
  });
}
