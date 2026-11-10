/// A wall-clock time budget. Optimisers check it and return the best route
/// found so far, so the app always gets an answer within a known time.
class Deadline {
  Deadline(Duration budget)
      : _limitMicros = budget.inMicroseconds,
        _watch = Stopwatch()..start();

  /// A deadline that never expires.
  Deadline.none()
      : _limitMicros = -1,
        _watch = Stopwatch();

  final int _limitMicros;
  final Stopwatch _watch;

  bool get expired => _limitMicros >= 0 && _watch.elapsedMicroseconds >= _limitMicros;

  Duration get elapsed => _watch.elapsed;

  /// Fraction of the budget used, 0..1 (0 for [Deadline.none]).
  double get progress => _limitMicros <= 0 ? 0 : (_watch.elapsedMicroseconds / _limitMicros).clamp(0.0, 1.0);
}
