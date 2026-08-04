// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings/bindings.dart' as raw;
import 'bindings/dart_bridge.dart';
import 'bindings/native_library.dart';
import 'native_strings.dart';

/// The Foundry Local core never performs HTTP itself. It decides what needs to
/// be downloaded — which manifest, which variant, which files, and what each
/// must hash to — and delegates the actual transfer through this transport.
///
/// **Why this contract is not optional.**
///
/// A model download is hundreds of megabytes to several gigabytes, so it must
/// survive the app being backgrounded — and only the platform's own background
/// download APIs can do that. A socket loop inside the runtime, or inside a
/// pure-Dart `HttpClient`, is suspended along with the process and then killed.
/// Delegating also means the app's certificate pinning, proxy configuration,
/// Android Network Security Config, per-app VPN routing and credential-refresh
/// logic all apply because the request goes through the app's own HTTP stack.
///
/// The default implementation ([DartHttpTransport]) uses `dart:io HttpClient`
/// and is correct for most flows, but it does not survive the app being
/// backgrounded. Long-running downloads should use a native background
/// transport wired through a method channel. See the README for details.
abstract class FlmTransport {
  /// Begin [request]. Must return immediately, having started the work
  /// elsewhere. Report progress with [reportProgress], deliver body bytes for
  /// in-memory requests with [reportBody], and always finish with
  /// [reportComplete] — even for cancelled and failed requests.
  ///
  /// Throwing from [send] is not correct: the core is already waiting for
  /// [reportComplete]. Report an error status through [reportComplete]
  /// instead.
  void send(FlmHttpRequest request);

  /// Cancel an in-flight request. [reportComplete] still needs to be called
  /// (with a non-2xx status) so the core's waiting job thread wakes up.
  void cancel(int requestId);
}

/// One transport request, copied out of the borrowed `flm_http_request` before
/// it is handed to Dart.
class FlmHttpRequest {
  const FlmHttpRequest({
    required this.requestId,
    required this.url,
    required this.method,
    required this.headers,
    required this.destinationPath,
    required this.offset,
    required this.expectedBytes,
  });

  /// Echoes back to every `reportProgress` / `reportBody` / `reportComplete`
  /// call, so the core can associate them with the right plan.
  final int requestId;

  final String url;

  /// `GET` or `HEAD`.
  final String method;

  /// Headers to attach to the request.
  final Map<String, String> headers;

  /// Absolute path to write the body to. NULL means deliver the bytes in
  /// memory via [FlmTransportReporter.reportBody].
  final String? destinationPath;

  /// When > 0, a resume offset. Send `Range: bytes=<offset>-` and **append**
  /// to the destination file rather than truncating it.
  final int offset;

  /// Expected body size, or `-1` when unknown.
  final int expectedBytes;
}

/// Static entry points on `flm_transport_report_*`. Transports call these to
/// report state back to the core. Safe from any thread.
abstract final class FlmTransportReporter {
  static void reportProgress(int requestId, int completedBytes, int totalBytes) {
    NativeLibrary.instance.bindings.flm_transport_report_progress(
      requestId,
      completedBytes,
      totalBytes,
    );
  }

  static void reportBody(int requestId, Uint8List data) {
    if (data.isEmpty) return;
    final ptr = calloc<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      NativeLibrary.instance.bindings.flm_transport_report_body(
        requestId,
        ptr.cast<Char>(),
        data.length,
      );
    } finally {
      calloc.free(ptr);
    }
  }

  /// Report request completion. **Must be called exactly once per request**,
  /// including cancelled and failed ones — the core blocks a job thread on
  /// this notification, so a missed call is a permanent hang.
  ///
  /// `statusCode` is the HTTP status, or 0 to signal a network error before a
  /// response was received (`errorMessage` describes it).
  static void reportComplete(
    int requestId, {
    required int statusCode,
    Map<String, String>? headers,
    String? errorMessage,
  }) {
    final headersJson =
        headers == null ? null : jsonEncode(headers);
    withNullableCString(headersJson, (headersPtr) {
      withNullableCString(errorMessage, (errorPtr) {
        NativeLibrary.instance.bindings.flm_transport_report_complete(
          requestId,
          statusCode,
          headersPtr,
          errorPtr,
        );
      });
    });
  }
}

/// Installs a Dart transport into the core.
///
/// Only one transport is active at a time. Installing a new one replaces the
/// old. The returned [TransportRegistration] must be kept alive for as long as
/// the transport is installed — closing it clears the transport and releases
/// the underlying `NativeCallable.listener`s.
class TransportRegistration {
  TransportRegistration._({
    required this.transport,
    required Pointer<FlmDartBridgeCtx> ctxPtr,
    required NativeCallable<Void Function(Pointer<raw.flm_http_request>, Pointer<Void>)>
        sendListener,
    required NativeCallable<Void Function(Uint64, Pointer<Void>)> cancelListener,
    required Pointer<raw.flm_transport> transportPtr,
  })  : _ctxPtr = ctxPtr,
        _sendListener = sendListener,
        _cancelListener = cancelListener,
        _transportPtr = transportPtr;

