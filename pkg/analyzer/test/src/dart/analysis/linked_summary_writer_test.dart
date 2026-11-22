// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_coordinator.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_writer.dart';
import 'package:test/test.dart';

void main() {
  if (!LinkedSummaryCoordinator.isSupported) {
    return;
  }

  test('can retry in the same directory after the index fails to open', () {
    var directory = Directory.systemTemp.createTempSync('cycle-writer-');
    addTearDown(() => directory.deleteSync(recursive: true));
    var obstruction = Directory('${directory.path}/index')..createSync();

    expect(
      () => SummaryCycleWriter(directory.path),
      throwsA(isA<FileSystemException>()),
    );
    obstruction.deleteSync();

    var writer = SummaryCycleWriter(directory.path);
    addTearDown(writer.close);
    expect(writer.bytesWritten, 0);
  });

  group('summary cycle writer', () {
    late Directory directory;
    late SummaryCycleWriter writer;
    late MemoryByteStore backing;
    late PublishingSummaryStore producerStore;
    late LinkedSummaryCoordinator reader;
    late ByteStore readerStore;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('cycle-writer-');
      addTearDown(() => directory.delete(recursive: true));

      writer = SummaryCycleWriter(directory.path);
      addTearDown(writer.close);
      writer.selectScope(
        jsonEncode([directory.path, null, null, <String, String>{}]),
      );
      backing = MemoryByteStore();
      producerStore = PublishingSummaryStore(backing, writer);

      var broker = ReceivePort();
      addTearDown(broker.close);
      broker.listen((message) {
        var [..., SendPort reply] = message as List;
        reply.send([directory.path, SummaryCycleWriter.capacity, 0]);
      });
      reader = LinkedSummaryCoordinator(broker.sendPort);
      addTearDown(reader.close);
      readerStore = reader.wrapIfSupported(MemoryByteStore())!;
    });

    Future<List<String>> readPublishedPaths() async {
      var paths = <String>[];
      var result = await reader.prepare(
        root: directory.path,
        paths: [],
        onAvailable: (cycles) => paths.addAll(cycles.takePaths()),
      );
      expect(result, SummaryPreparationResult.prepared);

      return paths;
    }

    test('publishes cached and newly written summaries together', () async {
      backing.putGet('b.unlinked2', Uint8List.fromList([2]));
      producerStore.get('b.unlinked2');
      producerStore.putGet('a.linked', Uint8List.fromList([1]));

      expect(await readPublishedPaths(), isEmpty);
      expect(readerStore.get('a.linked'), isNull);
      expect(readerStore.get('b.unlinked2'), isNull);

      writer.publish(['a.dart', 'b.dart']);

      expect(await readPublishedPaths(), ['a.dart', 'b.dart']);
      expect(readerStore.get('a.linked'), [1]);
      expect(readerStore.get('b.unlinked2'), [2]);
    });

    test('a published replacement preserves the previous byte view', () async {
      producerStore.putGet('a.linked', Uint8List.fromList([1]));
      writer.publish(['a.dart']);
      expect(await readPublishedPaths(), ['a.dart']);
      var previousView = readerStore.get('a.linked')!;

      producerStore.putGet('a.linked', Uint8List.fromList([3]));

      expect(await readPublishedPaths(), isEmpty);
      expect(readerStore.get('a.linked'), [1]);

      writer.publish(['a.dart']);

      expect(await readPublishedPaths(), ['a.dart']);
      expect(readerStore.get('a.linked'), [3]);
      expect(previousView, [1]);
    });

    for (var key in ['aa.linked', 'aa.linked.digest']) {
      test(
        'publishes a replacement read from the disk cache for $key',
        () async {
          var disk = FileByteStore(directory.path, tempNameSuffix: 'producer');
          var other = FileByteStore(directory.path, tempNameSuffix: 'other');
          var store = PublishingSummaryStore(disk, writer);

          Future<void> replace(int value) async {
            other.putGet(key, Uint8List.fromList([value]));
            await other.flush();
            expect(store.get(key), [value]);
          }

          await replace(1);
          writer.publish(['a.dart']);
          expect(await readPublishedPaths(), ['a.dart']);
          var previousView = readerStore.get(key)!;

          await replace(2);
          expect(readerStore.get(key), [1]);
          writer.publish(['a.dart']);

          expect(await readPublishedPaths(), ['a.dart']);
          expect(readerStore.get(key), [2]);
          expect(previousView, [1]);
        },
      );
    }

    test('stages a cached digest once and skips unrelated entries', () async {
      backing.putGet('a.linked.digest', Uint8List.fromList([7]));
      producerStore.get('a.linked.digest');
      producerStore.get('a.linked.digest');
      producerStore.putGet('other', Uint8List.fromList([9]));

      expect(writer.bytesWritten, 1);
      expect(producerStore.get('other'), [9]);

      writer.publish(['a.dart']);

      expect(await readPublishedPaths(), ['a.dart']);
      expect(readerStore.get('a.linked.digest'), [7]);
      expect(readerStore.get('other'), isNull);
    });
  });
}
