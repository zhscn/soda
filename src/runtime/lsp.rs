//! Language servers, at the level of the protocol: processes, JSON-RPC and
//! keeping servers' copies of documents current. What to ask a server, and
//! what to do with its answers, is Lua's: `lua/lsp.lua`.
//!
//! A server is started for the first document of a language under a root,
//! so two projects have two servers. Documents are sent whole, shortly
//! after typing stops and before any request. Bytes are written on a thread, so that a large document costs the editor nothing.
use crate::{
    application::{Application, RootSource},
    core::Snapshot,
    editor::DocumentId,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::mpsc::{self, Receiver, Sender},
    time::{Duration, Instant},
};

/// How long after an edit a document goes out without a request needing it.
const SETTLE: Duration = Duration::from_millis(150);
/// A server that exits is started again, unless it exited this many times
/// within `CRASH_WINDOW`: then it waits for `lsp-restart`.
const CRASHES: usize = 3;
const CRASH_WINDOW: Duration = Duration::from_secs(180);

enum Outgoing {
    Message(Value),
    /// A document's text, turned into JSON on the writer thread.
    Open {
        uri: String,
        language: String,
        version: u64,
        snapshot: Snapshot,
    },
    Change {
        uri: String,
        version: u64,
        snapshot: Snapshot,
    },
}
impl Outgoing {
    fn value(self) -> Value {
        let notification = |method: &str, params: Value| json!({ "jsonrpc": "2.0", "method": method, "params": params });
        match self {
            Self::Message(value) => value,
            Self::Open {
                uri,
                language,
                version,
                snapshot,
            } => notification(
                "textDocument/didOpen",
                json!({ "textDocument": {
                    "uri": uri,
                    "languageId": language,
                    "version": version,
                    "text": snapshot.text(),
                }}),
            ),
            Self::Change {
                uri,
                version,
                snapshot,
            } => notification(
                "textDocument/didChange",
                json!({
                    "textDocument": { "uri": uri, "version": version },
                    "contentChanges": [{ "text": snapshot.text() }],
                }),
            ),
        }
    }
}

/// What a server said, or that it is gone.
enum Incoming {
    Message(Key, Value),
    Closed(Key),
}
/// What the runtime hands to Lua.
pub(super) enum Delivery {
    /// The answer to a request, for the function with this id.
    Answer {
        function: u64,
        result: Value,
        error: Value,
        /// Whether Lua takes the result as JSON behind a handle.
        raw: bool,
    },
    /// A language's function, to choose the root of a document's server.
    Root {
        function: u64,
        document: DocumentId,
        path: PathBuf,
    },
    /// A notification, for a function given to `soda.lsp.on`.
    Notification { function: u64, params: Value },
    /// A request from a server, for the functions given to `soda.lsp.on`:
    /// the first that returns something answers, otherwise `fallback`.
    Request {
        functions: Vec<u64>,
        params: Value,
        key: Key,
        id: Value,
        fallback: Value,
    },
}
/// How to run a language's server.
pub(super) struct Server {
    /// What keymaps of servers name it by.
    pub name: String,
    pub command: Vec<String>,
    /// `initializationOptions` of `initialize`.
    pub init: Value,
    /// What `workspace/configuration` answers from, by dotted section, and
    /// `workspace/didChangeConfiguration` sends once the server is up.
    pub settings: Value,
    pub auto: Auto,
    /// A Lua function that chooses a document's root, instead of markers.
    pub roots: Option<u64>,
}
/// When opening a document starts its server.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Auto {
    Always,
    /// Only where its root was found: a marker, a jump or a function, not
    /// a project taken for want of one.
    Marked,
    /// Only by `lsp-start`, as eglot; the default.
    Never,
}
/// A server as `soda.lsp.servers` lists it.
pub(super) struct Listed {
    pub language: String,
    pub root: PathBuf,
    pub command: Vec<String>,
    pub state: &'static str,
    pub uris: Vec<String>,
}

/// A language and the root a server for it runs in.
pub(super) type Key = (String, PathBuf);

