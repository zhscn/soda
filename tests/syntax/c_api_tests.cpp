#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include "document/c_api.h"
#include "syntax/c_api.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string_view>

namespace {

struct DocumentDeleter {
    void operator()(soda_document* value) const { soda_document_destroy(value); }
};

struct SnapshotDeleter {
    void operator()(soda_snapshot* value) const { soda_snapshot_destroy(value); }
};

struct TransactionDeleter {
    void operator()(soda_transaction* value) const { soda_transaction_destroy(value); }
};

struct ChangeDeleter {
    void operator()(soda_change* value) const { soda_change_destroy(value); }
};

struct AnalyzerDeleter {
    void operator()(soda_cpp_analyzer* value) const { soda_cpp_analyzer_destroy(value); }
};

using DocumentHandle = std::unique_ptr<soda_document, DocumentDeleter>;
using SnapshotHandle = std::unique_ptr<soda_snapshot, SnapshotDeleter>;
using TransactionHandle = std::unique_ptr<soda_transaction, TransactionDeleter>;
using ChangeHandle = std::unique_ptr<soda_change, ChangeDeleter>;
using AnalyzerHandle = std::unique_ptr<soda_cpp_analyzer, AnalyzerDeleter>;

DocumentHandle make_document(std::string_view value, std::uint32_t id = 0) {
    return DocumentHandle(soda_document_create(reinterpret_cast<const std::uint8_t*>(value.data()),
                                               value.size(), id));
}

} // namespace

TEST_CASE("analysis ABI exposes revision-keyed syntax nodes") {
    CHECK(soda_cpp_analysis_abi_version() == SODA_CPP_ANALYSIS_ABI_VERSION);
    CHECK(std::string_view(soda_syntax_kind_name(SODA_SYNTAX_FUNCTION_DEFINITION)) ==
          "FunctionDefinition");

    DocumentHandle document = make_document("int main() { return 0; }\n", 42);
    SnapshotHandle snapshot(soda_document_snapshot(document.get()));
    AnalyzerHandle analyzer(soda_cpp_analyzer_create());
    REQUIRE(snapshot != nullptr);
    REQUIRE(analyzer != nullptr);
    REQUIRE(soda_cpp_analyzer_analyze(analyzer.get(), snapshot.get()) == 0);

    CHECK(soda_cpp_analyzer_document_id(analyzer.get()) == 42);
    CHECK(soda_cpp_analyzer_revision(analyzer.get()) == 0);
    CHECK(soda_cpp_analyzer_node_count(analyzer.get()) > 1);

    const std::uint32_t root = soda_cpp_analyzer_root(analyzer.get());
    REQUIRE(root != SODA_SYNTAX_NODE_NONE);
    CHECK(soda_cpp_analyzer_node_kind(analyzer.get(), root) == SODA_SYNTAX_TRANSLATION_UNIT);
    CHECK(soda_cpp_analyzer_node_parent(analyzer.get(), root) == SODA_SYNTAX_NODE_NONE);
    CHECK(std::strlen(soda_cpp_analysis_last_error()) == 0);

    const std::uint32_t body = soda_cpp_analyzer_node_at(analyzer.get(), 13);
    REQUIRE(body != SODA_SYNTAX_NODE_NONE);
    std::uint32_t start = SODA_TEXT_NPOS;
    std::uint32_t end = SODA_TEXT_NPOS;
    REQUIRE(soda_cpp_analyzer_node_range(analyzer.get(), body, &start, &end) == 0);
    CHECK(start <= 13);
    CHECK(end > 13);
}

