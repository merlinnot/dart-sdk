// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_contexts.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_coordinator.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_protocol.dart';
import 'package:test/test.dart';

void main() {
  for (var explicit in [false, true]) {
    test(
      'replacement driver preserves ${explicit ? "explicit" : "discovered"} options',
      () async {
        var directory = Directory.systemTemp.createTempSync('summary-driver-');
        var sdk = File(Platform.resolvedExecutable).parent.parent.path;
        var nested = File.fromUri(directory.uri.resolve('nested/entry.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('class Entry {}');
        var rootOptions = File.fromUri(
          directory.uri.resolve('analysis_options.yaml'),
        )..writeAsStringSync('analyzer: {}');
        var nestedOptions = File.fromUri(
          nested.parent.uri.resolve('analysis_options.yaml'),
        )..writeAsStringSync('analyzer:\n  language:\n    strict-casts: true');
        var packages =
            File.fromUri(
                directory.uri.resolve('.dart_tool/package_config.json'),
              )
              ..createSync(recursive: true)
              ..writeAsStringSync('{"configVersion":2,"packages":[]}');
        var contexts = SummaryProducerContexts(sdk, MemoryByteStore());
        var inbox = ReceivePort();
        var client = LinkedSummaryCoordinator(inbox.sendPort);
        var producerOptions = <bool>[];
        var requests = <SummaryRequest>[];
        bool strictCasts(AnalysisContextCollectionImpl collection) {
          var context = collection.contextFor(nested.path);
          return context.driver
              .getAnalysisOptionsForFile(
                context.resourceProvider.getFile(nested.path),
              )
              .strictCasts;
        }

        // Consume the driver's actual wire messages in order. Replying with a
        // cache miss also exercises disposal after a driver has fallen back.
        Future<void> serve() async {
          await for (var message in inbox) {
            switch (message) {
              case ['invalidateRoot', String root]:
                await contexts.invalidateRoot(root);
              case List<Object?> values when values.length > 1:
                var request = SummaryRequest.tryDecode(values)!;
                requests.add(request);
                producerOptions.add(
                  strictCasts((await contexts.prepare(request)).collection),
                );
                request.reply.send(null);
            }
          }
        }

        var serving = serve();
        Future<bool> runDriver() async {
          var collection = AnalysisContextCollectionImpl(
            includedPaths: [directory.path],
            sdkPath: sdk,
            optionsFile: explicit ? rootOptions.path : null,
            packageConfigFile: explicit ? packages.path : null,
            byteStore: MemoryByteStore(),
            withFineDependencies: true,
            linkedSummaryCoordinator: client,
          );
          try {
            var result = await collection
                .contextFor(nested.path)
                .currentSession
                .getResolvedUnit(nested.path);
            expect(result, isA<ResolvedUnitResult>());

            return strictCasts(collection);
          } finally {
            await collection.dispose();
          }
        }

        try {
          expect(await runDriver(), !explicit);
          expect(producerOptions, [!explicit]);
          expect(
            requests.single.scope.options,
            explicit ? rootOptions.path : null,
          );
          expect(
            requests.single.scope.packages,
            explicit ? packages.path : null,
          );

          // The replacement sees the same paths with new configuration on disk.
          var activeOptions = explicit ? rootOptions : nestedOptions;
          activeOptions.writeAsStringSync(
            explicit
                ? 'analyzer:\n  language:\n    strict-casts: true'
                : 'analyzer: {}',
          );
          expect(await runDriver(), explicit);
          expect(requests.last.changedFiles, isEmpty);
          expect(producerOptions, [!explicit, explicit]);
        } finally {
          client.close();
          inbox.close();
          await serving;
          await contexts.dispose();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }
}
