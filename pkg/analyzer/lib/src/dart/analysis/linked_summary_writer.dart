// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/summary_arena.dart';
import 'package:crypto/crypto.dart';

const _unlinkedSummarySuffix = '.unlinked2';

/// Stages both cached and newly serialized summaries for the cycle writer.
///
/// Reads of unchanged bytes reuse the staged range. Each write stages the bytes
/// returned by the backing store in a new range, so earlier views stay valid.
final class PublishingSummaryStore(
  final ByteStore _backing,
  final SummaryCycleWriter _writer,
) implements ByteStore {
  // Unlinked keys include the content signature. Linked bundles and their
  // digests can be replaced under the same key by another disk-cache writer.
  final _unlinkedKeys = <String>{};
  final _linkedDigests = <String, Digest>{};

  @override
  Uint8List? get(String key) {
    var bytes = _backing.get(key);

    if (bytes != null) {
      _stageSummary(key, bytes);
    }

    return bytes;
  }

  @override
  Uint8List putGet(String key, Uint8List bytes) {
    var stored = _backing.putGet(key, bytes);
    _stageSummary(key, stored, replace: true);

    return stored;
  }

  @override
  void release(Iterable<String> keys) => _backing.release(keys);

  void _stageSummary(String key, Uint8List bytes, {bool replace = false}) {
    if (key.endsWith(_unlinkedSummarySuffix)) {
      if (replace || !_unlinkedKeys.contains(key)) {
        _writer._stageEntry(key, bytes);
        _unlinkedKeys.add(key);
      }
    } else if (key.endsWith('.linked') || key.endsWith('.linked.digest')) {
      var digest = sha256.convert(bytes);

      if (!replace && _linkedDigests[key] == digest) {
        return;
      }

      _writer._stageEntry(key, bytes);
      _linkedDigests[key] = digest;
    }
  }
}

/// Publishes one index record per completed dependency cycle.
///
/// Bytes are appended to the arena as the driver reads or writes summaries.
/// Readers can find those bytes once [publish] writes the newline that
/// terminates the index record for the cycle.
final class SummaryCycleWriter {
  /// Size in bytes of the file mapped by every reader.
  static const capacity = 384 * 1024 * 1024;

  final SummaryArenaWriter _arena;
  final RandomAccessFile _index;
  final _pendingIndexEntries = <List<Object>>[];
  String? _selectedScope;

  /// Number of cycle records published to the index.
  int cycles = 0;

  /// Number of unlinked unit summaries appended to the arena.
  int units = 0;

  factory(String directory) {
    var data = File('$directory/data');
    var arena = SummaryArenaWriter(data.path, capacity);

    try {
      var index = File('$directory/index').openSync(mode: FileMode.writeOnly);

      return SummaryCycleWriter._(arena, index);
    } catch (_) {
      try {
        arena.close();
      } finally {
        data.deleteSync();
      }
      rethrow;
    }
  }

  new _(this._arena, this._index);

  /// Number of bytes in the arena, including entries awaiting publication.
  int get bytesWritten => _arena.length;

  void close() {
    try {
      _index.closeSync();
    } finally {
      _arena.close();
    }
  }

  /// Commits the staged byte ranges and [libraryPaths] in one index record.
  void publish(List<String> libraryPaths) {
    _writeRecord([_pendingIndexEntries, libraryPaths]);
    _pendingIndexEntries.clear();
    cycles++;
  }

  /// Associates subsequent cycle records with [scope] until the scope changes.
  void selectScope(String scope) {
    if (scope == _selectedScope) {
      return;
    }

    _writeRecord([scope]);
    _selectedScope = scope;
  }

  void _stageEntry(String key, Uint8List bytes) {
    var offset = _arena.append(bytes);
    _pendingIndexEntries.add([key, offset, bytes.length]);

    if (key.endsWith(_unlinkedSummarySuffix)) {
      units++;
    }
  }

  void _writeRecord(List<Object> record) {
    _index.writeFromSync(utf8.encode('${jsonEncode(record)}\n'));
  }
}
