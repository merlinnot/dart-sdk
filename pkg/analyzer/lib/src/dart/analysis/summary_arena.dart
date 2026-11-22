// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

/// One writer appends to the arena. Only readers need a resident mapping.
final class SummaryArenaWriter {
  final RandomAccessFile _file;
  final int _capacity;
  int _length = 0;

  factory(String path, int capacity) {
    if (capacity <= 0) throw ArgumentError.value(capacity);
    var file = File(path)..createSync(exclusive: true);
    var sink = file.openSync(mode: FileMode.writeOnly);
    try {
      sink.truncateSync(capacity);
      return SummaryArenaWriter._(sink, capacity);
    } catch (_) {
      sink.closeSync();
      rethrow;
    }
  }

  new _(this._file, this._capacity);
  int get length => _length;

  int append(Uint8List bytes) {
    var start = _length;
    var end = start + bytes.length;
    if (end > _capacity) throw StateError('Summary budget exhausted');
    _file.writeFromSync(bytes);
    _length = end;
    return start;
  }

  void close() => _file.closeSync();
}
