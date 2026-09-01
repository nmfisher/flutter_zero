// Objective-C capture shim for examples/webcam_depth.
//
// Wraps AVCaptureSession and fills a caller-owned buffer pool with BGRA
// frames. Phase 1 of the design doc: capture + pass-through, no model.
//
// Threading: the sample-buffer callback runs on a private serial dispatch
// queue; the wc_* entry points are called from the Dart isolate thread.
// All pool state is therefore atomic, and handover uses compare-and-
// exchange so a buffer can never be overwritten while Dart is reading it.
//
// Frame policy (design doc §2.4/§5.2): frames drop, never queue. A frame
// that arrives when every buffer is held is discarded and counted, and
// `alwaysDiscardsLateVideoFrames` keeps AVFoundation itself from building
// a backlog.

#import "webcam_depth_capture.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <os/log.h>
#import <os/signpost.h>
#import <stdatomic.h>
#include <time.h>

// ---------------------------------------------------------------------------
// Pool state
// ---------------------------------------------------------------------------

// Buffer is free for the capture callback.
static const int kStateFree = 0;
// Buffer holds a complete frame nobody has read yet.
static const int kStateFull = 1;
// Buffer is held by the Dart side.
static const int kStateHeld = 2;

static uint8_t *_buffers[WC_MAX_BUFFERS];
static atomic_int _state[WC_MAX_BUFFERS];
// Presentation timestamp for each buffer. Written before a buffer is
// marked FULL and read after Dart observes it FULL, so no lock is needed.
static int64_t _timestamps[WC_MAX_BUFFERS];
static int32_t _bufferCount = 0;
static int32_t _bufferBytes = 0;

// Index of the most recently completed buffer, -1 until the first frame.
static atomic_int _newestIndex;
// Index most recently handed to Dart, so "new" means "newer than this".
static atomic_int _deliveredIndex;

static atomic_bool _running;
static atomic_llong _frameCount;
static atomic_llong _droppedFrames;

static AVCaptureSession *_session = nil;
static dispatch_queue_t _captureQueue = nil;
static id _outputDelegate = nil;

static char _lastError[256] = "no error";

// AVCapture presentation timestamps are host-time microseconds since boot
// (the mach_absolute_time clock). The Dart side measures latency with the
// Unix clock, so cache the boot -> Unix offset once per start and add it
// to every timestamp. Drift over one session is far below what a latency
// readout can resolve.
static int64_t _hostToUnixOffsetUs = 0;

static int64_t wc_host_to_unix_offset_us(void) {
  const int64_t hostUs =
      (int64_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000u);
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  const int64_t unixUs = (int64_t)now.tv_sec * 1000000 + now.tv_nsec / 1000;
  return unixUs - hostUs;
}

static os_log_t _wcLog = NULL;
static os_signpost_id_t _wcSignpostId = OS_SIGNPOST_ID_INVALID;
static const char *const kSignpostDelivery = "capture-delivery";
static const char *const kSignpostCopy = "buffer-copy";

