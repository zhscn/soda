#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include "soda/core.hpp"

using namespace soda;

TEST_CASE("aggregate native core advances analysis with an atomic editor command") {
    Document document("int main() {^}\n");
    EditTransaction remove_marker = document.begin_transaction();
    remove_marker.erase(make_range(12, 13));
    remove_marker.commit();

    Analyzer analyzer;
    const DocumentSnapshot before = document.snapshot();
    CHECK(analyzer.analyze(before).revision == before.revision());

    const EnterResult result = press_enter(document, TextOffset{12}, CppIndentStyle{}, analyzer);
    const DocumentSnapshot after = document.snapshot();

    CHECK(result.change.new_revision == after.revision());
    CHECK(analyzer.analyze(after).revision == after.revision());
    CHECK(after.content().to_string() == "int main() {\n    \n}\n");
}
