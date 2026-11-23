// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:dart2wasm/class_info.dart';
import 'package:expect/expect.dart';
import 'package:kernel/ast.dart';

void main() {
  testImplementsChain();
  testPartiallyCoveredSubclassRange();
  testOverlappingAndDisjointRanges();
}

Class newClass(String name) => Class(name: name, fileUri: Uri.parse('test:'));

void testImplementsChain() {
  const length = 1000;
  final chain = [for (var i = 0; i < length; i++) newClass('C$i')];
  final subclassRanges = CountingRangeMap({
    for (var i = 0; i < length; i++) chain[i]: [Range(i, i)],
  });
  final ranges = computeConcreteClassIdRanges(
    chain,
    subclassRanges: subclassRanges,
    subclasses: {},
    implementors: {
      for (var i = 1; i < length; i++) chain[i - 1]: [chain[i]],
    },
  );

  for (var i = 0; i < length; i++) {
    Expect.listEquals([Range(i, length - 1)], ranges[chain[i]]!);
  }
  // Expanding each class's transitive implementors reads n(n + 1)/2
  // subclass ranges for this graph, although each result is one interval.
  Expect.isTrue(
    subclassRanges.reads <= 2 * length,
    'Read subclass ranges ${subclassRanges.reads} times for $length classes',
  );
}

void testPartiallyCoveredSubclassRange() {
  final parent = newClass('Parent');
  final child = newClass('Child');
  final implementor = newClass('Implementor');
  final ranges = computeConcreteClassIdRanges(
    [parent, child, implementor],
    subclassRanges: {
      parent: [Range(2, 3)],
      child: [Range(3, 3)],
      implementor: [Range(4, 4)],
    },
    subclasses: {
      parent: [child],
    },
    implementors: {
      child: [implementor],
    },
  );

  Expect.listEquals([Range(3, 4)], ranges[child]!);
  Expect.listEquals([Range(2, 4)], ranges[parent]!);
}

void testOverlappingAndDisjointRanges() {
  final a = newClass('A');
  final b = newClass('B');
  final c = newClass('C');
  final d = newClass('D');
  final e = newClass('E');
  final unused = newClass('Unused');
  final ranges = computeConcreteClassIdRanges(
    [a, b, c, d, e, unused],
    subclassRanges: {
      a: [Range(2, 2)],
      b: [Range(2, 2)],
      c: [Range(5, 6)],
      d: [Range(6, 6)],
      e: [Range(8, 8), Range(10, 11)],
    },
    subclasses: {
      a: [b],
      c: [d],
    },
    implementors: {
      a: [e],
      b: [c, e],
    },
  );

  Expect.listEquals([
    Range(2, 2),
    Range(5, 6),
    Range(8, 8),
    Range(10, 11),
  ], ranges[a]!);
  Expect.listEquals(ranges[a]!, ranges[b]!);
  Expect.listEquals([Range(5, 6)], ranges[c]!);
  Expect.listEquals([Range(6, 6)], ranges[d]!);
  Expect.listEquals([Range(8, 8), Range(10, 11)], ranges[e]!);
  Expect.isEmpty(ranges[unused]!);
}

class CountingRangeMap extends MapView<Class, List<Range>> {
  int reads = 0;

  CountingRangeMap(super.map);

  @override
  List<Range>? operator [](Object? key) {
    reads++;
    return super[key];
  }
}
