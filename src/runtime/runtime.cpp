#include "runtime/runtime.hpp"

#include <uv.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <exception>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
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

    struct PathWatch {
        Impl* owner = nullptr;
        SourceId id;
        uv_fs_event_t handle{};
        std::string path;
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

    struct FileWrite {
        Impl* owner = nullptr;
        SourceId id;
        uv_work_t request{};
        std::string path;
        std::string temporary_path;
        std::vector<std::byte> data;
        int status = 0;
    };

    struct DirectoryScan {
        Impl* owner = nullptr;
        SourceId id;
        uv_fs_t request{};
        std::string path;
    };

    struct PathStat {
        Impl* owner = nullptr;
        SourceId id;
        uv_fs_t request{};
        std::string path;
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
        for (auto& [id, watch] : path_watches) {
            (void)id;
            close_path_watch(*watch);
        }
        for (auto& [id, read] : file_reads) {
            (void)id;
            (void)uv_cancel(reinterpret_cast<uv_req_t*>(&read->request));
        }
        for (auto& [id, write] : file_writes) {
            (void)id;
            (void)uv_cancel(reinterpret_cast<uv_req_t*>(&write->request));
        }
        for (auto& [id, scan] : directory_scans) {
            (void)id;
            (void)uv_cancel(reinterpret_cast<uv_req_t*>(&scan->request));
        }
        for (auto& [id, stat] : path_stats) {
            (void)id;
            (void)uv_cancel(reinterpret_cast<uv_req_t*>(&stat->request));
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

    SourceId write_file(std::string path, std::vector<std::byte> data) {
        require_owner_thread();
        if (path.empty()) {
            throw std::invalid_argument("file write has no path");
        }

        auto write = std::make_unique<FileWrite>();
        write->owner = this;
        write->id = allocate_id();
        write->path = std::move(path);
        write->data = std::move(data);
        write->request.data = write.get();
        const SourceId id = write->id;
        file_writes.emplace(id.value, std::move(write));

        FileWrite& operation = *file_writes.at(id.value);
        const int status =
            uv_queue_work(&loop, &operation.request, perform_file_write, on_file_write);
        if (status < 0) {
            queue_file_write_result(operation, status);
            file_writes.erase(id.value);
        }
        return id;
    }

    SourceId scan_directory(std::string path) {
        require_owner_thread();
        if (path.empty()) {
            throw std::invalid_argument("directory scan has no path");
        }

        auto scan = std::make_unique<DirectoryScan>();
        scan->owner = this;
        scan->id = allocate_id();
        scan->path = std::move(path);
        scan->request.data = scan.get();
        const SourceId id = scan->id;
        directory_scans.emplace(id.value, std::move(scan));

        DirectoryScan& operation = *directory_scans.at(id.value);
        const int status =
            uv_fs_scandir(&loop, &operation.request, operation.path.c_str(), 0, on_directory_scan);
        if (status < 0) {
            uv_fs_req_cleanup(&operation.request);
            queue_directory_scan_result(operation, status, {});
            directory_scans.erase(id.value);
        }
        return id;
    }

    SourceId stat_path(std::string path, bool follow_symlinks) {
        require_owner_thread();
        if (path.empty()) {
            throw std::invalid_argument("stat has no path");
        }

        auto stat = std::make_unique<PathStat>();
        stat->owner = this;
        stat->id = allocate_id();
        stat->path = std::move(path);
        stat->request.data = stat.get();
        const SourceId id = stat->id;
        path_stats.emplace(id.value, std::move(stat));

        PathStat& operation = *path_stats.at(id.value);
        const int status =
            follow_symlinks
                ? uv_fs_stat(&loop, &operation.request, operation.path.c_str(), on_path_stat)
                : uv_fs_lstat(&loop, &operation.request, operation.path.c_str(), on_path_stat);
        if (status < 0) {
            uv_fs_req_cleanup(&operation.request);
            queue_path_stat_result(operation, status, 0, {});
            path_stats.erase(id.value);
        }
        return id;
    }

    SourceId watch_path(std::string path) {
        require_owner_thread();
        if (path.empty()) {
            throw std::invalid_argument("path watch has no path");
        }

        auto watch = std::make_unique<PathWatch>();
        watch->owner = this;
        watch->id = allocate_id();
        watch->path = std::move(path);
        const SourceId id = watch->id;

        const int init_status = uv_fs_event_init(&loop, &watch->handle);
        if (init_status < 0) {
            throw uv_error(init_status, "cannot initialize path watch");
        }
        watch->handle.data = watch.get();
        path_watches.emplace(id.value, std::move(watch));

        const int start_status =
            uv_fs_event_start(&path_watches.at(id.value)->handle, on_path_change,
                              path_watches.at(id.value)->path.c_str(), 0);
        if (start_status < 0) {
            close_path_watch(*path_watches.at(id.value));
            (void)uv_run(&loop, UV_RUN_NOWAIT);
            throw uv_error(start_status, "cannot start path watch");
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
        if (const auto watch = path_watches.find(source.value); watch != path_watches.end()) {
            if (watch->second->closing) {
                return false;
            }
            close_path_watch(*watch->second);
            return true;
        }
        if (const auto read = file_reads.find(source.value); read != file_reads.end()) {
            return uv_cancel(reinterpret_cast<uv_req_t*>(&read->second->request)) == 0;
        }
        if (const auto write = file_writes.find(source.value); write != file_writes.end()) {
            return uv_cancel(reinterpret_cast<uv_req_t*>(&write->second->request)) == 0;
        }
        if (const auto scan = directory_scans.find(source.value); scan != directory_scans.end()) {
            return uv_cancel(reinterpret_cast<uv_req_t*>(&scan->second->request)) == 0;
        }
        if (const auto stat = path_stats.find(source.value); stat != path_stats.end()) {
            return uv_cancel(reinterpret_cast<uv_req_t*>(&stat->second->request)) == 0;
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

    void close_path_watch(PathWatch& watch) {
        if (watch.closing) {
            return;
        }
        watch.closing = true;
        (void)uv_fs_event_stop(&watch.handle);
        uv_close(reinterpret_cast<uv_handle_t*>(&watch.handle), on_path_watch_closed);
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

    void queue_file_write_result(FileWrite& operation, int status) {
        events.push_back({
            .kind = EventKind::FileWrite,
            .source = operation.id,
            .status = status,
            .flags = 0,
            .data = {},
        });
    }

    void queue_directory_scan_result(DirectoryScan& operation, int status,
                                     std::vector<std::byte> data) {
        events.push_back({
            .kind = EventKind::DirectoryScan,
            .source = operation.id,
            .status = status,
            .flags = 0,
            .data = std::move(data),
        });
    }

    void queue_path_stat_result(PathStat& operation, int status, std::uint32_t kind,
                                std::vector<std::byte> data) {
        events.push_back({
            .kind = EventKind::PathStat,
            .source = operation.id,
            .status = status,
            .flags = kind,
            .data = std::move(data),
        });
    }

    static void append_u32(std::vector<std::byte>& data, std::uint32_t value) {
        for (unsigned int shift = 0; shift < 32; shift += 8) {
            data.push_back(static_cast<std::byte>((value >> shift) & 0xffU));
        }
    }

    static void append_u64(std::vector<std::byte>& data, std::uint64_t value) {
        for (unsigned int shift = 0; shift < 64; shift += 8) {
            data.push_back(static_cast<std::byte>((value >> shift) & 0xffU));
        }
    }

    static std::uint32_t stat_kind(std::uint64_t mode) {
        if (S_ISREG(mode))
            return 1;
        if (S_ISDIR(mode))
            return 2;
        if (S_ISLNK(mode))
            return 3;
        if (S_ISFIFO(mode))
            return 4;
        if (S_ISSOCK(mode))
            return 5;
        if (S_ISCHR(mode))
            return 6;
        if (S_ISBLK(mode))
            return 7;
        return 0;
    }

    static void on_path_stat(uv_fs_t* request) noexcept {
        guard_callback([&] {
            auto& operation = *static_cast<PathStat*>(request->data);
            Impl& owner = *operation.owner;
            int status = request->result < 0 ? static_cast<int>(request->result) : 0;
            std::uint32_t kind = 0;
            std::vector<std::byte> data;
            if (status == 0 && !owner.shutting_down) {
                const uv_stat_t& stat = request->statbuf;
                kind = stat_kind(stat.st_mode);
                append_u64(data, stat.st_size);
                append_u64(data, static_cast<std::uint64_t>(stat.st_mtim.tv_sec));
                append_u64(data, static_cast<std::uint64_t>(stat.st_mtim.tv_nsec));
                append_u64(data, stat.st_dev);
                append_u64(data, stat.st_ino);
            } else if (owner.shutting_down) {
                status = UV_ECANCELED;
            }
            uv_fs_req_cleanup(request);
            const auto id = operation.id.value;
            if (!owner.shutting_down) {
                owner.queue_path_stat_result(operation, status, kind, std::move(data));
            }
            owner.path_stats.erase(id);
        });
    }

    static void on_directory_scan(uv_fs_t* request) noexcept {
        guard_callback([&] {
            auto& operation = *static_cast<DirectoryScan*>(request->data);
            Impl& owner = *operation.owner;
            int status = request->result < 0 ? static_cast<int>(request->result) : 0;
            std::vector<std::byte> data;
            if (status == 0 && !owner.shutting_down) {
                uv_dirent_t entry{};
                for (;;) {
                    const int next = uv_fs_scandir_next(request, &entry);
                    if (next == UV_EOF) {
                        break;
                    }
                    if (next < 0) {
                        status = next;
                        data.clear();
                        break;
                    }
                    const std::string_view name{entry.name};
                    if (name.size() > std::numeric_limits<std::uint32_t>::max()) {
                        status = UV_ENAMETOOLONG;
                        data.clear();
                        break;
                    }
                    data.push_back(static_cast<std::byte>(entry.type));
                    append_u32(data, static_cast<std::uint32_t>(name.size()));
                    data.insert(data.end(), reinterpret_cast<const std::byte*>(name.data()),
                                reinterpret_cast<const std::byte*>(name.data() + name.size()));
                }
            } else if (owner.shutting_down) {
                status = UV_ECANCELED;
            }
            uv_fs_req_cleanup(request);
            const auto id = operation.id.value;
            if (!owner.shutting_down) {
                owner.queue_directory_scan_result(operation, status, std::move(data));
            }
            owner.directory_scans.erase(id);
        });
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

    static void on_path_change(uv_fs_event_t* handle, const char* filename, int events,
                               int status) noexcept {
        guard_callback([&] {
            auto& watch = *static_cast<PathWatch*>(handle->data);
            std::vector<std::byte> data;
            if (filename != nullptr) {
                const std::string_view name{filename};
                data.insert(data.end(), reinterpret_cast<const std::byte*>(name.data()),
                            reinterpret_cast<const std::byte*>(name.data() + name.size()));
            }
            watch.owner->events.push_back({
                .kind = EventKind::PathChange,
                .source = watch.id,
                .status = status,
                .flags = static_cast<std::uint32_t>(events),
                .data = std::move(data),
            });
            if (status < 0) {
                watch.owner->close_path_watch(watch);
            }
        });
    }

    static void on_path_watch_closed(uv_handle_t* handle) noexcept {
        const auto& watch = *static_cast<PathWatch*>(handle->data);
        watch.owner->path_watches.erase(watch.id.value);
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

    static int synchronous_close(uv_file file) noexcept {
        uv_fs_t request{};
        const int status = uv_fs_close(nullptr, &request, file, nullptr);
        uv_fs_req_cleanup(&request);
        return status;
    }

    static void remove_temporary_file(FileWrite& operation) noexcept {
        if (operation.temporary_path.empty()) {
            return;
        }
        uv_fs_t request{};
        (void)uv_fs_unlink(nullptr, &request, operation.temporary_path.c_str(), nullptr);
        uv_fs_req_cleanup(&request);
    }

    static int open_temporary_file(FileWrite& operation) {
        constexpr unsigned int maximum_attempts = 100;
        for (unsigned int attempt = 0; attempt < maximum_attempts; ++attempt) {
            operation.temporary_path = operation.path + ".soda-save-" +
                                       std::to_string(operation.id.value) + "-" +
                                       std::to_string(attempt);
            uv_fs_t request{};
            const int result = uv_fs_open(nullptr, &request, operation.temporary_path.c_str(),
                                          O_WRONLY | O_CREAT | O_EXCL, 0666, nullptr);
            uv_fs_req_cleanup(&request);
            if (result >= 0) {
                return result;
            }
            if (result != UV_EEXIST) {
                return result;
            }
        }
        return UV_EEXIST;
    }

    static int write_temporary_file(FileWrite& operation, uv_file file) noexcept {
        std::size_t offset = 0;
        while (offset < operation.data.size()) {
            constexpr std::size_t max_chunk = std::numeric_limits<unsigned int>::max();
            const std::size_t remaining = operation.data.size() - offset;
            const auto chunk_size = static_cast<unsigned int>(std::min(remaining, max_chunk));
            const uv_buf_t buffer =
                uv_buf_init(reinterpret_cast<char*>(operation.data.data() + offset), chunk_size);
            uv_fs_t request{};
            const int result = uv_fs_write(nullptr, &request, file, &buffer, 1,
                                           static_cast<std::int64_t>(offset), nullptr);
            uv_fs_req_cleanup(&request);
            if (result < 0) {
                return result;
            }
            if (result == 0) {
                return UV_EIO;
            }
            offset += static_cast<std::size_t>(result);
        }
        return 0;
    }

    static int synchronize_file(uv_file file) noexcept {
        uv_fs_t request{};
        const int status = uv_fs_fsync(nullptr, &request, file, nullptr);
        uv_fs_req_cleanup(&request);
        return status;
    }

    static int preserve_target_mode(const FileWrite& operation) noexcept {
        uv_fs_t stat_request{};
        const int stat_status = uv_fs_stat(nullptr, &stat_request, operation.path.c_str(), nullptr);
        if (stat_status == UV_ENOENT) {
            uv_fs_req_cleanup(&stat_request);
            return 0;
        }
        if (stat_status < 0) {
            uv_fs_req_cleanup(&stat_request);
            return stat_status;
        }
        const int mode = static_cast<int>(stat_request.statbuf.st_mode & 07777U);
        uv_fs_req_cleanup(&stat_request);

        uv_fs_t chmod_request{};
        const int chmod_status =
            uv_fs_chmod(nullptr, &chmod_request, operation.temporary_path.c_str(), mode, nullptr);
        uv_fs_req_cleanup(&chmod_request);
        return chmod_status;
    }

    static int replace_target(FileWrite& operation) noexcept {
        uv_fs_t request{};
        const int status = uv_fs_rename(nullptr, &request, operation.temporary_path.c_str(),
                                        operation.path.c_str(), nullptr);
        uv_fs_req_cleanup(&request);
        if (status == 0) {
            operation.temporary_path.clear();
        }
        return status;
    }

    static void perform_file_write(uv_work_t* request) noexcept {
        auto& operation = *static_cast<FileWrite*>(request->data);
        uv_file file = -1;
        try {
            file = open_temporary_file(operation);
            if (file < 0) {
                operation.status = file;
                remove_temporary_file(operation);
                return;
            }

            int status = preserve_target_mode(operation);
            if (status == 0) {
                status = write_temporary_file(operation, file);
            }
            if (status == 0) {
                status = synchronize_file(file);
            }
            const int close_status = synchronous_close(file);
            file = -1;
            if (status == 0) {
                status = close_status;
            }
            if (status == 0) {
                status = replace_target(operation);
            }
            operation.status = status;
            if (status != 0) {
                remove_temporary_file(operation);
            }
        } catch (const std::bad_alloc&) {
            if (file >= 0) {
                (void)synchronous_close(file);
            }
            operation.status = UV_ENOMEM;
            remove_temporary_file(operation);
        } catch (...) {
            if (file >= 0) {
                (void)synchronous_close(file);
            }
            operation.status = UV_EIO;
            remove_temporary_file(operation);
        }
    }

    static void on_file_write(uv_work_t* request, int status) noexcept {
        guard_callback([&] {
            auto& operation = *static_cast<FileWrite*>(request->data);
            Impl& owner = *operation.owner;
            if (!owner.shutting_down) {
                owner.queue_file_write_result(operation,
                                              status == UV_ECANCELED ? status : operation.status);
            }
            owner.file_writes.erase(operation.id.value);
        });
    }

    uv_loop_t loop{};
    const std::thread::id owner_thread;
    std::uint64_t next_id = 1;
    bool shutting_down = false;
    std::deque<Event> events;
    std::unordered_map<std::uint64_t, std::unique_ptr<Timer>> timers;
    std::unordered_map<std::uint64_t, std::unique_ptr<FdWatch>> fd_watches;
    std::unordered_map<std::uint64_t, std::unique_ptr<PathWatch>> path_watches;
    std::unordered_map<int, SourceId> watched_fds;
    std::unordered_map<std::uint64_t, std::unique_ptr<FileRead>> file_reads;
    std::unordered_map<std::uint64_t, std::unique_ptr<FileWrite>> file_writes;
    std::unordered_map<std::uint64_t, std::unique_ptr<DirectoryScan>> directory_scans;
    std::unordered_map<std::uint64_t, std::unique_ptr<PathStat>> path_stats;
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

SourceId Runtime::write_file(std::string path, std::vector<std::byte> data) {
    return impl_->write_file(std::move(path), std::move(data));
}

SourceId Runtime::scan_directory(std::string path) {
    return impl_->scan_directory(std::move(path));
}

SourceId Runtime::stat_path(std::string path, bool follow_symlinks) {
    return impl_->stat_path(std::move(path), follow_symlinks);
}

SourceId Runtime::watch_path(std::string path) {
    return impl_->watch_path(std::move(path));
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
