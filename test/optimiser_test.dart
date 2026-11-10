import 'dart:math' as math;

import 'package:route_optimizer/route_optimizer.dart';
import 'package:test/test.dart';

void expectValidRound(Schedule s, Problem p, int stops) {
  final inner = s.route.sublist(1, s.last);
  expect(inner.length, equals(stops));
  expect(inner.toSet().length, equals(stops), reason: 'no stop visited twice');
  expect(inner.contains(0), isFalse);
  expect(s.violations, equals(0), reason: 'no time window broken');
}

void main() {
  group('local search', () {
    final p = CityInstance.generate(stops: 200, seed: 8).problem;
    final nb = NeighbourLists(p);
    final initial = buildInitialRoute(p, p.stopIds).schedule;

    test('never breaks a window and never makes the route worse', () {
      final ls = LocalSearch(p, nb);
      final s = ls.run(initial);
      expectValidRound(s, p, 200);
      expect(s.cost, lessThan(initial.cost));
      expect(ls.stats.movesApplied, greaterThan(0));
    });

    test('screens most candidates in O(1) before any exact check', () {
      final ls = LocalSearch(p, nb)..run(initial);
      expect(ls.stats.exactChecks * 5, lessThan(ls.stats.candidates));
    });

    test('respects locked positions (stops already driven)', () {
      final ls = LocalSearch(p, nb, lockedPos: 80);
      final s = ls.run(initial);
      expect(s.route.sublist(0, 81), equals(initial.route.sublist(0, 81)));
      expectValidRound(s, p, 200);
    });
  });

  group('full planner', () {
    test('with an iteration cap the plan is fully reproducible', () {
      final p = CityInstance.generate(stops: 200, seed: 31).problem;
      List<int> plan() => planRound(p, budget: const Duration(seconds: 30), maxIterations: 300).schedule.route;
      expect(plan(), equals(plan()));
    });

    test('finishes within its time budget with a valid round', () {
      final p = CityInstance.generate(stops: 300, seed: 2).problem;
      final watch = Stopwatch()..start();
      final r = planRound(p, budget: const Duration(milliseconds: 800));
      expect(watch.elapsedMilliseconds, lessThan(1500));
      expect(r.unassigned, isEmpty);
      expectValidRound(r.schedule, p, 300);
      expect(r.schedule.cost, lessThan(r.stages.first.$3.cost));
    });

    test('a plan that ignores congestion breaks windows on the real road; the aware plan does not', () {
      final p = CityInstance.generate(stops: 300, seed: 3).problem;
      final blind = p.withTravel(p.travel.withProfile(CongestionProfile(16)));
      final aware = planRound(p, budget: const Duration(seconds: 30), maxIterations: 400).schedule;
      final blindPlan = planRound(blind, budget: const Duration(seconds: 30), maxIterations: 400).schedule;
      final replayed = Schedule.compute(p, blindPlan.route); // what really happens on the road
      expect(aware.violations, equals(0));
      expect(replayed.violations, greaterThan(0));
      expect(replayed.finish - blindPlan.finish, greaterThan(5 * 60), reason: 'blind ETAs are optimistic');
    });
  });

  group('safety margin', () {
    test('planning with a 10-minute deadline buffer leaves 10 minutes before every deadline', () {
      final p = CityInstance.generate(stops: 200, seed: 10).problem;
      final planned =
          planRound(p.withDeadlineBuffer(600), budget: const Duration(seconds: 30), maxIterations: 400).schedule;
      final real = Schedule.compute(p, planned.route);
      expect(real.violations, equals(0));
      for (var k = 1; k < real.last; k++) {
        final node = real.route[k];
        if (p.latest[node] < p.shiftEnd && p.latest[node] - p.earliest[node] > 600) {
          expect(p.latest[node] - real.start[k], greaterThanOrEqualTo(600));
        }
      }
    });
  });

  group('dynamic insertion', () {
    final city = CityInstance.generate(stops: 250, seed: 6);
    final p = city.problem;
    final nb = NeighbourLists(p);
    // Planned with the recommended 10-minute safety margin, run against the real windows.
    final planned =
        planRound(p.withDeadlineBuffer(600), budget: const Duration(seconds: 30), maxIterations: 400, neighbours: nb);
    final plan = Schedule.compute(p, planned.schedule.route);
    final now = hhmm(12, 0);
    var cur = 0;
    while (plan.departure[cur + 1] <= now) {
      cur++;
    }

    test('inserts a timed collection without touching driven stops', () {
      final id = city.addStop(city.randomStop(kind: StopKind.collection, earliest: now + 3600, latest: now + 5400));
      nb.addNode(id);
      final r = DynamicInserter(p, nb).insert(plan, cur, id);
      expect(r.feasible, isTrue);
      final s = r.schedule!;
      expect(s.route.sublist(0, cur + 1), equals(plan.route.sublist(0, cur + 1)));
      final pos = s.positionOf(id);
      expect(pos, greaterThan(cur));
      expect(s.start[pos], greaterThanOrEqualTo(now + 3600));
      expect(s.start[pos], lessThanOrEqualTo(now + 5400));
      expect(s.violations, equals(0));
    });

    test('reports why a stop cannot be served', () {
      final id = city.addStop(city.randomStop(kind: StopKind.collection, earliest: now - 3600, latest: now - 1800));
      nb.addNode(id);
      final r = DynamicInserter(p, nb).insert(plan, cur, id);
      expect(r.feasible, isFalse);
      expect(r.reason, isNotNull);
    });

    test('pure insertion reorders no existing stops', () {
      final id = city.addStop(city.randomStop());
      nb.addNode(id);
      final r = DynamicInserter(p, nb).insert(plan, cur, id, repair: false);
      expect(r.stopsReordered, equals(0));
    });
  });

  group('driver control', () {
    final p = CityInstance.generate(stops: 60, seed: 12).problem;
    final s1 = buildInitialRoute(p, p.stopIds).schedule;
    final s2 = LocalSearch(p, NeighbourLists(p)).run(s1);

    test('propose -> reject keeps the current route', () {
      final session = RouteSession(p, s1);
      session.propose(s2, 'Optimised');
      session.reject();
      expect(session.current.route, equals(s1.route));
      expect(session.pending, isNull);
    });

    test('propose -> accept -> revert restores the exact previous route', () {
      final session = RouteSession(p, s1);
      final proposal = session.propose(s2, 'Optimised');
      expect(proposal.finishDelta, lessThanOrEqualTo(0));
      session.accept();
      expect(session.current.route, equals(s2.route));
      session.revert();
      expect(session.current.route, equals(s1.route));
      expect(session.canRevert, isFalse);
    });
  });

  group('service-time learning (cold start)', () {
    test('a new driver starts on the fleet estimate, then becomes personal', () {
      final m = ServiceTimeModel();
      final rnd = math.Random(1);
      for (var i = 0; i < 500; i++) {
        m.record('fleet-${i % 20}', AddressType.flat, 120 + rnd.nextDouble() * 20 - 10);
      }
      final fleet = m.estimate('new-driver', AddressType.flat);
      expect(fleet, closeTo(120, 5));
      for (var i = 0; i < 60; i++) {
        m.record('new-driver', AddressType.flat, 80 + rnd.nextDouble() * 10 - 5);
      }
      expect(m.estimate('new-driver', AddressType.flat), closeTo(85, 6));
    });

    test('one outlier cannot skew the estimate', () {
      final m = ServiceTimeModel();
      for (var i = 0; i < 30; i++) {
        m.record('d', AddressType.house, 40);
      }
      final before = m.estimate('d', AddressType.house);
      m.record('d', AddressType.house, 3600); // e.g. a forgotten scan
      expect(m.estimate('d', AddressType.house) - before, lessThan(10));
    });
  });
}
