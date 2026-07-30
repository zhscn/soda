#include "runtime/c_api.h"

#include "runtime/runtime.hpp"

#include <uv.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

struct soda_runtime {
    soda::runtime::Runtime runtime;
    std::optional<soda::runtime::Event> current_event;
    std::array<char, 512> last_error{};
};

namespace {

void set_error(soda_runtime& runtime, std::string_view message) noexcept {
    const std::size_t size = std::min(message.size(), runtime.last_error.size() - 1);
    std::ranges::copy_n(message.begin(), static_cast<std::ptrdiff_t>(size),
                        runtime.last_error.begin());
    runtime.last_error[size] = '\0';
}

template <typename Result, typename Operation>
Result guard(soda_runtime* runtime, Result failure, Operation&& operation) noexcept {
    if (runtime == nullptr) {
        return failure;
    }
    try {
        runtime->last_error.front() = '\0';
        return std::forward<Operation>(operation)();
    } catch (const std::exception& exception) {
        set_error(*runtime, exception.what());
    } catch (...) {
        set_error(*runtime, "unknown native runtime failure");
    }
    return failure;
}

const soda::runtime::Event* current_event(soda_runtime* runtime) noexcept {
    if (runtime == nullptr || !runtime->current_event.has_value()) {
        return nullptr;
    }
    return &*runtime->current_event;
}

std::uint32_t read_u32(const std::uint8_t* data, std::size_t offset) {
    return static_cast<std::uint32_t>(data[offset]) |
           (static_cast<std::uint32_t>(data[offset + 1]) << 8U) |
           (static_cast<std::uint32_t>(data[offset + 2]) << 16U) |
           (static_cast<std::uint32_t>(data[offset + 3]) << 24U);
}

std::vector<std::string> decode_process_arguments(const std::uint8_t* data, std::size_t size) {
    if (data == nullptr && size != 0) {
        throw std::invalid_argument("process arguments are null");
    }
    std::vector<std::string> arguments;
    std::size_t offset = 0;
    while (offset < size) {
        if (size - offset < sizeof(std::uint32_t)) {
            throw std::invalid_argument("truncated process argument length");
        }
        const std::size_t length = read_u32(data, offset);
        offset += sizeof(std::uint32_t);
        if (length > size - offset) {
            throw std::invalid_argument("truncated process argument");
        }
        std::string argument(reinterpret_cast<const char*>(data + offset), length);
        if (argument.find('\0') != std::string::npos) {
            throw std::invalid_argument("process argument contains a null byte");
        }
        arguments.push_back(std::move(argument));
        offset += length;
    }
    if (arguments.empty() || arguments.front().empty()) {
        throw std::invalid_argument("process executable is empty");
    }
    return arguments;
}

} // namespace

