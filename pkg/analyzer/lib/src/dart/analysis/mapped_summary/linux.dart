// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/mapped_summary/shared_section.dart';

Uint8List mapSummaryFile(String path, int length) =>
    mapSummarySection(path, length);
