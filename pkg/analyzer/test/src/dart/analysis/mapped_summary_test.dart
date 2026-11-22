// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/mapped_summary.dart';
import 'package:test/test.dart';

void main() {
  group('mapped summary transport', () {
    test(
      'both readers retain immutable subviews after publication is removed',
      () async {
        var directory = await Directory.systemTemp.createTemp(
          'mapped-summary-test-',
        );
        try {
          var file = await File('${directory.path}/batch')
              .writeAsBytes([7, 11, 13]);
          expect(
            () => mapSummaryFile(file.path, 4),
            throwsA(isA<FileSystemException>()),
          );
          var bytes = mapSummaryFile(file.path, 3);
          var slice = Uint8List.sublistView(bytes, 1);
          var ready = ReceivePort();
          var reader = await Isolate.spawn(_readAfterUnlink, [
            file.path,
            ready.sendPort,
          ]);
          try {
            var result = ReceivePort();
            var gate = await ready.first as SendPort;
            await file.delete();
            gate.send(result.sendPort);
            expect(slice, [11, 13]);
            expect(() => bytes[0] = 0, throwsUnsupportedError);
            expect(await result.first, [7, 11, 13]);
            result.close();
          } finally {
            reader.kill();
            ready.close();
          }
        } finally {
          await directory.delete(recursive: true);
        }
      },
    );
    test('missing publication fails without exposing a pointer', () {
      expect(
        () => mapSummaryFile('/no-such-dart-analyzer-summary', 1),
        throwsA(isA<FileSystemException>()),
      );
    });
  }, skip: !Platform.isMacOS);
}

void _readAfterUnlink(List<dynamic> args) async {
  var [String path, SendPort ready] = args;
  var bytes = mapSummaryFile(path, 3);
  var gate = ReceivePort();
  ready.send(gate.sendPort);
  var result = await gate.first as SendPort;
  result.send(bytes.toList());
  gate.close();
}