extern "C" {

uint32_t soda_runtime_abi_version(void) {
    return SODA_RUNTIME_ABI_VERSION;
}

soda_runtime* soda_runtime_create(void) {
    try {
        return new soda_runtime();
    } catch (...) {
        return nullptr;
    }
}

void soda_runtime_destroy(soda_runtime* runtime) {
    delete runtime;
}

uint64_t soda_runtime_start_timer(soda_runtime* runtime, uint64_t timeout_ms, uint64_t repeat_ms) {
    return guard(runtime, uint64_t{0},
                 [&] { return runtime->runtime.start_timer(timeout_ms, repeat_ms).value; });
}

uint64_t soda_runtime_watch_fd(soda_runtime* runtime, int fd, uint32_t events) {
    return guard(runtime, uint64_t{0}, [&] {
        return runtime->runtime.watch_fd(fd, static_cast<soda::runtime::FdEvent>(events)).value;
    });
}

uint64_t soda_runtime_read_file(soda_runtime* runtime, const char* path) {
    return guard(runtime, uint64_t{0}, [&] {
        if (path == nullptr) {
            throw std::invalid_argument("file read path is null");
        }
        return runtime->runtime.read_file(path).value;
    });
}

uint64_t soda_runtime_write_file(soda_runtime* runtime, const char* path, const uint8_t* data,
                                 size_t size) {
    return guard(runtime, uint64_t{0}, [&] {
        if (path == nullptr) {
            throw std::invalid_argument("file write path is null");
        }
        if (data == nullptr && size != 0) {
            throw std::invalid_argument("file write data is null");
        }
        std::vector<std::byte> owned_data(size);
        if (size != 0) {
            std::ranges::copy_n(reinterpret_cast<const std::byte*>(data),
                                static_cast<std::ptrdiff_t>(size), owned_data.begin());
        }
        return runtime->runtime.write_file(path, std::move(owned_data)).value;
    });
}

uint64_t soda_runtime_scan_directory(soda_runtime* runtime, const char* path) {
    return guard(runtime, uint64_t{0}, [&] {
        if (path == nullptr) {
            throw std::invalid_argument("directory scan path is null");
        }
        return runtime->runtime.scan_directory(path).value;
    });
}

uint64_t soda_runtime_stat_path(soda_runtime* runtime, const char* path, int follow_symlinks) {
    return guard(runtime, uint64_t{0}, [&] {
        if (path == nullptr) {
            throw std::invalid_argument("stat path is null");
        }
        return runtime->runtime.stat_path(path, follow_symlinks != 0).value;
    });
}

uint64_t soda_runtime_watch_path(soda_runtime* runtime, const char* path) {
    return guard(runtime, uint64_t{0}, [&] {
        if (path == nullptr) {
            throw std::invalid_argument("path watch path is null");
        }
        return runtime->runtime.watch_path(path).value;
    });
}

uint64_t soda_runtime_spawn_process(soda_runtime* runtime, const char* working_directory,
                                    const uint8_t* arguments, size_t arguments_size) {
    return guard(runtime, uint64_t{0}, [&] {
        const std::string directory =
            working_directory == nullptr ? std::string{} : std::string{working_directory};
        return runtime->runtime
            .spawn_process(decode_process_arguments(arguments, arguments_size), directory)
            .value;
    });
}

int soda_runtime_cancel(soda_runtime* runtime, uint64_t source) {
    return guard(runtime, -1,
                 [&] { return runtime->runtime.cancel(soda::runtime::SourceId{source}) ? 1 : 0; });
}

int soda_runtime_poll(soda_runtime* runtime, int mode) {
    return guard(runtime, -1, [&] {
        soda::runtime::PollMode poll_mode;
        switch (mode) {
        case SODA_POLL_NOWAIT:
            poll_mode = soda::runtime::PollMode::NoWait;
            break;
        case SODA_POLL_ONCE:
            poll_mode = soda::runtime::PollMode::Once;
            break;
        default:
            throw std::invalid_argument("invalid poll mode");
        }
        (void)runtime->runtime.poll(poll_mode);
        return 0;
    });
}

size_t soda_runtime_pending_events(soda_runtime* runtime) {
    return guard(runtime, size_t{0}, [&] { return runtime->runtime.pending_events(); });
}

int soda_runtime_next_event(soda_runtime* runtime) {
    return guard(runtime, -1, [&] {
        runtime->current_event = runtime->runtime.next_event();
        return runtime->current_event.has_value() ? 1 : 0;
    });
}

uint32_t soda_runtime_event_kind(soda_runtime* runtime) {
    const auto* event = current_event(runtime);
    return event == nullptr ? 0 : static_cast<std::uint32_t>(event->kind);
}

uint64_t soda_runtime_event_source(soda_runtime* runtime) {
    const auto* event = current_event(runtime);
    return event == nullptr ? 0 : event->source.value;
}

int soda_runtime_event_status(soda_runtime* runtime) {
    const auto* event = current_event(runtime);
    return event == nullptr ? 0 : event->status;
}

uint32_t soda_runtime_event_flags(soda_runtime* runtime) {
    const auto* event = current_event(runtime);
    return event == nullptr ? 0 : event->flags;
}

size_t soda_runtime_event_data_size(soda_runtime* runtime) {
    const auto* event = current_event(runtime);
    return event == nullptr ? 0 : event->data.size();
}

const uint8_t* soda_runtime_event_data(soda_runtime* runtime) {
    const auto* event = current_event(runtime);
    if (event == nullptr || event->data.empty()) {
        return nullptr;
    }
    return reinterpret_cast<const std::uint8_t*>(event->data.data());
}

size_t soda_runtime_copy_event_data(soda_runtime* runtime, uint8_t* destination, size_t capacity) {
    return guard(runtime, size_t{0}, [&] {
        const auto* event = current_event(runtime);
        if (event == nullptr) {
            throw std::logic_error("no current event");
        }
        if (capacity < event->data.size()) {
            throw std::invalid_argument("event data destination is too small");
        }
        if (!event->data.empty() && destination == nullptr) {
            throw std::invalid_argument("event data destination is null");
        }
        std::ranges::copy(event->data, reinterpret_cast<std::byte*>(destination));
        return event->data.size();
    });
}

const char* soda_runtime_status_name(int status) {
    return uv_err_name(status);
}

const char* soda_runtime_status_message(int status) {
    return uv_strerror(status);
}

const char* soda_runtime_last_error(soda_runtime* runtime) {
    if (runtime == nullptr) {
        return "runtime is null";
    }
    return runtime->last_error.data();
}

} // extern "C"
