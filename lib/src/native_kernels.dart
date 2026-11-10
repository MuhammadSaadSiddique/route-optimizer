import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'travel_time.dart';

typedef _AbiC = Int32 Function();
typedef _AbiDart = int Function();
typedef _AllocC = Pointer<Void> Function(Int64);
typedef _AllocDart = Pointer<Void> Function(int);
typedef _ArrivalsC = Void Function(Pointer<Uint16>, Int32, Pointer<Uint8>, Pointer<Float>, Int32, Int32, Pointer<Int32>,
    Pointer<Int32>, Pointer<Int32>, Int32, Pointer<Int32>);
typedef _ArrivalsDart = void Function(Pointer<Uint16>, int, Pointer<Uint8>, Pointer<Float>, int, int, Pointer<Int32>,
    Pointer<Int32>, Pointer<Int32>, int, Pointer<Int32>);
typedef _MatrixC = Void Function(
    Pointer<Uint16>, Int32, Pointer<Uint8>, Pointer<Float>, Int32, Int32, Int32, Int32, Pointer<Int32>);
typedef _MatrixDart = void Function(
    Pointer<Uint16>, int, Pointer<Uint8>, Pointer<Float>, int, int, int, int, Pointer<Int32>);

/// A travel matrix whose tables live in native memory.
///
/// [matrix] is an ordinary [TravelMatrix] for the Dart optimiser, backed by
/// the same bytes that native code (the kernels here, or an embedded
/// Valhalla filling it from `sources_to_targets`) reads and writes.
/// Nothing is copied in either direction.
final class NativeTravelMatrix {
  NativeTravelMatrix._(this.capacity, this.timePtr, this.distPtr, this.matrix);

  final int capacity;
  final Pointer<Uint16> timePtr;
  final Pointer<Int32> distPtr;
  final TravelMatrix matrix;
}

/// Native copies of the small per-zone tables (zones of nodes, speed factors).
/// Kilobytes, so they are copied on [sync]; the big matrix is shared.
final class NativeTraffic {
  NativeTraffic._(this.matrix, this._zonesPtr, this._zones, this._speedsPtr, this._speeds);

  final NativeTravelMatrix matrix;
  final Pointer<Uint8> _zonesPtr;
  final Uint8List _zones;
  final Pointer<Float> _speedsPtr;
  final Float32List _speeds;

  /// Copies the current zones and congestion profile (e.g. after the speed
  /// learner publishes a new profile).
  void sync(TimeDependentTravel travel) {
    _zones.setAll(0, travel.zoneOf);
    _speeds.setAll(0, travel.profile.table);
  }
}

/// A reusable batch of legs in native memory. Fill [from], [to] and
/// [depart] from Dart, call [NativeKernels.arrivals], read [arrival].
final class NativeLegBatch {
  NativeLegBatch._(this.capacity, this._ptrs, this.from, this.to, this.depart, this.arrival);

  final int capacity;
  final List<Pointer<Int32>> _ptrs;
  final Int32List from, to, depart, arrival;
}

/// C++ kernels called through `dart:ffi` (see `native/route_kernels.cpp`).
///
/// * Leaf calls (`isLeaf: true`): no safepoint transition, so a call costs
///   nanoseconds.
/// * Work is batched: one call per batch of legs or per whole matrix, never
///   one call per arc.
/// * Large buffers are allocated natively and exposed to Dart as typed lists
///   with a native finalizer, so they are freed automatically and never
///   copied.
final class NativeKernels {
  NativeKernels._(DynamicLibrary lib)
      : _alloc = lib.lookupFunction<_AllocC, _AllocDart>('rk_alloc', isLeaf: true),
        _free = lib.lookup<NativeFinalizerFunction>('rk_free'),
        _arrivals = lib.lookupFunction<_ArrivalsC, _ArrivalsDart>('rk_td_arrivals', isLeaf: true),
        _matrix = lib.lookupFunction<_MatrixC, _MatrixDart>('rk_td_matrix', isLeaf: true) {
    final abi = lib.lookupFunction<_AbiC, _AbiDart>('rk_abi_version')();
    if (abi != 1) throw StateError('route_kernels ABI $abi, expected 1. Rebuild the native library.');
  }

