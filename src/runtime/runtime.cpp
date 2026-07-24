#include "runtime/runtime.hpp"

#include <uv.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <exception>
#include <fcntl.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace soda::runtime {

namespace {

class UvErrorCategory final : public std::error_category {
public:
    const char* name() const noexcept override { return "libuv"; }
    std::string message(int status) const override { return uv_strerror(status); }
};

const std::error_category& uv_error_category() {
    static const UvErrorCategory category;
    return category;
}

std::system_error uv_error(int status, std::string_view operation) {
    return {std::error_code(status, uv_error_category()), std::string(operation)};
}

} // namespace

struct Runtime::Impl {
    struct Timer {
        Impl* owner = nullptr;
        SourceId id;
        uv_timer_t handle{};
        std::uint64_t repeat_ms = 0;
        bool closing = false;
    };

    struct FdWatch {
        Impl* owner = nullptr;
        SourceId id;
        uv_poll_t handle{};
        int fd = -1;
        bool closing = false;
    };

    struct FileRead {
        enum class Phase : std::uint8_t {
            Open,
            Read,
            Close,
        };

        Impl* owner = nullptr;
        SourceId id;
        uv_fs_t request{};
        std::string path;
        std::vector<std::byte> data;
        std::array<char, 64UZ * 1024UZ> chunk{};
        uv_file file = -1;
        std::int64_t offset = 0;
        int final_status = 0;
        Phase phase = Phase::Open;
    };

    Impl() : owner_thread(std::this_thread::get_id()) {
        const int status = uv_loop_init(&loop);
        if (status < 0) {
            throw uv_error(status, "cannot initialize libuv loop");
        }
    }

    ~Impl() {
        if (std::this_thread::get_id() != owner_thread) {
            std::terminate();
        }
        shutting_down = true;

        for (auto& [id, timer] : timers) {
            (void)id;
            close_timer(*timer);
        }
        for (auto& [id, watch] : fd_watches) {
            (void)id;
            close_watch(*watch);
        }
        for (auto& [id, read] : file_reads) {
            (void)id;
            (void)uv_cancel(reinterpret_cast<uv_req_t*>(&read->request));
        }

        while (uv_loop_alive(&loop) != 0) {
            (void)uv_run(&loop, UV_RUN_DEFAULT);
        }
        const int status = uv_loop_close(&loop);
        if (status != 0) {
            std::terminate();
        }
    }

    void require_owner_thread() const {
        if (std::this_thread::get_id() != owner_thread) {
            throw std::logic_error("libuv runtime used from a non-owning thread");
        }
    }

    SourceId allocate_id() {
        const SourceId result{next_id};
        ++next_id;
        if (!result.valid() || next_id == 0) {
            throw std::overflow_error("libuv source id space exhausted");
        }
        return result;
    }

    SourceId start_timer(std::uint64_t timeout_ms, std::uint64_t repeat_ms) {
        require_owner_thread();
        auto timer = std::make_unique<Timer>();
        timer->owner = this;
        timer->id = allocate_id();
        timer->repeat_ms = repeat_ms;
        const SourceId id = timer->id;

        const int init_status = uv_timer_init(&loop, &timer->handle);
        if (init_status < 0) {
            throw uv_error(init_status, "cannot initialize timer");
        }
        timer->handle.data = timer.get();
        timers.emplace(id.value, std::move(timer));

        const int start_status =
            uv_timer_start(&timers.at(id.value)->handle, on_timer, timeout_ms, repeat_ms);
        if (start_status < 0) {
            close_timer(*timers.at(id.value));
            (void)uv_run(&loop, UV_RUN_NOWAIT);
            throw uv_error(start_status, "cannot start timer");
        }
        return id;
    }

    SourceId watch_fd(int fd, FdEvent requested_events) {
        require_owner_thread();
        if (fd < 0) {
            throw std::invalid_argument("file descriptor must be non-negative");
        }
        if (!contains(requested_events, FdEvent::Readable) &&
            !contains(requested_events, FdEvent::Writable)) {
            throw std::invalid_argument("fd watch has no requested events");
        }
        constexpr std::uint32_t known_events = static_cast<std::uint32_t>(FdEvent::Readable) |
                                               static_cast<std::uint32_t>(FdEvent::Writable);
        if ((static_cast<std::uint32_t>(requested_events) & ~known_events) != 0) {
            throw std::invalid_argument("fd watch contains unsupported events");
        }
        if (watched_fds.contains(fd)) {
            throw std::invalid_argument("file descriptor is already watched");
        }

        auto watch = std::make_unique<FdWatch>();
        watch->owner = this;
        watch->id = allocate_id();
        watch->fd = fd;
        const SourceId id = watch->id;

        const int init_status = uv_poll_init(&loop, &watch->handle, fd);
        if (init_status < 0) {
            throw uv_error(init_status, "cannot initialize fd watch");
        }
        watch->handle.data = watch.get();
        fd_watches.emplace(id.value, std::move(watch));
        watched_fds.emplace(fd, id);

        int uv_events = 0;
        if (contains(requested_events, FdEvent::Readable)) {
            uv_events |= UV_READABLE;
        }
        if (contains(requested_events, FdEvent::Writable)) {
            uv_events |= UV_WRITABLE;
        }
        const int start_status =
            uv_poll_start(&fd_watches.at(id.value)->handle, uv_events, on_fd_ready);
        if (start_status < 0) {
            close_watch(*fd_watches.at(id.value));
            (void)uv_run(&loop, UV_RUN_NOWAIT);
            throw uv_error(start_status, "cannot start fd watch");
        }
        return id;
    }

