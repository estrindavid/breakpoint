// System calls whose headers the Swift WinSDK module does not cover (wtsapi32, powrprof,
// WinHTTP), wrapped with plain C types. Implemented in System.cpp.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Session notifications (lock, unlock, remote connect and disconnect) to `hwnd`. 1 on success.
int bp_session_notifications_register(void *hwnd);
void bp_session_notifications_unregister(void *hwnd);

/// Some process asks the display to stay on (`ES_DISPLAY_REQUIRED` in the system's execution
/// state). 1 yes, 0 no, -1 unknown.
int bp_display_required(void);

/// The result of `bp_http_get`. `data` is malloc'd; free it with `bp_http_free`.
typedef struct BPHTTPResult {
    int status;          // HTTP status, 0 when no response
    uint32_t error;      // WinHTTP or Win32 error, 0 when none
    int tooLarge;        // the body passed `limit` and was dropped
    uint8_t *data;
    size_t length;
} BPHTTPResult;

/// One HTTPS GET with WinHTTP: no cookies, no cache, no credentials, the system proxy, TLS 1.2+,
/// redirects followed. `url`, `userAgent` and `headers` are UTF-16, NUL-terminated; `headers` is
/// "Name: value\r\n" lines. At most `limit` bytes are kept.
BPHTTPResult bp_http_get(const uint16_t *url, const uint16_t *userAgent, const uint16_t *headers, size_t limit,
                         int requestTimeoutMs, int totalTimeoutMs);
void bp_http_free(BPHTTPResult *result);

/// `TrackPopupMenu` with `TPM_RETURNCMD`: the chosen item's ID, 0 when none (Swift imports the
/// function's result as a Bool).
int bp_track_popup_menu(void *menu, unsigned flags, int x, int y, void *hwnd);

#ifdef __cplusplus
}
#endif
