import 'dart:math' as math;

import 'package:route_optimizer/route_optimizer.dart';
import 'package:test/test.dart';

/// The naive model many implementations use: free-flow time divided by the
/// speed factor of the *departure* bucket. Kept here only to show why it is
/// not used.
int naiveArrive(TimeDependentTravel t, int from, int to, int depart) {
  final b = depart ~/ CongestionProfile.bucketSeconds;
  final v = 0.5 * (t.profile.speed(t.zoneOf[from], b) + t.profile.speed(t.zoneOf[to], b));
  return depart + (t.matrix.time(from, to) / v).ceil();
}

void main() {
  final city = CityInstance.generate(stops: 120, seed: 3);
  final travel = city.problem.travel;
  final rnd = math.Random(11);

  group('time-dependent travel (IGP model)', () {
    test('is FIFO: leaving later never arrives earlier', () {
      for (var c = 0; c < 20000; c++) {
        final i = rnd.nextInt(121), j = rnd.nextInt(121);
        final t = hhmm(7, 0) + rnd.nextInt(12 * 3600);
        expect(travel.arrive(i, j, t + 1), greaterThanOrEqualTo(travel.arrive(i, j, t)));
      }
    });

    test('latestDeparture is the exact inverse of arrive', () {
      for (var c = 0; c < 20000; c++) {
        final i = rnd.nextInt(121), j = rnd.nextInt(121);
        final a = hhmm(8, 0) + rnd.nextInt(10 * 3600);
        final d = travel.latestDeparture(i, j, a);
        expect(travel.arrive(i, j, d), lessThanOrEqualTo(a), reason: 'departing at $d must arrive by $a');
        if (travel.freeFlow(i, j) > 0) {
          expect(travel.arrive(i, j, d + 1), greaterThan(a), reason: 'one second later must be too late');
        }
      }
    });

    test('school-run congestion slows trips inside school zones', () {
      final inSchoolZone = [
        for (var i = 1; i < city.problem.size; i++)
          if (CityInstance.schoolZones.contains(city.problem.stops[i].zone)) i,
      ];
      final a = inSchoolZone[0], b = inSchoolZone[1];
      final early = travel.arrive(a, b, hhmm(7, 50)) - hhmm(7, 50);
      final schoolRun = travel.arrive(a, b, hhmm(8, 30)) - hhmm(8, 30);
      expect(schoolRun, greaterThan(early));
    });

    test('the naive step model breaks FIFO (why IGP is used)', () {
      var violations = 0;
      for (var i = 1; i < 121 && violations == 0; i++) {
        for (var j = 1; j < 121; j++) {
          // Leave just before / at the end of the school run.
          final before = naiveArrive(travel, i, j, hhmm(9, 15) - 1);
          final after = naiveArrive(travel, i, j, hhmm(9, 15));
          if (after < before) violations++;
        }
      }
      expect(violations, greaterThan(0));
    });
  });

  group('travel matrix', () {
    test('a new stop adds one row and column without touching the rest', () {
      final c = CityInstance.generate(stops: 50, seed: 9);
      final m = c.problem.travel.matrix;
      final before = [
        for (var i = 0; i < 51; i++)
          for (var j = 0; j < 51; j++) m.time(i, j)
      ];
      final id = c.addStop(c.randomStop());
      expect(id, equals(51));
      final after = [
        for (var i = 0; i < 51; i++)
          for (var j = 0; j < 51; j++) m.time(i, j)
      ];
      expect(after, equals(before));
      expect(m.time(id, 0), greaterThan(0));
      expect(m.time(0, id), greaterThan(0));
    });

    test('500-stop travel-time table fits in about half a megabyte', () {
      final m = TravelMatrix(501);
      expect(m.timeTableBytes, lessThan(520 * 1024));
    });
  });
}