static void wc_set_error(const char *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void wc_set_error(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  vsnprintf(_lastError, sizeof(_lastError), fmt, args);
  va_end(args);
  if (_wcLog != NULL) {
    os_log_error(_wcLog, "webcam_depth_capture: %{public}s", _lastError);
  }
}

// ---------------------------------------------------------------------------
// Device selection (design doc §2.2: built-in first, then external/UVC)
// ---------------------------------------------------------------------------

static AVCaptureDevice *wc_find_device(void) {
  NSMutableArray<AVCaptureDeviceType> *types =
      [NSMutableArray<AVCaptureDeviceType> array];
  [types addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
  // AVCaptureDeviceTypeExternal replaced ExternalUnknown in macOS 10.15.
  if (@available(macOS 10.15, *)) {
    [types addObject:AVCaptureDeviceTypeExternal];
  } else {
    [types addObject:AVCaptureDeviceTypeExternalUnknown];
  }

  AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:types
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];
  NSArray<AVCaptureDevice *> *devices = session.devices;
  if (devices.count == 0) {
    return nil;
  }

  // Prefer a built-in camera over an external one, keeping the discovery
  // order as the tie-break.
  for (AVCaptureDevice *device in devices) {
    if (device.position != AVCaptureDevicePositionUnspecified) {
      return device;
    }
  }
  return devices.firstObject;
}

// ---------------------------------------------------------------------------
// Sample buffer delegate
// ---------------------------------------------------------------------------

// Swizzles one BGRA pixel to RGBA in place, as a 32-bit word.
//
// thermion's upload API only offers PixelDataFormat.RGBA, but every macOS
// camera delivers BGRA. Rather than depend on camera-specific RGBA support
// we swap the outer two bytes of each 4-byte group and upload as RGBA.
//
//   little-endian word holding bytes [B,G,R,A] = A<<24 | R<<16 | G<<8 | B
//   keep A and G, move B into R's slot and R into B's slot
//   result: A<<24 | B<<16 | G<<8 | R = bytes [R,G,B,A]
//
// 4-byte misalignment is impossible: a BGRA stride is always a multiple of
// 4, and ARM64/x86-64 both tolerate unaligned loads regardless.
static inline uint32_t wc_bgra_to_rgba(const uint32_t bgra) {
  return (bgra & 0xFF00FF00u) | ((bgra & 0x000000FFu) << 16) |
         ((bgra & 0x00FF0000u) >> 16);
}

// Copies one row, swizzling BGRA -> RGBA as it goes.
static void wc_copy_row_swizzled(uint32_t *dst, const uint32_t *src,
                                 const size_t pixelCount) {
  for (size_t x = 0; x < pixelCount; x++) {
    dst[x] = wc_bgra_to_rgba(src[x]);
  }
}

@interface WCDepthCaptureDelegate
    : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation WCDepthCaptureDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  (void)output;
  (void)connection;

  if (!atomic_load(&_running)) {
    return;
  }

  os_signpost_interval_begin(_wcLog, _wcSignpostId, kSignpostDelivery);

  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (imageBuffer == NULL) {
    os_signpost_interval_end(_wcLog, _wcSignpostId, kSignpostDelivery);
    return;
  }

  const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  const int64_t timestampUs =
      (int64_t)(CMTimeGetSeconds(pts) * 1000000.0 + 0.5) +
      _hostToUnixOffsetUs;

  // Read-only: we only copy out of the buffer, never write into it.
  const CVReturn lockResult =
      CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
  if (lockResult != kCVReturnSuccess) {
    atomic_fetch_add(&_droppedFrames, 1);
    os_signpost_interval_end(_wcLog, _wcSignpostId, kSignpostDelivery);
    return;
  }

  const size_t srcWidth = CVPixelBufferGetWidth(imageBuffer);
  const size_t srcHeight = CVPixelBufferGetHeight(imageBuffer);
  const size_t srcStride = CVPixelBufferGetBytesPerRow(imageBuffer);
  uint8_t *const srcBase = (uint8_t *)CVPixelBufferGetBaseAddress(imageBuffer);

  if (CVPixelBufferIsPlanar(imageBuffer) || srcBase == NULL) {
    // BGRA is never planar; if we ever see a planar buffer here the video
    // settings were ignored, which is a configuration bug worth reporting.
    wc_set_error("unexpected planar or null-pixel capture buffer");
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    atomic_fetch_add(&_droppedFrames, 1);
    os_signpost_interval_end(_wcLog, _wcSignpostId, kSignpostDelivery);
    return;
  }

  os_signpost_interval_begin(_wcLog, _wcSignpostId, kSignpostCopy);

  // Claim a free buffer. The capture queue is serial so only one callback
  // is in flight, but Dart concurrently moves buffers between FREE and
  // HELD, hence the compare-and-exchange.
  int target = -1;
  for (int i = 0; i < _bufferCount; i++) {
    int expected = kStateFree;
    if (atomic_compare_exchange_strong(&_state[i], &expected, kStateHeld)) {
      target = i;
      break;
    }
  }

  if (target < 0) {
    // Every buffer is held or already full: drop, never queue.
    atomic_fetch_add(&_droppedFrames, 1);
  } else {
    const size_t packedStride = srcWidth * 4;
    const size_t packedSize = packedStride * srcHeight;
    uint8_t *const dst = _buffers[target];

    if (packedSize <= (size_t)_bufferBytes) {
      // Always swizzles BGRA -> RGBA while copying (see
      // wc_bgra_to_rgba), so the pool holds upload-ready RGBA either way.
      uint32_t *const dstRow = (uint32_t *)dst;
      for (size_t y = 0; y < srcHeight; y++) {
        wc_copy_row_swizzled(
            dstRow + y * srcWidth,
            (const uint32_t *)(srcBase + y * srcStride), srcWidth);
      }
      _timestamps[target] = timestampUs;
      atomic_store(&_newestIndex, target);
      atomic_store(&_state[target], kStateFull);
      atomic_fetch_add(&_frameCount, 1);
    } else {
      wc_set_error("frame %zux%zu needs %zu bytes, pool holds %d", srcWidth,
                   srcHeight, packedSize, _bufferBytes);
      atomic_store(&_state[target], kStateFree);
      atomic_fetch_add(&_droppedFrames, 1);
    }
  }

  os_signpost_interval_end(_wcLog, _wcSignpostId, kSignpostCopy);
  os_signpost_interval_end(_wcLog, _wcSignpostId, kSignpostDelivery);

  CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}

