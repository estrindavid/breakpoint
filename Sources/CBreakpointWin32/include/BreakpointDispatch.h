// libdispatch's hooks for a host run loop (exported by dispatch.dll / dispatch.lib; CoreFoundation
// uses them the same way). The Windows app's message loop waits on the main queue's event and
// drains the queue itself, so DispatchQueue.main works without polling.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void *_dispatch_get_main_queue_handle_4CF(void);
void _dispatch_main_queue_callback_4CF(void *message);

#ifdef __cplusplus
}
#endif
