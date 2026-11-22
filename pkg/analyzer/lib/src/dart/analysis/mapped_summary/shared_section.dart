// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final supportsSummaryMapping = _supportsSummaryMapping();

Uint8List mapSummarySection(String path, int length) {
  if (length <= 0) throw ArgumentError.value(length, 'length');
  if (!supportsSummaryMapping) {
    throw UnsupportedError('Native summary mappings unavailable');
  }
  var bytes = using(
    (arena) => _mapReadOnlyShared(path.toNativeUtf8(allocator: arena), length),
  );
  if (bytes is Uint8List) return bytes;
  throw FileSystemException('Could not map summary batch', path);
}

@Native<Handle Function(Pointer<Utf8>, IntPtr)>(
  assetId: 'dart:io',
  symbol: 'File::MapReadOnlyShared',
)
external Object? _mapReadOnlyShared(Pointer<Utf8> path, int length);

bool _supportsSummaryMapping() {
  try {
    return Native.addressOf<
          NativeFunction<Handle Function(Pointer<Utf8>, IntPtr)>
        >(_mapReadOnlyShared) !=
        nullptr;
  } on ArgumentError {
    return false;
  }
}
