#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include "document/c_api.h"
#include "runtime/c_api.h"
#include "runtime/runtime.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <span>
#include <string>
#include <vector>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#endif

using namespace soda::runtime;

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

TEST_CASE("asynchronous file read returns owned bytes") {
    namespace fs = std::filesystem;
    const fs::path path =
        fs::temp_directory_path() /
        ("soda-runtime-" +
         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    {
        std::ofstream output(path, std::ios::binary);
        output.write("alpha\0beta", 10);
    }

    Runtime runtime;
    const SourceId read = runtime.read_file(path.string());
    while (runtime.pending_events() == 0) {
        (void)runtime.poll(PollMode::Once);
    }
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::FileRead);
    CHECK(event->source == read);
    CHECK(event->status == 0);
    const std::string content(reinterpret_cast<const char*>(event->data.data()),
                              event->data.size());
    CHECK(content == std::string("alpha\0beta", 10));
    fs::remove(path);
}

TEST_CASE("file read failures are completion events") {
    Runtime runtime;
    const SourceId read = runtime.read_file("/soda/path/that/does/not/exist");

    CHECK(runtime.poll(PollMode::Once) == 1);
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::FileRead);
    CHECK(event->source == read);
    CHECK(event->status < 0);
    CHECK(event->data.empty());
}

TEST_CASE("asynchronous file write owns bytes and reports completion") {
    namespace fs = std::filesystem;
    const fs::path path =
        fs::temp_directory_path() /
        ("soda-runtime-write-" +
         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    const std::string expected{"new\0content", 11};
    std::vector<std::byte> data(expected.size());
    std::ranges::copy(std::as_bytes(std::span(expected.data(), expected.size())), data.begin());

    Runtime runtime;
    const SourceId write = runtime.write_file(path.string(), std::move(data));
    while (runtime.pending_events() == 0) {
        (void)runtime.poll(PollMode::Once);
    }
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::FileWrite);
    CHECK(event->source == write);
    CHECK(event->status == 0);
    CHECK(event->data.empty());

    std::ifstream input(path, std::ios::binary);
    const std::string actual((std::istreambuf_iterator<char>(input)),
                             std::istreambuf_iterator<char>());
    CHECK(actual == expected);
    fs::remove(path);
}

TEST_CASE("empty file write truncates existing content") {
    namespace fs = std::filesystem;
    const fs::path path =
        fs::temp_directory_path() /
        ("soda-runtime-empty-write-" +
         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    {
        std::ofstream output(path, std::ios::binary);
        output << "existing content";
    }

    Runtime runtime;
    const SourceId write = runtime.write_file(path.string(), {});
    while (runtime.pending_events() == 0) {
        (void)runtime.poll(PollMode::Once);
    }
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::FileWrite);
    CHECK(event->source == write);
    CHECK(event->status == 0);
    CHECK(fs::file_size(path) == 0);
    fs::remove(path);
}

TEST_CASE("file write failures are completion events") {
    Runtime runtime;
    const SourceId write = runtime.write_file("/soda/path/that/does/not/exist/file", {});

    CHECK(runtime.poll(PollMode::Once) == 1);
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::FileWrite);
    CHECK(event->source == write);
    CHECK(event->status < 0);
    CHECK(event->data.empty());
}

TEST_CASE("failed file replacement leaves the target intact and removes temporary files") {
    namespace fs = std::filesystem;
    const fs::path parent =
        fs::temp_directory_path() /
        ("soda-runtime-replace-failure-" +
         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    const fs::path target = parent / "target";
    fs::create_directories(target);
    {
        std::ofstream marker(target / "marker", std::ios::binary);
        marker << "original";
    }

    Runtime runtime;
    const SourceId write = runtime.write_file(target.string(), {std::byte{'x'}});
    while (runtime.pending_events() == 0) {
        (void)runtime.poll(PollMode::Once);
    }
    const auto event = runtime.next_event();
    REQUIRE(event.has_value());
    CHECK(event->kind == EventKind::FileWrite);
    CHECK(event->source == write);
    CHECK(event->status < 0);
    CHECK(fs::is_directory(target));
    CHECK(fs::exists(target / "marker"));
    CHECK(
        std::ranges::none_of(fs::directory_iterator(parent), [&](const fs::directory_entry& item) {
            return item.path().filename().string().starts_with("target.soda-save-");
        }));
    fs::remove_all(parent);
}

TEST_CASE("runtime destruction drains an active file request") {
    Runtime runtime;
    CHECK(runtime.read_file("/soda/path/that/does/not/exist").valid());
    CHECK(runtime.write_file("/soda/path/that/does/not/exist/file", {}).valid());
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

TEST_CASE("file event data constructs native Text without a Scheme copy") {
    namespace fs = std::filesystem;
    const fs::path path =
        fs::temp_directory_path() /
        ("soda-runtime-abi-" +
         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    {
        std::ofstream output(path, std::ios::binary);
        output << "native text";
    }

    soda_runtime* runtime = soda_runtime_create();
    REQUIRE(runtime != nullptr);
    const std::string path_string = path.string();
    REQUIRE(soda_runtime_read_file(runtime, path_string.c_str()) != 0);
    REQUIRE(soda_runtime_poll(runtime, SODA_POLL_ONCE) == 0);
    REQUIRE(soda_runtime_next_event(runtime) == 1);
    REQUIRE(soda_runtime_event_kind(runtime) == SODA_EVENT_FILE_READ);
    REQUIRE(soda_runtime_event_status(runtime) == 0);

    const std::size_t size = soda_runtime_event_data_size(runtime);
    const std::uint8_t* data = soda_runtime_event_data(runtime);
    REQUIRE(data != nullptr);
    soda_text* text = soda_text_create(data, size);
    REQUIRE(text != nullptr);
    CHECK(soda_text_size(text) == size);
    std::string content(size, '\0');
    REQUIRE(soda_text_copy(text, 0, static_cast<std::uint32_t>(size),
                           reinterpret_cast<std::uint8_t*>(content.data()), content.size()) == 0);
    CHECK(content == "native text");

    soda_text_destroy(text);
    soda_runtime_destroy(runtime);
    fs::remove(path);
}

TEST_CASE("C ABI writes caller bytes asynchronously") {
    namespace fs = std::filesystem;
    const fs::path path =
        fs::temp_directory_path() /
        ("soda-runtime-write-abi-" +
         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    const std::array<std::uint8_t, 5> data{'a', 'b', 0, 'c', 'd'};

    soda_runtime* runtime = soda_runtime_create();
    REQUIRE(runtime != nullptr);
    const std::string path_string = path.string();
    const std::uint64_t source =
        soda_runtime_write_file(runtime, path_string.c_str(), data.data(), data.size());
    REQUIRE(source != 0);
    REQUIRE(soda_runtime_poll(runtime, SODA_POLL_ONCE) == 0);
    REQUIRE(soda_runtime_next_event(runtime) == 1);
    CHECK(soda_runtime_event_kind(runtime) == SODA_EVENT_FILE_WRITE);
    CHECK(soda_runtime_event_source(runtime) == source);
    CHECK(soda_runtime_event_status(runtime) == 0);
    CHECK(soda_runtime_event_data_size(runtime) == 0);

    std::ifstream input(path, std::ios::binary);
    const std::string actual((std::istreambuf_iterator<char>(input)),
                             std::istreambuf_iterator<char>());
    CHECK(actual == std::string("ab\0cd", 5));

    soda_runtime_destroy(runtime);
    fs::remove(path);
}