struct Opened {
    uri: String,
    version: u64,
    edited: Option<Instant>,
}
struct Client {
    process: Child,
    writer: Sender<Outgoing>,
    next: i64,
    /// Waiting for the answer to `initialize`.
    held: Option<Vec<Outgoing>>,
    /// The function each answer goes to, and whether it goes raw.
    waiting: HashMap<i64, (u64, bool)>,
    encoding: String,
    capabilities: Value,
    opened: HashMap<DocumentId, Opened>,
    /// The file watchers the server registered, by registration id.
    watchers: Vec<(String, Vec<Value>)>,
}
impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}
impl Client {
    fn send(&mut self, message: Outgoing) {
        match &mut self.held {
            Some(held) => held.push(message),
            None => {
                let _ = self.writer.send(message);
            }
        }
    }
}

pub(super) struct Lsp {
    enabled: bool,
    servers: HashMap<String, Server>,
    clients: HashMap<Key, Client>,
    /// Servers that failed; `lsp-restart` lets them try again.
    failed: Vec<Key>,
    /// Servers `lsp-stop` stopped, and the documents it took from them, by
    /// language: only `lsp-start` starts a server for them again.
    stopped: Vec<Key>,
    held: HashMap<DocumentId, String>,
    /// Documents whose root a function was asked for, and the questions
    /// not yet handed out.
    asking: std::collections::HashSet<DocumentId>,
    asks: Vec<Delivery>,
    /// When each server exited lately.
    crashes: HashMap<Key, Vec<Instant>>,
    handlers: HashMap<String, Vec<u64>>,
    incoming: (Sender<Incoming>, Receiver<Incoming>),
}
impl Default for Lsp {
    fn default() -> Self {
        Self {
            enabled: false,
            servers: HashMap::new(),
            clients: HashMap::new(),
            failed: vec![],
            stopped: vec![],
            held: HashMap::new(),
            asking: Default::default(),
            asks: vec![],
            crashes: HashMap::new(),
            handlers: HashMap::new(),
            incoming: mpsc::channel(),
        }
    }
}

