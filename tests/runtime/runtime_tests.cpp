#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include "runtime/c_api.h"
#include "runtime/runtime.hpp"

#include <uv.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <span>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#endif

using namespace soda::runtime;

static_assert(static_cast<std::uint8_t>(EventKind::Timer) == SODA_EVENT_TIMER);
static_assert(static_cast<std::uint8_t>(EventKind::FdReady) == SODA_EVENT_FD_READY);
static_assert(static_cast<std::uint8_t>(EventKind::PathChange) == SODA_EVENT_PATH_CHANGE);
static_assert(static_cast<std::uint8_t>(EventKind::ProcessOutput) == SODA_EVENT_PROCESS_OUTPUT);
static_assert(static_cast<std::uint8_t>(EventKind::ProcessExit) == SODA_EVENT_PROCESS_EXIT);

TEST_CASE("one-shot timer is delivered as a pulled event") {
    Runtime runtime;
    const SourceId timer = runtime.start_timer(1);

    CHECK(timer.valid());
    CHECK(runtime.poll(PollMode::Once) == 1);
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::Timer);
    CHECK(event->source == timer);
    CHECK(event->status == 0);
    CHECK(event->data.empty());

    (void)runtime.poll(PollMode::NoWait);
    CHECK_FALSE(runtime.alive());
}

TEST_CASE("repeating timer remains active until cancellation") {
    Runtime runtime;
    const SourceId timer = runtime.start_timer(0, 1);

    CHECK(runtime.poll(PollMode::Once) == 1);
    REQUIRE(runtime.next_event().has_value());
    CHECK(runtime.cancel(timer));
    CHECK_FALSE(runtime.cancel(timer));
    (void)runtime.poll(PollMode::NoWait);
    CHECK_FALSE(runtime.alive());
}

#if !defined(_WIN32)
TEST_CASE("process output streams precede its exit event") {
    Runtime runtime;
    const SourceId process = runtime.spawn_process({"/bin/sh", "-c",
                                                    "printf 'standard output'; "
                                                    "printf 'standard error' >&2; exit 7"});

    std::string standard_output;
    std::string standard_error;
    bool exited = false;
    while (!exited) {
        if (runtime.pending_events() == 0) {
            (void)runtime.poll(PollMode::Once);
        }
        while (const auto event = runtime.next_event()) {
            REQUIRE(event->source == process);
            if (event->kind == EventKind::ProcessOutput) {
                REQUIRE(event->status == 0);
                const std::string chunk(reinterpret_cast<const char*>(event->data.data()),
                                        event->data.size());
                if (event->flags == SODA_PROCESS_STDOUT) {
                    standard_output += chunk;
                } else if (event->flags == SODA_PROCESS_STDERR) {
                    standard_error += chunk;
                } else {
                    FAIL("unknown process output stream");
                }
            } else {
                REQUIRE(event->kind == EventKind::ProcessExit);
                CHECK(event->status == 7);
                CHECK(event->flags == 0);
                exited = true;
            }
        }
    }

    CHECK(standard_output == "standard output");
    CHECK(standard_error == "standard error");
    CHECK_FALSE(runtime.alive());
}

TEST_CASE("process input is written asynchronously and can be closed") {
    Runtime runtime;
    const SourceId process = runtime.spawn_process({"/bin/cat"});
    const std::string input = "first line\nsecond line\n";
    std::vector<std::byte> bytes(input.size());
    std::ranges::copy_n(reinterpret_cast<const std::byte*>(input.data()),
                        static_cast<std::ptrdiff_t>(input.size()), bytes.begin());
    runtime.write_process(process, std::move(bytes));
    runtime.close_process_input(process);

    std::string output;
    bool exited = false;
    while (!exited) {
        if (runtime.pending_events() == 0) {
            (void)runtime.poll(PollMode::Once);
        }
        while (const auto event = runtime.next_event()) {
            REQUIRE(event->source == process);
            if (event->kind == EventKind::ProcessOutput) {
                REQUIRE(event->status == 0);
                REQUIRE(event->flags == SODA_PROCESS_STDOUT);
                output.append(reinterpret_cast<const char*>(event->data.data()),
                              event->data.size());
            } else {
                REQUIRE(event->kind == EventKind::ProcessExit);
                CHECK(event->status == 0);
                CHECK(event->flags == 0);
                exited = true;
            }
        }
    }

    CHECK(output == input);
    CHECK_FALSE(runtime.alive());
}

