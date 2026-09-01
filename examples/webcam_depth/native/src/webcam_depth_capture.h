#ifndef WEBCAM_DEPTH_CAPTURE_H
#define WEBCAM_DEPTH_CAPTURE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Maximum pooled buffers the shim will accept. Dart hands us three. */
#define WC_MAX_BUFFERS 4

/* wc_request_permission_async callback result codes. */
enum {
  WC_PERMISSION_GRANTED = 0,
  WC_PERMISSION_DENIED = 1,
  WC_PERMISSION_DENIED_PREVIOUSLY = 2,
  WC_PERMISSION_ERROR = 3,
};

/* wc_start result codes. */
enum {
  WC_START_OK = 0,
  WC_START_ERR_NO_DEVICE = 1,
  WC_START_ERR_CONFIGURATION = 2,
  WC_START_ERR_PERMISSION = 3,
  WC_START_ERR_ALLOCATION = 4,
  WC_START_ERR_ALREADY_RUNNING = 5,
};

/*
 * Asks the user for camera access and reports the outcome on `callback`.
 * Runs the request off the calling thread so the caller keeps drawing
 * while the system dialog is up. `context` is passed through untouched.
 */
void wc_request_permission_async(
    void (*callback)(int32_t result, void *context), void *context);

/*
 * Starts the capture session.
 *
 * `buffers`/`buffer_count`/`buffer_bytes` describe a caller-owned pool the
 * shim fills round-robin; nothing is allocated per frame. The negotiated
 * geometry is written to the four out params.
 *
 * Returns a WC_START_* code.
 */
int32_t wc_start(uint8_t **buffers, int32_t buffer_count, int32_t buffer_bytes,
                 int32_t *out_width, int32_t *out_height,
                 int32_t *out_frames_per_second, int32_t *out_bytes_per_row);

/*
 * Returns the index of the newest completed buffer and writes its camera
 * presentation timestamp to `out_timestamp_us` (Unix-epoch microseconds,
 * so the Dart side can diff it against its own clock), or -1 if nothing
 * new has arrived since the last call. The returned buffer stays held by
 * the caller until wc_release_frame.
 */
int32_t wc_get_newest_frame(int64_t *out_timestamp_us);

/* Returns a held buffer to the capture callback. */
void wc_release_frame(int32_t index);

/*
 * Frames discarded because every pooled buffer was held when a new one
 * arrived. This is the HUD's capture-side drop count: such a frame never
 * reached the consumer.
 */
int64_t wc_get_dropped_frames(void);

/* Frames delivered to the capture callback since wc_start. */
int64_t wc_get_frame_count(void);

/* Stops the session. Buffers may be freed after this returns. */
void wc_stop(void);

/* Detail for the last WC_START_* failure; valid until the next call. */
const char *wc_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* WEBCAM_DEPTH_CAPTURE_H */
