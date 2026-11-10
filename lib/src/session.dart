import 'dynamic_insertion.dart';
import 'model.dart';
import 'schedule.dart';

/// One version of the driver's route.
class RoutePlan {
  RoutePlan._(this.version, this.schedule, this.label);

  final int version;
  final Schedule schedule;
  final String label;

  List<int> get route => schedule.route;
}

/// What a proposed change would do, shown to the driver before they decide.
class Proposal {
  Proposal._(this.plan, this.added, this.removed, this.stopsReordered, this.finishDelta, this.maxStopDelay);

  final RoutePlan plan;
  final List<int> added, removed;
  final int stopsReordered;
  final int finishDelta;
  final int maxStopDelay;

  @override
  String toString() {
    final parts = <String>[
      if (added.isNotEmpty) '+${added.length} stop${added.length == 1 ? '' : 's'}',
      if (removed.isNotEmpty) '-${removed.length} stop${removed.length == 1 ? '' : 's'}',
      '$stopsReordered reordered',
      'finish ${finishDelta >= 0 ? '+' : '-'}${_mmss(finishDelta.abs())}',
      'worst delay ${_mmss(maxStopDelay)}',
    ];
    return parts.join(', ');
  }

  static String _mmss(int s) => '${s ~/ 60}m${(s % 60).toString().padLeft(2, '0')}s';
}

/// Driver-controlled route changes: the optimiser proposes, the driver
/// accepts or rejects, and any accepted change can be reverted.
///
/// Every version is an immutable [Schedule], so revert is instant and
/// exact. Nothing is recomputed.
class RouteSession {
  RouteSession(this.problem, Schedule initial, {String label = 'Planned'}) : _current = RoutePlan._(1, initial, label);

  final Problem problem;
  RoutePlan _current;
  final List<RoutePlan> _history = [];
  Proposal? _pending;
  int _nextVersion = 2;

  RoutePlan get current => _current;
  Proposal? get pending => _pending;
  bool get canRevert => _history.isNotEmpty;
  int get versions => _history.length + 1;

  /// Proposes [candidate] as the next route. Replaces any pending proposal.
  Proposal propose(Schedule candidate, String label) {
    final before = _current.route.toSet(), after = candidate.route.toSet();
    var maxDelay = 0;
    for (var q = 1; q < _current.schedule.last; q++) {
      final node = _current.route[q];
      final pos = candidate.positionOf(node);
      if (pos < 0) continue;
      final d = candidate.start[pos] - _current.schedule.start[q];
      if (d > maxDelay) maxDelay = d;
    }
    return _pending = Proposal._(
      RoutePlan._(_nextVersion++, candidate, label),
      after.difference(before).toList(),
      before.difference(after).toList(),
      stopsReordered(_current.route, candidate.route),
      candidate.finish - _current.schedule.finish,
      maxDelay,
    );
  }

  RoutePlan accept() {
    final p = _pending;
    if (p == null) throw StateError('No pending proposal.');
    _history.add(_current);
    _current = p.plan;
    _pending = null;
    return _current;
  }

  void reject() {
    if (_pending == null) throw StateError('No pending proposal.');
    _pending = null;
  }

  /// Returns to the previous accepted version.
  RoutePlan revert() {
    if (_history.isEmpty) throw StateError('Nothing to revert.');
    _pending = null;
    _current = _history.removeLast();
    return _current;
  }
}
