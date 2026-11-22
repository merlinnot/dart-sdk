// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:_fe_analyzer_shared/src/scanner/characters.dart' show $LF;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:analyzer/src/dart/analysis/library_graph.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_contexts.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_protocol.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_writer.dart';
import 'package:analyzer/src/dart/analysis/mapped_summary.dart';
import 'package:path/path.dart' as path;

part 'linked_summary_broker.dart';
part 'linked_summary_producer.dart';

final _traceDirectory = Platform.environment['DART_ANALYZER_SUMMARY_TRACE_DIR'];

void _writeTrace(String name, String contents) {
  try {
    File('$_traceDirectory/$name').writeAsStringSync(contents);
  } on FileSystemException {
    // Profiling output is optional, even if the trace directory disappears.
  }
}

/// Identifies the producer's arena. The reader maps all `length` bytes once
/// and uses the index to find published ranges within that mapping. For timing
/// the first linked read, `epoch` is the producer's start time in microseconds
/// since the Unix epoch.
typedef _ArenaDescriptor = ({String directory, int length, int epoch});

/// Requests summaries from the producer and reads its append-only cycle index.
class LinkedSummaryCoordinator {
  /// The plugin startup capability that carries the broker's send port.
  static const capability = 'dart.analyzer.linkedSummaryCoordinator';

  /// The wire protocol version a plugin must recognize to use the broker.
  static const protocolVersion = 4;

  static const _producerIdleTimeout = Duration(seconds: 20);

  final SendPort _broker;
  final _pending = <ReceivePort>{};
  final _ReaderStats _stats;
  _CycleIndex? _index;
  bool _closed = false;

  new(SendPort broker) : this._(broker, 'plugin');

  new _(this._broker, String role) : _stats = _ReaderStats(role);

  /// Ends pending requests and releases this reader's reference to the arena.
  /// Previously returned bytes keep their mapping alive.
  void close() {
    _closed = true;
    for (var port in _pending) {
      port.close();
    }
    _stats.flush();
    _index?.file.closeSync();
    _index = null;
  }

  /// Releases producer contexts for [root] after a client disposes its driver.
  /// The broker handles this before later requests from the same client.
  void invalidateRoot(String root) {
    if (!_closed) {
      _broker.send(['invalidateRoot', root]);
    }
  }

  /// Requests summaries for [paths] in the analysis context identified by
  /// [root], [options], [packages], and the declared [variables].
  ///
  /// [overlays] is the complete set of unsaved file contents for this scope.
  /// Omitting a previously overlaid path restores its on-disk contents.
  /// Use [changedFiles] for paths the producer should reread after disk edits.
  ///
  /// With [onAvailable], each notification supplies the same [PublishedCycles]
  /// cursor so the caller can defer reading the index until its next background
  /// turn. Otherwise, the final reply is read before this method completes.
  ///
  /// Returns [SummaryPreparationResult.unavailable] if the request cannot be
  /// completed and the caller should continue with local analysis.
  Future<SummaryPreparationResult> prepare({
    required String root,
    required List<String> paths,
    String? options,
    String? packages,
    Map<String, String> variables = const {},
    Map<String, String> overlays = const {},
    List<String> changedFiles = const [],
    void Function(PublishedCycles)? onAvailable,
  }) async {
    if (_closed) {
      return .unavailable;
    }

    var scope = SummaryAnalysisScope(
      root,
      options: options,
      packages: packages,
      variables: variables,
    );
    var scopeKey = scope.indexKey;
    var cursor = _index?.paths[scopeKey]?.length ?? 0;
    PublishedCycles? publication;

    PublishedCycles cycles(_ArenaDescriptor descriptor) =>
        publication ??= PublishedCycles._(this, scopeKey, descriptor, cursor);

    var reply = ReceivePort();
    _pending.add(reply);
    try {
      var request = SummaryRequest(
        scope: scope,
        paths: paths,
        overlays: overlays,
        changedFiles: changedFiles,
        reply: reply.sendPort,
        wantsProgress: onAvailable != null,
      );
      _broker.send(request.toMessage());

      // Each progress notification renews the timeout for a live producer.
      await for (var message in reply.timeout(_producerIdleTimeout)) {
        if (_closed) {
          return .unavailable;
        }

        switch (message) {
          case ['progress', [String directory, int length, int epoch]]
              when onAvailable != null:
            onAvailable(
              cycles((directory: directory, length: length, epoch: epoch)),
            );
          case [String directory, int length, int epoch]:
            var descriptor = (
              directory: directory,
              length: length,
              epoch: epoch,
            );

            if (onAvailable == null) {
              return _follow(descriptor) == null ? .unavailable : .prepared;
            }
            onAvailable(cycles(descriptor));

            return .prepared;
          default:
            return .unavailable;
        }
      }

      return .unavailable;
    } catch (error, stack) {
      if (_traceDirectory != null) {
        _writeTrace(
          'reader-error-${identityHashCode(this)}.txt',
          '$error\n$stack',
        );
      }

      return .unavailable;
    } finally {
      _broker.send([reply.sendPort]);
      _pending.remove(reply);
      reply.close();
    }
  }

  /// Returns a store that reads published bytes before consulting [backing],
  /// or null if [backing] requires per-key release tracking.
  ByteStore? wrapIfSupported(ByteStore backing) => switch (backing) {
    MemoryCachingByteStore() ||
    MemoryByteStore() ||
    NullByteStore() => _ReaderStore(backing, this),
    _ => null,
  };

