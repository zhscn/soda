#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace soda::runtime {

struct SourceId {
    std::uint64_t value = 0;

    [[nodiscard]] bool valid() const noexcept { return value != 0; }
    bool operator==(const SourceId&) const = default;
};

enum class EventKind : std::uint8_t {
    Timer = 1,
    FdReady = 2,
    FileRead = 3,
    FileWrite = 4,
    DirectoryScan = 5,
    PathStat = 6,
};

enum class FdEvent : std::uint8_t {
    Readable = 1U << 0U,
    Writable = 1U << 1U,
};

constexpr FdEvent operator|(FdEvent left, FdEvent right) noexcept {
    return static_cast<FdEvent>(static_cast<std::uint32_t>(left) |
                                static_cast<std::uint32_t>(right));
}

constexpr bool contains(FdEvent events, FdEvent event) noexcept {
    return (static_cast<std::uint32_t>(events) & static_cast<std::uint32_t>(event)) != 0;
}

struct Event {
    EventKind kind = EventKind::Timer;
    SourceId source;
    int status = 0;
    std::uint32_t flags = 0;
    std::vector<std::byte> data;
};

} // namespace soda::runtime
