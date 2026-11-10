import 'dart:typed_data';

import 'model.dart';

/// The K nearest stops of every stop (by free-flow time, either direction).
///
/// Local search only tries moves that create an arc to a near neighbour.
/// That cuts each sweep from O(n^2) candidate moves to O(n * K), which is
/// what makes 500-stop rounds fast on a phone.
class NeighbourLists {
  NeighbourLists(this.problem, {this.k = 16})
      : _ids = Int32List(problem.capacity * k),
        _keys = Int32List(problem.capacity * k),
        _count = Int32List(problem.capacity) {
    for (var i = 1; i < problem.size; i++) {
      _rebuild(i);
    }
  }

  final Problem problem;
  final int k;
  final Int32List _ids, _keys, _count;

  int countOf(int node) => _count[node];

  int neighbour(int node, int index) => _ids[node * k + index];

  int _key(int a, int b) {
    final tm = problem.travel;
    final x = tm.freeFlow(a, b), y = tm.freeFlow(b, a);
    return x < y ? x : y;
  }

  void _rebuild(int i) {
    _count[i] = 0;
    for (var j = 1; j < problem.size; j++) {
      if (j != i) _offer(i, j, _key(i, j));
    }
  }

  /// Keeps node i's list sorted, inserting j if it is among the k nearest.
  void _offer(int i, int j, int key) {
    final base = i * k;
    var c = _count[i];
    if (c == k && key >= _keys[base + c - 1]) return;
    for (var t = 0; t < c; t++) {
      if (_ids[base + t] == j) return;
    }
    var pos = c < k ? c : k - 1;
    if (c < k) _count[i] = ++c;
    while (pos > 0 && _keys[base + pos - 1] > key) {
      _keys[base + pos] = _keys[base + pos - 1];
      _ids[base + pos] = _ids[base + pos - 1];
      pos--;
    }
    _keys[base + pos] = key;
    _ids[base + pos] = j;
  }

  /// Registers a stop added mid-round: builds its list and offers it to
  /// every other stop. O(n * k).
  void addNode(int node) {
    _rebuild(node);
    for (var j = 1; j < problem.size; j++) {
      if (j != node) _offer(j, node, _key(j, node));
    }
  }
}
