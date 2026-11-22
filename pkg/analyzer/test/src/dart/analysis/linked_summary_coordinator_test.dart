// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_coordinator.dart';
import 'package:analyzer/src/dart/analysis/summary_arena.dart';
import 'package:test/test.dart';

void main() {
  group('linked summary coordinator', () {
    late ReceivePort broker;
    late LinkedSummaryCoordinator reader;

    setUp(() {
      broker = ReceivePort();
      reader = LinkedSummaryCoordinator(broker.sendPort);
    });

    tearDown(() {
      reader.close();
      broker.close();
    });

    test('an unavailable producer leaves the local store usable', () async {
      var store = reader.wrapIfSupported(MemoryByteStore())!;
      var prepared = reader.prepare(root: '/root', paths: []);
      var [..., SendPort reply] = await broker.first as List;
      reply.send(null);

      expect(await prepared, SummaryPreparationResult.unavailable);
      store.putGet('a.linked', Uint8List.fromList([3]));
      expect(store.get('a.linked'), [3]);
    });

    if (!Platform.isMacOS) {
      return;
    }

    group('published cycles', () {
      late Directory directory;
      late File data;
      late File index;
      late SummaryArenaWriter arena;
      late List<Object> descriptor;

      setUp(() async {
        directory = await Directory.systemTemp.createTemp('cycle-index-test-');
        data = File('${directory.path}/data');
        index = File('${directory.path}/index');
        arena = SummaryArenaWriter(data.path, 3);
        descriptor = [directory.path, 3, 0];
        var scope = jsonEncode([
          directory.path,
          null,
          null,
          <String, String>{},
        ]);
        index.writeAsStringSync('${jsonEncode([scope])}\n');
      });

      tearDown(() async {
        arena.close();
        await directory.delete(recursive: true);
      });

      String cycleRecord(String path, List<int> bytes) {
        var offset = arena.append(Uint8List.fromList(bytes));

        return jsonEncode([
          [
            ['$path.linked', offset, bytes.length],
          ],
          [path],
        ]);
      }

      test(
        'reads published paths with a different declared variable order',
        () async {
          var scope = jsonEncode([
            directory.path,
            null,
            null,
            {'a': '1', 'b': '2'},
          ]);
          index.writeAsStringSync(
            '${jsonEncode([scope])}\n${cycleRecord('a', [5])}\n',
            mode: FileMode.append,
          );

          var published = <String>[];
          var prepared = reader.prepare(
            root: directory.path,
            paths: ['a'],
            variables: {'b': '2', 'a': '1'},
            onAvailable: (cycles) => published.addAll(cycles.takePaths()),
          );
          var [..., SendPort reply] = await broker.first as List;
          reply.send(descriptor);

          expect(await prepared, SummaryPreparationResult.prepared);
          expect(published, ['a']);
        },
      );

      test('the final reply loads the index without a callback', () async {
        var store = reader.wrapIfSupported(MemoryByteStore())!;
        index.writeAsStringSync(
          '${cycleRecord('a', [5])}\n',
          mode: FileMode.append,
        );

        var prepared = reader.prepare(root: directory.path, paths: ['a']);
        var [..., SendPort reply] = await broker.first as List;
        reply.send(descriptor);

        expect(await prepared, SummaryPreparationResult.prepared);
        expect(store.get('a.linked'), [5]);
      });

      test(
        'a reader can consume each complete cycle before completion',
        () async {
          var updates = StreamController<PublishedCycles>();
          var publications = StreamIterator(updates.stream);
          addTearDown(() async {
            await publications.cancel();
            await updates.close();
          });

          var store = reader.wrapIfSupported(MemoryByteStore())!;
          var prepared = reader.prepare(
            root: directory.path,
            paths: ['a', 'b'],
            onAvailable: updates.add,
          );
          var [..., SendPort reply] = await broker.first as List;

          Future<Iterable<String>> readProgress() async {
            reply.send(['progress', descriptor]);
            expect(await publications.moveNext(), isTrue);

            return publications.current.takePaths();
          }

          index.writeAsStringSync(
            '${cycleRecord('a', [3, 5])}\n',
            mode: FileMode.append,
          );
          expect(await readProgress(), ['a']);
          var held = store.get('a.linked')!;
          expect(held, [3, 5]);

          // The second record is readable only once its newline is visible.
          index.writeAsStringSync(cycleRecord('b', [7]), mode: FileMode.append);
          expect(await readProgress(), isEmpty);
          expect(store.get('b.linked'), isNull);

          index.writeAsStringSync('\n', mode: FileMode.append);
          expect(await readProgress(), ['b']);
          expect(store.get('b.linked'), [7]);

          reply.send(descriptor);
          expect(await prepared, SummaryPreparationResult.prepared);
          expect(await publications.moveNext(), isTrue);
          expect(publications.current.takePaths(), isEmpty);

          reader.close();
          await data.delete();
          expect(held, [3, 5]);
          expect(() => held[0] = 0, throwsUnsupportedError);
        },
      );
    });
  });
}