  final FlmTransport transport;
  final Pointer<FlmDartBridgeCtx> _ctxPtr;
  final NativeCallable<Void Function(Pointer<raw.flm_http_request>, Pointer<Void>)>
      _sendListener;
  final NativeCallable<Void Function(Uint64, Pointer<Void>)> _cancelListener;
  final Pointer<raw.flm_transport> _transportPtr;

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final bindings = NativeLibrary.instance.bindings;
    bindings.flm_set_transport(nullptr);
    _sendListener.close();
    _cancelListener.close();
    calloc.free(_ctxPtr);
    calloc.free(_transportPtr);
  }
}

/// Install [transport] and return its [TransportRegistration].
TransportRegistration installTransport(FlmTransport transport) {
  final bindings = NativeLibrary.instance.bindings;

  final ctxPtr = calloc<FlmDartBridgeCtx>();
  ctxPtr.ref.version = 1;
  ctxPtr.ref.on_progress = nullptr;
  ctxPtr.ref.on_delta = nullptr;
  ctxPtr.ref.user_data = nullptr;

  final sendListener = NativeCallable<
      Void Function(Pointer<raw.flm_http_request>,
          Pointer<Void>)>.listener((Pointer<raw.flm_http_request> ptr, Pointer<Void> _) {
    if (ptr == nullptr) return;
    final r = ptr.ref;
    Map<String, String> headers = const <String, String>{};
    if (r.headers_json != nullptr) {
      final s = cStringToDart(r.headers_json);
      if (s.isNotEmpty) {
        try {
          final decoded = jsonDecode(s);
          if (decoded is Map) {
            headers = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
          }
        } on FormatException {
          headers = const <String, String>{};
        }
      }
    }
    final request = FlmHttpRequest(
      requestId: r.request_id,
      url: cStringToDart(r.url),
      method: cStringToDart(r.method),
      headers: headers,
      destinationPath:
          r.destination_path == nullptr ? null : cStringToDart(r.destination_path),
      offset: r.offset,
      expectedBytes: r.expected_bytes,
    );
    try {
      transport.send(request);
    } catch (e, st) {
      // A synchronous throw would leave the core waiting forever, so translate
      // to an immediate report_complete instead.
      FlmTransportReporter.reportComplete(
        request.requestId,
        statusCode: 0,
        errorMessage: 'transport.send threw: $e\n$st',
      );
    }
  });

  ctxPtr.ref.on_send = sendListener.nativeFunction;

  final cancelListener =
      NativeCallable<Void Function(Uint64, Pointer<Void>)>.listener(
    (int requestId, Pointer<Void> _) {
      try {
        transport.cancel(requestId);
      } catch (_) {
        // Best-effort. The transport should still report_complete.
      }
    },
  );

  final transportPtr = calloc<raw.flm_transport>();
  transportPtr.ref.version = 1;
  transportPtr.ref.send = DartBridge.sendAdapter();
  transportPtr.ref.cancel = cancelListener.nativeFunction;
  transportPtr.ref.user_data = ctxPtr.cast<Void>();

  final status = bindings.flm_set_transport(transportPtr);
  if (status != raw.FlmStatus.ok) {
    sendListener.close();
    cancelListener.close();
    calloc.free(ctxPtr);
    calloc.free(transportPtr);
    throw StateError(
        'flm_set_transport failed with status $status; another transport may already be installed.');
  }

  return TransportRegistration._(
    transport: transport,
    ctxPtr: ctxPtr,
    sendListener: sendListener,
    cancelListener: cancelListener,
    transportPtr: transportPtr,
  );
}

// -----------------------------------------------------------------------------
// Default implementation
// -----------------------------------------------------------------------------

