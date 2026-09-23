use minijinja::{Environment, context};
use mlua::prelude::*;
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

struct State<'a> {
    environment: Mutex<Option<Environment<'a>>>,
}

impl<'a> State<'a> {
    fn new() -> Self {
        State {
            environment: Mutex::new(None),
        }
    }

    fn lock_environment(&self) -> LuaResult<MutexGuard<'_, Option<Environment<'a>>>> {
        self.environment.lock().map_err(|_| {
            LuaError::RuntimeError(
                "Avante template state is poisoned after an earlier panic; restart Neovim"
                    .to_string(),
            )
        })
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
    let environment = state.lock_environment()?;
    match environment.as_ref() {
        Some(environment) => {
            let jinja_template = environment.get_template(template).map_err(|err| {
                LuaError::RuntimeError(format!(
                    "Failed to load Avante template {template:?}: {err:#}"
                ))
            })?;

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
                .map_err(|err| {
                    LuaError::RuntimeError(format!(
                        "Failed to render Avante template {template:?}: {err:#}"
                    ))
                })
        }
        None => Err(LuaError::RuntimeError(
            "Environment not initialized".to_string(),
        )),
    }
}

fn initialize(state: &State, cache_directory: String, project_directory: String) -> LuaResult<()> {
    let mut environment_mutex = state.lock_environment()?;
    let mut env = Environment::new();

    // Create a custom loader that searches both cache and project directories
    let cache_dir = cache_directory.clone();
    let project_dir = project_directory.clone();

    env.set_loader(
        move |name: &str| -> Result<Option<String>, minijinja::Error> {
            // First try the cache directory (for built-in templates)
            let cache_path = Path::new(&cache_dir).join(name);
            if cache_path.exists() {
                match std::fs::read_to_string(&cache_path) {
                    Ok(content) => return Ok(Some(content)),
                    Err(_) => {} // Continue to try project directory
                }
            }

            // Then try the project directory (for custom includes)
            let project_path = Path::new(&project_dir).join(name);
            if project_path.exists() {
                match std::fs::read_to_string(&project_path) {
                    Ok(content) => return Ok(Some(content)),
                    Err(_) => {} // File not found or read error
                }
            }

            // Template not found in either directory
            Ok(None)
        },
    );

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
