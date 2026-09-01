import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;

import 'camera_frame.dart';
import 'camera_source.dart';
import 'capture_bindings.dart';

/// Number of pooled frame buffers handed to the capture shim.
///
/// Three is the smallest pool that never starves the capture callback at
/// display-rate consumption: one being filled, one complete and unread,
/// one being uploaded. If all three are outstanding the callback drops
/// the frame rather than queueing it, which is the intended behaviour.
const int _kBufferCount = 3;

/// [CameraSource] backed by the Objective-C capture shim.
///
/// The shim owns `AVCaptureSession`; this class owns the buffer pool and
/// translates the C surface into [CameraFrame]s. One `malloc` per buffer
/// happens at [start], and nothing allocates again until [stop].
class NativeCameraSource implements CameraSource {
  NativeCameraSource();

  @override
  bool get isSupported => true;

  CameraFormat? _format;

  @override
  CameraFormat? get format => _format;

  @override
  int get supersededFrames {
    if (!_running) return _droppedAtStop;
    // The shim counts every frame it discarded because no buffer was
    // free — which is exactly a frame the consumer never saw.
    return wc_get_dropped_frames();
  }

  /// Drop count at the moment capture stopped, so the counter stays
  /// readable after teardown.
  int _droppedAtStop = 0;

  final List<ffi.Pointer<ffi.Uint8>> _buffers = [];
  final List<Uint8List> _views = [];
  final List<bool> _outstanding = [];
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> _bufferArray = ffi.nullptr;

  int _bufferBytes = 0;
  bool _running = false;
  int _lastReleasedIndex = 0;

  /// Resolves once the permission callback fires.
  Completer<int>? _permissionCompleter;
  ffi.NativeCallable<WcPermissionCallbackNative>? _permissionCallable;

  @override
  Future<CameraStartResult> start() async {
    final permission = await _requestPermission();
    switch (permission) {
      case WcPermission.granted:
        break;
      case WcPermission.denied:
        return const CameraStartResult.failed(CameraUnavailableReason.denied);
      case WcPermission.deniedPreviously:
        return const CameraStartResult.failed(
          CameraUnavailableReason.deniedPreviously,
        );
      default:
        return CameraStartResult.failed(
          CameraUnavailableReason.unknown,
          'Permission request returned code $permission.',
        );
    }

    return _startSession();
  }

  Future<int> _requestPermission() async {
    _permissionCompleter = Completer<int>();
    _permissionCallable?.close();
    _permissionCallable =
        ffi.NativeCallable<WcPermissionCallbackNative>.listener((
      int result,
      ffi.Pointer<ffi.Void> context,
    ) {
      final completer = _permissionCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(result);
      }
    });

