#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(SODA_RUNTIME_BUILD)
#define SODA_RUNTIME_API __declspec(dllexport)
#else
#define SODA_RUNTIME_API __declspec(dllimport)
#endif
#else
#define SODA_RUNTIME_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct soda_runtime soda_runtime;
typedef struct soda_terminal soda_terminal;

#define SODA_POLL_NOWAIT 0
#define SODA_POLL_ONCE 1

#define SODA_EVENT_TIMER 1U
#define SODA_EVENT_FD_READY 2U
#define SODA_EVENT_FILE_READ 3U

#define SODA_FD_READABLE (1U << 0U)
#define SODA_FD_WRITABLE (1U << 1U)

SODA_RUNTIME_API soda_runtime* soda_runtime_create(void);
SODA_RUNTIME_API void soda_runtime_destroy(soda_runtime* runtime);

SODA_RUNTIME_API uint64_t soda_runtime_start_timer(soda_runtime* runtime, uint64_t timeout_ms,
                                                   uint64_t repeat_ms);
SODA_RUNTIME_API uint64_t soda_runtime_watch_fd(soda_runtime* runtime, int fd, uint32_t events);
SODA_RUNTIME_API uint64_t soda_runtime_read_file(soda_runtime* runtime, const char* path);
SODA_RUNTIME_API int soda_runtime_cancel(soda_runtime* runtime, uint64_t source);

SODA_RUNTIME_API int soda_runtime_poll(soda_runtime* runtime, int mode);
SODA_RUNTIME_API size_t soda_runtime_pending_events(soda_runtime* runtime);

// Advances to the next event and returns one when an event is available.
// Current-event accessors remain valid until the next call that advances the
// event. Event data is copied into caller-owned memory with
// soda_runtime_copy_event_data.
SODA_RUNTIME_API int soda_runtime_next_event(soda_runtime* runtime);
SODA_RUNTIME_API uint32_t soda_runtime_event_kind(soda_runtime* runtime);
SODA_RUNTIME_API uint64_t soda_runtime_event_source(soda_runtime* runtime);
SODA_RUNTIME_API int soda_runtime_event_status(soda_runtime* runtime);
SODA_RUNTIME_API uint32_t soda_runtime_event_flags(soda_runtime* runtime);
SODA_RUNTIME_API size_t soda_runtime_event_data_size(soda_runtime* runtime);
// Borrowed view of the current event payload. The pointer remains valid until
// the next operation that advances the current event or destroys the runtime.
SODA_RUNTIME_API const uint8_t* soda_runtime_event_data(soda_runtime* runtime);
SODA_RUNTIME_API size_t soda_runtime_copy_event_data(soda_runtime* runtime, uint8_t* destination,
                                                     size_t capacity);

// The returned message is owned by the runtime and remains valid until the
// next C API operation on that runtime.
SODA_RUNTIME_API const char* soda_runtime_last_error(soda_runtime* runtime);

SODA_RUNTIME_API soda_terminal* soda_terminal_create(int input_fd, int output_fd);
SODA_RUNTIME_API void soda_terminal_destroy(soda_terminal* terminal);
SODA_RUNTIME_API int soda_terminal_enter_raw(soda_terminal* terminal);
SODA_RUNTIME_API int soda_terminal_leave_raw(soda_terminal* terminal);
SODA_RUNTIME_API int64_t soda_terminal_read(soda_terminal* terminal, uint8_t* destination,
                                            size_t capacity);
SODA_RUNTIME_API int soda_terminal_write(soda_terminal* terminal, const uint8_t* data, size_t size);
SODA_RUNTIME_API int soda_terminal_size(soda_terminal* terminal, uint32_t* rows, uint32_t* columns);
SODA_RUNTIME_API const char* soda_terminal_last_error(soda_terminal* terminal);

#ifdef __cplusplus
}
#endif
