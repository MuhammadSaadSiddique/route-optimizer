import 'dart:math' as math;
import 'dart:typed_data';

import 'package:route_optimizer/route_optimizer.dart';
import 'package:test/test.dart';

void main() {
  final city = CityInstance.generate(stops: 150, seed: 5);
  final problem = city.problem;
  final planned = buildInitialRoute(problem, problem.stopIds).schedule;
  final rnd = math.Random(21);

  group('schedule', () {
    test('initial route visits every stop once and breaks no window', () {
      final ids = planned.route.sublist(1, planned.last);
      expect(ids.toSet().length, equals(150));
      expect(planned.violations, equals(0));
    });

    test('O(1) insertion check agrees with full re-simulation (5,000 random cases)', () {
      final extra = city.addStop(city.randomStop());
      var feasible = 0, infeasible = 0;
      for (var c = 0; c < 5000; c++) {
        final draft = city.randomStop();
        final e = hhmm(8, 0) + rnd.nextInt(9) * 1800;
        city.relocateStop(extra, draft.copyWith(earliest: e, latest: e + 1800 + rnd.nextInt(4) * 900));
        final p = rnd.nextInt(planned.last);
        final fast = planned.insertionShift(p, extra) != kInfeasible;
        final route = List<int>.of(planned.route)..insert(p + 1, extra);
        final brute = Schedule.compute(problem, route).feasible;
        expect(fast, equals(brute), reason: 'insert at $p');
        fast ? feasible++ : infeasible++;
      }
      // Both outcomes must be well covered for the test to mean anything.
      expect(feasible, greaterThan(500));
      expect(infeasible, greaterThan(500));
    });

    test('spliceCost matches full re-simulation for random moves (5,000 cases)', () {
      final r = planned.route;
      final buf = Int32List(r.length);
      var feasible = 0, infeasible = 0;
      for (var c = 0; c < 5000; c++) {
        // Random relocate of a segment, or a random 2-opt reversal.
        final i = 1 + rnd.nextInt(planned.last - 1);
        final len = 1 + rnd.nextInt(3);
        if (i + len - 1 >= planned.last) continue;
        late List<int> candidate;
        late int p, k, m;
        if (rnd.nextBool()) {
          final y = i + 2 + rnd.nextInt(20);
          if (y >= planned.last) continue;
          m = 0;
          for (var q = y; q > i - 1; q--) {
            buf[m++] = r[q];
          }
          p = i - 1;
          k = y + 1;
        } else {
          final j = (i - 30 + rnd.nextInt(61)).clamp(0, planned.last - 1);
          if (j >= i - 1 && j <= i + len - 1) continue;
          m = 0;
          if (j < i - 1) {
            for (var q = i; q < i + len; q++) {
              buf[m++] = r[q];
            }
            for (var q = j + 1; q < i; q++) {
              buf[m++] = r[q];
            }
            p = j;
            k = i + len;
          } else {
            for (var q = i + len; q <= j; q++) {
              buf[m++] = r[q];
            }
            for (var q = i; q < i + len; q++) {
              buf[m++] = r[q];
            }
            p = i - 1;
            k = j + 1;
          }
        }
        candidate = [...r.sublist(0, p + 1), ...buf.sublist(0, m), ...r.sublist(k)];
        final full = Schedule.compute(problem, candidate);
        final fast = planned.spliceCost(p, buf, m, k);
        if (full.feasible) {
          expect(fast, equals(full.cost));
          feasible++;
        } else {
          expect(fast, equals(-1));
          infeasible++;
        }
      }
      expect(feasible, greaterThan(1000));
      expect(infeasible, greaterThan(50));
    });
  });
}