    wc_request_permission_async(
      _permissionCallable!.nativeFunction,
      ffi.nullptr,
    );
    return _permissionCompleter!.future;
  }

  CameraStartResult _startSession() {
    if (_running) {
      return const CameraStartResult.failed(
        CameraUnavailableReason.configurationFailed,
        'Capture already running.',
      );
    }

    // Sized for 1080p BGRA, the largest format the shim will negotiate
    // (it skips anything above 1080p), and the shim drops rather than
    // truncates if a frame ever arrives larger than this. Three buffers
    // is ~25 MB held for the lifetime of the session.
    const provisionalBytes = 1920 * 1080 * 4;
    _bufferBytes = provisionalBytes;

    final width = pkg_ffi.calloc<ffi.Int32>();
    final height = pkg_ffi.calloc<ffi.Int32>();
    final fps = pkg_ffi.calloc<ffi.Int32>();
    final bytesPerRow = pkg_ffi.calloc<ffi.Int32>();
    final timestamp = pkg_ffi.calloc<ffi.Int32>();

    try {
      for (var i = 0; i < _kBufferCount; i++) {
        final buffer = pkg_ffi.malloc<ffi.Uint8>(_bufferBytes);
        if (buffer == ffi.nullptr) {
          _freePool();
          return const CameraStartResult.failed(
            CameraUnavailableReason.configurationFailed,
            'Frame buffer allocation failed.',
          );
        }
        _buffers.add(buffer);
        _views.add(buffer.asTypedList(_bufferBytes));
        _outstanding.add(false);
      }

      _bufferArray = pkg_ffi.calloc<ffi.Pointer<ffi.Uint8>>(_kBufferCount);
      for (var i = 0; i < _kBufferCount; i++) {
        _bufferArray[i] = _buffers[i];
      }

      final status = wc_start(
        _bufferArray,
        _kBufferCount,
        _bufferBytes,
        width,
        height,
        fps,
        bytesPerRow,
      );

      if (status != WcStart.ok) {
        final detail = readNativeString(wc_last_error());
        _freePool();
        return CameraStartResult.failed(_reasonFor(status), detail);
      }

      final w = width.value;
      final h = height.value;
      final stride = bytesPerRow.value;
      final needed = stride * h;
      if (needed > _bufferBytes) {
        _freePool();
        return CameraStartResult.failed(
          CameraUnavailableReason.configurationFailed,
          'Negotiated format ${w}x$h needs $needed bytes, pool holds '
          '$_bufferBytes.',
        );
      }

      _format = CameraFormat(
        width: w,
        height: h,
        framesPerSecond: fps.value,
        layout: PixelLayout.rgba8,
        bytesPerRow: stride,
      );
      _running = true;
      _lastReleasedIndex = 0;
      return CameraStartResult.granted(_format!);
    } finally {
      pkg_ffi.calloc
        ..free(width)
        ..free(height)
        ..free(fps)
        ..free(bytesPerRow)
        ..free(timestamp);
    }
  }

  CameraUnavailableReason _reasonFor(int status) => switch (status) {
        WcStart.errNoDevice => CameraUnavailableReason.noDevice,
        WcStart.errConfiguration => CameraUnavailableReason.configurationFailed,
        WcStart.errPermission => CameraUnavailableReason.denied,
        _ => CameraUnavailableReason.unknown,
      };

  @override
  CameraFrame? takeFrame() {
    if (!_running) return null;

    final timestamp = pkg_ffi.calloc<ffi.Int64>();
    int index;
    int timestampUs;
    try {
      index = wc_get_newest_frame(timestamp);
      timestampUs = timestamp.value;
    } finally {
      pkg_ffi.calloc.free(timestamp);
    }
    if (index == wcNoNewFrame || index < 0 || index >= _kBufferCount) {
      return null;
    }

    final format = _format!;
    _outstanding[index] = true;
    return CameraFrame(
      pixels: _views[index],
      width: format.width,
      height: format.height,
      bytesPerRow: format.effectiveBytesPerRow,
      timestampUs: timestampUs,
      layout: format.layout,
      onRelease: () => _release(index),
    );
  }

  void _release(int index) {
    if (index < 0 || index >= _kBufferCount) return;
    if (!_outstanding[index]) return;
    _outstanding[index] = false;
    _lastReleasedIndex = index;
    if (_running) {
      wc_release_frame(index);
    }
  }

  void _freePool() {
    for (final buffer in _buffers) {
      pkg_ffi.malloc.free(buffer);
    }
    _buffers.clear();
    _views.clear();
    _outstanding.clear();
    if (_bufferArray != ffi.nullptr) {
      pkg_ffi.calloc.free(_bufferArray);
      _bufferArray = ffi.nullptr;
    }
  }

  @override
  Future<void> stop() async {
    if (_running) {
      _droppedAtStop = wc_get_dropped_frames();
      _running = false;
      wc_stop();
      _format = null;
    }
    _permissionCallable?.close();
    _permissionCallable = null;
    _permissionCompleter = null;
    _freePool();
  }

  /// Index most recently handed back to the shim; exposed for diagnostics.
  int get lastReleasedIndex => _lastReleasedIndex;
}
