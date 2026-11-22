// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

/// Appends summary bytes to a fixed-size file shared with mapped readers.
final class SummaryArenaWriter {
  final RandomAccessFile _file;
  final int _capacity;
  int _length = 0;

  /// Creates a new file at [path] with room for [capacity] bytes.
  factory(String path, int capacity) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity');
    }

    var file = File(path)..createSync(exclusive: true);
    var handle = file.openSync(mode: FileMode.writeOnly);

    try {
      handle.truncateSync(capacity);

      return SummaryArenaWriter._(handle, capacity);
    } catch (_) {
      handle.closeSync();
      rethrow;
    }
  }

  new _(this._file, this._capacity);

  /// The number of bytes appended so far.
  int get length => _length;

  /// Appends [bytes] and returns their starting offset in the arena.
  ///
  /// Throws a [StateError] if the bytes would exceed the arena's capacity.
  int append(Uint8List bytes) {
    var start = _length;
    var end = start + bytes.length;

    if (end > _capacity) {
      throw StateError('Summary budget exhausted');
    }

    _file.writeFromSync(bytes);
    _length = end;

    return start;
  }

  void close() => _file.closeSync();
}
