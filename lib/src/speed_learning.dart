import 'dart:math' as math;
import 'dart:typed_data';

import 'travel_time.dart';

/// One driven leg between two stops, as map-matched from GPS
/// (e.g. Meili traces snapped to the road graph, free-flow time from Valhalla).
class TravelObservation {
  const TravelObservation({
    required this.fromZone,
    required this.toZone,
    required this.departAt,
    required this.freeFlowSeconds,
    required this.observedSeconds,
  });

  final int fromZone, toZone;

  /// Departure time, seconds since midnight.
  final int departAt;

  final int freeFlowSeconds, observedSeconds;
}

/// Learns congestion (a speed factor per zone and 15-minute bucket) from
/// driven legs, and stays reliable where there is little or no data.
///
/// Each estimate shrinks towards the level below it:
///
///     this zone, this 15-minute bucket
///       -> this zone, the buckets either side   (fills gaps in sparse data)
///         -> whole fleet at this time            (time-of-day pattern from every zone)
///           -> 1.0                               (the base map's free-flow speeds)
///
/// A new area therefore gets the fleet's time-of-day pattern, and no data
/// at all gives free-flow speeds: never worse than the base map. Estimates
/// are ratios of sums (total free-flow time / total observed time), which is
/// what makes predicted travel times unbiased. Each leg is capped at 2.5x
/// what is currently expected there, so one GPS glitch or a long wait at
/// a red light cannot distort a zone, while real slowdowns are still learned.
///
/// The output is a [CongestionProfile]: zones x 96 floats that sync to the
/// phone as data, with no rebuild of offline map packages.
class SpeedProfileLearner {
  SpeedProfileLearner({required this.zones, this.priorMinutes = 5, this.minLegSeconds = 10})
      : _ff = Float64List(zones * _buckets),
        _obs = Float64List(zones * _buckets);

  final int zones;

  /// Weight of the prior, in minutes of observed driving.
  final double priorMinutes;

  /// Legs shorter than this (free flow) are too noisy to learn from.
  final int minLegSeconds;

  static const int _buckets = CongestionProfile.buckets;
  static const int _bs = CongestionProfile.bucketSeconds;

  final Float64List _ff, _obs;
  final Float64List _fleetFf = Float64List(_buckets), _fleetObs = Float64List(_buckets);

  int _count = 0;

  /// Number of legs learned from.
  int get observations => _count;

  void record(TravelObservation o) {
    if (o.freeFlowSeconds < minLegSeconds || o.observedSeconds <= 0) return;
    final ff = o.freeFlowSeconds.toDouble();
    final b = (o.departAt ~/ _bs).clamp(0, _buckets - 1);
    // Cap each leg relative to what is currently expected there, so one
    // glitch (a stop at a red light, a GPS jump) moves the estimate only a little.
    final expected = ff / (o.fromZone == o.toZone ? estimate(o.fromZone, b) : fleetEstimate(b));
    final obs = o.observedSeconds.toDouble().clamp(math.max(ff / 1.5, expected / 2.5), expected * 2.5);
    if (o.fromZone == o.toZone) {
      _ff[o.fromZone * _buckets + b] += ff;
      _obs[o.fromZone * _buckets + b] += obs;
    } else {
      for (final z in [o.fromZone, o.toZone]) {
        _ff[z * _buckets + b] += ff / 2;
        _obs[z * _buckets + b] += obs / 2;
      }
    }
    _fleetFf[b] += ff;
    _fleetObs[b] += obs;
    _count++;
  }

  void recordAll(Iterable<TravelObservation> legs) {
    for (final o in legs) {
      record(o);
    }
  }

  double _shrink(double ff, double obs, double prior) {
    final k = priorMinutes * 60;
    return (ff + prior * k) / (obs + k);
  }

  (double, double) _neighbours(Float64List ff, Float64List obs, int base, int b) {
    var f = 0.0, o = 0.0;
    if (b > 0) {
      f += ff[base + b - 1];
      o += obs[base + b - 1];
    }
    if (b < _buckets - 1) {
      f += ff[base + b + 1];
      o += obs[base + b + 1];
    }
    return (f, o);
  }

  /// Own data first; neighbouring buckets only fill in where data is thin,
  /// so sharp edges (the school run starting at 08:15) are not blurred.
  double _layered(Float64List ff, Float64List obs, int base, int b, double prior) {
    final (nf, no) = _neighbours(ff, obs, base, b);
    final nearby = _shrink(nf, no, prior);
    return _shrink(ff[base + b], obs[base + b], nearby);
  }

  /// Fleet-wide speed factor for a time bucket.
  double fleetEstimate(int bucket) => _layered(_fleetFf, _fleetObs, 0, bucket, 1.0);

  /// Speed factor for [zone] at [bucket].
  double estimate(int zone, int bucket) => _layered(_ff, _obs, zone * _buckets, bucket, fleetEstimate(bucket));

  /// 0 = pure fallback, approaching 1 = driven by this zone's own data.
  double confidence(int zone, int bucket) {
    final o = _obs[zone * _buckets + bucket];
    return o / (o + priorMinutes * 60);
  }

  /// The learned profile, ready to plug into [TimeDependentTravel].
  CongestionProfile buildProfile() {
    final p = CongestionProfile(zones);
    if (_count == 0) return p;
    for (var z = 0; z < zones; z++) {
      for (var b = 0; b < _buckets; b++) {
        p.setSpeed(z, b, estimate(z, b).clamp(0.1, 1.5));
      }
    }
    return p;
  }
}