TEST_CASE("terminal processes receive a pseudo-terminal and resize events") {
    Runtime runtime;
    const SourceId process = runtime.spawn_terminal_process(
        {"/bin/sh", "-c",
         "IFS= read line; size=$(stty size); printf 'line=%s size=%s' \"$line\" \"$size\""},
        "", 24, 80);
    runtime.resize_process_terminal(process, 40, 120);
    const std::string input = "terminal input\n";
    std::vector<std::byte> bytes(input.size());
    std::ranges::copy_n(reinterpret_cast<const std::byte*>(input.data()),
                        static_cast<std::ptrdiff_t>(input.size()), bytes.begin());
    runtime.write_process(process, std::move(bytes));

    std::string output;
    bool exited = false;
    while (!exited) {
        if (runtime.pending_events() == 0) {
            (void)runtime.poll(PollMode::Once);
        }
        while (const auto event = runtime.next_event()) {
            REQUIRE(event->source == process);
            if (event->kind == EventKind::ProcessOutput) {
                REQUIRE(event->status == 0);
                REQUIRE(event->flags == SODA_PROCESS_TERMINAL);
                output.append(reinterpret_cast<const char*>(event->data.data()),
                              event->data.size());
            } else {
                REQUIRE(event->kind == EventKind::ProcessExit);
                CHECK(event->status == 0);
                exited = true;
            }
        }
    }

    CHECK(output.find("terminal input") != std::string::npos);
    CHECK(output.find("line=terminal input size=40 120") != std::string::npos);
    CHECK_FALSE(runtime.alive());
}

TEST_CASE("process spawn failures are asynchronous exit events") {
    Runtime runtime;
    const SourceId process = runtime.spawn_process({"/soda/program/that/does/not/exist"});

    while (runtime.pending_events() == 0) {
        (void)runtime.poll(PollMode::Once);
    }
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::ProcessExit);
    CHECK(event->source == process);
    CHECK(event->status == UV_ENOENT);
    CHECK(event->data.empty());
    CHECK_FALSE(runtime.alive());
}

TEST_CASE("process cancellation terminates the child asynchronously") {
    Runtime runtime;
    const SourceId process = runtime.spawn_process({"/bin/sleep", "30"});
    CHECK(runtime.cancel(process));

    bool exited = false;
    while (!exited) {
        if (runtime.pending_events() == 0) {
            (void)runtime.poll(PollMode::Once);
        }
        while (const auto event = runtime.next_event()) {
            REQUIRE(event->source == process);
            if (event->kind == EventKind::ProcessExit) {
                CHECK(event->flags == SIGTERM);
                exited = true;
            }
        }
    }
    CHECK_FALSE(runtime.cancel(process));
    CHECK_FALSE(runtime.alive());
}

TEST_CASE("processes accept an explicit signal") {
    Runtime runtime;
    const SourceId process = runtime.spawn_process({"/bin/sleep", "30"});
    runtime.signal_process(process, SIGINT);

    bool exited = false;
    while (!exited) {
        if (runtime.pending_events() == 0) {
            (void)runtime.poll(PollMode::Once);
        }
        while (const auto event = runtime.next_event()) {
            REQUIRE(event->source == process);
            if (event->kind == EventKind::ProcessExit) {
                CHECK(event->flags == SIGINT);
                exited = true;
            }
        }
    }
    CHECK_FALSE(runtime.alive());
}
#endif

