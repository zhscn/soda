#!/usr/bin/env python3
"""Capture complete-layout indentation examples from clang-format.

Usage: python3 scripts/generate_clang_format_indent_cases.py [clang-format-23]
Tests preserve each captured layout and only perturb its leading whitespace.
"""
import json
import pathlib
import subprocess
import sys

formatter = sys.argv[1] if len(sys.argv) > 1 else 'clang-format-23'
root = pathlib.Path(__file__).resolve().parents[1]
base = {'ColumnLimit': 0, 'AllowShortFunctionsOnASingleLine': 'None',
        'AllowShortIfStatementsOnASingleLine': 'Never',
        'AllowShortLoopsOnASingleLine': False, 'AllowShortBlocksOnASingleLine': 'Never'}
scopes = 'namespace outer { namespace inner { class A { int before; public: void f() { if (ok) { work(); } } private: int after; }; } }\n'
constructor = 'A::A() : first(1), second(2), third(3) {}\n'
call = 'void f() { call(argument,\nnext_argument); int a[] = {first,\nsecond}; }\n'
profiles = []
for tabs in ['Never', 'ForIndentation', 'ForContinuationAndIndentation', 'AlignWithSpaces', 'Always']:
    for width, tab in [(2, 4), (3, 8), (4, 4)]:
        profiles.append((f'tabs-{tabs}-{width}-{tab}', {'IndentWidth': width, 'TabWidth': tab, 'UseTab': tabs}, scopes))
for namespace in ['None', 'Inner', 'All']:
    profiles.append((f'namespace-{namespace}', {'NamespaceIndentation': namespace}, scopes))
for access in [False, True]:
    profiles.append((f'access-{access}', {'IndentAccessModifiers': access}, scopes))
for access_offset in [-4, -2, 0, 2]:
    profiles.append((f'access-offset-{access_offset}', {'IndentWidth': 4, 'AccessModifierOffset': access_offset}, scopes))
for layout in ['BeforeColon', 'BeforeComma', 'AfterColon', 'AfterComma']:
    profiles.append((f'constructor-{layout}', {'BreakConstructorInitializers': layout, 'ConstructorInitializerIndentWidth': 6}, constructor))
for layout in ['Block', 'FunctionCall', 'AlignFirstComment']:
    profiles.append((f'initializer-{layout}', {'Cpp11BracedListStyle': layout, 'BracedInitializerIndentWidth': 5}, call))
for extern in ['NoIndent', 'Indent', 'AfterExternBlock']:
    for braces in ['Attach', 'Allman']:
        profiles.append((f'extern-{extern}-{braces}', {'IndentExternBlock': extern, 'BreakBeforeBraces': braces}, 'extern "C" { void f() { work(); } }\n'))
for align in [False, True]:
    profiles.append((f'bracket-{align}', {'AlignAfterOpenBracket': align}, call))
for case_labels in [False, True]:
    profiles.append((f'case-labels-{case_labels}', {'IndentCaseLabels': case_labels}, 'void f() { switch (x) { case 1: work(); break; default: other(); } }\n'))
for wrapped in [False, True]:
    profiles.append((f'wrapped-name-{wrapped}', {'IndentWrappedFunctionNames': wrapped, 'BreakAfterReturnType': 'All'}, 'long unsigned function_name(int x) { return x; }\n'))
for layout in ['None', 'BeforeHash', 'AfterHash']:
    profiles.append((f'pp-{layout}', {'IndentPPDirectives': layout, 'PPIndentWidth': 3}, '#if A\n#define X 1\n#if B\n#define Y 2\n#endif\n#endif\n'))
for layout in ['BeforeHash', 'AfterHash']:
    for tabs in ['ForIndentation', 'ForContinuationAndIndentation', 'AlignWithSpaces', 'Always']:
        for indent, pp, tab in [(2, 4, 4), (4, 2, 4), (3, 8, 4)]:
            profiles.append((f'pp-tabs-{layout}-{tabs}-{indent}-{pp}-{tab}',
                {'IndentPPDirectives': layout, 'IndentWidth': indent, 'PPIndentWidth': pp,
                 'TabWidth': tab, 'UseTab': tabs},
                '#if A\n#define X 1\n#if B\n#define Y 2\n#endif\n#endif\n'))
lambdas = ('void f() {\nif ([&] {\nwork();\nreturn done();\n}()) {\ngo();\n}\n'
           'call(first, [&] {\nwork();\n});\nint value = compute(\n[&](int x) {\nreturn x;\n},\nother);\n'
           'auto g =\n[&](int x) {\nreturn x;\n};\nauto h =\n[&](int x) -> int {\nreturn x;\n};\n'
           'const auto [a,\nb] = [&]() {\nreturn pair();\n}();\nreturn ok() && [&] {\nreturn x;\n}();\n}\n')
