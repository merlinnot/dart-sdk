// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final supportsSummaryMapping = _hasSharedMappingSymbol();

Uint8List mapSummaryFile(String path, int length) {
  if (length <= 0) {
    throw ArgumentError.value(length, 'length');
  }

  if (!supportsSummaryMapping) {
    throw UnsupportedError('Native summary mappings unavailable');
  }

  var bytes = using(
    (arena) => _mapReadOnlyShared(path.toNativeUtf8(allocator: arena), length),
  );

  if (bytes == null) {
    throw FileSystemException('Could not map summary batch', path);
  }

  return bytes;
}

bool _hasSharedMappingSymbol() {
  try {
    var symbol = Native.addressOf<NativeFunction<_MapReadOnlyShared>>(
      _mapReadOnlyShared,
    );

    return symbol != nullptr;
  } on ArgumentError {
    // Older dart:io embedders do not export the mapping function.
    return false;
  }
}

@Native<_MapReadOnlyShared>(
  assetId: 'dart:io',
  symbol: 'File::MapReadOnlyShared',
)
external Uint8List? _mapReadOnlyShared(Pointer<Utf8> path, int length);

typedef _MapReadOnlyShared = Handle Function(Pointer<Utf8>, IntPtr);
