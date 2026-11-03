#!/usr/bin/env python3
"""A language server that answers from fixed data and logs what it is told."""
import json
import os
import sys

log = open(os.environ["FAKE_LSP_LOG"], "a", buffering=1)
texts = {}


def read():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        line = line.strip()
        if not line:
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    return json.loads(sys.stdin.buffer.read(length))


def write(message):
    body = json.dumps(message).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


def answer(message, result):
    write({"jsonrpc": "2.0", "id": message["id"], "result": result})


def spot(uri, line, character):
    position = {"line": line, "character": character}
    return {"uri": uri, "range": {"start": position, "end": position}}


def replacement(line, start, end, text):
    return {"range": {"start": {"line": line, "character": start},
                      "end": {"line": line, "character": end}}, "newText": text}


while True:
    message = read()
    method = message.get("method", "")
    params = message.get("params", {})
    if method == "initialize":
        log.write("initialize %s\n" % params["rootUri"])
        log.write("init %s\n" % json.dumps(params.get("initializationOptions")))
        # A question first, as real servers ask, to see that it is answered.
        write({"jsonrpc": "2.0", "id": "q", "method": "window/workDoneProgress/create"})
        answer(message, {"capabilities": {
            "positionEncoding": "utf-16",
            "inlayHintProvider": True,
            "semanticTokensProvider": {
                "legend": {"tokenTypes": ["function", "variable", "parameter"],
                           "tokenModifiers": []},
                "full": {"delta": True},
            },
            "completionProvider": {"resolveProvider": True},
            "definitionProvider": True, "declarationProvider": True,
            "typeDefinitionProvider": True, "referencesProvider": True,
            "implementationProvider": True, "documentHighlightProvider": True,
            "diagnosticProvider": {"interFileDependencies": False, "workspaceDiagnostics": False},
            "hoverProvider": True, "renameProvider": {"prepareProvider": True}, "codeActionProvider": True,
            "documentFormattingProvider": True, "documentRangeFormattingProvider": True, "documentSymbolProvider": True,
            "callHierarchyProvider": True, "signatureHelpProvider": {},
            "workspaceSymbolProvider": True,
            "workspace": {"fileOperations": {
                "didCreate": {"filters": [{"pattern": {"glob": "**/*.cpp"}}]},
                "didRename": {"filters": [{"pattern": {"glob": "**/*.cpp", "matches": "file"}},
                                          {"pattern": {"glob": "**/old", "matches": "folder"}}]},
                "didDelete": {"filters": [{"pattern": {"glob": "**/*.{c,h}"}}]},
            }},
        }})
    elif method == "initialized":
        write({"jsonrpc": "2.0", "id": "config", "method": "workspace/configuration",
               "params": {"items": [{"section": "fake.index"}, {"section": "fake.none"}, {}]}})
        write({"jsonrpc": "2.0", "id": "private", "method": "$fake/ask", "params": {"n": 2}})
        write({"jsonrpc": "2.0", "id": "reg", "method": "client/registerCapability", "params": {
            "registrations": [{"id": "w", "method": "workspace/didChangeWatchedFiles",
                               "registerOptions": {"watchers": [
                                   # Created and deleted anywhere; changed only
                                   # under made/, relative to the project.
                                   {"globPattern": "**/*.cpp", "kind": 5},
                                   {"globPattern": {"baseUri": os.path.dirname(
                                       "file://" + os.environ["FAKE_LSP_LOG"]),
                                       "pattern": "made/*.cpp"}, "kind": 2}]}}]}})
    elif method == "workspace/didChangeWatchedFiles":
        log.write("watched %s\n" % json.dumps(
            [[c["uri"].rsplit("/", 1)[1], c["type"]] for c in params["changes"]]))
    elif method in ("workspace/didCreateFiles", "workspace/didDeleteFiles"):
        log.write("%s %s\n" % (method.split("/")[1], json.dumps(
            [f["uri"].rsplit("/", 1)[1] for f in params["files"]])))
    elif method == "workspace/didRenameFiles":
        log.write("didRenameFiles %s\n" % json.dumps(
            [[f["oldUri"].rsplit("/", 1)[1], f["newUri"].rsplit("/", 1)[1]] for f in params["files"]]))
    elif method == "textDocument/didClose":
        log.write("didClose %s\n" % params["textDocument"]["uri"].rsplit("/", 1)[1])
    elif method in ("textDocument/didOpen", "textDocument/didChange"):
        document = params["textDocument"]
        text = params.get("contentChanges", [{}])[0].get("text", document.get("text"))
        log.write("%s %d %s\n" % (method, document["version"], json.dumps(text)))
        texts[document["uri"]] = text
        if method == "textDocument/didOpen":
            log.write("opened %s\n" % document["uri"].rsplit("/", 1)[1])
        # ccls: lines 2 to 3 (zero-based 1 to 2) are not compiled.
        write({"jsonrpc": "2.0", "method": "$ccls/publishSkippedRanges", "params": {
            "uri": document["uri"], "skippedRanges": [
                {"start": {"line": 1, "character": 0}, "end": {"line": 2, "character": 3}}]}})
        write({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": document["uri"],
                "diagnostics": [{
                    "range": spot("", 1, 0)["range"],
                    "severity": 1,
                    "message": "bad line\nmore",
                }] + ([{
                    "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}},
                    "severity": 2, "message": "unused", "tags": [1],
                    "relatedInformation": [{"location": spot(document["uri"], 1, 0),
                                            "message": "declared here"}],
                }, {
                    "range": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 10}},
                    "severity": 3, "message": "old", "tags": [2],
                }] if "tagged" in text else []),
            },
        })
    elif method == "textDocument/definition":
        log.write("definition %s\n" % json.dumps(params["position"]))
        uri = params["textDocument"]["uri"]
        answer(message, [spot(uri, 1, 2)])
    elif method == "textDocument/references":
        uri = params["textDocument"]["uri"]
        answer(message, [spot(uri, 0, 0), spot(uri, 1, 2)])
    elif method == "textDocument/completion":
        position = params["position"]
        line, character = position["line"], position["character"]
        def span(start, end):
            return {"start": {"line": line, "character": start},
                    "end": {"line": line, "character": end}}
        answer(message, {"isIncomplete": False, "items": [
            {"label": "qq_replace", "textEdit": {
                "newText": "qq_replace", "insert": span(character - 2, character),
                "replace": span(character - 2, character + 2)}},
            {"label": "qq_doc", "commitCharacters": ["."], "data": 7},
            {"label": " server_call(int a)", "filterText": "server_call",
             "insertTextFormat": 2, "textEdit": {
                 "newText": "server_call(${1:int a})", "range": spot("", 0, 0)["range"]}},
            {"label": "server_plain", "insertText": "server_plain", "detail": "int"},
            {"label": "\u2022server_vector", "filterText": "server_vector",
             "insertText": "server_vector", "additionalTextEdits": [
                 {"newText": "#include <vector>\n", "range": spot("", 0, 0)["range"]}]},
        ]})
    elif method == "completionItem/resolve":
        log.write("resolve %s\n" % json.dumps(params.get("data")))
        params["documentation"] = {"kind": "plaintext", "value": "Some docs"}
        params["detail"] = "resolved"
        answer(message, params)
    elif method == "$/cancelRequest":
        log.write("cancel %s\n" % json.dumps(params["id"]))
    elif method == "textDocument/semanticTokens/full":
        # On line 0, column 1 for 2 units; then line 1, column 0 for 3, of a
        # type the client does not show, and a parameter at column 4.
        answer(message, {"resultId": "1",
                         "data": [0, 1, 2, 0, 0, 1, 0, 3, 1, 0, 0, 4, 1, 2, 0]})
    elif method == "textDocument/semanticTokens/full/delta":
        # The first token moves to column 2 for one unit.
        log.write("delta %s\n" % params["previousResultId"])
        answer(message, {"resultId": "2",
                         "edits": [{"start": 1, "deleteCount": 2, "data": [2, 1]}]})
    elif method == "textDocument/inlayHint":
        answer(message, [{"position": {"line": 0, "character": 2}, "label": "a:",
                          "paddingRight": True},
                         {"position": {"line": 1, "character": 0},
                          "label": [{"value": "int"}, {"value": "&"}]}])
    elif method == "textDocument/didSave":
        log.write("didSave\n")
    elif method == "$fake/progress":
        if True:
            def progress(value):
                write({"jsonrpc": "2.0", "method": "$/progress", "params": {"token": "t", "value": value}})
            progress({"kind": "begin", "title": "indexing", "percentage": 0})
            progress({"kind": "report", "message": "3/10", "percentage": 30})
            write({"jsonrpc": "2.0", "method": "window/logMessage", "params": {"type": 4, "message": "quiet words"}})
            write({"jsonrpc": "2.0", "method": "window/showMessage", "params": {"type": 3, "message": "loud words"}})
    elif method == "workspace/symbol" and params["query"] == "end":
        write({"jsonrpc": "2.0", "method": "$/progress", "params": {"token": "t", "value": {"kind": "end"}}})
        answer(message, [])
    elif method == "textDocument/signatureHelp":
        # A label with é, whose parameters are where they stand, in UTF-16.
        if params["position"]["character"] > 20:
            answer(message, {"activeSignature": 0, "activeParameter": 1, "signatures": [
                {"label": "é(int a, int b)", "parameters": [{"label": [2, 7]}, {"label": [9, 14]}]},
            ]})
        else:
            answer(message, {"activeSignature": 0, "activeParameter": 1, "signatures": [
                {"label": "add(int a, int b)", "parameters": [{"label": "int a"}, {"label": "int b"}]},
            ]})
    elif method == "textDocument/documentSymbol":
        answer(message, [{"name": "Outer", "kind": 5,
                          "selectionRange": spot("", 0, 1)["range"],
                          "children": [{"name": "inner", "kind": 6,
                                        "selectionRange": spot("", 1, 2)["range"]}]}])
    elif method == "workspace/symbol":
        uri = "file://" + os.path.dirname(os.environ["FAKE_LSP_LOG"]) + "/a.cpp"
        answer(message, [dict(name=params["query"], containerName="space", location=spot(uri, 1, 0))])
    elif method == "textDocument/switchSourceHeader":
        answer(message, params["uri"].replace("a.cpp", "b.cpp"))
    elif method == "textDocument/rangeFormatting":
        r = params["range"]
        log.write("rangeFormat %d:%d-%d:%d\n" % (r["start"]["line"], r["start"]["character"],
                                                r["end"]["line"], r["end"]["character"]))
        answer(message, [replacement(r["start"]["line"], 0, 3, "ranged")])
    elif method == "textDocument/formatting":
        log.write("format %d\n" % params["options"]["tabSize"])
        answer(message, [replacement(0, 0, 3, "formatted")])
    elif method == "textDocument/declaration":
        answer(message, spot(params["textDocument"]["uri"], 1, 2))
    elif method == "textDocument/documentHighlight":
        # Read on the first line, written on the second.
        answer(message, [{"range": spot("", 0, 0)["range"] | {"end": {"line": 0, "character": 3}}, "kind": 2},
                         {"range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 3}}, "kind": 3}])
    elif method == "textDocument/diagnostic":
        uri = params["textDocument"]["uri"]
        log.write("pull %s\n" % json.dumps(params.get("previousResultId")))
        if "pulled" in texts.get(uri, ""):
            answer(message, {"kind": "full", "resultId": "r1", "items": [
                {"range": spot("", 0, 0)["range"], "severity": 2, "message": "pulled one"}]})
        else:
            answer(message, {"kind": "unchanged", "resultId": "r0"})
    elif method == "textDocument/implementation":
        uri = params["textDocument"]["uri"]
        answer(message, [spot(uri, 0, 1), {"targetUri": uri, "targetSelectionRange": spot(uri, 1, 0)["range"],
                                           "targetRange": spot(uri, 1, 0)["range"]}])
    elif method == "textDocument/typeDefinition":
        answer(message, [])
    elif method == "textDocument/prepareRename":
        # Only the first line has a name, from the second byte on.
        line = params["position"]["line"]
        answer(message, None if line > 0 else
               {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 3}})
    elif method == "textDocument/rename" and params["newName"] in ("files", "clash"):
        uri = params["textDocument"]["uri"]
        base = uri.rsplit("/", 1)[0]
        made = base + "/made/new.cpp"
        if params["newName"] == "clash":
            answer(message, {"documentChanges": [
                {"kind": "rename", "oldUri": uri, "newUri": base + "/c.cpp"},
                {"kind": "create", "uri": base + "/gone.cpp"},
            ]})
            continue
        answer(message, {"documentChanges": [
            {"kind": "create", "uri": made},
            {"textDocument": {"uri": made, "version": None},
             "edits": [replacement(0, 0, 0, "// new\n")]},
            {"kind": "rename", "oldUri": uri, "newUri": base + "/c.cpp"},
            {"textDocument": {"uri": base + "/c.cpp", "version": None},
             "edits": [replacement(0, 0, 3, "renamed")]},
            {"kind": "rename", "oldUri": base + "/old", "newUri": base + "/new"},
            {"textDocument": {"uri": base + "/new/x.cpp", "version": None},
             "edits": [replacement(0, 0, 1, "y")]},
            {"kind": "delete", "uri": base + "/gone.cpp"},
        ]})
    elif method == "textDocument/rename":
        log.write("rename %s\n" % params["newName"])
        uri = params["textDocument"]["uri"]
        answer(message, {"changes": {
            uri: [replacement(0, 0, 3, params["newName"])],
            uri.replace("a.cpp", "b.cpp"): [replacement(1, 2, 5, params["newName"])],
        }})
    elif method == "textDocument/codeAction":
        uri = params["textDocument"]["uri"]
        # A real server refuses anything but an array here.
        log.write("codeAction %s\n" % json.dumps(params["context"]["diagnostics"])[:1])
        log.write("codeAction %d\n" % len(params["context"]["diagnostics"]))
        answer(message, [
            {"title": "Fix it", "kind": "quickfix",
             "edit": {"changes": {uri: [replacement(0, 0, 3, "fixed")]}}},
            {"title": "Tweak", "kind": "refactor",
             "command": {"title": "Tweak", "command": "tweak", "arguments": [uri]}},
            {"title": "Unavailable", "disabled": {"reason": "no"}},
        ])
    elif method == "workspace/executeCommand":
        log.write("execute %s\n" % params["command"])
        uri = params["arguments"][0]
        answer(message, None)
        write({"jsonrpc": "2.0", "id": "edit", "method": "workspace/applyEdit",
               "params": {"edit": {"changes": {uri: [replacement(0, 0, 3, "tweaked")]}}}})
    elif message.get("id") == "edit":
        log.write("applied %s\n" % json.dumps(message.get("result")))
    elif method == "workspace/didChangeConfiguration":
        log.write("settings %s\n" % json.dumps(params["settings"], sort_keys=True))
    elif "method" not in message and message.get("id") in ("config", "private"):
        log.write("answer %s %s\n" % (message["id"], json.dumps(message.get("result"), sort_keys=True)))
    elif method == "textDocument/hover":
        answer(message, {"contents": {"kind": "plaintext", "value": "first\n  second"}})
    elif method == "textDocument/prepareCallHierarchy":
        uri = params["textDocument"]["uri"]
        answer(message, [{"name": "target", "uri": uri}])
    elif method == "callHierarchy/incomingCalls":
        uri = params["item"]["uri"]
        answer(message, [{"from": {"name": "caller", "uri": uri},
                          "fromRanges": [spot(uri, 1, 2)["range"]]}])
    elif method in ("$ccls/call", "$ccls/inheritance", "$ccls/member"):
        log.write("%s %s\n" % (method, json.dumps({k: v for k, v in params.items()
                                                    if k not in ("textDocument", "position")},
                                                   sort_keys=True)))
        uri = "file://" + os.path.dirname(os.environ["FAKE_LSP_LOG"]) + "/a.cpp"
        def item(id, name, line, count, children=()):
            return {"id": id, "name": name, "fieldName": name + "_field", "kind": 2,
                    "location": spot(uri, line, 0), "numChildren": count,
                    "children": list(children)}
        if "id" not in params:
            answer(message, item("1", "root", 0, 2, [item("2", "first", 1, 1), item("3", "second", 2, 0)]))
        else:
            answer(message, item(params["id"], "x", 0, 1, [item("4", "deeper", 1, 0)]))
    elif method == "$ccls/vars":
        uri = params["textDocument"]["uri"]
        answer(message, [spot(uri, 1, 0)])
    elif method == "$ccls/navigate":
        log.write("navigate %s\n" % params["direction"])
        answer(message, [spot(params["textDocument"]["uri"], 2, 1)])
    elif method == "$ccls/reload":
        log.write("reload\n")
    elif method == "exit-now":
        sys.exit(0)
