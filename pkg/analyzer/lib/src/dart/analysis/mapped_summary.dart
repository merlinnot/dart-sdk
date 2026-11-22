// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final _close = _sys.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _destructor = _sys
    .lookup<Pointer<Void>>('_dispatch_data_destructor_munmap')
    .value;
final _dispatchDataCreate = _sys
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Size, Pointer<Void>, Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>, int, Pointer<Void>, Pointer<Void>)
    >('dispatch_data_create');
final _map = _sys
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Size, Int32, Int32, Int32, Int64),
      Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)
    >('mmap');
final _open = _sys
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32, VarArgs<()>),
      int Function(Pointer<Utf8>, int)
    >('open');
final _release = _sys.lookup<NativeFinalizerFunction>('dispatch_release');
final _seek = _sys
    .lookupFunction<
      Int64 Function(Int32, Int64, Int32),
      int Function(int, int, int)
    >('lseek');
// Darwin owns the mapping through a dispatch_data_t. The external typed
// list and all its subviews keep that object alive, even after unlink.
final _sys = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
final _unmap = _sys
    .lookupFunction<
      Int32 Function(Pointer<Void>, Size),
      int Function(Pointer<Void>, int)
    >('munmap');

/// Maps a read-only Darwin arena. Derived views retain the dispatch owner.
Uint8List mapSummaryFile(String path, int length) {
  if (length <= 0) throw ArgumentError.value(length);
  // Resolve the finalizer before taking ownership of a native resource.
  var createOwner = _dispatchDataCreate;
  var release = _release;
  var destructor = _destructor;
  const openReadOnly = 0;
  const seekEnd = 2;
  const protRead = 1;
  const mapShared = 1;
  var fd = using(
    (arena) => _open(path.toNativeUtf8(allocator: arena), openReadOnly),
  );
  if (fd < 0) throw FileSystemException('Could not open summary batch', path);
  late Pointer<Void> ptr;
  try {
    if (_seek(fd, 0, seekEnd) != length) {
      throw FileSystemException('Summary batch length mismatch', path);
    }
    ptr = _map(nullptr, length, protRead, mapShared, fd, 0);
  } finally {
    _close(fd);
  }
  if (ptr.address == Pointer<Void>.fromAddress(-1).address) {
    throw FileSystemException('Could not map summary batch', path);
  }
  var owner = createOwner(ptr, length, nullptr, destructor);
  if (owner == nullptr) {
    _unmap(ptr, length);
    throw StateError('Could not own summary mapping');
  }
  return ptr
      .cast<Uint8>()
      .asTypedList(length, finalizer: release, token: owner)
      .asUnmodifiableView();
}
