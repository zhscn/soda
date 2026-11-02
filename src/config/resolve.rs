use super::{ClangConfig, ConfigError, ConfigOptions, parse_config, preset};
use std::{
    collections::HashSet,
    fs,
    path::{Component, Path, PathBuf},
};

#[derive(Clone, Debug)]
pub struct ConfigSource {
    pub path: PathBuf,
    pub content: String,
}
#[derive(Clone, Debug)]
pub struct ResolvedConfig {
    pub config: ClangConfig,
    /// Applied configuration files, in parent-to-child order.
    pub sources: Vec<ConfigSource>,
    /// Includes absent candidates so a watcher can detect creation of a nearer
    /// configuration file. Resolution performs I/O only when explicitly called.
    pub searched: Vec<PathBuf>,
}
struct Resolver<'a> {
    options: &'a ConfigOptions,
    language: &'static str,
    header: bool,
    visited: HashSet<PathBuf>,
    searched: Vec<PathBuf>,
    unsuitable: Vec<PathBuf>,
}
fn normalize(path: &Path) -> Result<PathBuf, ConfigError> {
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|e| ConfigError::message(e.to_string()))?
            .join(path)
    };
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            _ => out.push(component),
        }
    }
    Ok(out)
}
impl Resolver<'_> {
    fn resolve(
        &mut self,
        mut dir: PathBuf,
    ) -> Result<(ClangConfig, Vec<ConfigSource>), ConfigError> {
        loop {
            let identity = fs::canonicalize(&dir).unwrap_or_else(|_| dir.clone());
            if !self.visited.insert(identity) {
                return Err(ConfigError::message(format!(
                    "configuration inheritance cycle at {}",
                    dir.display()
                )));
            }
            for name in [".clang-format", "_clang-format"] {
                let path = dir.join(name);
                self.searched.push(path.clone());
                match fs::metadata(&path) {
                    Ok(metadata) if !metadata.is_file() => continue,
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                    Err(e) => return Err(ConfigError::message(format!("{}: {e}", path.display()))),
                    _ => {}
                }
                let text = match fs::read_to_string(&path) {
                    Ok(text) => text,
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                    Err(e) => return Err(ConfigError::message(format!("{}: {e}", path.display()))),
                };
                let initial = preset("LLVM")?;
                let Some(child) = parse_config(
                    &text,
                    &initial,
                    self.language,
                    self.header,
                    self.options.unknown_options,
                )
                .map_err(|e| ConfigError::message(format!("{}: {e}", path.display())))?
                else {
                    self.unsuitable.push(path);
                    continue;
                };
                let Some(inherit) = &child.inherit else {
                    return Ok((
                        child,
                        vec![ConfigSource {
                            path,
                            content: text,
                        }],
                    ));
                };
                let parent = if inherit == ".." {
                    dir.parent().map(Path::to_path_buf)
                } else {
                    let expanded = if let Some(rest) = inherit.strip_prefix("~/") {
                        std::env::var_os("HOME")
                            .map(PathBuf::from)
                            .ok_or_else(|| {
                                ConfigError::message("cannot expand inheritance home directory")
                            })?
                            .join(rest)
                    } else {
                        PathBuf::from(inherit)
                    };
                    let redirected = normalize(&if expanded.is_absolute() {
                        expanded
                    } else {
                        dir.join(expanded)
                    })?;
                    if !redirected.is_dir() {
                        return Err(ConfigError::message(format!(
                            "inheritance directory does not exist: {}",
                            redirected.display()
                        )));
                    }
                    Some(redirected)
                };
                let (base, mut sources) = match parent {
                    Some(parent) => self.resolve(parent)?,
                    None => (preset(&self.options.fallback)?, vec![]),
                };
                let mut config = parse_config(
                    &text,
                    &base,
                    self.language,
                    self.header,
                    self.options.unknown_options,
                )?
                .expect("previously selected language");
                config.inherit = None;
                sources.push(ConfigSource {
                    path,
                    content: text,
                });
                return Ok((config, sources));
            }
            let Some(parent) = dir.parent() else {
                return Ok((preset(&self.options.fallback)?, vec![]));
            };
            dir = parent.to_owned();
        }
    }
}
/// What a file gets when its configuration cannot be used: the fallback
/// preset, as if no file had been found.
pub fn fallback_config(
    file: &Path,
    options: &ConfigOptions,
) -> Result<ResolvedConfig, ConfigError> {
    let mut config = preset(&options.fallback)?;
    let language = if file.extension().and_then(|e| e.to_str()) == Some("c") {
        "C"
    } else {
        "Cpp"
    };
    config.values.insert(
        "Language".into(),
        serde_json::Value::String(language.into()),
    );
    Ok(ResolvedConfig {
        config,
        sources: vec![],
        searched: vec![],
    })
}
/// Resolve for an existing or newly-created file. Search begins at its parent;
/// .clang-format takes precedence over _clang-format in the same directory.
pub fn resolve_config(file: &Path, options: &ConfigOptions) -> Result<ResolvedConfig, ConfigError> {
    preset(&options.fallback)?;
    let file = normalize(file)?;
    let extension = file.extension().and_then(|e| e.to_str());
    let mut resolver = Resolver {
        options,
        language: if extension == Some("c") { "C" } else { "Cpp" },
        header: extension == Some("h"),
        visited: HashSet::new(),
        searched: vec![],
        unsuitable: vec![],
    };
    let (mut config, sources) = resolver.resolve(
        file.parent()
            .ok_or_else(|| ConfigError::message("file has no parent directory"))?
            .to_owned(),
    )?;
    if sources.is_empty() && !resolver.unsuitable.is_empty() {
        return Err(ConfigError::message(format!(
            "no configuration supports the file language: {:?}",
            resolver.unsuitable
        )));
    }
    config.values.insert(
        "Language".into(),
        serde_json::Value::String(resolver.language.into()),
    );
    Ok(ResolvedConfig {
        config,
        sources,
        searched: resolver.searched,
    })
}
