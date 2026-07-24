#pragma once

#include "runtime/event.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace soda::runtime {

enum class PollMode : std::uint8_t {
    NoWait,
    Once,
};

class Runtime {
public:
    Runtime();
    ~Runtime();

    Runtime(const Runtime&) = delete;
    Runtime& operator=(const Runtime&) = delete;
    Runtime(Runtime&&) = delete;
    Runtime& operator=(Runtime&&) = delete;

    [[nodiscard]] SourceId start_timer(std::uint64_t timeout_ms, std::uint64_t repeat_ms = 0);
    [[nodiscard]] SourceId watch_fd(int fd, FdEvent events);
    [[nodiscard]] SourceId read_file(std::string path);
    bool cancel(SourceId source);

    std::size_t poll(PollMode mode);
    [[nodiscard]] std::size_t pending_events() const;
    std::optional<Event> next_event();
    [[nodiscard]] bool alive() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace soda::runtime
