use minijinja::{Environment, context};
use mlua::prelude::*;
use serde::{Deserialize, Serialize};
use std::path::{Component, Path};
use std::sync::{Arc, Mutex};

struct State<'a> {
    environment: Mutex<Option<Environment<'a>>>,
}

impl State<'_> {
    fn new() -> Self {
        State {
            environment: Mutex::new(None),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct SelectedCode {
    path: String,
    content: Option<String>,
    file_type: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct SelectedFile {
    path: String,
    content: Option<String>,
    file_type: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct TemplateContext {
    ask: bool,
    code_lang: String,
    selected_files: Option<Vec<SelectedFile>>,
    selected_code: Option<SelectedCode>,
    recently_viewed_files: Option<Vec<String>>,
    relevant_files: Option<Vec<String>>,
    project_context: Option<String>,
    diagnostics: Option<String>,
    system_info: Option<String>,
    model_name: Option<String>,
    memory: Option<String>,
    todos: Option<String>,
    enable_fastapply: Option<bool>,
    use_react_prompt: Option<bool>,
}

// Given the file name registered after add, the context table in Lua, resulted in a formatted
// Lua string
#[allow(clippy::needless_pass_by_value)]
fn render(state: &State, template: &str, context: TemplateContext) -> LuaResult<String> {
    let environment = state.environment.lock().unwrap();
    match environment.as_ref() {
        Some(environment) => {
            let jinja_template = environment
                .get_template(template)
                .map_err(LuaError::external)?;

            jinja_template
                .render(context! {
                  ask => context.ask,
                  code_lang => context.code_lang,
                  selected_files => context.selected_files,
                  selected_code => context.selected_code,
                  recently_viewed_files => context.recently_viewed_files,
                  relevant_files => context.relevant_files,
                  project_context => context.project_context,
                  diagnostics => context.diagnostics,
                  system_info => context.system_info,
                  model_name => context.model_name,
                  memory => context.memory,
                  todos => context.todos,
                  enable_fastapply => context.enable_fastapply,
                  use_react_prompt => context.use_react_prompt,
                })
                .map_err(LuaError::external)
        }
        None => Err(LuaError::RuntimeError(
            "Environment not initialized".to_string(),
        )),
    }
}

// Resolve symlinks before checking containment: lexical checks alone cannot keep
// a repository-controlled symlink from loading files outside its template root.
fn contained_loader(
    directory: &Path,
) -> std::io::Result<
    impl Fn(&str) -> Result<Option<String>, minijinja::Error> + Send + Sync + 'static,
> {
    let root = directory.canonicalize()?;
    Ok(move |name: &str| {
        // Template names use forward slashes on every platform. Match MiniJinja's
        // path_loader restrictions, and explicitly reject absolute/drive paths.
        if name.is_empty()
            || name.starts_with('/')
            || name.contains(['\\', ':'])
            || name.split('/').any(|part| part.starts_with('.'))
            || Path::new(name)
                .components()
                .any(|part| !matches!(part, Component::Normal(_)))
        {
            return Ok(None);
        }

        let read = || -> std::io::Result<Option<String>> {
            let path = root.join(name).canonicalize()?;
            if !path.starts_with(&root) {
                return Ok(None);
            }
            std::fs::read_to_string(path).map(Some)
        };
        match read() {
            Ok(content) => Ok(content),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(minijinja::Error::new(
                minijinja::ErrorKind::InvalidOperation,
                "could not read template",
            )
            .with_source(err)),
        }
    })
}

fn initialize(state: &State, cache_directory: String, project_directory: String) -> LuaResult<()> {
    let mut environment_mutex = state.environment.lock().unwrap();
    // A failed reinitialization must not leave a previous project's loader active.
    *environment_mutex = None;
    let mut env = Environment::new();

    let cache_loader = contained_loader(Path::new(&cache_directory)).map_err(LuaError::external)?;
    let project_loader =
        contained_loader(Path::new(&project_directory)).map_err(LuaError::external)?;
    env.set_loader(move |name: &str| match cache_loader(name)? {
        Some(content) => Ok(Some(content)),
        None => project_loader(name),
    });

    *environment_mutex = Some(env);
    Ok(())
}

#[mlua::lua_module]
fn avante_templates(lua: &Lua) -> LuaResult<LuaTable> {
    let core = State::new();
    let state = Arc::new(core);
    let state_clone = Arc::clone(&state);

    let exports = lua.create_table()?;
    exports.set(
        "initialize",
        lua.create_function(
            move |_, (cache_directory, project_directory): (String, String)| {
                initialize(&state, cache_directory, project_directory)
            },
        )?,
    )?;
    exports.set(
        "render",
        lua.create_function_mut(move |lua, (template, context): (String, LuaValue)| {
            let ctx = lua.from_value(context)?;
            render(&state_clone, template.as_str(), ctx)
        })?,
    )?;
    Ok(exports)
}
