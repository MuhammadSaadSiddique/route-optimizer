import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:route_optimizer/native.dart';
import 'package:route_optimizer/route_optimizer.dart';
import 'package:test/test.dart';

void main() {
  final kernels = NativeKernels.tryLoad();
  final skip = kernels == null ? 'native library not built: run tool/build_native.sh' : false;

  group('C++ kernels via dart:ffi', () {
    late NativeTravelMatrix nm;
    late CityInstance city;
    late NativeTraffic traffic;
    if (kernels != null) {
      city = CityInstance.generate(
          stops: 300, seed: 13, matrixFactory: (cap) => (nm = kernels.allocateMatrix(cap)).matrix);
      traffic = kernels.traffic(nm, city.problem.travel);
    }

    test('arrivals are bit-identical to the Dart model (200,000 random legs)', () {
      final travel = city.problem.travel;
      final rnd = math.Random(4);
      const n = 200000;
      final batch = kernels!.legBatch(n);
      for (var i = 0; i < n; i++) {
        batch.from[i] = rnd.nextInt(301);
        batch.to[i] = rnd.nextInt(301);
        batch.depart[i] = hhmm(6, 0) + rnd.nextInt(14 * 3600);
      }
      kernels.arrivals(traffic, batch, n);
      var mismatches = 0;
      for (var i = 0; i < n; i++) {
        if (travel.arrive(batch.from[i], batch.to[i], batch.depart[i]) != batch.arrival[i]) mismatches++;
      }
      expect(mismatches, equals(0));
    }, skip: skip);

    test('a full time-dependent matrix snapshot matches Dart', () {
      final travel = city.problem.travel;
      const n = 301, depart = 8 * 3600 + 40 * 60;
      final out = kernels!.intBuffer(n * n);
      kernels.matrixSnapshot(traffic, n, depart, out);
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
          expect(out.$2[i * n + j], equals(travel.arrive(i, j, depart) - depart));
        }
      }
    }, skip: skip);

    test('the matrix is shared memory: Dart writes are seen by C++ without copying', () {
      final id = city.addStop(city.randomStop()); // written through the Dart view
      final batch = kernels!.legBatch(1);
      batch.from[0] = 0;
      batch.to[0] = id;
      batch.depart[0] = hhmm(10, 0);
      kernels.arrivals(traffic..sync(city.problem.travel), batch, 1); // sync copies zones only
      expect(batch.arrival[0], equals(city.problem.travel.arrive(0, id, hhmm(10, 0))));
      expect(nm.timePtr.asTypedList(nm.capacity * nm.capacity)[id], equals(city.problem.travel.freeFlow(0, id)));
    }, skip: skip);

    test('a newly learned congestion profile is picked up after sync', () {
      final learned = CongestionProfile(16)..slowDownEverywhere(hhmm(9, 0), hhmm(10, 0), 0.6);
      final travel = city.problem.travel.withProfile(learned);
      traffic.sync(travel);
      final batch = kernels!.legBatch(100);
      for (var i = 0; i < 100; i++) {
        batch.from[i] = i + 1;
        batch.to[i] = 200 - i;
        batch.depart[i] = hhmm(9, 10);
      }
      kernels.arrivals(traffic, batch, 100);
      final expected = Int32List.fromList([for (var i = 0; i < 100; i++) travel.arrive(i + 1, 200 - i, hhmm(9, 10))]);
      expect(batch.arrival.toList(), equals(expected.toList()));
      traffic.sync(city.problem.travel);
    }, skip: skip);
  });
}
