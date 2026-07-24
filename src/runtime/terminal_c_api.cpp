#include "runtime/c_api.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>
#include <ranges>
#include <string_view>

#if !defined(_WIN32)
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#endif

struct soda_terminal {
    int input_fd = -1;
    int output_fd = -1;
    bool raw = false;
    std::array<char, 512> last_error{};
#if !defined(_WIN32)
    termios original{};
#endif
};

namespace {

void clear_error(soda_terminal& terminal) noexcept {
    terminal.last_error.front() = '\0';
}

[[maybe_unused]] void set_error(soda_terminal& terminal, std::string_view message) noexcept {
    const std::size_t size = std::min(message.size(), terminal.last_error.size() - 1);
    std::ranges::copy_n(message.begin(), static_cast<std::ptrdiff_t>(size),
                        terminal.last_error.begin());
    terminal.last_error[size] = '\0';
}

void set_errno_error(soda_terminal& terminal, std::string_view operation) noexcept {
    const char* detail = std::strerror(errno);
    const std::size_t prefix =
        std::min(operation.size(), terminal.last_error.size() - std::size_t{1});
    std::ranges::copy_n(operation.begin(), static_cast<std::ptrdiff_t>(prefix),
                        terminal.last_error.begin());
    std::size_t offset = prefix;
    if (offset + 2 < terminal.last_error.size()) {
        terminal.last_error[offset++] = ':';
        terminal.last_error[offset++] = ' ';
    }
    const std::string_view detail_view = detail == nullptr ? "unknown error" : detail;
    const std::size_t suffix =
        std::min(detail_view.size(), terminal.last_error.size() - offset - 1);
    std::ranges::copy_n(detail_view.begin(), static_cast<std::ptrdiff_t>(suffix),
                        terminal.last_error.begin() + static_cast<std::ptrdiff_t>(offset));
    terminal.last_error[offset + suffix] = '\0';
}

} // namespace

extern "C" {

soda_terminal* soda_terminal_create(int input_fd, int output_fd) {
    if (input_fd < 0 || output_fd < 0) {
        return nullptr;
    }
    auto* terminal = new (std::nothrow) soda_terminal();
    if (terminal == nullptr) {
        return nullptr;
    }
    terminal->input_fd = input_fd;
    terminal->output_fd = output_fd;
    return terminal;
}

void soda_terminal_destroy(soda_terminal* terminal) {
    if (terminal == nullptr) {
        return;
    }
    (void)soda_terminal_leave_raw(terminal);
    delete terminal;
}

int soda_terminal_enter_raw(soda_terminal* terminal) {
    if (terminal == nullptr) {
        return -1;
    }
    clear_error(*terminal);
#if defined(_WIN32)
    set_error(*terminal, "raw terminal mode is unavailable on this platform");
    return -1;
#else
    if (terminal->raw) {
        return 0;
    }
    if (::tcgetattr(terminal->input_fd, &terminal->original) < 0) {
        set_errno_error(*terminal, "cannot read terminal attributes");
        return -1;
    }
    termios raw = terminal->original;
    raw.c_iflag &= static_cast<tcflag_t>(~(BRKINT | ICRNL | INPCK | ISTRIP | IXON));
    raw.c_oflag &= static_cast<tcflag_t>(~OPOST);
    raw.c_cflag |= CS8;
    raw.c_lflag &= static_cast<tcflag_t>(~(ECHO | ICANON | IEXTEN | ISIG));
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    if (::tcsetattr(terminal->input_fd, TCSAFLUSH, &raw) < 0) {
        set_errno_error(*terminal, "cannot enter raw terminal mode");
        return -1;
    }
    terminal->raw = true;
    return 0;
#endif
}

int soda_terminal_leave_raw(soda_terminal* terminal) {
    if (terminal == nullptr) {
        return -1;
    }
    clear_error(*terminal);
#if defined(_WIN32)
    terminal->raw = false;
    return 0;
#else
    if (!terminal->raw) {
        return 0;
    }
    if (::tcsetattr(terminal->input_fd, TCSAFLUSH, &terminal->original) < 0) {
        set_errno_error(*terminal, "cannot restore terminal mode");
        return -1;
    }
    terminal->raw = false;
    return 0;
#endif
}

int64_t soda_terminal_read(soda_terminal* terminal, uint8_t* destination, size_t capacity) {
    if (terminal == nullptr || (capacity != 0 && destination == nullptr)) {
        return -1;
    }
    clear_error(*terminal);
#if defined(_WIN32)
    set_error(*terminal, "terminal reads are unavailable on this platform");
    return -1;
#else
    for (;;) {
        const ssize_t result = ::read(terminal->input_fd, destination, capacity);
        if (result >= 0) {
            return result;
        }
        if (errno != EINTR) {
            set_errno_error(*terminal, "cannot read terminal input");
            return -1;
        }
    }
#endif
}

int soda_terminal_write(soda_terminal* terminal, const uint8_t* data, size_t size) {
    if (terminal == nullptr || (size != 0 && data == nullptr)) {
        return -1;
    }
    clear_error(*terminal);
#if defined(_WIN32)
    set_error(*terminal, "terminal writes are unavailable on this platform");
    return -1;
#else
    std::size_t offset = 0;
    while (offset < size) {
        const ssize_t result = ::write(terminal->output_fd, data + offset, size - offset);
        if (result > 0) {
            offset += static_cast<std::size_t>(result);
        } else if (result < 0 && errno == EINTR) {
            continue;
        } else {
            set_errno_error(*terminal, "cannot write terminal output");
            return -1;
        }
    }
    return 0;
#endif
}

int soda_terminal_size(soda_terminal* terminal, uint32_t* rows, uint32_t* columns) {
    if (terminal == nullptr || rows == nullptr || columns == nullptr) {
        return -1;
    }
    clear_error(*terminal);
#if defined(_WIN32)
    set_error(*terminal, "terminal size is unavailable on this platform");
    return -1;
#else
    winsize size{};
    if (::ioctl(terminal->output_fd, TIOCGWINSZ, &size) < 0) {
        set_errno_error(*terminal, "cannot read terminal size");
        return -1;
    }
    *rows = size.ws_row;
    *columns = size.ws_col;
    return 0;
#endif
}

const char* soda_terminal_last_error(soda_terminal* terminal) {
    return terminal == nullptr ? "terminal is null" : terminal->last_error.data();
}

} // extern "C"