TEST_CASE("path watch reports directory entry changes until cancellation") {
    namespace fs = std::filesystem;
    const fs::path directory =
        fs::temp_directory_path() /
        ("soda-runtime-watch-" +
         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    REQUIRE(fs::create_directory(directory));

    Runtime runtime;
    const SourceId watch = runtime.watch_path(directory.string());
    {
        std::ofstream output(directory / "source.scm", std::ios::binary);
        output << "value";
    }

    while (runtime.pending_events() == 0) {
        (void)runtime.poll(PollMode::Once);
    }
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::PathChange);
    CHECK(event->source == watch);
    CHECK(event->status == 0);
    CHECK((event->flags & (UV_RENAME | UV_CHANGE)) != 0);
    const std::string name(reinterpret_cast<const char*>(event->data.data()), event->data.size());
    CHECK(name == "source.scm");

    CHECK(runtime.cancel(watch));
    CHECK_FALSE(runtime.cancel(watch));
    (void)runtime.poll(PollMode::NoWait);
    fs::remove_all(directory);
}

#if !defined(_WIN32)
TEST_CASE("fd readiness does not transfer fd ownership") {
    std::array<int, 2> pipe_fds{};
    REQUIRE(::pipe(pipe_fds.data()) == 0);

    Runtime runtime;
    const SourceId watch = runtime.watch_fd(pipe_fds[0], FdEvent::Readable);
    const char input = 'x';
    REQUIRE(::write(pipe_fds[1], &input, 1) == 1);

    CHECK(runtime.poll(PollMode::Once) == 1);
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::FdReady);
    CHECK(event->source == watch);
    CHECK(event->status == 0);
    CHECK((event->flags & static_cast<std::uint32_t>(FdEvent::Readable)) != 0);

    char output = '\0';
    REQUIRE(::read(pipe_fds[0], &output, 1) == 1);
    CHECK(output == input);
    CHECK(runtime.cancel(watch));
    (void)runtime.poll(PollMode::NoWait);

    CHECK(::close(pipe_fds[0]) == 0);
    CHECK(::close(pipe_fds[1]) == 0);
}

TEST_CASE("terminal ABI owns raw mode but not its descriptors") {
    const int master = ::posix_openpt(O_RDWR | O_NOCTTY);
    REQUIRE(master >= 0);
    REQUIRE(::grantpt(master) == 0);
    REQUIRE(::unlockpt(master) == 0);
    const char* slave_name = ::ptsname(master);
    REQUIRE(slave_name != nullptr);
    const int slave = ::open(slave_name, O_RDWR | O_NOCTTY);
    REQUIRE(slave >= 0);

    termios original{};
    REQUIRE(::tcgetattr(slave, &original) == 0);
    winsize requested{};
    requested.ws_row = 40;
    requested.ws_col = 100;
    REQUIRE(::ioctl(slave, TIOCSWINSZ, &requested) == 0);

    soda_terminal* terminal = soda_terminal_create(slave, slave);
    REQUIRE(terminal != nullptr);
    REQUIRE(soda_terminal_enter_raw(terminal) == 0);

    termios raw{};
    REQUIRE(::tcgetattr(slave, &raw) == 0);
    CHECK((raw.c_lflag & ICANON) == 0);
    CHECK((raw.c_lflag & ECHO) == 0);

    std::uint32_t rows = 0;
    std::uint32_t columns = 0;
    REQUIRE(soda_terminal_size(terminal, &rows, &columns) == 0);
    CHECK(rows == 40);
    CHECK(columns == 100);

    Runtime runtime;
    const SourceId watch = runtime.watch_fd(slave, FdEvent::Readable);
    const std::uint8_t input = 'x';
    REQUIRE(::write(master, &input, 1) == 1);
    REQUIRE(runtime.poll(PollMode::Once) == 1);
    REQUIRE(runtime.next_event().has_value());
    std::uint8_t received = 0;
    REQUIRE(soda_terminal_read(terminal, &received, 1) == 1);
    CHECK(received == input);
    CHECK(runtime.cancel(watch));
    (void)runtime.poll(PollMode::NoWait);

    const std::uint8_t output = 'y';
    REQUIRE(soda_terminal_write(terminal, &output, 1) == 0);
    std::uint8_t observed = 0;
    REQUIRE(::read(master, &observed, 1) == 1);
    CHECK(observed == output);

    REQUIRE(soda_terminal_leave_raw(terminal) == 0);
    termios restored{};
    REQUIRE(::tcgetattr(slave, &restored) == 0);
    CHECK(restored.c_lflag == original.c_lflag);
    soda_terminal_destroy(terminal);

    CHECK(::close(slave) == 0);
    CHECK(::close(master) == 0);
}