profiles.append(('lambda-contexts', {'AllowShortLambdasOnASingleLine': 'None'}, lambdas))
arguments = ('void f(unsigned Level,\nconst Map<A *, B<C>>\n&Active,\nfunction_ref<bool(int A,\nint B)>\nCheck) {\n'
             'State.push(ParenState(/*Tok=*/nullptr, First,\n/*AvoidBinPacking=*/false,\n/*NoLineBreak=*/false));\n'
             'for (auto I = List.begin(),\nE = List.end();\nI != E; ++I) {\nwork();\n}\n'
             'if (Ready)\nreturn First() &&\n!Second();\nValue =\n// comment\ncompute(x);\n'
             'if (A ||\n// comment\nB) {\ngo();\n}\nDetails.push(\nnew (Context) Diagnostic{\nFirst,\nSecond});\n}\n')
profiles.append(('argument-alignment', {}, arguments))
# An all-caps call at the end of a line ends a statement only when the next
# line could start one; `<<` and `.` carry the expression on.
macro_calls = ('void f() {\nEXPECT_EQ(first, second)\n<< "message " << value;\n'
               'ASSERT_TRUE(ready)\n.With(x);\nLOG_EVENT(x)\nwork();\n}\n')
profiles.append(('macro-call-continuation', {'BasedOnStyle': 'Google'}, macro_calls))
# So does an all-caps name of five letters or more alone on its line.
profiles.append(('macro-name-statement', {'BasedOnStyle': 'Google'},
                 'namespace absl {\nABSL_NAMESPACE_BEGIN\n\n// Comment.\nvoid f();\nABSL_NAMESPACE_END\n}  // namespace absl\n'))
# Conditionals: a condition ending in a call, a chain whose colons line up with
# its first condition, and a link of the chain that is itself wrapped.
conditionals = ('void f() {\nWidth = VT->isPacked(*this)\n? VT->size()\n: 0;\n'
                'Kind K = A == B ? First\n: A == C ? Second\n: Third;\n}\n')
for before in [True, False]:
    profiles.append((f'conditional-before-{before}', {'BreakBeforeTernaryOperators': before}, conditionals))
# A #define replacement is laid out as code one level in; the expression of
# another directive continues from the `#`.
macros = ('#define PRINT(Name) \\\nif (counts[Idx]) \\\nerrs() << "  " << counts[Idx] \\\n<< #Name << " types"; \\\n++Idx;\n'
          '#define CASE(Id) \\\ncase Kind::Id: \\\nWidth = 0; \\\nbreak;\n'
          '#define CHECK_INFO(ci, y) \\\ndo { \\\nEXPECT_EQ(y, ci.year()); \\\n} while (0)\n'
          '#if defined(FIRST) && \\\ndefined(SECOND)\nint x;\n#elif (THIRD + \\\nFOURTH) > 3\nint y;\n#endif\n')
for style in ['LLVM', 'Google']:
    profiles.append((f'macro-body-{style}', {'BasedOnStyle': style}, macros))
# Declarators after a class body belong to its declaration; `struct` in a
# parameter list or a return type names a type and defines none.
records = ('static inline struct tm local(int t) {\nstruct tm value = convert(t);\nreturn value;\n}\n'
           'void f() {\nstatic const struct {\nconst char* in;\nint out;\n} specs[] = {\n{"", 0},\n{"a", 1},\n};\n}\n'
           'int convert(\nstruct addrinfo* ai, int host) {\nreturn host;\n}\n')
profiles.append(('record-declarators', {'BasedOnStyle': 'Google'}, records))
# A block a case label opens stands at the label's level, unless
# IndentCaseBlocks makes it a statement of the case.
case_blocks = ('void f() {\nswitch (x) {\ncase 1: {\nwork();\nbreak;\n}\ncase 2: // note\n{\nother();\n}\n'
               'case 3:\n// comment\n{\nmore();\n}\n}\n}\n')
for blocks in [False, True]:
    for after in [False, True]:
        profiles.append((f'case-blocks-{blocks}-after-{after}',
                         {'IndentCaseBlocks': blocks, 'BreakBeforeBraces': 'Custom',
                          'BraceWrapping': {'AfterCaseLabel': after}}, case_blocks))
# A requires clause on its own line under template parameters.
requires = ('template <class T>\nrequires Executor<std::decay_t<T>>\nvoid run(T t);\n'
            'struct A {\ntemplate <class C, class E>\nrequires(!Executor<C> &&\nExecutor<E>)\nA(C c, E e)\n: e(e) {}\nE e;\n};\n')
for indent in [True, False]:
    profiles.append((f'requires-{indent}', {'IndentRequiresClause': indent}, requires))
profiles.append(('conditional-wrapped-link', {},
                 'void f() {\nResult = Context.isHidden()\n? Hidden\n: Context.isProtected()\n? Protected\n: Default;\n}\n'))
cases = []
unsupported = []
for label, options, code in profiles:
    options = {**base, **options}
    result = subprocess.run([formatter, '--style=' + json.dumps(options)], input=code, text=True, capture_output=True)
    if result.returncode:
        unsupported.append({'name': label, 'error': result.stderr.strip()})
        continue
    cases.append({'name': label, 'options': options, 'expected': result.stdout})
if not cases:
    raise RuntimeError('reference executable produced no supported profiles')
output = {'reference': subprocess.check_output([formatter, '--version'], text=True).strip(), 'cases': cases, 'unsupported_profiles': unsupported}
(root / 'tests/fixtures/clang_format_indent_options.json').write_text(json.dumps(output, indent=2) + '\n')
print(f'Captured {len(cases)} indentation cases')
