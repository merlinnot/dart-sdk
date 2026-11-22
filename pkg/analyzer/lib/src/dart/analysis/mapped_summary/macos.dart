// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final _close = _libSystem
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _dispatchDataCreate = _libSystem
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Size, Pointer<Void>, Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>, int, Pointer<Void>, Pointer<Void>)
    >('dispatch_data_create');
final _dispatchRelease = _libSystem.lookup<NativeFinalizerFunction>(
  'dispatch_release',
);
final _libSystem = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
final _lseek = _libSystem
    .lookupFunction<
      Int64 Function(Int32, Int64, Int32),
      int Function(int, int, int)
    >('lseek');
final _mmap = _libSystem
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Size, Int32, Int32, Int32, Int64),
      Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)
    >('mmap');
final _munmap = _libSystem
    .lookupFunction<
      Int32 Function(Pointer<Void>, Size),
      int Function(Pointer<Void>, int)
    >('munmap');
final _open = _libSystem
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32, VarArgs<()>),
      int Function(Pointer<Utf8>, int)
    >('open');
final _unmapDestructor = _libSystem
    .lookup<Pointer<Void>>('_dispatch_data_destructor_munmap')
    .value;

Uint8List mapSummaryFile(String path, int length) {
  if (length <= 0) {
    throw ArgumentError.value(length, 'length');
  }

  // Resolve the dispatch bindings before acquiring a mapping to clean up.
  var createDispatchData = _dispatchDataCreate;
  var releaseDispatchData = _dispatchRelease;
  var unmapDestructor = _unmapDestructor;
  var address = _mapReadOnlyFile(path, length);
  var owner = createDispatchData(address, length, nullptr, unmapDestructor);

  if (owner == nullptr) {
    _munmap(address, length);
    throw StateError('Could not own summary mapping');
  }

  // The typed data owns the dispatch object from here. Its finalizer
  // releases the object, which runs the destructor that unmaps the file.
  return address
      .cast<Uint8>()
      .asTypedList(length, finalizer: releaseDispatchData, token: owner)
      .asUnmodifiableView();
}

/// Returns a shared mapping of the file. The caller owns the mapping.
Pointer<Void> _mapReadOnlyFile(String path, int length) {
  const openReadOnly = 0;
  const openNonBlocking = 0x0004; // O_NONBLOCK on Darwin.
  const seekEnd = 2;
  const protectRead = 1;
  const mapShared = 1;
  var descriptor = using(
    (arena) => _open(
      path.toNativeUtf8(allocator: arena),
      openReadOnly | openNonBlocking,
    ),
  );

  if (descriptor < 0) {
    throw FileSystemException('Could not open summary batch', path);
  }

  try {
    if (_lseek(descriptor, 0, seekEnd) != length) {
      throw FileSystemException('Summary batch length mismatch', path);
    }

    var address = _mmap(nullptr, length, protectRead, mapShared, descriptor, 0);

    // mmap reports failure with MAP_FAILED, the pointer value -1.
    if (address == Pointer<Void>.fromAddress(-1)) {
      throw FileSystemException('Could not map summary batch', path);
    }

    return address;
  } finally {
    _close(descriptor);
  }
}