TEST_CASE("terminal writes resume after a nonblocking descriptor would block") {
    std::array<int, 2> pipe_fds{};
    REQUIRE(::pipe(pipe_fds.data()) == 0);

    const int original_flags = ::fcntl(pipe_fds[1], F_GETFL, 0);
    REQUIRE(original_flags >= 0);
    REQUIRE(::fcntl(pipe_fds[1], F_SETFL, original_flags | O_NONBLOCK) == 0);

    std::array<std::uint8_t, 4096> filler{};
    std::size_t filled = 0;
    for (;;) {
        const ssize_t result = ::write(pipe_fds[1], filler.data(), filler.size());
        if (result > 0) {
            filled += static_cast<std::size_t>(result);
            continue;
        }
        REQUIRE(result < 0);
        REQUIRE((errno == EAGAIN || errno == EWOULDBLOCK));
        break;
    }

    soda_terminal* terminal = soda_terminal_create(pipe_fds[0], pipe_fds[1]);
    REQUIRE(terminal != nullptr);
    CHECK(soda_terminal_write_some(terminal, filler.data(), filler.size(), 0) ==
          SODA_TERMINAL_WOULD_BLOCK);
    const std::array<std::uint8_t, 15> payload{
        't', 'e', 'r', 'm', 'i', 'n', 'a', 'l', '-', 'o', 'u', 't', 'p', 'u', 't',
    };
    int write_status = -2;
    std::thread writer(
        [&] { write_status = soda_terminal_write(terminal, payload.data(), payload.size()); });

    std::vector<std::uint8_t> observed(filled + payload.size());
    std::size_t offset = 0;
    while (offset < observed.size()) {
        const ssize_t result =
            ::read(pipe_fds[0], observed.data() + offset, observed.size() - offset);
        REQUIRE(result > 0);
        offset += static_cast<std::size_t>(result);
    }
    writer.join();

    CHECK(write_status == 0);
    CHECK(std::ranges::equal(payload, std::span(observed).last(payload.size())));

    soda_terminal_destroy(terminal);
    CHECK(::close(pipe_fds[0]) == 0);
    CHECK(::close(pipe_fds[1]) == 0);
}

TEST_CASE("terminal read reports a nonblocking descriptor would block") {
    std::array<int, 2> pipe_fds{};
    REQUIRE(::pipe(pipe_fds.data()) == 0);
    const int original_flags = ::fcntl(pipe_fds[0], F_GETFL, 0);
    REQUIRE(original_flags >= 0);
    REQUIRE(::fcntl(pipe_fds[0], F_SETFL, original_flags | O_NONBLOCK) == 0);

    soda_terminal* terminal = soda_terminal_create(pipe_fds[0], pipe_fds[1]);
    REQUIRE(terminal != nullptr);
    std::uint8_t byte = 0;
    CHECK(soda_terminal_read(terminal, &byte, 1) == SODA_TERMINAL_WOULD_BLOCK);

    soda_terminal_destroy(terminal);
    CHECK(::close(pipe_fds[0]) == 0);
    CHECK(::close(pipe_fds[1]) == 0);
}
#endif

TEST_CASE("C ABI exposes an event without native callbacks into its caller") {
    CHECK(soda_runtime_abi_version() == SODA_RUNTIME_ABI_VERSION);
    soda_runtime* runtime = soda_runtime_create();
    REQUIRE(runtime != nullptr);
    const std::uint64_t timer = soda_runtime_start_timer(runtime, 1, 0);
    REQUIRE(timer != 0);

    CHECK(soda_runtime_poll(runtime, SODA_POLL_ONCE) == 0);
    CHECK(soda_runtime_pending_events(runtime) == 1);
    CHECK(soda_runtime_next_event(runtime) == 1);
    CHECK(soda_runtime_event_kind(runtime) == SODA_EVENT_TIMER);
    CHECK(soda_runtime_event_source(runtime) == timer);
    CHECK(soda_runtime_event_status(runtime) == 0);
    CHECK(soda_runtime_event_data_size(runtime) == 0);
    CHECK(soda_runtime_next_event(runtime) == 0);

    soda_runtime_destroy(runtime);
}