  final _AllocDart _alloc;
  final Pointer<NativeFinalizerFunction> _free;
  final _ArrivalsDart _arrivals;
  final _MatrixDart _matrix;

  /// Where [tryLoad] looks for the library, in order.
  static List<String> candidatePaths() {
    final name = Platform.isWindows
        ? 'route_kernels.dll'
        : Platform.isMacOS
            ? 'libroute_kernels.dylib'
            : 'libroute_kernels.so';
    return [
      if (Platform.environment['ROUTE_KERNELS_LIB'] case final env?) env,
      'build/$name',
      'build/Release/$name',
      name,
    ];
  }

  /// Loads the native library, or returns null if it has not been built
  /// (everything else in the package works without it).
  static NativeKernels? tryLoad({String? path}) {
    for (final p in [if (path != null) path, ...candidatePaths()]) {
      if (!File(p).existsSync()) continue;
      return NativeKernels._(DynamicLibrary.open(p));
    }
    return null;
  }

  Pointer<T> _allocate<T extends NativeType>(int bytes) {
    final p = _alloc(bytes);
    if (p == nullptr) throw StateError('Native allocation of $bytes bytes failed.');
    return p.cast<T>();
  }

  /// Allocates a [TravelMatrix] in native memory.
  NativeTravelMatrix allocateMatrix(int capacity) {
    final cells = capacity * capacity;
    final tp = _allocate<Uint16>(cells * 2);
    final dp = _allocate<Int32>(cells * 4);
    final times = tp.asTypedList(cells, finalizer: _free, token: tp.cast());
    final dist = dp.asTypedList(cells, finalizer: _free, token: dp.cast());
    return NativeTravelMatrix._(capacity, tp, dp, TravelMatrix.view(capacity, times, dist));
  }

  /// Native zone and speed tables for [matrix], filled from [travel].
  NativeTraffic traffic(NativeTravelMatrix matrix, TimeDependentTravel travel) {
    final zp = _allocate<Uint8>(matrix.capacity);
    final cells = travel.profile.zones * CongestionProfile.buckets;
    final sp = _allocate<Float>(cells * 4);
    final t = NativeTraffic._(
      matrix,
      zp,
      zp.asTypedList(matrix.capacity, finalizer: _free, token: zp.cast()),
      sp,
      sp.asTypedList(cells, finalizer: _free, token: sp.cast()),
    )..sync(travel);
    return t;
  }

  NativeLegBatch legBatch(int capacity) {
    final ptrs = [for (var i = 0; i < 4; i++) _allocate<Int32>(capacity * 4)];
    Int32List view(Pointer<Int32> p) => p.asTypedList(capacity, finalizer: _free, token: p.cast());
    return NativeLegBatch._(capacity, ptrs, view(ptrs[0]), view(ptrs[1]), view(ptrs[2]), view(ptrs[3]));
  }

  /// Arrival times for the first [count] legs of [batch], in one call.
  void arrivals(NativeTraffic traffic, NativeLegBatch batch, int count) {
    if (count > batch.capacity) throw RangeError.range(count, 0, batch.capacity, 'count');
    final m = traffic.matrix;
    _arrivals(m.timePtr, m.capacity, traffic._zonesPtr, traffic._speedsPtr, CongestionProfile.buckets,
        CongestionProfile.bucketSeconds, batch._ptrs[0], batch._ptrs[1], batch._ptrs[2], count, batch._ptrs[3]);
  }

  /// Travel time of every arc between the first [n] nodes when leaving at
  /// [depart], written row-major into [out] (a native buffer from [intBuffer]).
  void matrixSnapshot(NativeTraffic traffic, int n, int depart, (Pointer<Int32>, Int32List) out) {
    if (out.$2.length < n * n) throw ArgumentError('Output buffer too small.');
    final m = traffic.matrix;
    _matrix(m.timePtr, m.capacity, traffic._zonesPtr, traffic._speedsPtr, CongestionProfile.buckets,
        CongestionProfile.bucketSeconds, n, depart, out.$1);
  }

  /// A native int32 buffer and its Dart view.
  (Pointer<Int32>, Int32List) intBuffer(int length) {
    final p = _allocate<Int32>(length * 4);
    return (p, p.asTypedList(length, finalizer: _free, token: p.cast()));
  }
}
