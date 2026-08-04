// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Owning C string allocated with `calloc`. Must be freed by the caller.
///
/// Uses null-terminated UTF-8. Prefer [withCString] instead of calling this
/// directly, so the pointer is always freed on the exception path.
Pointer<Char> stringToNative(String s, {Allocator allocator = calloc}) {
  final bytes = utf8.encode(s);
  final ptr = allocator.allocate<Uint8>(bytes.length + 1);
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  ptr[bytes.length] = 0;
  return ptr.cast<Char>();
}

/// Read a null-terminated C string that the C ABI owns for the duration of
/// this call (log messages, error strings, borrowed callback fields).
String cStringToDart(Pointer<Char> ptr) {
  if (ptr == nullptr) return '';
  final bytes = ptr.cast<Uint8>();
  var length = 0;
  while (bytes[length] != 0) {
    length++;
  }
  return utf8.decode(bytes.asTypedList(length));
}

/// Read an out-parameter C string owned by the caller. The pointer is freed
/// with [freeOutString].
String takeOutString(Pointer<Char> ptr) {
  if (ptr == nullptr) return '';
  final bytes = ptr.cast<Uint8>();
  var length = 0;
  while (bytes[length] != 0) {
    length++;
  }
  return utf8.decode(Uint8List.fromList(bytes.asTypedList(length)));
}

/// Run [body] with a native UTF-8 copy of [s], freeing it before returning.
T withCString<T>(String s, T Function(Pointer<Char>) body,
    {Allocator allocator = calloc}) {
  final ptr = stringToNative(s, allocator: allocator);
  try {
    return body(ptr);
  } finally {
    allocator.free(ptr);
  }
}

/// Nullable version of [withCString].
T withNullableCString<T>(String? s, T Function(Pointer<Char>) body,
    {Allocator allocator = calloc}) {
  if (s == null) return body(nullptr);
  return withCString(s, body, allocator: allocator);
}
