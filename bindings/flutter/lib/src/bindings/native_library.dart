// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:ffi';
import 'dart:io';

import 'bindings.dart';

/// Resolves the platform-appropriate shared library and gives every other file in the
/// package a shared [FlmBindings] instance.
///
/// The runtime is `libfoundry_local_mobile`:
///   * Android — packaged inside the AAR under `jniLibs/<abi>/`; `DynamicLibrary.open`
///     with a bare filename lets the OS find it in the app's `nativeLibraryDir`.
///   * iOS — statically linked into the app binary (see `foundry_local_mobile.podspec`),
///     so the symbols are already in the process image and we look them up through
///     `DynamicLibrary.process()`. iOS refuses to load dynamic shared libraries that
///     are not part of the bundle.
///   * macOS — same shape as iOS, statically linked into the .app.
///   * Linux/Windows — used only by the Dart test host and `flutter test`; the
///     library is expected next to the executable.
class NativeLibrary {
  NativeLibrary._(this.dylib) : bindings = FlmBindings(dylib);

  static NativeLibrary? _instance;

  /// The raw DynamicLibrary. Exposed so the shim adapter layer can look up the
  /// `flm_dart_bridge_*` trampolines embedded in the native core.
  final DynamicLibrary dylib;

  /// Handle onto the raw FFI bindings. Never null after [instance] has been read.
  final FlmBindings bindings;

  /// Convenience accessor for the DynamicLibrary. Equivalent to
  /// `NativeLibrary.instance.dylib`.
  static DynamicLibrary get process => instance.dylib;

  /// Lazily open the runtime library the first time it is needed.
  ///
  /// Safe to call from any isolate. The `DynamicLibrary` handle is process-global,
  /// so opening it a second time from a background isolate is cheap and matches the
  /// original.
  static NativeLibrary get instance {
    return _instance ??= NativeLibrary._(_open());
  }

  /// Test / integration hook. Callers that already opened the library themselves (or
  /// linked it statically into a host executable) can inject an alternate lookup.
  static void overrideForTesting(DynamicLibrary library) {
    _instance = NativeLibrary._(library);
  }

  static DynamicLibrary _open() {
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libfoundry_local_mobile.so');
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open('libfoundry_local_mobile.so');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('foundry_local_mobile.dll');
    }
    throw UnsupportedError(
        'Foundry Local Mobile is not supported on ${Platform.operatingSystem}.');
  }
}