TEST_CASE("analysis ABI advances across a committed document change") {
    DocumentHandle document = make_document("int main() {}\n", 7);
    SnapshotHandle before(soda_document_snapshot(document.get()));
    AnalyzerHandle analyzer(soda_cpp_analyzer_create());
    REQUIRE(soda_cpp_analyzer_analyze(analyzer.get(), before.get()) == 0);

    TransactionHandle transaction(soda_document_begin_transaction(document.get()));
    const std::array<std::uint8_t, 9> inserted{'r', 'e', 't', 'u', 'r', 'n', ' ', '0', ';'};
    REQUIRE(soda_transaction_insert(transaction.get(), 12, inserted.data(), inserted.size()) == 0);
    ChangeHandle change(soda_transaction_commit(transaction.get()));
    SnapshotHandle after(soda_document_snapshot(document.get()));
    REQUIRE(change != nullptr);
    REQUIRE(after != nullptr);
    REQUIRE(soda_cpp_analyzer_apply(analyzer.get(), change.get(), after.get()) == 0);

    CHECK(soda_cpp_analyzer_revision(analyzer.get()) == 1);
    const std::uint32_t node = soda_cpp_analyzer_node_at(analyzer.get(), 12);
    CHECK(node != SODA_SYNTAX_NODE_NONE);

    std::uint32_t start = SODA_TEXT_NPOS;
    std::uint32_t end = SODA_TEXT_NPOS;
    CHECK(soda_cpp_analyzer_matching_bracket_range(analyzer.get(), 11, &start, &end) == 1);
    CHECK(start == 11);
    CHECK(end == 22);
    CHECK(soda_cpp_analyzer_sexp_forward(analyzer.get(), 12, &start, &end) == 1);
    CHECK(start == 12);
    CHECK(end == 18);
}

TEST_CASE("analysis ABI classifies revisioned lexical highlights") {
    constexpr std::string_view source =
        "#include <vector>\nconst int value = 42;\n// note\nconst char* text = \"ok\";\n";
    DocumentHandle document = make_document(source);
    SnapshotHandle snapshot(soda_document_snapshot(document.get()));
    AnalyzerHandle analyzer(soda_cpp_analyzer_create());
    REQUIRE(soda_cpp_analyzer_analyze(analyzer.get(), snapshot.get()) == 0);

    bool preprocessor = false;
    bool keyword = false;
    bool type = false;
    bool number = false;
    bool comment = false;
    bool string = false;
    bool delimiter = false;
    const std::uint32_t count = soda_cpp_analyzer_highlight_count(analyzer.get());
    REQUIRE(count != SODA_SYNTAX_NODE_NONE);
    for (std::uint32_t index = 0; index < count; ++index) {
        std::uint32_t start = SODA_TEXT_NPOS;
        std::uint32_t end = SODA_TEXT_NPOS;
        const int category = soda_cpp_analyzer_highlight_at(analyzer.get(), index, &start, &end);
        REQUIRE(category >= SODA_CPP_HIGHLIGHT_NONE);
        REQUIRE(start <= end);
        REQUIRE(end <= source.size());
        const std::string_view spelling = source.substr(start, end - start);
        preprocessor |= category == SODA_CPP_HIGHLIGHT_PREPROCESSOR && spelling == "include";
        keyword |= category == SODA_CPP_HIGHLIGHT_KEYWORD && spelling == "const";
        type |= category == SODA_CPP_HIGHLIGHT_TYPE && spelling == "int";
        number |= category == SODA_CPP_HIGHLIGHT_NUMBER && spelling == "42";
        comment |= category == SODA_CPP_HIGHLIGHT_COMMENT && spelling == "// note";
        string |= category == SODA_CPP_HIGHLIGHT_STRING && spelling == "\"ok\"";
        delimiter |= category == SODA_CPP_HIGHLIGHT_DELIMITER && spelling == ";";
    }
    CHECK(preprocessor);
    CHECK(keyword);
    CHECK(type);
    CHECK(number);
    CHECK(comment);
    CHECK(string);
    CHECK(delimiter);

    std::uint32_t start = 0;
    std::uint32_t end = 0;
    CHECK(soda_cpp_analyzer_highlight_at(analyzer.get(), count, &start, &end) == -1);
    CHECK(std::strlen(soda_cpp_analysis_last_error()) != 0);
}

TEST_CASE("analysis ABI rejects stale and fabricated node ids") {
    DocumentHandle document = make_document("int value;\n");
    SnapshotHandle snapshot(soda_document_snapshot(document.get()));
    AnalyzerHandle analyzer(soda_cpp_analyzer_create());
    REQUIRE(soda_cpp_analyzer_analyze(analyzer.get(), snapshot.get()) == 0);

    CHECK(soda_cpp_analyzer_node_kind(analyzer.get(), 99) == -1);
    CHECK(std::strlen(soda_cpp_analysis_last_error()) != 0);
    CHECK(soda_cpp_analyzer_node_at(analyzer.get(), 99) == SODA_SYNTAX_NODE_NONE);
    CHECK(std::strlen(soda_cpp_analysis_last_error()) != 0);
}
