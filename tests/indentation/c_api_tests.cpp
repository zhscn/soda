#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include "document/c_api.h"
#include "indentation/c_api.h"
#include "syntax/c_api.h"

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>

namespace {

struct DocumentDeleter {
    void operator()(soda_document* value) const { soda_document_destroy(value); }
};

struct SnapshotDeleter {
    void operator()(soda_snapshot* value) const { soda_snapshot_destroy(value); }
};

struct TextDeleter {
    void operator()(soda_text* value) const { soda_text_destroy(value); }
};

struct AnalyzerDeleter {
    void operator()(soda_cpp_analyzer* value) const { soda_cpp_analyzer_destroy(value); }
};

struct StyleDeleter {
    void operator()(soda_cpp_indent_style* value) const { soda_cpp_indent_style_destroy(value); }
};

struct ResultDeleter {
    void operator()(soda_indent_result* value) const { soda_indent_result_destroy(value); }
};

struct ChangeDeleter {
    void operator()(soda_change* value) const { soda_change_destroy(value); }
};

using DocumentHandle = std::unique_ptr<soda_document, DocumentDeleter>;
using SnapshotHandle = std::unique_ptr<soda_snapshot, SnapshotDeleter>;
using TextHandle = std::unique_ptr<soda_text, TextDeleter>;
using AnalyzerHandle = std::unique_ptr<soda_cpp_analyzer, AnalyzerDeleter>;
using StyleHandle = std::unique_ptr<soda_cpp_indent_style, StyleDeleter>;
using ResultHandle = std::unique_ptr<soda_indent_result, ResultDeleter>;
using ChangeHandle = std::unique_ptr<soda_change, ChangeDeleter>;

DocumentHandle make_document(std::string_view value) {
    return DocumentHandle(
        soda_document_create(reinterpret_cast<const std::uint8_t*>(value.data()), value.size(), 0));
}

std::string document_text(const soda_document* document) {
    SnapshotHandle snapshot(soda_document_snapshot(document));
    TextHandle text(soda_snapshot_text(snapshot.get()));
    const std::uint32_t size = soda_text_size(text.get());
    std::string output(size, '\0');
    REQUIRE(soda_text_copy(text.get(), 0, size, reinterpret_cast<std::uint8_t*>(output.data()),
                           output.size()) == 0);
    return output;
}

std::string indentation(const soda_indent_result* result) {
    const std::uint32_t size = soda_indent_result_indentation_size(result);
    std::string output(size, '\0');
    REQUIRE(soda_indent_result_copy_indentation(
                result, reinterpret_cast<std::uint8_t*>(output.data()), output.size()) == 0);
    return output;
}

} // namespace

TEST_CASE("indentation ABI computes decisions with a configurable style") {
    CHECK(soda_indentation_abi_version() == SODA_INDENTATION_ABI_VERSION);
    DocumentHandle document = make_document("int main() {\nreturn 0;\n}\n");
    SnapshotHandle snapshot(soda_document_snapshot(document.get()));
    AnalyzerHandle analyzer(soda_cpp_analyzer_create());
    StyleHandle style(soda_cpp_indent_style_create());
    REQUIRE(document != nullptr);
    REQUIRE(snapshot != nullptr);
    REQUIRE(analyzer != nullptr);
    REQUIRE(style != nullptr);

    REQUIRE(soda_cpp_indent_style_set(style.get(), SODA_INDENT_WIDTH, 2) == 0);
    int width = 0;
    REQUIRE(soda_cpp_indent_style_get(style.get(), SODA_INDENT_WIDTH, &width) == 0);
    CHECK(width == 2);

    ResultHandle result(
        soda_cpp_compute_line_indent(snapshot.get(), analyzer.get(), 1, style.get()));
    REQUIRE(result != nullptr);
    CHECK(soda_indent_result_target_column(result.get()) == 2);
    CHECK(indentation(result.get()) == "  ");
    CHECK(soda_cpp_analyzer_revision(analyzer.get()) == 0);
}

TEST_CASE("indentation ABI executes Enter as one document change") {
    DocumentHandle document = make_document("int main() {}\n");
    AnalyzerHandle analyzer(soda_cpp_analyzer_create());
    StyleHandle style(soda_cpp_indent_style_create());

    ResultHandle result(soda_cpp_press_enter(document.get(), analyzer.get(), 12, style.get()));
    REQUIRE(result != nullptr);
    CHECK(std::string_view(soda_indent_result_handler(result.get())) == "EnterBetweenBraces");
    CHECK(soda_indent_result_caret(result.get()) == 17);
    CHECK(document_text(document.get()) == "int main() {\n    \n}\n");
    CHECK(soda_cpp_analyzer_revision(analyzer.get()) == 1);

    ChangeHandle change(soda_indent_result_take_change(result.get()));
    REQUIRE(change != nullptr);
    CHECK(soda_change_old_revision(change.get()) == 0);
    CHECK(soda_change_new_revision(change.get()) == 1);
    CHECK(soda_indent_result_take_change(result.get()) == nullptr);
}
