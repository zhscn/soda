#include "regex/c_api.h"

#include "document/c_api_internal.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <regex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

struct soda_regex {
    explicit soda_regex(std::regex requested_value) : value(std::move(requested_value)) {}

    std::regex value;
};

struct soda_regex_matches {
    std::vector<std::pair<std::uint32_t, std::uint32_t>> values;
};

namespace {

thread_local std::array<char, 512> last_error{};

void clear_error() noexcept {
    last_error.front() = '\0';
}

void set_error(std::string_view message) noexcept {
    const std::size_t size = std::min(message.size(), last_error.size() - 1);
    std::ranges::copy_n(message.begin(), static_cast<std::ptrdiff_t>(size), last_error.begin());
    last_error[size] = '\0';
}

template <typename Result, typename Operation>
Result guard(Result failure, Operation&& operation) noexcept {
    try {
        clear_error();
        return std::forward<Operation>(operation)();
    } catch (const std::exception& exception) {
        set_error(exception.what());
    } catch (...) {
        set_error("unknown native regex failure");
    }
    return failure;
}

std::string_view bytes(const std::uint8_t* data, std::size_t size) {
    if (size == 0) {
        return {};
    }
    if (data == nullptr) {
        throw std::invalid_argument("regular-expression pattern is null");
    }
    return {reinterpret_cast<const char*>(data), size};
}

template <typename Handle>
const Handle& require_handle(const Handle* handle, std::string_view kind) {
    if (handle == nullptr) {
        throw std::invalid_argument(std::string(kind) + " handle is null");
    }
    return *handle;
}

std::uint32_t next_utf8_character(std::string_view text, std::uint32_t position,
                                  std::uint32_t limit) {
    if (position >= limit) {
        return limit;
    }
    std::uint32_t next = position + 1;
    while (next < limit &&
           (static_cast<unsigned char>(text[next]) & 0xc0U) == 0x80U) {
        ++next;
    }
    return next;
}

std::regex_constants::match_flag_type match_flags(std::uint32_t position,
                                                   std::uint32_t start,
                                                   std::uint32_t end,
                                                   std::uint32_t size) {
    auto flags = std::regex_constants::match_default;
    if (position != 0 || start != 0) {
        flags |= std::regex_constants::match_not_bol;
    }
    if (end != size) {
        flags |= std::regex_constants::match_not_eol;
    }
    return flags;
}

std::vector<std::pair<std::uint32_t, std::uint32_t>> collect_matches(const soda_regex& regex,
                                                                       const soda_text& handle,
                                                                       std::uint32_t start,
                                                                       std::uint32_t end) {
    const std::string text = soda::abi::unwrap_text(handle).to_string();
    const std::uint32_t size = static_cast<std::uint32_t>(text.size());
    if (start > end || end > size) {
        throw std::out_of_range("regular-expression range is outside text");
    }

    std::vector<std::pair<std::uint32_t, std::uint32_t>> output;
    std::uint32_t position = start;
    while (position <= end) {
        using Iterator = std::string::const_iterator;
        std::match_results<Iterator> result;
        const Iterator first = text.cbegin() + static_cast<std::ptrdiff_t>(position);
        const Iterator last = text.cbegin() + static_cast<std::ptrdiff_t>(end);
        if (!std::regex_search(first, last, result, regex.value,
                               match_flags(position, start, end, size))) {
            break;
        }
        const auto relative = static_cast<std::uint32_t>(result.position(0));
        const auto width = static_cast<std::uint32_t>(result.length(0));
        const std::uint32_t match_start = position + relative;
        const std::uint32_t match_end = match_start + width;
        output.emplace_back(match_start, match_end);
        if (match_end > match_start) {
            position = match_end;
        } else {
            const std::uint32_t next = next_utf8_character(text, match_start, end);
            if (next <= position) {
                break;
            }
            position = next;
        }
    }
    return output;
}

std::optional<std::pair<std::uint32_t, std::uint32_t>> find_match(
    const soda_regex& regex, const soda_text& handle, std::uint32_t start, std::uint32_t end,
    int direction) {
    const std::string text = soda::abi::unwrap_text(handle).to_string();
    const std::uint32_t size = static_cast<std::uint32_t>(text.size());
    if (start > end || end > size) {
        throw std::out_of_range("regular-expression range is outside text");
    }
    if (direction != SODA_REGEX_FORWARD && direction != SODA_REGEX_BACKWARD) {
        throw std::invalid_argument("regular-expression direction is invalid");
    }

    std::optional<std::pair<std::uint32_t, std::uint32_t>> latest;
    std::uint32_t position = start;
    while (position <= end) {
        using Iterator = std::string::const_iterator;
        std::match_results<Iterator> result;
        const Iterator first = text.cbegin() + static_cast<std::ptrdiff_t>(position);
        const Iterator last = text.cbegin() + static_cast<std::ptrdiff_t>(end);
        if (!std::regex_search(first, last, result, regex.value,
                               match_flags(position, start, end, size))) {
            break;
        }
        const std::uint32_t match_start =
            position + static_cast<std::uint32_t>(result.position(0));
        const std::uint32_t match_end =
            match_start + static_cast<std::uint32_t>(result.length(0));
        if (direction == SODA_REGEX_FORWARD) {
            return std::pair{match_start, match_end};
        }
        latest = std::pair{match_start, match_end};
        if (match_end > match_start) {
            position = match_end;
        } else {
            const std::uint32_t next = next_utf8_character(text, match_start, end);
            if (next <= position) {
                break;
            }
            position = next;
        }
    }
    return latest;
}

void write_range(std::pair<std::uint32_t, std::uint32_t> range, std::uint32_t* start,
                 std::uint32_t* end) {
    if (start == nullptr || end == nullptr) {
        throw std::invalid_argument("regular-expression output range is null");
    }
    *start = range.first;
    *end = range.second;
}

} // namespace

