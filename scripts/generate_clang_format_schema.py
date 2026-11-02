#!/usr/bin/env python3
"""Capture YAML types and enum spellings from an LLVM checkout.

Usage: python3 scripts/generate_clang_format_schema.py /path/to/llvm-project
The generated schema validates configuration independently of preset contents.
Review generated changes against LLVM's conditional compatibility conversions;
those conversions and interactive rule semantics remain handwritten Rust.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
if len(sys.argv) != 2:
    sys.exit(__doc__)
LLVM = pathlib.Path(sys.argv[1])
FORMAT_CPP = 'clang/lib/Format/Format.cpp'
FORMAT_H = 'clang/include/clang/Format/Format.h'
INCLUDE_CPP = 'clang/lib/Tooling/Inclusions/IncludeStyle.cpp'
INCLUDE_H = 'clang/include/clang/Tooling/Inclusions/IncludeStyle.h'
TOKEN_KINDS = 'clang/include/clang/Basic/TokenKinds.def'


def read(path):
    text = (LLVM / path).read_text()
    return re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/',
                  lambda m: m[0] if m[0].startswith('"') else '', text)


def body(text, start):
    depth = 1
    for token in re.finditer(r'"(?:\\.|[^"\\])*"|[{}]', text[start:]):
        if token[0] == '{':
            depth += 1
        elif token[0] == '}':
            depth -= 1
            if depth == 0:
                return text[start:start + token.start()]
    raise ValueError('unclosed C++ declaration')


def name(typ):
    return typ.strip().removeprefix('FormatStyle::').removeprefix('IncludeStyle::')


def trait(kind, text):
    return {'kind': kind,
            'values': re.findall(r'IO\.enumCase\(\w+,\s*"([^"]+)"', text),
            'fields': re.findall(r'IO\.map(?:Optional|Required)\("([^"]+)",\s*([\w.]+)', text)}


source = read(FORMAT_CPP)
traits = {}
for match in re.finditer(r'template\s*<>\s*struct\s+(ScalarEnumerationTraits|MappingTraits)\s*<\s*([^>]+)>\s*\{', source):
    text = body(source, match.end())
    traits[name(match[2])] = trait(match[1], text)
    if name(match[2]) == 'FormatStyle':
        format_body = text
external = read(INCLUDE_CPP)
for match in re.finditer(r'(ScalarEnumerationTraits|MappingTraits)<\s*([^>]+)>\s*::\s*\w+\([^{}]+\{', external):
    traits[name(match[2])] = trait(match[1], body(external, match.end()))
structs = {}
for header in [read(FORMAT_H), read(INCLUDE_H)]:
    for match in re.finditer(r'struct\s+(\w+)\s*\{', header):
        text = body(header, match.end())
        structs[match[1]] = {field: typ for typ, field in
            re.findall(r'\b([\w:]+(?:\s*<[^;{}]+>)?)\s+(\w+)\s*;', text) if typ != 'return'}

schema = {}
primitives = {'bool': 'boolean', 'int': 'integer', 'unsigned': 'unsigned',
              'int8_t': 'integer', 'unsigned char': 'unsigned',
              'std::string': 'string', 'StringRef': 'string'}


def resolve(typ):
    typ = name(typ)
    if typ in schema:
        return typ
    if typ in primitives:
        schema[typ] = {'kind': primitives[typ]}
    elif match := re.fullmatch(r'std::vector\s*<\s*(.+)\s*>', typ):
        schema[typ] = {'kind': 'sequence', 'item': resolve(match[1])}
    elif typ in traits:
        item = traits[typ]
        if item['kind'] == 'ScalarEnumerationTraits':
            schema[typ] = {'kind': 'enum', 'values': item['values']}
        else:
            fields = {}
            schema[typ] = {'kind': 'mapping', 'fields': fields, 'values': item['values']}
            for key, expression in item['fields']:
                field = expression.split('.')[-1]
                if typ == 'SpacesInLineComment' and key == 'Maximum':
                    fields[key] = resolve('int')
                else:
                    fields[key] = resolve(structs[typ][field])
    elif typ in ('clang::tok::TokenKind', 'tok::TokenKind'):
        tokens = read(TOKEN_KINDS)
        schema[typ] = {'kind': 'enum', 'values': re.findall(r'PUNCTUATOR\(\w+,\s*"([^"]+)"\)', tokens)}
    else:
        raise ValueError(f'Unresolved YAML type: {typ}')
    return typ


options = {}
local = {field: typ for typ, field in re.findall(r'(?m)^\s*(?:const\s+)?([\w:]+)\s+(\w+)\s*(?:=[^;]+)?;', format_body)}
for key, expression in traits['FormatStyle']['fields']:
    if expression.startswith('Style.IncludeStyle.'):
        typ = structs['IncludeStyle'][expression.split('.')[-1]]
    elif expression.startswith('Style.'):
        typ = 'FormatStyle'
        for field in expression.split('.')[1:]:
            typ = structs[name(typ)][field]
    else:
        typ = local[expression]
    options[key] = resolve(typ)
# Input for this bool field also accepts the historical enum.
options['AlignAfterOpenBracket'] = resolve('BracketAlignmentStyle')
revision = subprocess.check_output(['git', '-C', str(LLVM), 'rev-parse', 'HEAD'], text=True).strip()
result = {'revision': revision, 'sources': [FORMAT_CPP, FORMAT_H, INCLUDE_CPP, INCLUDE_H, TOKEN_KINDS],
          'options': dict(sorted(options.items())), 'types': dict(sorted(schema.items()))}
(ROOT / 'src/config/schema.json').write_text(json.dumps(result, indent=2) + '\n')
cases = []
def visit(path, typ):
    entry = schema[typ]
    if entry.get('values'):
        cases.append({'option': path, 'values': entry['values'], 'type': typ})
    if entry['kind'] == 'mapping':
        for key, child in entry['fields'].items():
            visit(path + '.' + key, child)
    elif entry['kind'] == 'sequence':
        visit(path + '[]', entry['item'])
for key, typ in sorted(options.items()):
    visit(key, typ)
fixture = {'revision': revision, 'keys': sorted(options), 'cases': cases,
           'nested_aliases': {
               'IntegerLiteralSeparator.BinaryMinDigits': 'BinaryMinDigitsInsert',
               'IntegerLiteralSeparator.DecimalMinDigits': 'DecimalMinDigitsInsert',
               'IntegerLiteralSeparator.HexMinDigits': 'HexMinDigitsInsert'}}
(ROOT / 'tests/fixtures/clang_format_options.json').write_text(json.dumps(fixture, indent=2) + '\n')
print(f'Captured {len(options)} options and {len(schema)} YAML types from {revision}')

# Publish the application boundary for every top-level option. Runtime schema
# coverage and interactive behavior are different contracts.
import csv
cpp_adapter = (ROOT / 'src/config/cpp.rs').read_text()
mapped = set(re.findall(r'"([A-Za-z]\w*)"', cpp_adapter)) & options.keys()
mapped.update(['IndentFunctionDeclarationAfterType', 'BreakConstructorInitializersBeforeComma', 'IndentRequires'])
parser = (ROOT / 'src/config/parse.rs').read_text()
unsupported_block = parser.split('const UNSUPPORTED:')[1].split('];', 1)[0]
unsupported = set(re.findall(r'"([^"]+)"', unsupported_block))
partial = {'AlignOperands', 'Cpp11BracedListStyle', 'BraceWrapping', 'BreakBeforeBraces', 'MacroBlockBegin', 'MacroBlockEnd'}
with (ROOT / 'docs/clang-format-options.csv').open('w', newline='') as output:
    writer = csv.writer(output, lineterminator='\n')
    writer.writerow(['option', 'yaml_type', 'application'])
    for key, typ in sorted(options.items()):
        if key in ('BasedOnStyle', 'Language'):
            scope = 'configuration'
        elif key in unsupported:
            scope = 'retained; capability diagnostic'
        elif key in mapped:
            scope = 'interactive; partial strategies' if key in partial else 'interactive'
        else:
            scope = 'retained; formatter option'
        writer.writerow([key, typ, scope])
