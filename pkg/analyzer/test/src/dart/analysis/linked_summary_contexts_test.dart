// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_contexts.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'disk edits refresh all scopes and option overlays affect only their owner',
    () async {
      var directory = await Directory.systemTemp.createTemp(
        'producer-contexts-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var reply = ReceivePort();
      addTearDown(reply.close);
      var contexts = SummaryProducerContexts(
        File(Platform.resolvedExecutable).parent.parent.path,
        MemoryByteStore(),
      );
      var entry = File('${directory.path}/entry.dart')..writeAsStringSync('');
      File('${directory.path}/analysis_options.yaml')
          .writeAsStringSync('include: shared.yaml');
      var shared = File('${directory.path}/shared.yaml')
        ..writeAsStringSync('analyzer: {}');
      var latest = <String, AnalysisContextCollectionImpl>{};
      addTearDown(() async {
        for (var collection in latest.values) {
          await collection.dispose();
        }
      });

      Future<AnalysisContextCollectionImpl> prepare(
        String mode, {
        List<String> changed = const [],
        Map<String, String> overlays = const {},
      }) async => latest[mode] = (await contexts.prepare(
        SummaryRequest(
          scope: SummaryAnalysisScope(
            directory.path,
            variables: {'mode': mode},
          ),
          paths: [entry.path],
          overlays: overlays,
          changedFiles: changed,
          reply: reply.sendPort,
          wantsProgress: false,
        ),
      )).collection;

      bool includesEntry(AnalysisContextCollectionImpl collection) => collection
          .contexts
          .any((context) => context.contextRoot.isAnalyzed(entry.path));

      var first = await prepare('first');
      var second = await prepare('second');
      expect(includesEntry(first), isTrue);
      expect(second, isNot(same(first)));
      expect(await prepare('first', changed: [entry.path]), same(first));

      shared.writeAsStringSync('analyzer:\n  exclude: [entry.dart]');
      expect(
        includesEntry(await prepare('first', changed: [shared.path])),
        isFalse,
      );
      var refreshedSecond = await prepare('second');
      expect(refreshedSecond, isNot(same(second)));
      expect(includesEntry(refreshedSecond), isFalse);

      expect(
        includesEntry(
          await prepare('first', overlays: {shared.path: 'analyzer: {}'}),
        ),
        isTrue,
      );
      expect(await prepare('second'), same(refreshedSecond));
      expect(includesEntry(await prepare('first')), isFalse);
      expect(contexts.length, 2);
    },
  );
}