extern "C" {

uint32_t soda_regex_abi_version(void) {
    return SODA_REGEX_ABI_VERSION;
}

const char* soda_regex_last_error(void) {
    return last_error.data();
}

soda_regex* soda_regex_compile(const uint8_t* pattern, size_t size, int case_sensitive) {
    return guard<soda_regex*>(nullptr, [&] {
        auto flags = std::regex_constants::extended;
        if (case_sensitive == 0) {
            flags |= std::regex_constants::icase;
        } else if (case_sensitive != 1) {
            throw std::invalid_argument("regular-expression case policy is invalid");
        }
        return new soda_regex(std::regex(bytes(pattern, size).begin(),
                                         bytes(pattern, size).end(), flags));
    });
}

void soda_regex_destroy(soda_regex* regex) {
    delete regex;
}

int soda_regex_find(const soda_regex* regex, const soda_text* text, uint32_t start, uint32_t end,
                    int direction, uint32_t* match_start, uint32_t* match_end) {
    return guard(-1, [&] {
        const auto match = find_match(require_handle(regex, "regular-expression"),
                                      require_handle(text, "text"), start, end, direction);
        if (!match) {
            return 0;
        }
        write_range(*match, match_start, match_end);
        return 1;
    });
}

soda_regex_matches* soda_regex_collect(const soda_regex* regex, const soda_text* text,
                                       uint32_t start, uint32_t end) {
    return guard<soda_regex_matches*>(nullptr, [&] {
        auto output = std::make_unique<soda_regex_matches>();
        output->values = collect_matches(require_handle(regex, "regular-expression"),
                                         require_handle(text, "text"), start, end);
        return output.release();
    });
}

void soda_regex_matches_destroy(soda_regex_matches* matches) {
    delete matches;
}

uint32_t soda_regex_matches_count(const soda_regex_matches* matches) {
    return guard<std::uint32_t>(std::numeric_limits<std::uint32_t>::max(), [&] {
        const std::size_t count = require_handle(matches, "regular-expression matches").values.size();
        if (count > std::numeric_limits<std::uint32_t>::max()) {
            throw std::length_error("too many regular-expression matches");
        }
        return static_cast<std::uint32_t>(count);
    });
}

int soda_regex_matches_range(const soda_regex_matches* matches, uint32_t index,
                             uint32_t* match_start, uint32_t* match_end) {
    return guard(-1, [&] {
        const auto& values = require_handle(matches, "regular-expression matches").values;
        if (index >= values.size()) {
            throw std::out_of_range("regular-expression match index is out of range");
        }
        write_range(values[index], match_start, match_end);
        return 0;
    });
}

} // extern "C"