fn frame(value: &Value) -> Vec<u8> {
    let body = value.to_string();
    let mut bytes = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
    bytes.extend_from_slice(body.as_bytes());
    bytes
}
/// One message, or `None` at the end of the stream.
fn read_message(reader: &mut impl BufRead) -> Option<Value> {
    let mut length = None;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse::<usize>().ok();
        }
    }
    let mut body = vec![0; length?];
    reader.read_exact(&mut body).ok()?;
    // A message that does not parse is the server's bug, not the end of it.
    Some(serde_json::from_slice(&body).unwrap_or(Value::Null))
}
pub(super) fn uri(path: &Path) -> String {
    let mut uri = String::from("file://");
    for byte in path.to_string_lossy().bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => {
                uri.push(byte as char);
            }
            byte => uri.push_str(&format!("%{byte:02X}")),
        }
    }
    uri
}
/// What `workspace/configuration` answers for a section of the settings.
fn section(settings: &Value, name: Option<&str>) -> Value {
    let Some(name) = name.filter(|name| !name.is_empty()) else {
        return settings.clone();
    };
    name.split('.')
        .try_fold(settings, |value, key| value.get(key))
        .cloned()
        .unwrap_or(Value::Null)
}
fn initialize(root: &Path, init: &Value) -> Value {
    let mut message = json!({
        "jsonrpc": "2.0",
        "id": 0,
        "method": "initialize",
        "params": {
            "processId": std::process::id(),
            "rootUri": uri(root),
            "capabilities": {
                "general": { "positionEncodings": ["utf-8", "utf-16"] },
                "textDocument": {
                    "synchronization": { "didSave": true },
                    "completion": {
                        "completionItem": {
                            "snippetSupport": true,
                            "commitCharactersSupport": true,
                            "insertReplaceSupport": true,
                            "documentationFormat": ["plaintext"],
                            "resolveSupport": { "properties": ["documentation", "detail"] },
                        },
                        "completionList": { "itemDefaults": ["commitCharacters", "editRange"] },
                    },
                    "hover": { "contentFormat": ["plaintext"] },
                    "definition": {},
                    "references": {},
                    "callHierarchy": {},
                    "typeHierarchy": {},
                    "publishDiagnostics": {
                        "relatedInformation": true,
                        "tagSupport": { "valueSet": [1, 2] },
                    },
                    "diagnostic": { "relatedDocumentSupport": false },
                    "rename": { "prepareSupport": true },
                    "inlayHint": {},
                    "semanticTokens": {
                        "requests": { "full": { "delta": true } },
                        "tokenTypes": [
                            "namespace", "type", "class", "enum", "interface", "struct",
                            "typeParameter", "parameter", "variable", "property", "enumMember",
                            "function", "method", "macro", "keyword", "modifier", "comment",
                            "string", "number", "regexp", "operator", "decorator",
                        ],
                        "tokenModifiers": [
                            "declaration", "definition", "readonly", "static", "deprecated",
                            "abstract", "async", "modification", "documentation",
                            "defaultLibrary",
                        ],
                        "formats": ["relative"],
                    },
                    "declaration": {},
                    "typeDefinition": {},
                    "implementation": {},
                    "documentHighlight": {},
                    "formatting": {},
                    "rangeFormatting": {},
                    "signatureHelp": {
                        "signatureInformation": {
                            "parameterInformation": { "labelOffsetSupport": true },
                            "activeParameterSupport": true,
                        },
                    },
                    "documentSymbol": { "hierarchicalDocumentSymbolSupport": true },
                    "codeAction": {
                        "dataSupport": true,
                        "resolveSupport": { "properties": ["edit"] },
                        "codeActionLiteralSupport": {
                            "codeActionKind": {
                                "valueSet": ["quickfix", "refactor", "source"],
                            },
                        },
                    },
                },
                "window": {
                    "workDoneProgress": true,
                    "showMessage": {},
                    "showDocument": { "support": true },
                },
                "workspace": {
                    "applyEdit": true,
                    "configuration": true,
                    "diagnostics": { "refreshSupport": true },
                    "didChangeConfiguration": {},
                    "didChangeWatchedFiles": {
                        "dynamicRegistration": true,
                        "relativePatternSupport": true,
                    },
                    "fileOperations": {
                        "didCreate": true,
                        "didRename": true,
                        "didDelete": true,
                    },
                    "workspaceEdit": {
                        "documentChanges": true,
                        "resourceOperations": ["create", "rename", "delete"],
                        "failureHandling": "abort",
                    },
                },
            },
        },
    });
    if !init.is_null() {
        message["params"]["initializationOptions"] = init.clone();
    }
    message
}
impl Lsp {
    /// Lets documents start servers; frontends turn this on, so that
    /// headless runs start none.
    pub fn enable(&mut self) {
        self.enabled = true;
    }
    pub fn set_server(&mut self, language: String, server: Option<Server>) {
        match server {
            Some(server) => {
                self.servers.insert(language, server);
            }
            None => {
                self.servers.remove(&language);
                self.clients.retain(|key, _| key.0 != language);
            }
        }
    }
    /// Whether `language` has a server configured.
    pub fn serves(&self, language: &str) -> bool {
        self.servers.contains_key(language)
    }
    pub fn on(&mut self, method: String, function: u64) {
        self.handlers.entry(method).or_default().push(function);
    }
    /// Lets a server start where `lsp-stop` stopped it, or one failed.
    pub fn allow(&mut self, key: &Key) {
        self.stopped.retain(|stopped| stopped != key);
        self.held.retain(|_, language| *language != key.0);
        self.failed.retain(|failed| failed != key);
        self.crashes.remove(key);
    }
    /// Stops a server until `lsp-start`; returns the documents it had.
    pub fn stop(&mut self, key: &Key) -> Vec<(DocumentId, String)> {
        if !self.stopped.contains(key) {
            self.stopped.push(key.clone());
        }
        let opened: Vec<_> = self.clients.remove(key).map_or(vec![], |client| {
            client
                .opened
                .iter()
                .map(|(document, opened)| (*document, opened.uri.clone()))
                .collect()
        });
        for (document, _) in &opened {
            self.held.insert(*document, key.0.clone());
        }
        opened
    }
    /// The names of the servers each document is open in: what keymaps
    /// of servers hold in.
    pub fn serving(&self) -> HashMap<DocumentId, Vec<String>> {
        let mut serving: HashMap<DocumentId, Vec<String>> = HashMap::new();
        for ((language, _), client) in &self.clients {
            let Some(name) = self.servers.get(language).map(|server| &server.name) else {
                continue;
            };
            for document in client.opened.keys() {
                serving.entry(*document).or_default().push(name.clone());
            }
        }
        serving
    }
    /// Running, failed and stopped servers.
    pub fn servers(&self) -> Vec<Listed> {
        let command = |language: &str| {
            self.servers
                .get(language)
                .map_or(vec![], |server| server.command.clone())
        };
        let mut listed: Vec<Listed> = self
            .clients
            .iter()
            .map(|(key, client)| {
                let mut uris: Vec<_> = client.opened.values().map(|o| o.uri.clone()).collect();
                uris.sort();
                Listed {
                    language: key.0.clone(),
                    root: key.1.clone(),
                    command: command(&key.0),
                    state: if client.held.is_some() {
                        "starting"
                    } else {
                        "running"
                    },
                    uris,
                }
            })
            .collect();
        for (keys, state) in [(&self.failed, "failed"), (&self.stopped, "stopped")] {
            listed.extend(keys.iter().map(|key| Listed {
                language: key.0.clone(),
                root: key.1.clone(),
                command: command(&key.0),
                state,
                uris: vec![],
            }));
        }
        listed.sort_by(|a, b| (&a.language, &a.root).cmp(&(&b.language, &b.root)));
        listed
    }
    pub fn restart(&mut self, key: &Key) {
        self.failed.retain(|failed| failed != key);
        self.crashes.remove(key);
        self.clients.remove(key);
    }
    /// A server's position encoding, capabilities and file watchers.
    pub fn client_of(&self, key: &Key) -> Option<(&str, &Value, Vec<&Value>)> {
        let client = self.clients.get(key)?;
        let watchers = client.watchers.iter().flat_map(|(_, w)| w).collect();
        Some((&client.encoding, &client.capabilities, watchers))
    }
    fn start(&mut self, key: &Key) -> Result<(), String> {
        let (language, root) = key;
        let server = &self.servers[language];
        let command = &server.command;
        let mut process = Command::new(&command[0])
            .args(&command[1..])
            .current_dir(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| format!("{}: {error}", command[0]))?;
        let mut stdin = process.stdin.take().unwrap();
        let stdout = process.stdout.take().unwrap();
        let (writer, outgoing) = mpsc::channel::<Outgoing>();
        std::thread::spawn(move || {
            for message in outgoing {
                let bytes = frame(&message.value());
                if stdin
                    .write_all(&bytes)
                    .and_then(|()| stdin.flush())
                    .is_err()
                {
                    break;
                }
            }
        });
        let incoming = self.incoming.0.clone();
        let name = key.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            while let Some(message) = read_message(&mut reader) {
                if incoming
                    .send(Incoming::Message(name.clone(), message))
                    .is_err()
                {
                    return;
                }
                crate::wake::wake();
            }
            let _ = incoming.send(Incoming::Closed(name));
            crate::wake::wake();
        });
        let _ = writer.send(Outgoing::Message(initialize(root, &server.init)));
        self.clients.insert(
            key.clone(),
            Client {
                process,
                writer,
                next: 1,
                held: Some(vec![]),
                waiting: HashMap::new(),
                encoding: "utf-16".into(),
                capabilities: Value::Null,
                opened: HashMap::new(),
                watchers: vec![],
            },
        );
        Ok(())
    }
    /// Starts servers and tells them about documents. With `now`, sends
    /// edits that are still settling. Returns an error to show, if any.
    /// When an edited document is next due to go to its server.
    pub fn next_change(&self) -> Option<Instant> {
        self.clients
            .values()
            .flat_map(|client| client.opened.values())
            .filter_map(|opened| opened.edited)
            .map(|edited| edited + SETTLE)
            .min()
    }
    pub fn sync(&mut self, app: &Application, now: bool) -> Option<String> {
        if !self.enabled {
            return None;
        }
        let mut failure = None;
        let workspace = app.workspace();
        self.asking
            .retain(|document| workspace.editor(*document).is_some());
        self.held
            .retain(|document, _| workspace.editor(*document).is_some());
        for document in workspace.documents() {
            let Some(path) = workspace.file(document).and_then(|file| file.path()) else {
                continue;
            };
            let model = workspace.editor(document).unwrap().model().document();
            let language = model.language().profile().id.clone();
            let Some(server) = self.servers.get(&language) else {
                continue;
            };
            let root = app.server_root(document);
            // A function chooses where markers would; its answer comes later.
            if let Some(function) = server.roots
                && matches!(root.source, RootSource::Marked | RootSource::Project)
                && !app.server_root_chosen(document)
            {
                if self.asking.insert(document) {
                    self.asks.push(Delivery::Root {
                        function,
                        document,
                        path: path.to_owned(),
                    });
                }
                continue;
            }
            let wanted = match (server.auto, root.source) {
                (_, RootSource::Started) => true,
                (Auto::Never, _) | (Auto::Marked, RootSource::Project) => false,
                _ => true,
            };
            let key = (language.clone(), root.path);
            if self.failed.contains(&key) {
                continue;
            }
            let held = self.held.contains_key(&document) && root.source != RootSource::Started;
            if !self.clients.contains_key(&key) && (!wanted || held || self.stopped.contains(&key))
            {
                continue;
            }
            if !self.clients.contains_key(&key)
                && let Err(error) = self.start(&key)
            {
                self.failed.push(key);
                failure = Some(error);
                continue;
            }
            let client = self.clients.get_mut(&key).unwrap();
            let snapshot = model.snapshot();
            let version = snapshot.version();
            // A document whose file was renamed is another document to the
            // server: the old one closes and the new one opens.
            let current = uri(path);
            if let Some(opened) = client.opened.get(&document)
                && opened.uri != current
            {
                let old = client.opened.remove(&document).unwrap();
                client.send(Outgoing::Message(json!({
                    "jsonrpc": "2.0",
                    "method": "textDocument/didClose",
                    "params": { "textDocument": { "uri": old.uri } },
                })));
            }
            let Some(opened) = client.opened.get_mut(&document) else {
                let uri = current;
                client.opened.insert(
                    document,
                    Opened {
                        uri: uri.clone(),
                        version,
                        edited: None,
                    },
                );
                client.send(Outgoing::Open {
                    uri,
                    language,
                    version,
                    snapshot: snapshot.clone(),
                });
                continue;
            };
            if opened.version == version {
                continue;
            }
            let edited = *opened.edited.get_or_insert_with(Instant::now);
            if now || edited.elapsed() >= SETTLE {
                opened.version = version;
                opened.edited = None;
                let uri = opened.uri.clone();
                client.send(Outgoing::Change {
                    uri,
                    version,
                    snapshot: snapshot.clone(),
                });
            }
        }
        for (key, client) in &mut self.clients {
            // Gone, or now with another server.
            let closed: Vec<_> = client
                .opened
                .keys()
                .filter(|document| {
                    workspace.editor(**document).is_none_or(|editor| {
                        *editor.model().document().language().profile().id != key.0
                            || app.server_root_of(**document) != key.1
                    })
                })
                .copied()
                .collect();
            for document in closed {
                let opened = client.opened.remove(&document).unwrap();
                client.send(Outgoing::Message(json!({
                    "jsonrpc": "2.0",
                    "method": "textDocument/didClose",
                    "params": { "textDocument": { "uri": opened.uri } },
                })));
            }
        }
        failure
    }
    pub fn request(
        &mut self,
        key: &Key,
        method: &str,
        params: Value,
        function: u64,
        raw: bool,
    ) -> bool {
        let Some(client) = self.clients.get_mut(key) else {
            return false;
        };
        let id = client.next;
        client.next += 1;
        client.waiting.insert(id, (function, raw));
        client.send(Outgoing::Message(json!({
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        })));
        true
    }
    /// Tells the server that a request's answer is no longer wanted, and
    /// drops it when it comes; false when it already came.
    pub fn cancel(&mut self, function: u64) -> bool {
        for client in self.clients.values_mut() {
            let Some(id) = client
                .waiting
                .iter()
                .find(|(_, waiting)| waiting.0 == function)
                .map(|(id, _)| *id)
            else {
                continue;
            };
            client.waiting.remove(&id);
            client.send(Outgoing::Message(json!({
                "jsonrpc": "2.0", "method": "$/cancelRequest", "params": { "id": id },
            })));
            return true;
        }
        false
    }
    /// Answers a request a server made.
    pub fn reply(&mut self, key: &Key, id: Value, result: Value) {
        if let Some(client) = self.clients.get_mut(key) {
            client.send(Outgoing::Message(
                json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            ));
        }
    }
    pub fn notify(&mut self, key: &Key, method: &str, params: Value) -> bool {
        let Some(client) = self.clients.get_mut(key) else {
            return false;
        };
        client.send(Outgoing::Message(json!({
            "jsonrpc": "2.0", "method": method, "params": params,
        })));
        true
    }
    /// What servers said since the last call, and an error to show if one
    /// went away.
    pub fn poll(&mut self) -> (Vec<Delivery>, Option<String>) {
        let mut deliveries = std::mem::take(&mut self.asks);
        let mut failure = None;
        while let Ok(incoming) = self.incoming.1.try_recv() {
            match incoming {
                Incoming::Closed(key) => {
                    if self.clients.remove(&key).is_some() {
                        let crashes = self.crashes.entry(key.clone()).or_default();
                        crashes.retain(|at| at.elapsed() < CRASH_WINDOW);
                        crashes.push(Instant::now());
                        // The next sync starts it again and opens its
                        // documents anew.
                        if crashes.len() <= CRASHES {
                            failure = Some(format!(
                                "language server for {} exited; starting it again",
                                key.0
                            ));
                        } else {
                            failure = Some(format!(
                                "language server for {} exited {} times; lsp-restart tries again",
                                key.0,
                                crashes.len()
                            ));
                            self.failed.push(key);
                        }
                    }
                }
                Incoming::Message(key, message) => {
                    self.message(&key, message, &mut deliveries);
                }
            }
        }
        (deliveries, failure)
    }
    fn message(&mut self, key: &Key, mut message: Value, out: &mut Vec<Delivery>) {
        let Some(client) = self.clients.get_mut(key) else {
            return;
        };
        let id = message.get("id").cloned();
        let method = message.get("method").and_then(Value::as_str);
        match (id, method) {
            // Asked of us: nothing a client here needs to say, but servers
            // wait for an answer. Those with handlers reach Lua like any
            // notification, which cannot answer back, so an edit is reported
            // as applied before it is.
            (Some(id), Some(method)) => {
                let params = &message["params"];
                match method {
                    "client/registerCapability" => {
                        for registration in params["registrations"].as_array().into_iter().flatten()
                        {
                            if registration["method"] == "workspace/didChangeWatchedFiles" {
                                let watchers = registration["registerOptions"]["watchers"]
                                    .as_array()
                                    .cloned()
                                    .unwrap_or_default();
                                let id = registration["id"].as_str().unwrap_or_default();
                                client.watchers.push((id.to_owned(), watchers));
                            }
                        }
                    }
                    "client/unregisterCapability" => {
                        // The protocol spells it so.
                        for gone in params["unregisterations"].as_array().into_iter().flatten() {
                            client.watchers.retain(|(id, _)| gone["id"] != id.as_str());
                        }
                    }
                    _ => {}
                }
                let settings = self
                    .servers
                    .get(&key.0)
                    .map_or(&Value::Null, |server| &server.settings);
                let fallback = match method {
                    "workspace/applyEdit" => json!({ "applied": true }),
                    "workspace/configuration" => Value::Array(
                        params["items"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .map(|item| section(settings, item["section"].as_str()))
                            .collect(),
                    ),
                    _ => Value::Null,
                };
                // Lua answers when it has something to say; the server waits.
                match self.handlers.get(method) {
                    Some(functions) if !functions.is_empty() => out.push(Delivery::Request {
                        functions: functions.clone(),
                        params: params.clone(),
                        key: key.clone(),
                        id,
                        fallback,
                    }),
                    _ => client.send(Outgoing::Message(
                        json!({ "jsonrpc": "2.0", "id": id, "result": fallback }),
                    )),
                }
            }
            (None, Some(method)) => {
                for function in self.handlers.get(method).into_iter().flatten() {
                    out.push(Delivery::Notification {
                        function: *function,
                        params: message["params"].clone(),
                    });
                }
            }
            (Some(id), None) if id == json!(0) => {
                let result = &message["result"];
                client.capabilities = result["capabilities"].clone();
                if let Some(encoding) = result["capabilities"]["positionEncoding"]
                    .as_str()
                    .or(result["offsetEncoding"].as_str())
                {
                    client.encoding = encoding.to_owned();
                }
                let held = client.held.take().unwrap_or_default();
                client.send(Outgoing::Message(
                    json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }),
                ));
                if let Some(server) = self.servers.get(&key.0)
                    && !server.settings.is_null()
                {
                    client.send(Outgoing::Message(json!({
                        "jsonrpc": "2.0",
                        "method": "workspace/didChangeConfiguration",
                        "params": { "settings": server.settings },
                    })));
                }
                for message in held {
                    client.send(message);
                }
            }
            (Some(id), None) => {
                if let Some((function, raw)) = id.as_i64().and_then(|id| client.waiting.remove(&id))
                {
                    // Taken, not copied: an answer may be megabytes.
                    out.push(Delivery::Answer {
                        function,
                        result: message["result"].take(),
                        error: message["error"].take(),
                        raw,
                    });
                }
            }
            (None, None) => {}
        }
    }
}
