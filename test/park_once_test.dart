import 'package:route_optimizer/route_optimizer.dart';
import 'package:test/test.dart';

void main() {
  final city = CityInstance.generate(stops: 250, seed: 21);
  final p = city.problem;
  const settings = ParkOnceSettings();
  final groups = groupForParkOnce(p, settings: settings);

  group('Park Once', () {
    test('every stop is in exactly one group', () {
      final seen = [for (final g in groups) ...g.stops];
      expect(seen.length, equals(250));
      expect(seen.toSet().length, equals(250));
    });

    test('groups respect size and walking-distance limits', () {
      for (final g in groups) {
        expect(g.size, lessThanOrEqualTo(settings.maxGroupSize));
        final park = p.stops[g.parkAt];
        for (final d in g.stops) {
          final s = p.stops[d];
          final metres = ((s.x - park.x) * (s.x - park.x) + (s.y - park.y) * (s.y - park.y));
          expect(metres, lessThanOrEqualTo(settings.maxWalkMetres * settings.maxWalkMetres + 1e-6));
        }
      }
    });

    test('timed collections and slots keep their own van stop', () {
      for (final g in groups) {
        if (g.size > 1) {
          for (final d in g.stops) {
            expect(p.latest[d] - p.earliest[d], greaterThanOrEqualTo(settings.tightWindowSeconds));
          }
        }
      }
    });

    test('a planned Park Once round keeps every door inside its own window', () {
      final round = city.parkOnceRound(groups);
      final plan = planRound(round.problem, budget: const Duration(seconds: 30), maxIterations: 400).schedule;
      expect(plan.violations, equals(0));
      for (var k = 1; k < plan.last; k++) {
        final g = groups[plan.route[k] - 1];
        for (var i = 0; i < g.size; i++) {
          final doorStart = plan.start[k] + g.offsets[i];
          expect(doorStart, greaterThanOrEqualTo(p.earliest[g.stops[i]]));
          expect(doorStart, lessThanOrEqualTo(p.latest[g.stops[i]]));
        }
      }
    });

    test('saves time against stopping the van at every door (same cost model)', () {
      final everyDoor = groupForParkOnce(p, settings: settings.everyDoor);
      expect(everyDoor.length, equals(250));
      expect(groups.length, lessThan(220));
      final a =
          planRound(city.parkOnceRound(everyDoor).problem, budget: const Duration(seconds: 30), maxIterations: 400)
              .schedule;
      final b = planRound(city.parkOnceRound(groups).problem, budget: const Duration(seconds: 30), maxIterations: 400)
          .schedule;
      expect(b.finish, lessThan(a.finish - 20 * 60));
    });
  });
}
