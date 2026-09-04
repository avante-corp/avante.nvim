use hf_hub::{Repo, RepoType, api::sync::ApiBuilder};
use mlua::prelude::*;
use regex::Regex;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tiktoken_rs::{CoreBPE, bpe_for_model};
use tokenizers::Tokenizer;

struct Tiktoken {
    bpe: &'static CoreBPE,
}

impl Tiktoken {
    fn new(model: &str) -> Self {
        let bpe = bpe_for_model(model).unwrap();
        Self { bpe }
    }

    fn encode(&self, text: &str) -> (Vec<u32>, usize, usize) {
        let tokens = self.bpe.encode_with_special_tokens(text);
        let num_tokens = tokens.len();
        let num_chars = text.chars().count();
        (tokens, num_tokens, num_chars)
    }
}

struct HuggingFaceTokenizer {
    tokenizer: Tokenizer,
}

fn is_valid_url(url: &str) -> bool {
    let url_regex = Regex::new(r"^https?://[^\s/$.?#].[^\s]*$").unwrap();
    url_regex.is_match(url)
}

impl HuggingFaceTokenizer {
    fn new(model: &str) -> Self {
        let tokenizer_path = if is_valid_url(model) {
            Self::get_cached_tokenizer(model)
        } else {
            // Use existing HuggingFace Hub logic for model names
            let identifier = model.to_string();
            let api = ApiBuilder::new().with_progress(false).build().unwrap();
            let repo = Repo::new(identifier, RepoType::Model);
            let api = api.repo(repo);
            api.get("tokenizer.json").unwrap()
        };

        let tokenizer = Tokenizer::from_file(tokenizer_path).unwrap();
        Self { tokenizer }
    }

    fn encode(&self, text: &str) -> (Vec<u32>, usize, usize) {
        let encoding = self.tokenizer.encode(text, false).unwrap();
        let tokens = encoding.get_ids().to_vec();
        let num_tokens = tokens.len();
        let num_chars = encoding.get_offsets().last().unwrap().1;
        (tokens, num_tokens, num_chars)
    }

    fn get_cached_tokenizer(url: &str) -> PathBuf {
        let cache_dir = dirs::home_dir()
            .map(|h| h.join(".cache").join("avante"))
            .unwrap();
        std::fs::create_dir_all(&cache_dir).unwrap();

        // Extract filename from URL
        let filename = url.split('/').last().unwrap();

        let cached_path = cache_dir.join(filename);

        if !cached_path.exists() {
            let response = ureq::get(url).call().unwrap();
            let mut file = std::fs::File::create(&cached_path).unwrap();
            let mut reader = response.into_reader();
            std::io::copy(&mut reader, &mut file).unwrap();
        }
        cached_path
    }
}

enum TokenizerType {
    Tiktoken(Tiktoken),
    HuggingFace(Box<HuggingFaceTokenizer>),
}

struct State {
    tokenizer: Mutex<Option<TokenizerType>>,
}

impl State {
    fn new() -> Self {
        State {
            tokenizer: Mutex::new(None),
        }
    }
}

fn encode(state: &State, text: &str) -> LuaResult<(Vec<u32>, usize, usize)> {
    let tokenizer = state.tokenizer.lock().unwrap();
    match tokenizer.as_ref() {
        Some(TokenizerType::Tiktoken(tokenizer)) => Ok(tokenizer.encode(text)),
        Some(TokenizerType::HuggingFace(tokenizer)) => Ok(tokenizer.encode(text)),
        None => Err(LuaError::RuntimeError(
            "Tokenizer not initialized".to_string(),
        )),
    }
}

fn from_pretrained(state: &State, model: &str) {
    let mut tokenizer_mutex = state.tokenizer.lock().unwrap();
    *tokenizer_mutex = Some(match model {
        "gpt-4o" => TokenizerType::Tiktoken(Tiktoken::new(model)),
        _ => TokenizerType::HuggingFace(Box::new(HuggingFaceTokenizer::new(model))),
    });
}

#[mlua::lua_module]
fn avante_tokenizers(lua: &Lua) -> LuaResult<LuaTable> {
    let core = State::new();
    let state = Arc::new(core);
    let state_clone = Arc::clone(&state);

    let exports = lua.create_table()?;
    exports.set(
        "from_pretrained",
        lua.create_function(move |_, model: String| {
            from_pretrained(&state, model.as_str());
            Ok(())
        })?,
    )?;
    exports.set(
        "encode",
        lua.create_function(move |_, text: String| encode(&state_clone, text.as_str()))?,
    )?;
    Ok(exports)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tiktoken() {
        let model = "gpt-4o";
        let source = "Hello, world!";
        let tokenizer = Tiktoken::new(model);
        let (tokens, num_tokens, num_chars) = tokenizer.encode(source);
        assert_eq!(tokens, vec![13225, 11, 2375, 0]);
        assert_eq!(num_tokens, 4);
        assert_eq!(num_chars, source.chars().count());
    }

    #[test]
    fn test_hf() {
        let model = "gpt2";
        let source = "Hello, world!";
        let tokenizer = HuggingFaceTokenizer::new(model);
        let (tokens, num_tokens, num_chars) = tokenizer.encode(source);
        assert_eq!(tokens, vec![15496, 11, 995, 0]);
        assert_eq!(num_tokens, 4);
        assert_eq!(num_chars, source.chars().count());
    }

    #[test]
    fn test_roundtrip() {
        let state = State::new();
        let source = "Hello, world!";
        let model = "gpt2";

        from_pretrained(&state, model);
        let (tokens, num_tokens, num_chars) = encode(&state, "Hello, world!").unwrap();
        assert_eq!(tokens, vec![15496, 11, 995, 0]);
        assert_eq!(num_tokens, 4);
        assert_eq!(num_chars, source.chars().count());
    }

    // For example: https://storage.googleapis.com/cohere-public/tokenizers/command-r-08-2024.json
    // Disable testing on GitHub Actions to avoid rate limiting and file size limits
    #[test]
    fn test_public_url() {
        if std::env::var("GITHUB_ACTIONS").is_ok() {
            return;
        }
        let state = State::new();
        let source = "Hello, world!";
        let model =
            "https://storage.googleapis.com/cohere-public/tokenizers/command-r-08-2024.json";

        from_pretrained(&state, model);
        let (tokens, num_tokens, num_chars) = encode(&state, "Hello, world!").unwrap();
        assert_eq!(tokens, vec![28339, 19, 3845, 8]);
        assert_eq!(num_tokens, 4);
        assert_eq!(num_chars, source.chars().count());
    }
}
