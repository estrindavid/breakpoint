// System calls behind BreakpointSystem.h.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <powrprof.h>
#include <winhttp.h>
#include <wtsapi32.h>

#include <cstdlib>
#include <cstring>
#include <vector>

#include "BreakpointSystem.h"

extern "C" {

int bp_session_notifications_register(void *hwnd) {
    return WTSRegisterSessionNotification(static_cast<HWND>(hwnd), NOTIFY_FOR_THIS_SESSION) ? 1 : 0;
}

void bp_session_notifications_unregister(void *hwnd) { WTSUnRegisterSessionNotification(static_cast<HWND>(hwnd)); }

int bp_display_required(void) {
    EXECUTION_STATE state = 0;
    if (CallNtPowerInformation(SystemExecutionState, nullptr, 0, &state, sizeof(state)) != 0) return -1;
    return (state & ES_DISPLAY_REQUIRED) ? 1 : 0;
}

BPHTTPResult bp_http_get(const uint16_t *url, const uint16_t *userAgent, const uint16_t *headers, size_t limit,
                         int requestTimeoutMs, int totalTimeoutMs) {
    BPHTTPResult result = {};
    const wchar_t *wurl = reinterpret_cast<const wchar_t *>(url);
    URL_COMPONENTS parts = {};
    parts.dwStructSize = sizeof(parts);
    wchar_t host[256] = {};
    wchar_t path[2048] = {};
    parts.lpszHostName = host;
    parts.dwHostNameLength = ARRAYSIZE(host);
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = ARRAYSIZE(path);
    if (!WinHttpCrackUrl(wurl, 0, 0, &parts) || parts.nScheme != INTERNET_SCHEME_HTTPS) {
        result.error = GetLastError();
        return result;
    }
    HINTERNET session = WinHttpOpen(reinterpret_cast<const wchar_t *>(userAgent), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        result.error = GetLastError();
        return result;
    }
    WinHttpSetTimeouts(session, requestTimeoutMs, requestTimeoutMs, requestTimeoutMs, totalTimeoutMs);
    DWORD protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3;
    if (!WinHttpSetOption(session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols))) {
        protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;  // before TLS 1.3 support
        WinHttpSetOption(session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols));
    }
    HINTERNET connection = WinHttpConnect(session, host, parts.nPort, 0);
    HINTERNET request = connection ? WinHttpOpenRequest(connection, L"GET", path, nullptr, WINHTTP_NO_REFERER,
                                                        WINHTTP_DEFAULT_ACCEPT_TYPES,
                                                        WINHTTP_FLAG_SECURE | WINHTTP_FLAG_REFRESH)
                                   : nullptr;
    if (!request) {
        result.error = GetLastError();
    } else {
        DWORD disable = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
        WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &disable, sizeof(disable));
        DWORD logon = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
        WinHttpSetOption(request, WINHTTP_OPTION_AUTOLOGON_POLICY, &logon, sizeof(logon));
        const wchar_t *extra = reinterpret_cast<const wchar_t *>(headers);
        if (WinHttpSendRequest(request, extra, static_cast<DWORD>(-1L), WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
            WinHttpReceiveResponse(request, nullptr)) {
            DWORD status = 0, size = sizeof(status);
            WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                &status, &size, WINHTTP_NO_HEADER_INDEX);
            result.status = static_cast<int>(status);
            if (status == 200) {
                std::vector<uint8_t> body;
                for (;;) {
                    DWORD available = 0;
                    if (!WinHttpQueryDataAvailable(request, &available)) {
                        result.error = GetLastError();
                        break;
                    }
                    if (available == 0) break;
                    size_t start = body.size();
                    if (start + available > limit) {
                        result.tooLarge = 1;
                        break;
                    }
                    body.resize(start + available);
                    DWORD read = 0;
                    if (!WinHttpReadData(request, body.data() + start, available, &read)) {
                        result.error = GetLastError();
                        break;
                    }
                    body.resize(start + read);
                    if (read == 0) break;
                }
                if (!result.error && !result.tooLarge) {
                    result.length = body.size();
                    result.data = static_cast<uint8_t *>(std::malloc(body.size() ? body.size() : 1));
                    if (result.data && !body.empty()) std::memcpy(result.data, body.data(), body.size());
                }
            }
        } else {
            result.error = GetLastError();
        }
        WinHttpCloseHandle(request);
    }
    if (connection) WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    return result;
}

void bp_http_free(BPHTTPResult *result) {
    if (!result) return;
    std::free(result->data);
    result->data = nullptr;
    result->length = 0;
}

int bp_track_popup_menu(void *menu, unsigned flags, int x, int y, void *hwnd) {
    return static_cast<int>(TrackPopupMenu(static_cast<HMENU>(menu), flags | TPM_RETURNCMD, x, y, 0, static_cast<HWND>(hwnd), nullptr));
}

}  // extern "C"
