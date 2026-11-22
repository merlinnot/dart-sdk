// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:analyzer/src/dart/analysis/linked_summary_coordinator.dart';

Future<void> main(List<String> args) async {
  var entry = File(args.first);
  var sdk = File(Platform.resolvedExecutable).parent.parent.path;
  var broker = LinkedSummaryBroker(sdk);
  try {
    Future<SummaryPreparationResult> prepare(List<String> files) =>
        broker.prepare(root: entry.parent.path, paths: files);

    if (args[1] == 'producerFailure') {
      var corrupt = await _seedCorruptSummary(entry.parent, sdk);
      // The first path queues real disk writes. Decoding the second path's
      // summary fails inside the producer while those writes are outstanding.
      var pending = await Future.wait([
        prepare([entry.path, corrupt]),
        prepare([entry.path]),
      ]).timeout(const Duration(seconds: 5));

      if (pending.any(
            (result) => result != SummaryPreparationResult.unavailable,
          ) ||
          await prepare([entry.path]) != SummaryPreparationResult.unavailable) {
        throw StateError(
          'A failed producer must release current and later readers',
        );
      }
    } else if (await prepare([entry.path]) !=
        SummaryPreparationResult.prepared) {
      throw StateError('Could not prepare ${entry.path}');
    }
  } finally {
    await broker.shutdown();
  }

  stdout.writeln('shutdown complete');
}

/// Seeds an intact cache file whose payload cannot be decoded as a summary.
Future<String> _seedCorruptSummary(Directory root, String sdk) async {
  var file = File.fromUri(root.uri.resolve('corrupt.dart'))
    ..writeAsStringSync('class Corrupt {}');
  var collection = AnalysisContextCollectionImpl(
    includedPaths: [root.path],
    sdkPath: sdk,
    withFineDependencies: true,
  );
  try {
    var driver = collection.contextFor(file.path).driver;
    var key = driver.fsState.getFileForPath(file.path).unlinkedKey;
    var state = Platform.environment['ANALYZER_STATE_LOCATION_OVERRIDE']!;
    var cache = FileByteStore('$state/.analysis-driver');
    Directory('$state/.analysis-driver').createSync(recursive: true);
    cache.putGet(key, Uint8List.fromList([0xff]));
    await cache.flush();

    return file.path;
  } finally {
    await collection.dispose();
  }
}
