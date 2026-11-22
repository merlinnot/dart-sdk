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
  group('driver fallback', () {
    for (var (name, store, expectedRequests) in [
      ('rejected producer request', MemoryByteStore(), 1),
      ('reference-counted store', CiderByteStore(), 0),
    ]) {
      test('resolves locally with a $name', () async {
        var dir = await Directory.systemTemp.createTemp('analyzer-fallback-');
        var file = File.fromUri(dir.uri.resolve('client.dart'))
          ..writeAsStringSync('int value = "wrong";');
        var inbox = ReceivePort();
        var requests = 0;
        inbox.cast<List<Object?>>().listen((message) {
          if (SummaryRequest.tryDecode(message) case var request?) {
            requests++;
            request.reply.send(null);
          }
        });
        var client = LinkedSummaryCoordinator(inbox.sendPort);
        var collection = AnalysisContextCollectionImpl(
          includedPaths: [dir.path],
          sdkPath: File(Platform.resolvedExecutable).parent.parent.path,
          byteStore: store,
          withFineDependencies: true,
          linkedSummaryCoordinator: client,
        );
        try {
          var session = collection.contextFor(file.path).currentSession;
          var result =
              await session.getResolvedUnit(file.path) as ResolvedUnitResult;
          expect(
            result.diagnostics.map((d) => d.diagnosticCode.lowerCaseName),
            ['invalid_assignment'],
          );
          expect(requests, expectedRequests);
        } finally {
          await collection.dispose();
          client.close();
          inbox.close();
          await dir.delete(recursive: true);
        }
      });
    }
  });

  group('driver replacement', () {
    const defaultOptions = 'analyzer: {}';
    const strictOptions = 'analyzer:\n  language:\n    strict-casts: true';

    late Directory directory;
    late File entry;
    late File rootOptions;
    late File nestedOptions;
    late File packages;
    late LinkedSummaryCoordinator client;
    late List<SummaryRequest> requests;
    late List<bool> producerStrictCasts;

    var sdk = File(Platform.resolvedExecutable).parent.parent.path;

    bool strictCasts(AnalysisContextCollectionImpl collection) {
      var context = collection.contextFor(entry.path);
      var file = context.resourceProvider.getFile(entry.path);

      return context.driver.getAnalysisOptionsForFile(file).strictCasts;
    }

    Future<bool> resolveWithNewDriver({
      File? options,
      File? packageConfig,
    }) async {
      var collection = AnalysisContextCollectionImpl(
        includedPaths: [directory.path],
        sdkPath: sdk,
        optionsFile: options?.path,
        packageConfigFile: packageConfig?.path,
        byteStore: MemoryByteStore(),
        withFineDependencies: true,
        linkedSummaryCoordinator: client,
      );

      try {
        var session = collection.contextFor(entry.path).currentSession;
        expect(
          await session.getResolvedUnit(entry.path),
          isA<ResolvedUnitResult>(),
        );

        return strictCasts(collection);
      } finally {
        await collection.dispose();
      }
    }

    setUp(() {
      directory = Directory.systemTemp.createTempSync('summary-driver-');
      addTearDown(() => directory.deleteSync(recursive: true));

      File write(String path, String contents) =>
          File.fromUri(directory.uri.resolve(path))
            ..createSync(recursive: true)
            ..writeAsStringSync(contents);

      entry = write('nested/entry.dart', 'class Entry {}');
      rootOptions = write('analysis_options.yaml', defaultOptions);
      nestedOptions = write('nested/analysis_options.yaml', strictOptions);
      packages = write(
        '.dart_tool/package_config.json',
        '{"configVersion":2,"packages":[]}',
      );

      var contexts = SummaryProducerContexts(sdk, MemoryByteStore());
      var inbox = ReceivePort();
      client = LinkedSummaryCoordinator(inbox.sendPort);
      requests = [];
      producerStrictCasts = [];

      // Handle messages in delivery order. A cache miss exercises disposal
      // after the driver falls back to local resolution.
      var serving = inbox.asyncMap((message) async {
        switch (message) {
          case ['invalidateRoot', String root]:
            await contexts.invalidateRoot(root);
          case List<Object?> values when values.length > 1:
            var request = SummaryRequest.tryDecode(values)!;
            var context = await contexts.prepare(request);
            requests.add(request);
            producerStrictCasts.add(strictCasts(context.collection));
            request.reply.send(null);
        }
      }).drain<void>();

      addTearDown(() async {
        client.close();
        inbox.close();
        await serving;
        await contexts.dispose();
      });
    });

    test('discovers nested options again after replacement', () async {
      expect(await resolveWithNewDriver(), isTrue);
      expect(producerStrictCasts, [true]);
      expect(requests.single.scope.options, isNull);
      expect(requests.single.scope.packages, isNull);

      nestedOptions.writeAsStringSync(defaultOptions);

      expect(await resolveWithNewDriver(), isFalse);
      expect(requests.last.changedFiles, isEmpty);
      expect(producerStrictCasts, [true, false]);
    });

    test(
      'reuses explicit paths and rereads their contents after replacement',
      () async {
        Future<bool> resolve() =>
            resolveWithNewDriver(options: rootOptions, packageConfig: packages);

        expect(await resolve(), isFalse);
        expect(producerStrictCasts, [false]);
        expect(requests.single.scope.options, rootOptions.path);
        expect(requests.single.scope.packages, packages.path);

        rootOptions.writeAsStringSync(strictOptions);

        expect(await resolve(), isTrue);
        expect(requests.last.changedFiles, isEmpty);
        expect(producerStrictCasts, [false, true]);
      },
    );
  });
}
