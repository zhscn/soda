#!/usr/bin/env python3
"""Writes tests/fixtures/typing.json: code as clang-format lays it out, which
tests/typing.rs then types into the editor one key at a time."""
import json
import os
import subprocess
import tempfile

STYLES = {
    "llvm": "BasedOnStyle: LLVM\nColumnLimit: 0\n",
    "google": "BasedOnStyle: Google\nColumnLimit: 0\n",
    "webkit": "BasedOnStyle: WebKit\nColumnLimit: 0\n",
    "mozilla": "BasedOnStyle: Mozilla\nColumnLimit: 0\n",
}
for mode in ["Never", "ForIndentation", "ForContinuationAndIndentation", "Always"]:
    STYLES["tabs-" + mode] = (
        "BasedOnStyle: LLVM\nColumnLimit: 0\nIndentWidth: 4\nTabWidth: 4\n"
        "ContinuationIndentWidth: 4\nUseTab: %s\n" % mode
    )

CASES = {
    "call-arguments": """void f() {
call(aaa,
bbb,
ccc);
}""",
    "nested-calls": """void f() {
outer(inner(aaa,
bbb),
ccc);
}""",
    "argument-after-open": """void f() {
call(
aaa,
bbb);
}""",
    "condition": """void f() {
if (aaa &&
bbb) {
call();
}
}""",
    "continued-assignment": """void f() {
int y =
1;
int z = 2;
}""",
    "subscript": """void f() {
int v = table[aaa +
bbb];
}""",
    "parameters": """int add(int first,
int second) {
return first + second;
}""",
    "class": """class A {
public:
void f(int a,
int b);

private:
int x;
};""",
    "else": """void f() {
if (a) {
b();
} else {
c();
}
}""",
}


def formatted(style, source):
    with tempfile.TemporaryDirectory() as directory:
        with open(os.path.join(directory, ".clang-format"), "w") as config:
            config.write(style)
        return subprocess.run(
            ["clang-format", "--style=file", "--assume-filename=a.cpp"],
            cwd=directory, input=source, capture_output=True, text=True, check=True,
        ).stdout


cases = []
for style, yaml in STYLES.items():
    for name, source in CASES.items():
        expected = formatted(yaml, source + "\n")
        cases.append({"name": f"{style}/{name}", "yaml": yaml, "expected": expected})
path = os.path.join(os.path.dirname(__file__), "..", "tests", "fixtures", "typing.json")
with open(path, "w") as out:
    json.dump(cases, out, indent=1)
    out.write("\n")
