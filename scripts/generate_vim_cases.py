#!/usr/bin/env python3
"""Refresh Vim interaction fixtures with an isolated Vim executable."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--vim', default='vim')
parser.add_argument('--fixture', type=Path, default=Path('tests/fixtures/vim.json'))
args = parser.parse_args()
cases = json.loads(args.fixture.read_text())
with tempfile.TemporaryDirectory(prefix='soda-vim-') as temporary:
    root = Path(temporary)
    for case in cases:
        source, output, script = root/'input', root/'output', root/'script.vim'
        source.write_bytes(case['before'].encode())
        keys = case['keys'].replace('\\', '\\\\').replace('"', '\\"')
        for token in ['Esc', 'C-r', 'CR', 'BS']:
            keys = keys.replace('<'+token+'>', '\\<'+token+'>')
        script.write_text('set nocompatible\nset encoding=utf-8 tabstop=4 shiftwidth=4 autoindent nosmartindent\n'
            + 'edit '+str(source)+'\n'
            + 'call cursor(1,1)\n'
            + 'execute "normal! '+keys+'"\n'
            + 'let sep = &fileformat ==# "dos" ? "\\r\\n" : "\\n"\n'
            + 'let result = {"after": join(getline(1,"$"), sep), "cursor": max([0,line2byte(line("."))-1+col(".")-1])}\n'
            + 'call writefile([json_encode(result)], "'+str(output)+'")\nqa!\n')
        subprocess.run([args.vim, '-Nu', 'NONE', '-i', 'NONE', '-n', '-es', '-S', str(script)], check=True)
        case.update(json.loads(output.read_text()))
args.fixture.write_text(json.dumps(cases, ensure_ascii=False, indent=2)+'\n')
