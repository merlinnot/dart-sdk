// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/mapped_summary.dart';
import 'package:analyzer/src/dart/analysis/summary_arena.dart';
import 'package:test/test.dart';

void main() {
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

    test('rejects a missing file', () {
      expect(
        () => mapSummaryFile(file.path, 1),
        throwsA(isA<FileSystemException>()),
      );
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
  }, skip: !Platform.isMacOS);
}