    SourceId read_file(std::string path) {
        require_owner_thread();
        if (path.empty()) {
            throw std::invalid_argument("file read has no path");
        }

        auto read = std::make_unique<FileRead>();
        read->owner = this;
        read->id = allocate_id();
        read->path = std::move(path);
        read->request.data = read.get();
        const SourceId id = read->id;
        file_reads.emplace(id.value, std::move(read));

        FileRead& operation = *file_reads.at(id.value);
        const int status = uv_fs_open(&loop, &operation.request, operation.path.c_str(), O_RDONLY,
                                      0, on_file_read);
        if (status < 0) {
            uv_fs_req_cleanup(&operation.request);
            queue_file_result(operation, status);
            file_reads.erase(id.value);
        }
        return id;
    }

    bool cancel(SourceId source) {
        require_owner_thread();
        if (!source.valid()) {
            return false;
        }
        if (const auto timer = timers.find(source.value); timer != timers.end()) {
            if (timer->second->closing) {
                return false;
            }
            close_timer(*timer->second);
            return true;
        }
        if (const auto watch = fd_watches.find(source.value); watch != fd_watches.end()) {
            if (watch->second->closing) {
                return false;
            }
            close_watch(*watch->second);
            return true;
        }
        if (const auto read = file_reads.find(source.value); read != file_reads.end()) {
            return uv_cancel(reinterpret_cast<uv_req_t*>(&read->second->request)) == 0;
        }
        return false;
    }

    std::size_t poll(PollMode mode) {
        require_owner_thread();
        if (mode == PollMode::Once) {
            while (events.empty() && uv_loop_alive(&loop) != 0) {
                (void)uv_run(&loop, UV_RUN_ONCE);
            }
        } else {
            (void)uv_run(&loop, UV_RUN_NOWAIT);
        }
        return events.size();
    }

    std::optional<Event> next_event() {
        require_owner_thread();
        if (events.empty()) {
            return std::nullopt;
        }
        Event event = std::move(events.front());
        events.pop_front();
        return event;
    }

    void close_timer(Timer& timer) {
        if (timer.closing) {
            return;
        }
        timer.closing = true;
        (void)uv_timer_stop(&timer.handle);
        uv_close(reinterpret_cast<uv_handle_t*>(&timer.handle), on_timer_closed);
    }

    void close_watch(FdWatch& watch) {
        if (watch.closing) {
            return;
        }
        watch.closing = true;
        (void)uv_poll_stop(&watch.handle);
        watched_fds.erase(watch.fd);
        uv_close(reinterpret_cast<uv_handle_t*>(&watch.handle), on_watch_closed);
    }

    void submit_file_read(FileRead& operation) {
        operation.phase = FileRead::Phase::Read;
        const uv_buf_t buffer =
            uv_buf_init(operation.chunk.data(), static_cast<unsigned int>(operation.chunk.size()));
        const int status = uv_fs_read(&loop, &operation.request, operation.file, &buffer, 1,
                                      operation.offset, on_file_read);
        if (status < 0) {
            uv_fs_req_cleanup(&operation.request);
            submit_file_close(operation, status);
        }
    }

    void submit_file_close(FileRead& operation, int final_status) {
        operation.phase = FileRead::Phase::Close;
        operation.final_status = final_status;
        if (operation.file < 0) {
            finish_file_read(operation);
            return;
        }
        const int status = uv_fs_close(&loop, &operation.request, operation.file, on_file_read);
        if (status < 0) {
            uv_fs_req_cleanup(&operation.request);
            operation.file = -1;
            if (operation.final_status == 0) {
                operation.final_status = status;
            }
            finish_file_read(operation);
        }
    }

    void finish_file_read(FileRead& operation) {
        const std::uint64_t id = operation.id.value;
        if (!shutting_down) {
            queue_file_result(operation, operation.final_status);
        }
        file_reads.erase(id);
    }

    void queue_file_result(FileRead& operation, int status) {
        Event event{
            .kind = EventKind::FileRead,
            .source = operation.id,
            .status = status,
            .flags = 0,
            .data = {},
        };
        if (status == 0) {
            event.data = std::move(operation.data);
        }
        events.push_back(std::move(event));
    }