@end

// ---------------------------------------------------------------------------
// Permission
// ---------------------------------------------------------------------------

// Invokes the Dart callback on a background queue. NativeCallable.listener
// is safe to call from any thread, and the hop keeps us off whatever queue
// AVFoundation happens to call the completion handler on.
static void wc_report_permission(int32_t result,
                                 void (*callback)(int32_t, void *),
                                 void *context) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    callback(result, context);
  });
}

void wc_request_permission_async(
    void (*callback)(int32_t result, void *context), void *context) {
  if (callback == NULL) {
    return;
  }

  switch (
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
    case AVAuthorizationStatusAuthorized:
      wc_report_permission(WC_PERMISSION_GRANTED, callback, context);
      return;
    case AVAuthorizationStatusDenied:
    case AVAuthorizationStatusRestricted:
      wc_report_permission(WC_PERMISSION_DENIED_PREVIOUSLY, callback, context);
      return;
    case AVAuthorizationStatusNotDetermined:
      break;
  }

  [AVCaptureDevice
      requestAccessForMediaType:AVMediaTypeVideo
              completionHandler:^(BOOL granted) {
                wc_report_permission(
                    granted ? WC_PERMISSION_GRANTED : WC_PERMISSION_DENIED,
                    callback, context);
              }];
}

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------

