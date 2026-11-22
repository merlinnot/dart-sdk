// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/mapped_summary/linux.dart' as linux;
import 'package:analyzer/src/dart/analysis/mapped_summary/macos.dart' as macos;
import 'package:analyzer/src/dart/analysis/mapped_summary/windows.dart'
    as windows;
import 'package:analyzer/src/dart/analysis/mapped_summary_stub.dart'
    as unsupported;

bool get supportsSummaryMapping => Platform.isMacOS;

Uint8List mapSummaryFile(String path, int length) =>
    switch (Platform.operatingSystem) {
      'linux' => linux.mapSummaryFile(path, length),
      'macos' => macos.mapSummaryFile(path, length),
      'windows' => windows.mapSummaryFile(path, length),
      _ => unsupported.mapSummaryFile(path, length),
    };
