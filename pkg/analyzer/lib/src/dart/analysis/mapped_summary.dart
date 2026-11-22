// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/mapped_summary_stub.dart'
    if (dart.library.ffi) 'package:analyzer/src/dart/analysis/mapped_summary/native.dart'
    as platform;

/// Maps the [length]-byte summary file at [path].
///
/// The returned bytes and their subviews are read-only and keep the mapping
/// alive after the file is deleted. Throws [UnsupportedError] on platforms
/// without a summary mapping implementation.
Uint8List mapSummaryFile(String path, int length) =>
    platform.mapSummaryFile(path, length);
