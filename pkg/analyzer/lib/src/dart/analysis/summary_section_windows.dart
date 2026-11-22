// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Opens the backing file exclusively and publishes the name of the section.
/// Both sides use mapped views so writes are coherent with existing readers.
(void Function(Uint8List, int), void Function()) createSummarySection(
  File descriptor,
  int capacity,
) {
  var random = Random.secure();
  var id = base64Url.encode(List.generate(18, (_) => random.nextInt(256)));
  var name = 'Local\\DartAnalyzerSummary-$id';
  var backing = '${Directory.systemTemp.path}/dart-analysis-$id.tmp';
  return using((arena) {
    var out = arena<Pointer<Uint8>>();
    var section = _create(
      backing.toNativeUtf8(allocator: arena),
      name.toNativeUtf8(allocator: arena),
      capacity,
      out,
    );
    if (section == nullptr) {
      throw FileSystemException(
        'Could not create summary section',
        descriptor.path,
      );
    }
    var address = out.value;
    late _Section writer;
    try {
      writer = _Section(section, address.asTypedList(capacity));
    } catch (_) {
      _close(section);
      rethrow;
    }
    try {
      descriptor.writeAsStringSync(jsonEncode([capacity, name]));
      return (writer.write, writer.close);
    } catch (_) {
      writer.close();
      rethrow;
    }
  });
}

@Native<Void Function(Pointer<Void>)>(
  assetId: 'dart:io',
  symbol: 'File::CloseSharedSection',
)
external void _close(Pointer<Void> owner);

@Native<
  Pointer<Void> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    IntPtr,
    Pointer<Pointer<Uint8>>,
  )
>(assetId: 'dart:io', symbol: 'File::CreateSharedSection')
external Pointer<Void> _create(
  Pointer<Utf8> path,
  Pointer<Utf8> name,
  int length,
  Pointer<Pointer<Uint8>> address,
);

final class _Section implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFinalizerFunction>(_close),
  );
  final Pointer<Void> _owner;
  final Uint8List _bytes;
  new(this._owner, this._bytes) {
    _finalizer.attach(this, _owner, detach: this);
  }

  void close() {
    _finalizer.detach(this);
    _close(_owner);
  }

  void write(Uint8List value, int offset) {
    _bytes.setRange(offset, offset + value.length, value);
  }
}