  _CycleIndex? _follow(_ArenaDescriptor descriptor) {
    if (_closed) {
      return null;
    }

    try {
      var index = _index ??= _CycleIndex(descriptor);
      _stats.epoch = descriptor.epoch;
      index.refresh();

      return index;
    } on FileSystemException {
      return null;
    }
  }
}

/// A cursor over the paths published for one request's analysis context.
final class PublishedCycles {
  final LinkedSummaryCoordinator _reader;
  final String _scope;
  final _ArenaDescriptor _descriptor;
  int _cursor;

  new _(this._reader, this._scope, this._descriptor, this._cursor);

  /// Reads the index synchronously and advances this request's cursor.
  ///
  /// The first call returns paths added to the reader's index for this scope
  /// since the request began. Later calls return paths added since the previous
  /// call. One call can collect several cycles if notifications accumulated.
  /// Returns an empty iterable if the index is unavailable or has no new paths.
  Iterable<String> takePaths() {
    var paths = _reader._follow(_descriptor)?.paths[_scope];

    if (paths == null) {
      return const [];
    }

    var start = _cursor;
    _cursor = paths.length;

    return paths.getRange(start, _cursor);
  }
}

/// The outcome of a request to the summary producer.
enum SummaryPreparationResult {
  /// The producer completed the request.
  prepared,

  /// The caller should continue analysis using its local store.
  unavailable,
}

/// Reads complete records from one arena's index in publication order.
///
/// A scope record selects the analysis context for subsequent cycle records.
/// Each cycle record lists byte ranges by store key and the library paths
/// that became available in that scope. The producer appends the terminating
/// newline after writing the summary bytes, so readers can use those ranges
/// as soon as they see the complete line.
final class _CycleIndex {
  final Uint8List arena;
  final RandomAccessFile file;
  final entries = <String, Uint8List>{};
  final paths = <String, List<String>>{};
  int _position = 0;
  List<String>? _scopePaths;

  new(_ArenaDescriptor descriptor)
    : arena = mapSummaryFile('${descriptor.directory}/data', descriptor.length),
      file = File('${descriptor.directory}/index').openSync();

  void refresh() {
    var unread = file.lengthSync() - _position;

    if (unread == 0) {
      return;
    }

    var data = file.readSync(unread);
    // A newline commits a record. Leave a partial line (and any partial UTF-8
    // character in it) for the next read.
    var lastNewline = data.lastIndexOf($LF);
    var completeByteCount = lastNewline + 1;
    _position += completeByteCount;

    if (completeByteCount < data.length) {
      file.setPositionSync(_position);
    }

    if (completeByteCount == 0) {
      return;
    }

    var lines = utf8.decode(Uint8List.sublistView(data, 0, lastNewline));
    for (var line in lines.split('\n')) {
      _readRecord(jsonDecode(line));
    }
  }

  void _readRecord(Object? record) {
    var scopePaths = _scopePaths;
    switch (record) {
      case [String scope]:
        _scopePaths = paths[scope] ??= [];
      case [List cycleEntries, List cyclePaths] when scopePaths != null:
        for (var entry in cycleEntries) {
          var [String key, int offset, int length] = entry as List;
          entries[key] = Uint8List.sublistView(arena, offset, offset + length);
        }
        scopePaths.addAll(cyclePaths.cast<String>());
      default:
        throw const FormatException('Invalid summary index record');
    }
  }
}

final class _ReaderStats {
  static const _hitTraceInterval = 1024;
  static const _initialLocalLinksToTrace = 10;
  static const _localLinkTraceInterval = 64;

  final String name;
  int linked = 0;
  int unlinked = 0;
  int localLinks = 0;
  int epoch = 0;
  int? firstLinkedMicros;

  new(this.name);

  void flush() {
    if (_traceDirectory != null) {
      _writeTrace('local-links-$name.json', jsonEncode(localLinks));
    }
  }

  void hit(String key) {
    if (_traceDirectory == null) {
      return;
    }

    var isFirstLinked = false;

    if (key.endsWith('.linked')) {
      linked++;
      isFirstLinked = linked == 1;
      firstLinkedMicros ??= DateTime.now().microsecondsSinceEpoch - epoch;
    } else if (key.endsWith('.unlinked2')) {
      unlinked++;
    } else {
      return;
    }

    var count = linked + unlinked;

    if (isFirstLinked || count == 1 || count % _hitTraceInterval == 0) {
      _writeTrace(
        'reader-$name.json',
        jsonEncode({
          'linked': linked,
          'unlinked': unlinked,
          'firstLinkedMicros': firstLinkedMicros,
        }),
      );
    }
  }

  void recordLocalLink() {
    if (_traceDirectory == null) {
      return;
    }

    localLinks++;

    if (localLinks <= _initialLocalLinksToTrace ||
        localLinks % _localLinkTraceInterval == 0) {
      flush();
    }
  }
}

/// Reads published summaries directly from the mapped arena.
///
/// A local write goes to [backing] and removes the indexed entry for that
/// key, so later reads see the local bytes until the producer republishes it.
final class _ReaderStore implements ByteStore {
  final ByteStore backing;
  final LinkedSummaryCoordinator reader;

  new(this.backing, this.reader);

  @override
  Uint8List? get(String key) {
    var bytes = reader._index?.entries[key];

    if (bytes == null) {
      return backing.get(key);
    }
    reader._stats.hit(key);

    return bytes;
  }

  @override
  Uint8List putGet(String key, Uint8List bytes) {
    if (key.endsWith('.linked')) {
      reader._stats.recordLocalLink();
    }
    reader._index?.entries.remove(key);

    return backing.putGet(key, bytes);
  }

  @override
  void release(Iterable<String> keys) {}
}
