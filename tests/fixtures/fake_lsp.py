#!/usr/bin/env python3
"""A language server that answers from fixed data and logs what it is told."""
import json
import os
import sys

log = open(os.environ["FAKE_LSP_LOG"], "a", buffering=1)


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
        # A question first, as real servers ask, to see that it is answered.
        write({"jsonrpc": "2.0", "id": "q", "method": "window/workDoneProgress/create"})
        answer(message, {"capabilities": {"positionEncoding": "utf-16"}})
    elif method in ("textDocument/didOpen", "textDocument/didChange"):
        document = params["textDocument"]
        text = params.get("contentChanges", [{}])[0].get("text", document.get("text"))
        log.write("%s %d %s\n" % (method, document["version"], json.dumps(text)))
        write({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": document["uri"],
                "diagnostics": [{
                    "range": spot("", 1, 0)["range"],
                    "severity": 1,
                    "message": "bad line\nmore",
                }],
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
        answer(message, {"isIncomplete": False, "items": [
            {"label": " server_call(int a)", "filterText": "server_call",
             "insertTextFormat": 2, "textEdit": {
                 "newText": "server_call(${1:int a})", "range": spot("", 0, 0)["range"]}},
            {"label": "server_plain", "insertText": "server_plain", "detail": "int"},
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
    elif method == "textDocument/hover":
        answer(message, {"contents": {"kind": "plaintext", "value": "first\n  second"}})
    elif method == "textDocument/prepareCallHierarchy":
        uri = params["textDocument"]["uri"]
        answer(message, [{"name": "target", "uri": uri}])
    elif method == "callHierarchy/incomingCalls":
        uri = params["item"]["uri"]
        answer(message, [{"from": {"name": "caller", "uri": uri},
                          "fromRanges": [spot(uri, 1, 2)["range"]]}])
    elif method == "exit-now":
        sys.exit(0)
