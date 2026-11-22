// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

(void Function(Uint8List, int), void Function()) createSummarySection(
  File descriptor,
  int capacity,
) => throw UnsupportedError('Native summary sections unavailable');