    template <typename Operation> static void guard_callback(Operation&& operation) noexcept {
        try {
            std::forward<Operation>(operation)();
        } catch (...) {
            std::terminate();
        }
    }

    static void on_timer(uv_timer_t* handle) noexcept {
        guard_callback([&] {
            auto& timer = *static_cast<Timer*>(handle->data);
            timer.owner->events.push_back({
                .kind = EventKind::Timer,
                .source = timer.id,
                .status = 0,
                .flags = 0,
                .data = {},
            });
            if (timer.repeat_ms == 0) {
                timer.owner->close_timer(timer);
            }
        });
    }

    static void on_timer_closed(uv_handle_t* handle) noexcept {
        const auto& timer = *static_cast<Timer*>(handle->data);
        timer.owner->timers.erase(timer.id.value);
    }

    static void on_fd_ready(uv_poll_t* handle, int status, int uv_events) noexcept {
        guard_callback([&] {
            auto& watch = *static_cast<FdWatch*>(handle->data);
            std::uint32_t flags = 0;
            if ((uv_events & UV_READABLE) != 0) {
                flags |= static_cast<std::uint32_t>(FdEvent::Readable);
            }
            if ((uv_events & UV_WRITABLE) != 0) {
                flags |= static_cast<std::uint32_t>(FdEvent::Writable);
            }
            watch.owner->events.push_back({
                .kind = EventKind::FdReady,
                .source = watch.id,
                .status = status,
                .flags = flags,
                .data = {},
            });
            if (status < 0) {
                watch.owner->close_watch(watch);
            }
        });
    }

    static void on_watch_closed(uv_handle_t* handle) noexcept {
        const auto& watch = *static_cast<FdWatch*>(handle->data);
        watch.owner->fd_watches.erase(watch.id.value);
    }

    static void on_file_read(uv_fs_t* request) noexcept {
        guard_callback([&] {
            auto& operation = *static_cast<FileRead*>(request->data);
            Impl& owner = *operation.owner;
            const auto result = request->result;
            uv_fs_req_cleanup(request);

            switch (operation.phase) {
            case FileRead::Phase::Open:
                if (result < 0) {
                    operation.final_status = static_cast<int>(result);
                    owner.finish_file_read(operation);
                    return;
                }
                operation.file = static_cast<uv_file>(result);
                if (owner.shutting_down) {
                    owner.submit_file_close(operation, UV_ECANCELED);
                    return;
                }
                owner.submit_file_read(operation);
                return;

            case FileRead::Phase::Read:
                if (result < 0) {
                    owner.submit_file_close(operation, static_cast<int>(result));
                    return;
                }
                if (result == 0 || owner.shutting_down) {
                    owner.submit_file_close(operation, owner.shutting_down ? UV_ECANCELED : 0);
                    return;
                }
                operation.data.insert(
                    operation.data.end(),
                    reinterpret_cast<const std::byte*>(operation.chunk.data()),
                    reinterpret_cast<const std::byte*>(operation.chunk.data() + result));
                operation.offset += result;
                owner.submit_file_read(operation);
                return;

            case FileRead::Phase::Close:
                operation.file = -1;
                if (result < 0 && operation.final_status == 0) {
                    operation.final_status = static_cast<int>(result);
                }
                owner.finish_file_read(operation);
                return;
            }
        });
    }

    uv_loop_t loop{};
    const std::thread::id owner_thread;
    std::uint64_t next_id = 1;
    bool shutting_down = false;
    std::deque<Event> events;
    std::unordered_map<std::uint64_t, std::unique_ptr<Timer>> timers;
    std::unordered_map<std::uint64_t, std::unique_ptr<FdWatch>> fd_watches;
    std::unordered_map<int, SourceId> watched_fds;
    std::unordered_map<std::uint64_t, std::unique_ptr<FileRead>> file_reads;
};

Runtime::Runtime() : impl_(std::make_unique<Impl>()) {}
Runtime::~Runtime() = default;

SourceId Runtime::start_timer(std::uint64_t timeout_ms, std::uint64_t repeat_ms) {
    return impl_->start_timer(timeout_ms, repeat_ms);
}

SourceId Runtime::watch_fd(int fd, FdEvent events) {
    return impl_->watch_fd(fd, events);
}

SourceId Runtime::read_file(std::string path) {
    return impl_->read_file(std::move(path));
}

bool Runtime::cancel(SourceId source) {
    return impl_->cancel(source);
}

std::size_t Runtime::poll(PollMode mode) {
    return impl_->poll(mode);
}

std::size_t Runtime::pending_events() const {
    impl_->require_owner_thread();
    return impl_->events.size();
}

std::optional<Event> Runtime::next_event() {
    return impl_->next_event();
}

bool Runtime::alive() const {
    impl_->require_owner_thread();
    return uv_loop_alive(&impl_->loop) != 0;
}

} // namespace soda::runtime
