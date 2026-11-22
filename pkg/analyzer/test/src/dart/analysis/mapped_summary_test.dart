// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/mapped_summary.dart';
import 'package:analyzer/src/dart/analysis/summary_arena.dart';
import 'package:test/test.dart';

void main() {
  if (!Platform.isMacOS) {
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
      await file.writeAsBytes([7, 11, 13]);
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

    test('rejects a file with a different length', () async {
      await file.writeAsBytes([7, 11, 13]);

      expect(
        () => mapSummaryFile(file.path, 4),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('rejects a FIFO without waiting for a writer', () async {
      var fifo = await Process.run('mkfifo', [file.path]);
      expect(fifo.exitCode, 0, reason: fifo.stderr.toString());
      var analyzer = (await Isolate.resolvePackageUri(
        Uri.parse('package:analyzer/'),
      ))!;
      var fixture = analyzer.resolve(
        '../test/src/dart/analysis/fixtures/map_summary_fifo.dart',
      );
      var child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${(await Isolate.packageConfig)!}',
        fixture.toFilePath(),
        file.path,
      ]);
      var errors = child.stderr.transform(utf8.decoder).join();
      try {
        var status = await child.exitCode.timeout(const Duration(seconds: 10));
        expect(status, 0, reason: await errors);
      } finally {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
      }
    });

    test('rejects a missing file', () {
      expect(
        () => mapSummaryFile(file.path, 1),
        throwsA(isA<FileSystemException>()),
      );
    });

    for (var failure in _SetupFailure.values) {
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
}

enum _SetupFailure { open, truncate }
