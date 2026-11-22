// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:analyzer/src/dart/analysis/mapped_summary.dart';

void main(List<String> arguments) {
  try {
    mapSummaryFile(arguments.single, 1);
  } on FileSystemException {
    return;
  }
  throw StateError('Expected the summary mapper to reject the FIFO.');
}
