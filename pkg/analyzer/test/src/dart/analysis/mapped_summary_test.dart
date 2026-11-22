// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_coordinator.dart';
import 'package:analyzer/src/dart/analysis/mapped_summary.dart';
import 'package:analyzer/src/dart/analysis/summary_arena.dart';
import 'package:test/test.dart';

void main() {
  if (!supportsSummaryMapping) {
    test(
      'reports unsupported summary mappings on ${Platform.operatingSystem}',
      () {
        expect(() => mapSummaryFile('unused', 1), throwsUnsupportedError);
      },
    );

    return;
  }

  group('mapped summary transport', () {
    late Directory directory;
    late File file;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('mapped-summary-test-');
      file = File('${directory.path}/arena');
    });

    tearDown(() => directory.delete(recursive: true));

    test('readers retain their subviews after the file is deleted', () async {
      var writer = SummaryArenaWriter(file.path, 3);
      addTearDown(writer.close);
      writer.append(Uint8List.fromList([7, 11, 13]));
      var path = file.path;
      var view = Uint8List.sublistView(mapSummaryFile(path, 3), 1);

      // The second reader deletes the file after both readers have mapped it.
      var otherBytes = await Isolate.run(() {
        var view = Uint8List.sublistView(mapSummaryFile(path, 3), 1);
        File(path).deleteSync();

        return view.toList();
      });

      expect(otherBytes, [11, 13]);
      expect(view, [11, 13]);
      expect(() => view[0] = 0, throwsUnsupportedError);
    });

    for (var (name, store, expectedRequests) in [
      ('rejected producer request', MemoryByteStore(), 1),
      ('reference-counted store', CiderByteStore(), 0),
    ]) {
      test('resolves locally with a $name', () async {
        var dir = await Directory.systemTemp.createTemp('analyzer-fallback-');
        var file = File('${dir.path}/client.dart')
          ..writeAsStringSync('int value = "wrong";');
        var inbox = ReceivePort();
        var requests = 0;
        inbox.listen((dynamic message) {
          if (message case [..., SendPort reply] when message.length > 1) {
            requests++;
            reply.send(null);
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

    test('rejects a file with a different length', () async {
      var writer = SummaryArenaWriter(file.path, 3);
      addTearDown(writer.close);
      writer.append(Uint8List.fromList([7, 11, 13]));

      expect(
        () => mapSummaryFile(file.path, 4),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('rejects a missing file', () {
      expect(
        () => mapSummaryFile(file.path, 1),
        throwsA(isA<FileSystemException>()),
      );
    });

    for (var failure
        in Platform.isWindows
            ? [_SetupFailure.descriptor]
            : [_SetupFailure.open, _SetupFailure.truncate]) {
      test('can retry after failing to ${failure.name} the arena', () {
        IOOverrides.runZoned(
          () => expect(
            () => SummaryArenaWriter(file.path, 3),
            throwsA(isA<FileSystemException>()),
          ),
          createFile: (_) => _FailingFile(file, failure),
        );

        var writer = SummaryArenaWriter(file.path, 3);
        addTearDown(writer.close);
        expect(writer.append(Uint8List.fromList([7])), 0);
      });
    }

    test('a second writer cannot replace an existing arena', () async {
      await file.writeAsBytes([7]);

      expect(
        () => SummaryArenaWriter(file.path, 1),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsBytes(), [7]);
    });

    test('append returns the offset of each write visible to readers', () {
      var writer = SummaryArenaWriter(file.path, 3);
      try {
        var view = mapSummaryFile(file.path, 3);

        expect(writer.append(Uint8List.fromList([7, 11])), 0);
        expect(() => writer.append(Uint8List(2)), throwsStateError);
        expect(writer.append(Uint8List.fromList([13])), 2);
        expect(writer.length, 3);
        expect(view, [7, 11, 13]);
      } finally {
        writer.close();
      }
    });
  });
}

final class _FailingFile(final File file, final _SetupFailure failure)
    implements File {
  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      file.createSync(recursive: recursive, exclusive: exclusive);

  @override
  void deleteSync({bool recursive = false}) =>
      file.deleteSync(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    if (failure == _SetupFailure.open) {
      throw FileSystemException('Failed to open', file.path);
    }

    // A read-only handle makes truncateSync fail on the real file.
    return file.openSync();
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    throw FileSystemException(
      'Failed to write the section descriptor',
      file.path,
    );
  }
}

enum _SetupFailure { open, truncate, descriptor }
