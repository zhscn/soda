//! A TextMate grammar engine for VS Code's JSON grammars. Grammars compile on
//! first use into one rule arena; `include`s that reach other grammars
//! resolve when a scan first needs them. Regular expressions use Oniguruma,
//! whose dialect the grammars are written in.
mod lines;
mod scan;
pub(super) use lines::Lines;
pub(super) use scan::State;

use super::{Category, bundled::PACKAGES, scope};
use onig::{Regex, RegexOptions, Syntax};
use serde_json::{Map, Value};
use std::{collections::HashMap, path::Path, sync::Arc};

pub(super) type RuleId = usize;
pub(super) type RegexId = usize;
pub(super) type GrammarId = usize;

/// A `name` or `contentName`. Names with `$n` take capture text when used.
#[derive(Clone)]
pub(super) struct Name {
    category: Option<Category>,
    template: Option<Box<str>>,
}
pub(super) struct Capture {
    name: Option<Name>,
    /// Patterns applied to the captured text, as a `Rule::Patterns`.
    patterns: Option<RuleId>,
}
/// Shared so a scan can hold them while compiling grammars it includes.
pub(super) type Captures = Arc<[Option<Capture>]>;

#[derive(Clone)]
pub(super) enum Pattern {
    Rule(RuleId),
    /// `$self`: the root of the grammar that declares the include.
    Root(GrammarId),
    /// `$base`: the root of the grammar being scanned.
    Base,
    /// Another grammar's root or one of its repository rules.
    External(Arc<str>, Option<Arc<str>>),
}
pub(super) enum Rule {
    Match {
        regex: RegexId,
        name: Option<Name>,
        captures: Captures,
    },
    Begin {
        begin: RegexId,
        /// The `end` or `while` pattern source; back references are
        /// replaced by `begin` captures when the rule is entered.
        end: Arc<str>,
        while_: bool,
        name: Option<Name>,
        content_name: Option<Name>,
        begin_captures: Captures,
        end_captures: Captures,
        patterns: Vec<Pattern>,
        end_last: bool,
    },
    Patterns(Vec<Pattern>),
}

struct RegexEntry {
    source: Arc<str>,
    compiled: Option<Option<Regex>>,
    /// `\G` depends on where a search starts, so its results are not reused.
    anchored: bool,
}
struct Grammar {
    root: RuleId,
    repository: HashMap<String, RuleId>,
}
/// A language from the bundled manifests.
pub(super) struct Language {
    /// VS Code's language id, which language configurations will key on.
    #[cfg_attr(not(test), allow(dead_code))]
    pub id: String,
    pub name: String,
    pub scope: String,
    extensions: Vec<String>,
    filenames: Vec<String>,
}

#[derive(Default)]
pub(super) struct Registry {
    languages: Vec<Language>,
    /// Grammar sources by scope name.
    sources: HashMap<String, &'static str>,
    grammars: Vec<Grammar>,
    by_scope: HashMap<String, Option<GrammarId>>,
    rules: Vec<Rule>,
    regexes: Vec<RegexEntry>,
    regex_ids: HashMap<Arc<str>, RegexId>,
    expansions: HashMap<(RuleId, GrammarId), Arc<[RuleId]>>,
    names: HashMap<String, Option<Category>>,
    /// Grammars or patterns that failed to load; kept for diagnostics.
    pub warnings: Vec<String>,
}

fn strings(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}
fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}
fn number(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_i64() == Some(1),
        _ => false,
    }
}

