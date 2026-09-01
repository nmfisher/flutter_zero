// FFI surface of the macOS capture shim.
//
// The shim is a small Objective-C dylib built by this package's native
// assets hook (see `hook/build.dart`). On macOS the symbols resolve from
// the code asset declared below; on every other platform the hook emits
// no asset and nothing here is ever called.
//
// Design notes:
//
//  * Permission is requested through a callback, not a return value, so
//    the window keeps drawing while the system dialog is up.
//  * Frames are polled, not pushed. The render loop already runs at or
//    above the camera rate, and polling makes newest-wins fall out for
//    free: `wc_get_newest_frame` simply returns whichever buffer filled
//    last (§2.4, "frames drop, never queue").
//  * The buffer pool is allocated by Dart and handed to the shim once at
//    start, so the capture path allocates nothing per frame (§5.2).
//
// The snake_case names mirror the C symbols one-for-one, as usual for
// hand-written bindings.
@ffi.DefaultAsset('package:flutter_zero_webcam_depth/webcam_depth_capture.dart')
library;

// ignore_for_file: non_constant_identifier_names

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as pkg_ffi;

/// Buffer index returned when no new frame has arrived.
const int wcNoNewFrame = -1;

/// `wc_request_permission_async` result codes.
abstract final class WcPermission {
  static const granted = 0;
  static const denied = 1;
  static const deniedPreviously = 2;
  static const error = 3;
}

/// `wc_start` result codes.
abstract final class WcStart {
  static const ok = 0;
  static const errNoDevice = 1;
  static const errConfiguration = 2;
  static const errPermission = 3;
  static const errAllocation = 4;
  static const errAlreadyRunning = 5;
}

/// `void (*)(int32_t result, void* context)`
typedef WcPermissionCallbackNative =
    ffi.Void Function(ffi.Int32 result, ffi.Pointer<ffi.Void> context);

@ffi.Native<
    ffi.Void Function(
      ffi.Pointer<ffi.NativeFunction<WcPermissionCallbackNative>>,
      ffi.Pointer<ffi.Void>,
    )>()
external void wc_request_permission_async(
  ffi.Pointer<ffi.NativeFunction<WcPermissionCallbackNative>> callback,
  ffi.Pointer<ffi.Void> context,
);

/// Starts capture, filling [buffers] round-robin.
///
/// [bufferBytes] must be at least `bytesPerRow * height` for the
/// negotiated format, which is written to the out params. Returns one of
/// [WcStart].
@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Int32>,
    )>()
external int wc_start(
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> buffers,
  int bufferCount,
  int bufferBytes,
  ffi.Pointer<ffi.Int32> outWidth,
  ffi.Pointer<ffi.Int32> outHeight,
  ffi.Pointer<ffi.Int32> outFramesPerSecond,
  ffi.Pointer<ffi.Int32> outBytesPerRow,
);

/// Index of the newest completed buffer, or [wcNoNewFrame].
///
/// [outTimestampUs] receives the camera presentation timestamp of that
/// frame — the origin of the glass-to-glass measurement.
@ffi.Native<ffi.Int32 Function(ffi.Pointer<ffi.Int64>)>()
external int wc_get_newest_frame(ffi.Pointer<ffi.Int64> outTimestampUs);

/// Frames discarded by the shim because no pool buffer was free.
@ffi.Native<ffi.Int64 Function()>()
external int wc_get_dropped_frames();

/// Frames delivered to the shim's callback since `wc_start`.
@ffi.Native<ffi.Int64 Function()>()
external int wc_get_frame_count();

/// Hands a held buffer back to the capture callback.
@ffi.Native<ffi.Void Function(ffi.Int32)>()
external void wc_release_frame(int index);

/// Stops the session. Buffers may be freed after this returns.
@ffi.Native<ffi.Void Function()>()
external void wc_stop();

/// Detail for the last failed `wc_start`, for the error screen.
@ffi.Native<ffi.Pointer<pkg_ffi.Utf8> Function()>()
external ffi.Pointer<pkg_ffi.Utf8> wc_last_error();

/// Reads [pointer] as a Dart string, tolerating a null pointer.
String? readNativeString(ffi.Pointer<pkg_ffi.Utf8> pointer) {
  if (pointer == ffi.nullptr) return null;
  return pointer.toDartString();
}
