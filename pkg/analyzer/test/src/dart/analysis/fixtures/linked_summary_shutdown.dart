// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:analyzer/src/dart/analysis/linked_summary_coordinator.dart';

Future<void> main(List<String> args) async {
  var entry = File(args.single);
  var sdk = File(Platform.resolvedExecutable).parent.parent.path;
  var broker = LinkedSummaryBroker(sdk);
  try {
    var result = await broker.prepare(
      root: entry.parent.path,
      paths: [entry.path],
    );

    if (result != SummaryPreparationResult.prepared) {
      throw StateError('Could not prepare ${entry.path}');
    }
  } finally {
    await broker.shutdown();
  }

  stdout.writeln('shutdown complete');
}
