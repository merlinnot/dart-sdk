// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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

  test('background batches request only uncached summaries', () async {
    var dir = await Directory.systemTemp.createTemp('summary-background-');
    addTearDown(() => dir.delete(recursive: true));
    File write(String name) =>
        File.fromUri(dir.uri.resolve(name))
          ..writeAsStringSync('int value = "wrong";');
    var first = write('first.dart');
    var second = write('second.dart');
    var store = MemoryByteStore();

    Future<List<List<String>>> analyze(List<File> files) async {
      var requests = <List<String>>[];
      var inbox = ReceivePort();
      inbox.listen((message) {
        if (message is List<Object?>) {
          if (SummaryRequest.tryDecode(message) case var request?) {
            requests.add(request.paths);
            request.reply.send('declined');
          }
        }
      });
      var client = LinkedSummaryCoordinator(inbox.sendPort);
      var collection = AnalysisContextCollectionImpl(
        includedPaths: [dir.path],
        sdkPath: File(Platform.resolvedExecutable).parent.parent.path,
        byteStore: store,
        withFineDependencies: true,
        linkedSummaryCoordinator: client,
        drainStreams: false,
      );
      try {
        var driver = collection.contextFor(first.path).driver;
        var diagnostics = collection.scheduler.events
            .where((event) => event is AnalysisResultWithDiagnostics)
            .cast<AnalysisResultWithDiagnostics>()
            .take(files.length)
            .toList();
        for (var file in files) {
          driver.addFile(file.path);
        }
        var results = await diagnostics;
        expect(
          results.map((r) => r.path),
          unorderedEquals(files.map((f) => f.path)),
        );
        for (var result in results) {
          expect(
            result.diagnostics.map((d) => d.diagnosticCode.lowerCaseName),
            ['invalid_assignment'],
          );
        }
        return requests;
      } finally {
        await collection.dispose();
        client.close();
        inbox.close();
      }
    }

    expect(await analyze([first]), [
      [first.path],
    ]);
    expect(await analyze([second, first]), [
      [second.path],
    ]);
    expect(await analyze([first, second]), isEmpty);
  });

  group('interactive summary requests', () {
    late Directory directory;
    late File first;
    late File second;
    late ReceivePort inbox;
    late LinkedSummaryCoordinator client;
    late AnalysisContextCollectionImpl collection;
    late List<String> requestedPaths;
    late void Function(SummaryRequest) reply;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('summary-requests-');
      File write(String name) =>
          File.fromUri(directory.uri.resolve(name))
            ..writeAsStringSync('class Entry { void member() {} }');
      first = write('first.dart');
      second = write('second.dart');
      requestedPaths = [];
      inbox = ReceivePort();
      client = LinkedSummaryCoordinator(inbox.sendPort);
      inbox.listen((message) {
        if (message is List<Object?>) {
          var request = SummaryRequest.tryDecode(message);
          if (request != null) {
            requestedPaths.addAll(request.paths);
            reply(request);
          }
        }
      });
    });

    void start(ByteStore store) {
      collection = AnalysisContextCollectionImpl(
        includedPaths: [directory.path],
        sdkPath: File(Platform.resolvedExecutable).parent.parent.path,
        byteStore: store,
        withFineDependencies: true,
        linkedSummaryCoordinator: client,
      );
    }

    tearDown(() async {
      client.close();
      await collection.dispose();
      inbox.close();
      directory.deleteSync(recursive: true);
    });

    test('a corrupt bundle fails only the request that reads it', () async {
      start(_TruncatedBundleStore());
      reply = (request) => request.reply.send(null);
      var context = collection.contextFor(first.path);
      await expectLater(
        context.currentSession.getResolvedUnit(first.path),
        throwsRangeError,
      );
      expect(
        await context.currentSession.getResolvedUnit(second.path),
        isA<ResolvedUnitResult>(),
      );
    });

    test('a waiting file lets unrelated editor work finish', () async {
      start(MemoryByteStore());
      var firstRequest = Completer<SummaryRequest>();
      reply = (request) {
        if (request.paths.contains(first.path)) {
          firstRequest.complete(request);
        } else {
          request.reply.send('declined');
        }
      };
      var driver = collection.contextFor(first.path).driver;
      var resolving = driver.getResolvedUnit(first.path);
      var pending = await firstRequest.future;
      try {
        await driver.getFilesDefiningClassMemberName('member');
        expect(
          await driver.getResolvedUnit(second.path),
          isA<ResolvedUnitResult>(),
        );
        expect(requestedPaths, [first.path, second.path]);
      } finally {
        pending.reply.send('declined');
        await resolving;
      }
    });

    for (var (reason, response, retry) in [
      ('a declined file', 'declined', true),
      ('producer failure', null, false),
    ]) {
      test('resolves another cold file after $reason', () async {
        start(MemoryByteStore());
        reply = (request) => request.reply.send(response);
        var driver = collection.contextFor(first.path).driver;
        for (var file in [first, second]) {
          expect(
            await driver.getResolvedUnit(file.path),
            isA<ResolvedUnitResult>(),
          );
        }
        expect(requestedPaths, [first.path, if (retry) second.path]);
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

/// Supplies a single truncated linked bundle; subsequent reads use normal data.
final class _TruncatedBundleStore extends MemoryByteStore {
  bool _sentTruncatedBundle = false;

  @override
  Uint8List? get(String key) {
    if (!_sentTruncatedBundle && key.endsWith('.linked')) {
      _sentTruncatedBundle = true;
      return Uint8List(1);
    }
    return super.get(key);
  }
}
