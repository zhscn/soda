#pragma once

#include "syntax/analysis.hpp"

#include <cstdint>
#include <vector>

namespace soda {

enum class HighlightKind : std::uint8_t {
    None,
    Comment,
    String,
    Constant,
    Number,
    Keyword,
    Type,
    Delimiter,
    Preprocessor,
    Invalid,
    DocComment,
    FunctionName,
    FunctionCall,
    VariableName,
    PropertyName,
    Label,
    Operator,
    Bracket,
};

// Produces one category per token in the analysis tree. Lexical categories are
// refined with declaration and member-access context from the syntax tree.
std::vector<HighlightKind> classify_highlights(const Analysis& analysis);

} // namespace soda