/// Reference transport that speaks HTTP via `dart:io` `HttpClient`.
///
/// **Backgrounding caveat.** On mobile a socket loop running inside the app's
/// process is suspended when the app is backgrounded and eventually killed. A
/// multi-gigabyte model download started here will not survive that; the core
/// resumes from the byte offset on next launch, so no data is lost, but the
/// user has to bring the app to the foreground again for progress to happen.
///
/// For always-on downloads, ship a platform-native transport instead
/// (WorkManager / `URLSession` background sessions) and install it in place of
/// this one during app startup. The Kotlin/Swift bindings do exactly that in
/// their default transports.
class DartHttpTransport implements FlmTransport {
  DartHttpTransport({HttpClient? client})
      : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 30);
    _client.idleTimeout = const Duration(seconds: 30);
  }

  final HttpClient _client;
  final Map<int, _InFlight> _requests = <int, _InFlight>{};

  @override
  void send(FlmHttpRequest request) {
    // Fire and forget; the returned future writes bytes to disk or memory and
    // reports completion through the reporter. Errors surface via
    // reportComplete, so we swallow them here.
    unawaited(_run(request));
  }

  @override
  void cancel(int requestId) {
    final inFlight = _requests[requestId];
    inFlight?.cancelled = true;
    inFlight?.subscription?.cancel();
  }

  Future<void> _run(FlmHttpRequest request) async {
    final inFlight = _InFlight();
    _requests[request.requestId] = inFlight;

    HttpClientRequest? httpRequest;
    HttpClientResponse? response;
    IOSink? sink;
    var reported = false;

    void reportOnce({
      required int statusCode,
      Map<String, String>? headers,
      String? errorMessage,
    }) {
      if (reported) return;
      reported = true;
      _requests.remove(request.requestId);
      FlmTransportReporter.reportComplete(
        request.requestId,
        statusCode: statusCode,
        headers: headers,
        errorMessage: errorMessage,
      );
    }

    try {
      final uri = Uri.parse(request.url);
      httpRequest = await _client.openUrl(request.method, uri);

      request.headers.forEach((name, value) {
        // dart:io removes some hop-by-hop headers itself; anything else we
        // pass through untouched.
        httpRequest!.headers.set(name, value);
      });

      if (request.offset > 0) {
        // Contract: when offset > 0, append rather than truncate, and send a
        // Range header. This is what makes downloads resumable across
        // restarts of the app.
        httpRequest.headers.set('Range', 'bytes=${request.offset}-');
      }

      response = await httpRequest.close();

      final status = response.statusCode;
      final respHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        respHeaders[name] = values.join(', ');
      });

      // For a HEAD request there is no body; report immediately.
      if (request.method.toUpperCase() == 'HEAD') {
        // Drain the response to release the connection back to the pool.
        await response.drain<void>();
        reportOnce(statusCode: status, headers: respHeaders);
        return;
      }

      if (status >= 400) {
        // Consume the body but do not deliver it — the core just needs the
        // failure status. Attach the drained bytes to the error message when
        // small enough to be useful.
        final body = await response
            .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
        final preview = utf8.decode(body, allowMalformed: true);
        reportOnce(
          statusCode: status,
          headers: respHeaders,
          errorMessage: preview.length > 512
              ? preview.substring(0, 512)
              : preview,
        );
        return;
      }

      final total = response.contentLength >= 0
          ? response.contentLength
          : request.expectedBytes;
      var completed = 0;

      if (request.destinationPath != null) {
        final file = File(request.destinationPath!);
        await file.parent.create(recursive: true);
        // Append for resumed downloads (offset > 0), truncate otherwise. This
        // matters — a Range-based resume that then truncates the file would
        // start over from scratch.
        final mode = request.offset > 0 ? FileMode.append : FileMode.write;
        sink = file.openWrite(mode: mode);
        completed = request.offset;

        final completer = Completer<void>();
        inFlight.subscription = response.listen(
          (chunk) {
            sink!.add(chunk);
            completed += chunk.length;
            FlmTransportReporter.reportProgress(
              request.requestId,
              completed,
              total,
            );
          },
          onDone: () => completer.complete(),
          onError: completer.completeError,
          cancelOnError: true,
        );

        try {
          await completer.future;
        } finally {
          await sink.flush();
          await sink.close();
        }
      } else {
        // In-memory delivery. Stream chunks so we never build a giant
        // Uint8List for a manifest that turns out to be a package binary.
        final completer = Completer<void>();
        inFlight.subscription = response.listen(
          (chunk) {
            final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
            FlmTransportReporter.reportBody(request.requestId, bytes);
            completed += chunk.length;
            FlmTransportReporter.reportProgress(
              request.requestId,
              completed,
              total,
            );
          },
          onDone: () => completer.complete(),
          onError: completer.completeError,
          cancelOnError: true,
        );
        await completer.future;
      }

      if (inFlight.cancelled) {
        reportOnce(
          statusCode: 499, // "client closed request" (nginx convention).
          headers: respHeaders,
          errorMessage: 'cancelled',
        );
      } else {
        reportOnce(statusCode: status, headers: respHeaders);
      }
    } on HttpException catch (e) {
      reportOnce(statusCode: 0, errorMessage: e.message);
    } on SocketException catch (e) {
      reportOnce(statusCode: 0, errorMessage: e.message);
    } catch (e, st) {
      reportOnce(statusCode: 0, errorMessage: 'transport failed: $e\n$st');
    }
  }

  /// Release the underlying [HttpClient]. Any in-flight requests are cancelled.
  void close() {
    for (final r in _requests.values) {
      r.cancelled = true;
      r.subscription?.cancel();
    }
    _requests.clear();
    _client.close(force: true);
  }
}

class _InFlight {
  bool cancelled = false;
  StreamSubscription<List<int>>? subscription;
}