impl Registry {
    pub fn bundled() -> Self {
        let mut registry = Self::default();
        for package in PACKAGES {
            let manifest: Value = match serde_json::from_str(package.manifest) {
                Ok(manifest) => manifest,
                Err(error) => {
                    registry.warnings.push(format!("{}: {error}", package.name));
                    continue;
                }
            };
            let file = |path: &str| {
                let path = path.trim_start_matches("./");
                package
                    .files
                    .iter()
                    .find(|(p, _)| *p == path)
                    .map(|(_, text)| *text)
            };
            let grammars = manifest.get("grammars").and_then(Value::as_array);
            for grammar in grammars.into_iter().flatten() {
                if let (Some(scope), Some(source)) = (
                    text(grammar, "scopeName"),
                    text(grammar, "path").and_then(file),
                ) {
                    registry.sources.insert(scope.to_owned(), source);
                }
            }
            let languages = manifest.get("languages").and_then(Value::as_array);
            for language in languages.into_iter().flatten() {
                let Some(id) = text(language, "id") else {
                    continue;
                };
                let Some(scope) = grammars
                    .into_iter()
                    .flatten()
                    .find(|g| text(g, "language") == Some(id))
                    .and_then(|g| text(g, "scopeName"))
                else {
                    continue;
                };
                registry.languages.push(Language {
                    id: id.to_owned(),
                    name: strings(language, "aliases")
                        .into_iter()
                        .next()
                        .unwrap_or_else(|| id.to_owned()),
                    scope: scope.to_owned(),
                    extensions: strings(language, "extensions"),
                    filenames: strings(language, "filenames"),
                });
            }
        }
        registry
    }
    /// The language of a file: exact file names first, then the longest
    /// matching extension (extensions may contain dots, as in `.js.map`).
    pub fn detect(&self, path: &Path) -> Option<&Language> {
        let name = path.file_name()?.to_str()?;
        if let Some(language) = self
            .languages
            .iter()
            .find(|l| l.filenames.iter().any(|f| f == name))
        {
            return Some(language);
        }
        self.languages
            .iter()
            .flat_map(|l| l.extensions.iter().map(move |e| (l, e)))
            .filter(|(_, extension)| {
                name.len() > extension.len() && name.ends_with(extension.as_str())
            })
            .max_by_key(|(_, extension)| extension.len())
            .map(|(language, _)| language)
    }
    /// Compiles a grammar on first use.
    pub fn grammar(&mut self, scope: &str) -> Option<GrammarId> {
        if let Some(id) = self.by_scope.get(scope) {
            return *id;
        }
        self.by_scope.insert(scope.to_owned(), None);
        let source = *self.sources.get(scope)?;
        let value: Value = match serde_json::from_str(source) {
            Ok(value) => value,
            Err(error) => {
                self.warnings.push(format!("{scope}: {error}"));
                return None;
            }
        };
        let id = self.grammars.len();
        self.grammars.push(Grammar {
            root: 0,
            repository: HashMap::new(),
        });
        self.by_scope.insert(scope.to_owned(), Some(id));
        let mut compiler = Compiler {
            registry: self,
            grammar: id,
            memo: HashMap::new(),
        };
        let empty = Map::new();
        let repository = value
            .get("repository")
            .and_then(Value::as_object)
            .unwrap_or(&empty);
        let root = compiler.patterns_rule(&value, &[repository]);
        let mut named = HashMap::new();
        for (key, rule) in repository {
            named.insert(key.clone(), compiler.rule(rule, &[repository]));
        }
        self.grammars[id] = Grammar {
            root,
            repository: named,
        };
        Some(id)
    }
    /// Compiles every grammar and pattern; end patterns with back
    /// references compile once resolved, so they are skipped.
    #[cfg(test)]
    pub fn compile_all(&mut self) {
        let scopes: Vec<String> = self.sources.keys().cloned().collect();
        for scope in scopes {
            self.grammar(&scope);
        }
        for id in 0..self.rules.len() {
            let ends = match &self.rules[id] {
                Rule::Begin { end, .. }
                    if !end.contains('\\') || !end.chars().any(|c| c.is_ascii_digit()) =>
                {
                    Some(end.clone())
                }
                _ => None,
            };
            if let Some(end) = ends {
                let regex = self.regex_id(&end);
                self.regex(regex);
            }
        }
        for id in 0..self.regexes.len() {
            self.regex(id);
        }
    }
    pub fn root(&self, grammar: GrammarId) -> RuleId {
        self.grammars[grammar].root
    }
    pub(super) fn rule(&self, id: RuleId) -> &Rule {
        &self.rules[id]
    }
    fn push(&mut self, rule: Rule) -> RuleId {
        self.rules.push(rule);
        self.rules.len() - 1
    }
    pub(super) fn regex_id(&mut self, source: &str) -> RegexId {
        if let Some(id) = self.regex_ids.get(source) {
            return *id;
        }
        let source: Arc<str> = source.into();
        self.regexes.push(RegexEntry {
            anchored: source.contains("\\G"),
            source: source.clone(),
            compiled: None,
        });
        let id = self.regexes.len() - 1;
        self.regex_ids.insert(source, id);
        id
    }
    /// The compiled expression, or None when Oniguruma rejects it.
    pub(super) fn regex(&mut self, id: RegexId) -> Option<&Regex> {
        let entry = &mut self.regexes[id];
        if entry.compiled.is_none() {
            let compiled = Regex::with_options(
                &entry.source,
                RegexOptions::REGEX_OPTION_CAPTURE_GROUP,
                Syntax::default(),
            );
            if let Err(error) = &compiled {
                let message = format!("regex {:?}: {error}", entry.source);
                self.warnings.push(message);
            }
            self.regexes[id].compiled = Some(compiled.ok());
        }
        self.regexes[id].compiled.as_ref().unwrap().as_ref()
    }
    pub(super) fn anchored(&self, id: RegexId) -> bool {
        self.regexes[id].anchored
    }
    fn name(&mut self, value: Option<&Value>) -> Option<Name> {
        let text = value?.as_str()?;
        if text.contains('$') {
            return Some(Name {
                category: None,
                template: Some(text.into()),
            });
        }
        Some(Name {
            category: self.categorize(text),
            template: None,
        })
    }
    fn categorize(&mut self, names: &str) -> Option<Category> {
        if let Some(category) = self.names.get(names) {
            return *category;
        }
        let category = scope::categorize(names);
        self.names.insert(names.to_owned(), category);
        category
    }
    /// The category of a name, substituting `$n` and `${n:/downcase}` from
    /// the match when the name is a template.
    pub(super) fn name_category(
        &mut self,
        name: &Name,
        text: &str,
        groups: &[Option<(usize, usize)>],
    ) -> Option<Category> {
        let Some(template) = &name.template else {
            return name.category;
        };
        let mut out = String::new();
        let mut rest = &template[..];
        while let Some(index) = rest.find('$') {
            out.push_str(&rest[..index]);
            rest = &rest[index + 1..];
            let (group, consumed) = if let Some(inner) = rest.strip_prefix('{') {
                let end = inner.find('}').unwrap_or(inner.len());
                let digits: String = inner[..end]
                    .chars()
                    .take_while(char::is_ascii_digit)
                    .collect();
                (digits.parse::<usize>().ok(), end + 2)
            } else {
                let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
                (digits.parse::<usize>().ok(), digits.len())
            };
            if let Some(Some((start, end))) = group.and_then(|g| groups.get(g)) {
                out.push_str(&text[*start..*end].to_ascii_lowercase());
            }
            rest = &rest[consumed.min(rest.len())..];
        }
        out.push_str(rest);
        self.categorize(&out)
    }
    /// The rules a frame tries, with includes expanded. `$base` refers to
    /// the grammar being scanned, so expansions are cached per base.
    pub(super) fn candidates(&mut self, owner: RuleId, base: GrammarId) -> Arc<[RuleId]> {
        if let Some(list) = self.expansions.get(&(owner, base)) {
            return list.clone();
        }
        let patterns = match &self.rules[owner] {
            Rule::Patterns(patterns) => patterns.clone(),
            Rule::Begin { patterns, .. } => patterns.clone(),
            Rule::Match { .. } => vec![Pattern::Rule(owner)],
        };
        let mut out = vec![];
        let mut seen = vec![owner];
        self.expand(&patterns, base, &mut out, &mut seen);
        let list: Arc<[RuleId]> = out.into();
        self.expansions.insert((owner, base), list.clone());
        list
    }
    fn expand(
        &mut self,
        patterns: &[Pattern],
        base: GrammarId,
        out: &mut Vec<RuleId>,
        seen: &mut Vec<RuleId>,
    ) {
        for pattern in patterns {
            let id = match pattern {
                Pattern::Rule(id) => *id,
                Pattern::Root(grammar) => self.grammars[*grammar].root,
                Pattern::Base => self.grammars[base].root,
                Pattern::External(scope, name) => {
                    let Some(grammar) = self.grammar(scope) else {
                        continue;
                    };
                    match name {
                        None => self.grammars[grammar].root,
                        Some(name) => match self.grammars[grammar].repository.get(&**name) {
                            Some(id) => *id,
                            None => continue,
                        },
                    }
                }
            };
            match &self.rules[id] {
                Rule::Patterns(inner) => {
                    if seen.contains(&id) {
                        continue;
                    }
                    seen.push(id);
                    let inner = inner.clone();
                    self.expand(&inner, base, out, seen);
                }
                _ => out.push(id),
            }
        }
    }
}

