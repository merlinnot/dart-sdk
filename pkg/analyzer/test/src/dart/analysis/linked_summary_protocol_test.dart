// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:isolate';

import 'package:analyzer/src/dart/analysis/linked_summary_coordinator.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_protocol.dart';
import 'package:test/test.dart';

void main() {
  List<Object?> wireRequest(SendPort reply) => [
    '/root',
    <Object?>['/root/a.dart'],
    '/options',
    '/packages',
    <Object?, Object?>{'env': 'test'},
    true,
    <Object?, Object?>{'/root/b.dart': 'overlay'},
    <Object?>['/root/c.dart'],
    reply,
  ];

  test('version 4 preserves the reader request and reply port', () {
    var reply = ReceivePort();
    addTearDown(reply.close);
    var message = wireRequest(reply.sendPort);

    expect(LinkedSummaryCoordinator.protocolVersion, 4);
    var request = SummaryRequest.tryDecode(message)!;
    expect(request.scope.root, '/root');
    expect(request.scope.options, '/options');
    expect(request.scope.packages, '/packages');
    expect(request.scope.variables, {'env': 'test'});
    expect(request.paths, ['/root/a.dart']);
    expect(request.overlays, {'/root/b.dart': 'overlay'});
    expect(request.changedFiles, ['/root/c.dart']);
    expect(request.wantsProgress, isTrue);
    expect(request.reply, reply.sendPort);
    expect(request.toMessage(), message);
    expect(SummaryRequest.tryDecode([reply.sendPort]), isNull);
  });

  for (var (field, slot, invalid) in [
    ('paths element', 1, ['a.dart', null]),
    ('variable key', 4, {1: 'on'}),
    ('variable value', 4, {'env': false}),
    ('overlay key', 6, {1: 'content'}),
    ('overlay value', 6, {'a.dart': 0}),
    ('changedFiles element', 7, ['b.dart', 7]),
  ]) {
    test('decoding rejects an invalid $field', () {
      var reply = ReceivePort();
      addTearDown(reply.close);
      var message = wireRequest(reply.sendPort)..[slot] = invalid;

      expect(SummaryRequest.tryDecode(message), isNull);
    });
  }

  test(
    'scope identity depends on variable values and ignores insertion order',
    () {
      String key(Map<String, String> variables) =>
          SummaryAnalysisScope('/root', variables: variables).indexKey;
      var first = key({'a': '1', 'b': '2'});

      expect(key({'b': '2', 'a': '1'}), first);
      expect(key({'b': '1', 'a': '2'}), isNot(first));
    },
  );
}