int32_t wc_start(uint8_t **buffers, int32_t buffer_count, int32_t buffer_bytes,
                 int32_t *out_width, int32_t *out_height,
                 int32_t *out_frames_per_second, int32_t *out_bytes_per_row) {
  if (buffers == NULL || buffer_count <= 0 || buffer_count > WC_MAX_BUFFERS ||
      buffer_bytes <= 0) {
    wc_set_error("wc_start: invalid pool arguments");
    return WC_START_ERR_CONFIGURATION;
  }
  if (atomic_load(&_running)) {
    wc_set_error("wc_start: capture already running");
    return WC_START_ERR_ALREADY_RUNNING;
  }

  if (_wcLog == NULL) {
    _wcLog = os_log_create("dev.flutterzero.webcam-depth", "capture");
    _wcSignpostId = os_signpost_id_generate(_wcLog);
  }

  @try {
    AVCaptureDevice *device = wc_find_device();
    if (device == nil) {
      wc_set_error("no capture device found");
      return WC_START_ERR_NO_DEVICE;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input =
        [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input == nil) {
      wc_set_error("deviceInputWithDevice failed: %s",
                   error.localizedDescription.UTF8String ?: "unknown");
      return WC_START_ERR_CONFIGURATION;
    }

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.videoSettings = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    };
    output.alwaysDiscardsLateVideoFrames = YES;

    _captureQueue = dispatch_queue_create(
        "dev.flutterzero.webcam-depth.capture", DISPATCH_QUEUE_SERIAL);
    _outputDelegate = [[WCDepthCaptureDelegate alloc] init];

    _session = [[AVCaptureSession alloc] init];

    // Let a session preset negotiate the geometry rather than picking a
    // device format by hand: a preset re-applies itself when the session
    // runs and would override an activeFormat set here. 1280x720 is
    // precisely the >= 720p / 30 fps the design doc asks for.
    if ([_session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
      _session.sessionPreset = AVCaptureSessionPreset1280x720;
    } else if ([_session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
      _session.sessionPreset = AVCaptureSessionPresetHigh;
    }

    if (![_session canAddInput:input] || ![_session canAddOutput:output]) {
      wc_set_error("session rejected input or output");
      return WC_START_ERR_CONFIGURATION;
    }
    [_session addInput:input];
    [_session addOutput:output];
    [output setSampleBufferDelegate:_outputDelegate queue:_captureQueue];

    // Publish the pool before startRunning: frames can arrive the moment
    // the session is live, and the delegate must see a complete pool.
    _bufferCount = buffer_count;
    _bufferBytes = buffer_bytes;
    for (int32_t i = 0; i < buffer_count; i++) {
      _buffers[i] = buffers[i];
      atomic_store(&_state[i], kStateFree);
      _timestamps[i] = 0;
    }
    atomic_store(&_newestIndex, -1);
    atomic_store(&_deliveredIndex, -1);
    atomic_store(&_frameCount, 0);
    atomic_store(&_droppedFrames, 0);

    [_session startRunning];
    atomic_store(&_running, true);
    _hostToUnixOffsetUs = wc_host_to_unix_offset_us();

    // Cap the camera at 30 fps. Sixty would double the copy cost for a
    // pass-through already bounded by the display refresh; revisit when
    // the depth model lands and the budget tightens. Configuration while
    // running is allowed under a lock.
    const CMTime frameInterval = CMTimeMake(1, 30);
    if ([device lockForConfiguration:&error]) {
      device.activeVideoMinFrameDuration = frameInterval;
      device.activeVideoMaxFrameDuration = frameInterval;
      [device unlockForConfiguration];
    } else {
      // Non-fatal: the camera runs at its own pace and the HUD shows it.
      wc_set_error("lockForConfiguration failed: %s",
                   error.localizedDescription.UTF8String ?: "unknown");
    }

    // Report the geometry the session actually negotiated, not what was
    // requested, so Dart sizes its texture to reality.
    const CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(
        device.activeFormat.formatDescription);

    if (out_width != NULL) {
      *out_width = dims.width;
    }
    if (out_height != NULL) {
      *out_height = dims.height;
    }
    if (out_frames_per_second != NULL) {
      *out_frames_per_second = 30;
    }
    if (out_bytes_per_row != NULL) {
      *out_bytes_per_row = dims.width * 4;
    }
    return WC_START_OK;
  } @catch (NSException *exception) {
    wc_set_error("exception: %s", exception.reason.UTF8String ?: "unknown");
    atomic_store(&_running, false);
    _session = nil;
    // The pool pointers are the caller's, but they must not stay reachable:
    // wc_release_frame would otherwise write into memory Dart has freed.
    _bufferCount = 0;
    return WC_START_ERR_CONFIGURATION;
  }
}

int32_t wc_get_newest_frame(int64_t *out_timestamp_us) {
  if (!atomic_load(&_running)) {
    return -1;
  }

  const int newest = atomic_load(&_newestIndex);
  if (newest < 0 || newest == atomic_load(&_deliveredIndex)) {
    return -1;
  }

  // Claim the buffer for Dart. Losing the race means it was reclaimed or
  // already delivered; either way, try again on the next poll.
  int expected = kStateFull;
  if (!atomic_compare_exchange_strong(&_state[newest], &expected, kStateHeld)) {
    return -1;
  }

  atomic_store(&_deliveredIndex, newest);
  if (out_timestamp_us != NULL) {
    *out_timestamp_us = _timestamps[newest];
  }
  return newest;
}

void wc_release_frame(int32_t index) {
  if (index < 0 || index >= _bufferCount) {
    return;
  }
  atomic_store(&_state[index], kStateFree);
}

int64_t wc_get_dropped_frames(void) {
  return atomic_load(&_droppedFrames);
}

int64_t wc_get_frame_count(void) { return atomic_load(&_frameCount); }

void wc_stop(void) {
  atomic_store(&_running, false);

  if (_session != nil) {
    if (_session.isRunning) {
      if (_captureQueue != nil) {
        // Stop on the capture queue so the delegate cannot race teardown.
        dispatch_sync(_captureQueue, ^{
          [_session stopRunning];
        });
      } else {
        [_session stopRunning];
      }
    }
    _session = nil;
  }
  _outputDelegate = nil;
  _captureQueue = nil;
  _bufferCount = 0;
  _bufferBytes = 0;
}

const char *wc_last_error(void) { return _lastError; }
