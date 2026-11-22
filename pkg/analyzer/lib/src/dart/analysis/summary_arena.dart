// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/summary_section_stub.dart'
    if (dart.library.ffi) 'package:analyzer/src/dart/analysis/summary_section_windows.dart';

/// Appends summary bytes to a fixed-size file shared with mapped readers.
final class SummaryArenaWriter {
  final void Function(Uint8List, int) _write;
  final void Function() _close;
  bool _closed = false;
  final int _capacity;
  int _length = 0;

  /// Creates a new file at [path] with room for [capacity] bytes.
  factory(String path, int capacity) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity');
    }

    var file = File(path)..createSync(exclusive: true);
    RandomAccessFile? handle;
    try {
      if (Platform.isWindows) {
        var (write, close) = createSummarySection(file, capacity);
        return SummaryArenaWriter._(write, close, capacity);
      }
      var sink = handle = file.openSync(mode: FileMode.writeOnly);
      sink.truncateSync(capacity);

      return SummaryArenaWriter._(
        (bytes, _) => sink.writeFromSync(bytes),
        sink.closeSync,
        capacity,
      );
    } catch (_) {
      try {
        handle?.closeSync();
      } finally {
        file.deleteSync();
      }
      rethrow;
    }
  }

  new _(this._write, this._close, this._capacity);

  /// The number of bytes appended so far.
  int get length => _length;

  /// Appends [bytes] and returns their starting offset in the arena.
  ///
  /// Throws a [StateError] if the bytes would exceed the arena's capacity.
  int append(Uint8List bytes) {
    if (_closed) throw StateError('Summary arena is closed');
    var start = _length;
    var end = start + bytes.length;

    if (end > _capacity) {
      throw StateError('Summary budget exhausted');
    }

    _write(bytes, start);
    _length = end;

    return start;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _close();
  }
}