/// Compiles one grammar's JSON into the registry's arenas. Repositories are
/// lexical: a rule's own `repository` shadows the enclosing ones.
struct Compiler<'a> {
    registry: &'a mut Registry,
    grammar: GrammarId,
    /// Rule objects already compiled, by address, which also ends cycles.
    memo: HashMap<*const Value, RuleId>,
}
impl Compiler<'_> {
    fn rule(&mut self, value: &Value, repositories: &[&Map<String, Value>]) -> RuleId {
        let key = value as *const Value;
        if let Some(id) = self.memo.get(&key) {
            return *id;
        }
        let id = self.registry.push(Rule::Patterns(vec![]));
        self.memo.insert(key, id);
        let Some(object) = value.as_object() else {
            return id;
        };
        let mut scopes = repositories.to_vec();
        if let Some(local) = object.get("repository").and_then(Value::as_object) {
            scopes.push(local);
        }
        if number(object.get("disabled")) {
            return id;
        }
        let rule = if let Some(source) = object.get("match").and_then(Value::as_str) {
            Rule::Match {
                regex: self.registry.regex_id(source),
                name: self.registry.name(object.get("name")),
                captures: self.captures(object.get("captures"), &scopes),
            }
        } else if let Some(begin) = object.get("begin").and_then(Value::as_str) {
            let (end, while_) = match (object.get("end"), object.get("while")) {
                (Some(Value::String(end)), _) => (end.as_str(), false),
                (_, Some(Value::String(pattern))) => (pattern.as_str(), true),
                // Without an end the rule never closes on its own.
                _ => ("\\z", false),
            };
            let captures = object.get("captures");
            let begin_captures = object.get("beginCaptures").or(captures);
            let end_captures = object
                .get(if while_ {
                    "whileCaptures"
                } else {
                    "endCaptures"
                })
                .or(captures);
            Rule::Begin {
                begin: self.registry.regex_id(begin),
                end: end.into(),
                while_,
                name: self.registry.name(object.get("name")),
                content_name: self.registry.name(object.get("contentName")),
                begin_captures: self.captures(begin_captures, &scopes),
                end_captures: self.captures(end_captures, &scopes),
                patterns: self.patterns(object.get("patterns"), &scopes),
                end_last: number(object.get("applyEndPatternLast")),
            }
        } else if object.contains_key("include") {
            Rule::Patterns(self.patterns(Some(&Value::Array(vec![value.clone()])), &scopes))
        } else {
            Rule::Patterns(self.patterns(object.get("patterns"), &scopes))
        };
        self.registry.rules[id] = rule;
        id
    }
    fn patterns_rule(&mut self, value: &Value, repositories: &[&Map<String, Value>]) -> RuleId {
        let patterns = self.patterns(value.get("patterns"), repositories);
        self.registry.push(Rule::Patterns(patterns))
    }
    fn patterns(
        &mut self,
        value: Option<&Value>,
        repositories: &[&Map<String, Value>],
    ) -> Vec<Pattern> {
        let Some(items) = value.and_then(Value::as_array) else {
            return vec![];
        };
        let mut out = vec![];
        for item in items {
            let Some(include) = item.get("include").and_then(Value::as_str) else {
                out.push(Pattern::Rule(self.rule(item, repositories)));
                continue;
            };
            let pattern = match include {
                "$self" => Some(Pattern::Root(self.grammar)),
                "$base" => Some(Pattern::Base),
                local if local.starts_with('#') => repositories
                    .iter()
                    .rev()
                    .find_map(|repository| repository.get(&local[1..]))
                    .map(|rule| Pattern::Rule(self.rule(rule, repositories))),
                external => {
                    let (scope, name) = match external.split_once('#') {
                        Some((scope, name)) => (scope, Some(name.into())),
                        None => (external, None),
                    };
                    Some(Pattern::External(scope.into(), name))
                }
            };
            out.extend(pattern);
        }
        out
    }
    fn captures(
        &mut self,
        value: Option<&Value>,
        repositories: &[&Map<String, Value>],
    ) -> Captures {
        let Some(object) = value.and_then(Value::as_object) else {
            return Arc::new([]);
        };
        let mut out: Vec<Option<Capture>> = vec![];
        for (key, capture) in object {
            let Ok(index) = key.parse::<usize>() else {
                continue;
            };
            if out.len() <= index {
                out.resize_with(index + 1, || None);
            }
            let patterns = capture
                .get("patterns")
                .map(|_| self.patterns_rule(capture, repositories));
            out[index] = Some(Capture {
                name: self.registry.name(capture.get("name")),
                patterns,
            });
        }
        out.into()
    }
}
