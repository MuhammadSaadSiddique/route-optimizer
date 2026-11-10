import 'model.dart';

class _Stat {
  int n = 0;
  double sum = 0;
}

/// Learns how long each driver takes per address type, without failing on
/// new drivers or new areas (cold start).
///
/// Estimates shrink towards the next level up:
///   driver  -> fleet (same address type) -> default
/// using `(n * mean + strength * prior) / (n + strength)`. A new driver
/// gets the fleet value, and their own pace takes over as deliveries come
/// in. Observations far from the current estimate (a long chat, a missed
/// scan) are clamped so one outlier cannot skew the plan.
class ServiceTimeModel {
  ServiceTimeModel({this.priorStrength = 8, Map<AddressType, double>? defaults})
      : defaults = defaults ??
            const {
              AddressType.house: 45,
              AddressType.flat: 110,
              AddressType.business: 70,
              AddressType.depot: 0,
            };

  /// How many observations the prior is worth.
  final double priorStrength;
  final Map<AddressType, double> defaults;

  final Map<AddressType, _Stat> _fleet = {};
  final Map<String, _Stat> _driver = {};

  static String _key(String driver, AddressType t) => '$driver/${t.name}';

  double _shrink(_Stat? s, double prior) {
    if (s == null || s.n == 0) return prior;
    return (s.sum + priorStrength * prior) / (s.n + priorStrength);
  }

  double fleetEstimate(AddressType type) => _shrink(_fleet[type], defaults[type] ?? 60);

  /// Expected service seconds for [driver] at an address of [type].
  double estimate(String driver, AddressType type) => _shrink(_driver[_key(driver, type)], fleetEstimate(type));

  int observations(String driver, AddressType type) => _driver[_key(driver, type)]?.n ?? 0;

  /// Records an observed service time (arrival scan to departure).
  void record(String driver, AddressType type, double seconds) {
    final current = estimate(driver, type);
    final clamped = seconds.clamp(current / 4, current * 4).toDouble();
    (_driver[_key(driver, type)] ??= _Stat())
      ..n += 1
      ..sum += clamped;
    (_fleet[type] ??= _Stat())
      ..n += 1
      ..sum += clamped;
  }
}
