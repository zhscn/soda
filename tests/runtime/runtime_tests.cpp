#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include "document/c_api.h"
#include "runtime/c_api.h"
#include "runtime/runtime.hpp"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>

#if !defined(_WIN32)
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

TEST_CASE("runtime destruction drains an active file request") {
    Runtime runtime;
    CHECK(runtime.read_file("/soda/path/that/does/not/exist").valid());
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
#endif

TEST_CASE("C ABI exposes an event without native callbacks into its caller") {
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
