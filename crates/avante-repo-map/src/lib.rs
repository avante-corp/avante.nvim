#![allow(clippy::unnecessary_map_or)]

use mlua::prelude::*;
use std::cell::RefCell;
use std::collections::BTreeMap;
use tree_sitter::{Node, Parser, Query, QueryCursor};
use tree_sitter_language::LanguageFn;

#[derive(Debug, Clone)]
pub struct Func {
    pub name: String,
    pub params: String,
    pub return_type: String,
    pub accessibility_modifier: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Class {
    pub type_name: String,
    pub name: String,
    pub methods: Vec<Func>,
    pub properties: Vec<Variable>,
    pub visibility_modifier: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Enum {
    pub name: String,
    pub items: Vec<Variable>,
}

#[derive(Debug, Clone)]
pub struct Union {
    pub name: String,
    pub items: Vec<Variable>,
}

#[derive(Debug, Clone)]
pub struct Variable {
    pub name: String,
    pub value_type: String,
}

#[derive(Debug, Clone)]
pub enum Definition {
    Func(Func),
    Class(Class),
    Module(Class),
    Enum(Enum),
    Variable(Variable),
    Union(Union),
    // TODO: Namespace support
}

fn get_ts_language(language: &str) -> Option<LanguageFn> {
    match language {
        "rust" => Some(tree_sitter_rust::LANGUAGE),
        "python" => Some(tree_sitter_python::LANGUAGE),
        "php" => Some(tree_sitter_php::LANGUAGE_PHP),
        "java" => Some(tree_sitter_java::LANGUAGE),
        "javascript" => Some(tree_sitter_javascript::LANGUAGE),
        "typescript" => Some(tree_sitter_typescript::LANGUAGE_TSX),
        "go" => Some(tree_sitter_go::LANGUAGE),
        "c" => Some(tree_sitter_c::LANGUAGE),
        "cpp" => Some(tree_sitter_cpp::LANGUAGE),
        "lua" => Some(tree_sitter_lua::LANGUAGE),
        "ruby" => Some(tree_sitter_ruby::LANGUAGE),
        "zig" => Some(tree_sitter_zig::LANGUAGE),
        "scala" => Some(tree_sitter_scala::LANGUAGE),
        "swift" => Some(tree_sitter_swift::LANGUAGE),
        "elixir" => Some(tree_sitter_elixir::LANGUAGE),
        "csharp" => Some(tree_sitter_c_sharp::LANGUAGE),
        _ => None,
    }
}

const C_QUERY: &str = include_str!("../queries/tree-sitter-c-defs.scm");
const CPP_QUERY: &str = include_str!("../queries/tree-sitter-cpp-defs.scm");
const GO_QUERY: &str = include_str!("../queries/tree-sitter-go-defs.scm");
const JAVA_QUERY: &str = include_str!("../queries/tree-sitter-java-defs.scm");
const JAVASCRIPT_QUERY: &str = include_str!("../queries/tree-sitter-javascript-defs.scm");
const LUA_QUERY: &str = include_str!("../queries/tree-sitter-lua-defs.scm");
const PYTHON_QUERY: &str = include_str!("../queries/tree-sitter-python-defs.scm");
const PHP_QUERY: &str = include_str!("../queries/tree-sitter-php-defs.scm");
const RUST_QUERY: &str = include_str!("../queries/tree-sitter-rust-defs.scm");
const ZIG_QUERY: &str = include_str!("../queries/tree-sitter-zig-defs.scm");
const TYPESCRIPT_QUERY: &str = include_str!("../queries/tree-sitter-typescript-defs.scm");
const RUBY_QUERY: &str = include_str!("../queries/tree-sitter-ruby-defs.scm");
const SCALA_QUERY: &str = include_str!("../queries/tree-sitter-scala-defs.scm");
const SWIFT_QUERY: &str = include_str!("../queries/tree-sitter-swift-defs.scm");
const ELIXIR_QUERY: &str = include_str!("../queries/tree-sitter-elixir-defs.scm");
const CSHARP_QUERY: &str = include_str!("../queries/tree-sitter-c-sharp-defs.scm");

fn get_definitions_query(language: &str) -> Result<Query, String> {
    let ts_language = get_ts_language(language);
    if ts_language.is_none() {
        return Err(format!("Unsupported language: {language}"));
    }
    let ts_language = ts_language.unwrap();
    let contents = match language {
        "c" => C_QUERY,
        "cpp" => CPP_QUERY,
        "go" => GO_QUERY,
        "java" => JAVA_QUERY,
        "javascript" => JAVASCRIPT_QUERY,
        "lua" => LUA_QUERY,
        "php" => PHP_QUERY,
        "python" => PYTHON_QUERY,
        "rust" => RUST_QUERY,
        "zig" => ZIG_QUERY,
        "typescript" => TYPESCRIPT_QUERY,
        "ruby" => RUBY_QUERY,
        "scala" => SCALA_QUERY,
        "swift" => SWIFT_QUERY,
        "elixir" => ELIXIR_QUERY,
        "csharp" => CSHARP_QUERY,
        _ => return Err(format!("Unsupported language: {language}")),
    };
    let query = Query::new(&ts_language.into(), contents)
        .unwrap_or_else(|e| panic!("Failed to parse query for {language}: {e}"));
    Ok(query)
}

fn get_closest_ancestor_name(node: &Node, source: &str) -> String {
    let mut parent = node.parent();
    while let Some(parent_node) = parent {
        let name_node = parent_node.child_by_field_name("name");
        if let Some(name_node) = name_node {
            return get_node_text(&name_node, source.as_bytes());
        }
        parent = parent_node.parent();
    }
    String::new()
}

fn find_ancestor_by_type<'a>(node: &'a Node, parent_type: &str) -> Option<Node<'a>> {
    let mut parent = node.parent();
    while let Some(parent_node) = parent {
        if parent_node.kind() == parent_type {
            return Some(parent_node);
        }
        parent = parent_node.parent();
    }
    None
}

fn find_first_ancestor_by_types<'a>(
    node: &'a Node,
    possible_parent_types: &[&str],
) -> Option<Node<'a>> {
    let mut parent = node.parent();
    while let Some(parent_node) = parent {
        if possible_parent_types.contains(&parent_node.kind()) {
            return Some(parent_node);
        }
        parent = parent_node.parent();
    }
    None
}

fn find_descendant_by_type<'a>(node: &'a Node, child_type: &str) -> Option<Node<'a>> {
    let mut cursor = node.walk();
    for i in 0..node.descendant_count() {
        cursor.goto_descendant(i);
        let node = cursor.node();
        if node.kind() == child_type {
            return Some(node);
        }
    }
    None
}

fn ruby_method_is_private<'a>(node: &'a Node, source: &'a [u8]) -> bool {
    let mut prev_sibling = node.prev_sibling();
    while let Some(prev_sibling_node) = prev_sibling {
        if prev_sibling_node.kind() == "identifier" {
            let text = prev_sibling_node.utf8_text(source).unwrap_or_default();
            if text == "private" {
                return true;
            } else if text == "public" || text == "protected" {
                return false;
            }
        } else if prev_sibling_node.kind() == "class" || prev_sibling_node.kind() == "module" {
            return false;
        }
        prev_sibling = prev_sibling_node.prev_sibling();
    }
    false
}

fn find_child_by_type<'a>(node: &'a Node, child_type: &str) -> Option<Node<'a>> {
    node.children(&mut node.walk())
        .find(|child| child.kind() == child_type)
}

// Zig-specific function to find the parent variable declaration
fn zig_find_parent_variable_declaration_name<'a>(
    node: &'a Node,
    source: &'a [u8],
) -> Option<String> {
    let vardec = find_ancestor_by_type(node, "variable_declaration");
    if let Some(vardec) = vardec {
        // Find the identifier child node, which represents the class name
        let identifier_node = find_child_by_type(&vardec, "identifier");
        if let Some(identifier_node) = identifier_node {
            return Some(get_node_text(&identifier_node, source));
        }
    }
    None
}

fn zig_is_declaration_public<'a>(node: &'a Node, declaration_type: &str, source: &'a [u8]) -> bool {
    let declaration = find_ancestor_by_type(node, declaration_type);
    if let Some(declaration) = declaration {
        let declaration_text = get_node_text(&declaration, source);
        return declaration_text.starts_with("pub");
    }
    false
}

fn zig_is_variable_declaration_public<'a>(node: &'a Node, source: &'a [u8]) -> bool {
    zig_is_declaration_public(node, "variable_declaration", source)
}

fn zig_is_function_declaration_public<'a>(node: &'a Node, source: &'a [u8]) -> bool {
    zig_is_declaration_public(node, "function_declaration", source)
}

fn zig_find_type_in_parent<'a>(node: &'a Node, source: &'a [u8]) -> Option<String> {
    // First go to the parent and then get the child_by_field_name "type"
    if let Some(parent) = node.parent() {
        if let Some(type_node) = parent.child_by_field_name("type") {
            return Some(get_node_text(&type_node, source));
        }
    }
    None
}

fn csharp_is_primary_constructor(node: &Node) -> bool {
    node.kind() == "parameter_list"
        && node.parent().map_or(false, |n| {
            n.kind() == "class_declaration" || n.kind() == "record_declaration"
        })
}

fn csharp_find_parent_type_node<'a>(node: &'a Node) -> Option<Node<'a>> {
    find_first_ancestor_by_types(node, &["class_declaration", "record_declaration"])
}

fn ex_find_parent_module_declaration_name<'a>(node: &'a Node, source: &'a [u8]) -> Option<String> {
    let mut parent = node.parent();
    while let Some(parent_node) = parent {
        if parent_node.kind() == "call" {
            let text = get_node_text(&parent_node, source);
            if text.starts_with("defmodule ") {
                let arguments_node = find_child_by_type(&parent_node, "arguments");
                if let Some(arguments_node) = arguments_node {
                    return Some(get_node_text(&arguments_node, source));
                }
            }
        }
        parent = parent_node.parent();
    }
    None
}

fn ruby_find_parent_module_declaration_name<'a>(
    node: &'a Node,
    source: &'a [u8],
) -> Option<String> {
    let mut path_parts = Vec::new();
    let mut current = Some(*node);

    while let Some(current_node) = current {
        if current_node.kind() == "module" || current_node.kind() == "class" {
            if let Some(name_node) = current_node.child_by_field_name("name") {
                path_parts.push(get_node_text(&name_node, source));
            }
        }
        current = current_node.parent();
    }

    if path_parts.is_empty() {
        None
    } else {
        path_parts.reverse();
        Some(path_parts.join("::"))
    }
}

fn get_node_text<'a>(node: &'a Node, source: &'a [u8]) -> String {
    node.utf8_text(source).unwrap_or_default().to_string()
}

fn get_node_type<'a>(node: &'a Node, source: &'a [u8]) -> String {
    let predefined_type_node = find_descendant_by_type(node, "predefined_type");
    if let Some(type_node) = predefined_type_node {
        return type_node.utf8_text(source).unwrap().to_string();
    }
    let value_type_node = node.child_by_field_name("type");
    value_type_node
        .map(|n| n.utf8_text(source).unwrap().to_string())
        .unwrap_or_default()
}

fn is_first_letter_uppercase(name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    name.chars().next().unwrap().is_uppercase()
}

// Given a language, parse the given source code and return exported definitions
fn extract_definitions(language: &str, source: &str) -> Result<Vec<Definition>, String> {
    let ts_language = get_ts_language(language);

    if ts_language.is_none() {
        return Ok(vec![]);
    }

    let ts_language = ts_language.unwrap();

    let mut definitions = Vec::new();
    let mut parser = Parser::new();
    parser
        .set_language(&ts_language.into())
        .unwrap_or_else(|_| panic!("Failed to set language for {language}"));
    let tree = parser
        .parse(source, None)
        .unwrap_or_else(|| panic!("Failed to parse source code for {language}"));
    let root_node = tree.root_node();

    let query = get_definitions_query(language)?;
    let mut query_cursor = QueryCursor::new();
    let captures = query_cursor.captures(&query, root_node, source.as_bytes());

    let mut class_def_map: BTreeMap<String, RefCell<Class>> = BTreeMap::new();
    let mut enum_def_map: BTreeMap<String, RefCell<Enum>> = BTreeMap::new();
    let mut union_def_map: BTreeMap<String, RefCell<Union>> = BTreeMap::new();

    let ensure_class_def =
        |language: &str, name: &str, class_def_map: &mut BTreeMap<String, RefCell<Class>>| {
            let mut type_name = "class";
            if language == "elixir" {
                type_name = "module";
            }
            class_def_map.entry(name.to_string()).or_insert_with(|| {
                RefCell::new(Class {
                    type_name: type_name.to_string(),
                    name: name.to_string(),
                    methods: vec![],
                    properties: vec![],
                    visibility_modifier: None,
                })
            });
        };

    let ensure_module_def = |name: &str, class_def_map: &mut BTreeMap<String, RefCell<Class>>| {
        class_def_map.entry(name.to_string()).or_insert_with(|| {
            RefCell::new(Class {
                name: name.to_string(),
                type_name: "module".to_string(),
                methods: vec![],
                properties: vec![],
                visibility_modifier: None,
            })
        });
    };

    let ensure_enum_def = |name: &str, enum_def_map: &mut BTreeMap<String, RefCell<Enum>>| {
        enum_def_map.entry(name.to_string()).or_insert_with(|| {
            RefCell::new(Enum {
                name: name.to_string(),
                items: vec![],
            })
        });
    };

    let ensure_union_def = |name: &str, union_def_map: &mut BTreeMap<String, RefCell<Union>>| {
        union_def_map.entry(name.to_string()).or_insert_with(|| {
            RefCell::new(Union {
                name: name.to_string(),
                items: vec![],
            })
        });
    };

    // Sometimes, multiple queries capture the same node with the same capture name.
    // We need to ensure that we only add the node to the definition map once.
    let mut captured_nodes: BTreeMap<String, Vec<usize>> = BTreeMap::new();

    for (m, _) in captures {
        for capture in m.captures {
            let capture_name = &query.capture_names()[capture.index as usize];
            let node = capture.node;
            let node_text = node.utf8_text(source.as_bytes()).unwrap();

            let node_id = node.id();
            if captured_nodes
                .get(*capture_name)
                .map_or(false, |v| v.contains(&node_id))
            {
                continue;
            }
            captured_nodes
                .entry(String::from(*capture_name))
                .or_default()
                .push(node_id);

            let name = match language {
                "cpp" => {
                    if *capture_name == "class" {
                        node.child_by_field_name("name")
                            .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                            .unwrap_or(node_text)
                            .to_string()
                    } else {
                        let ident = find_descendant_by_type(&node, "field_identifier")
                            .or_else(|| find_descendant_by_type(&node, "operator_name"))
                            .or_else(|| find_descendant_by_type(&node, "identifier"))
                            .map(|n| n.utf8_text(source.as_bytes()).unwrap());
                        if let Some(ident) = ident {
                            let scope = node
                                .child_by_field_name("declarator")
                                .and_then(|n| n.child_by_field_name("declarator"))
                                .and_then(|n| n.child_by_field_name("scope"));

                            if let Some(scope_node) = scope {
                                format!(
                                    "{}::{}",
                                    scope_node.utf8_text(source.as_bytes()).unwrap(),
                                    ident
                                )
                            } else {
                                ident.to_string()
                            }
                        } else {
                            node_text.to_string()
                        }
                    }
                }
                "scala" => node
                    .child_by_field_name("name")
                    .or_else(|| node.child_by_field_name("pattern"))
                    .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                    .unwrap_or(node_text)
                    .to_string(),
                "csharp" => {
                    let mut identifier = node;
                    // Handle primary constructors (they are direct children of *_declaration)
                    if *capture_name == "method" && csharp_is_primary_constructor(&node) {
                        identifier = node.parent().unwrap_or(node);
                    } else if *capture_name == "class_variable" {
                        identifier =
                            find_descendant_by_type(&node, "variable_declarator").unwrap_or(node);
                    }

                    identifier
                        .child_by_field_name("name")
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or(node_text)
                        .to_string()
                }
                "ruby" => {
                    let name = node
                        .child_by_field_name("name")
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or(node_text)
                        .to_string();
                    if *capture_name == "class" || *capture_name == "module" {
                        ruby_find_parent_module_declaration_name(&node, source.as_bytes())
                            .unwrap_or(name)
                    } else {
                        name
                    }
                }
                _ => node
                    .child_by_field_name("name")
                    .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                    .unwrap_or(node_text)
                    .to_string(),
            };

            match *capture_name {
                "class" => {
                    if !name.is_empty() {
                        if language == "go" && !is_first_letter_uppercase(&name) {
                            continue;
                        }
                        ensure_class_def(language, &name, &mut class_def_map);
                        let visibility_modifier_node =
                            find_child_by_type(&node, "visibility_modifier");
                        let visibility_modifier = visibility_modifier_node
                            .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                            .unwrap_or("");
                        let class_def = class_def_map.get_mut(&name).unwrap();
                        class_def.borrow_mut().visibility_modifier =
                            if visibility_modifier.is_empty() {
                                None
                            } else {
                                Some(visibility_modifier.to_string())
                            };
                    }
                }
                "module" => {
                    if !name.is_empty() {
                        ensure_module_def(&name, &mut class_def_map);
                    }
                }
                "enum_item" => {
                    let visibility_modifier_node =
                        find_descendant_by_type(&node, "visibility_modifier");
                    let visibility_modifier = visibility_modifier_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");
                    if language == "rust" && !visibility_modifier.contains("pub") {
                        continue;
                    }
                    if language == "zig"
                        && !zig_is_variable_declaration_public(&node, source.as_bytes())
                    {
                        continue;
                    }
                    let mut enum_name = get_closest_ancestor_name(&node, source);
                    if language == "zig" {
                        enum_name =
                            zig_find_parent_variable_declaration_name(&node, source.as_bytes())
                                .unwrap_or_default();
                    }
                    if language == "scala" {
                        if let Some(enum_node) = find_ancestor_by_type(&node, "enum_definition") {
                            if let Some(name_node) = enum_node.child_by_field_name("name") {
                                enum_name =
                                    name_node.utf8_text(source.as_bytes()).unwrap().to_string();
                            }
                        }
                    }
                    if !enum_name.is_empty()
                        && language == "go"
                        && !is_first_letter_uppercase(&enum_name)
                    {
                        continue;
                    }
                    ensure_enum_def(&enum_name, &mut enum_def_map);
                    let enum_def = enum_def_map.get_mut(&enum_name).unwrap();
                    let enum_type_node = find_descendant_by_type(&node, "type_identifier");
                    let enum_type = enum_type_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");
                    let variable = Variable {
                        name: name.clone(),
                        value_type: enum_type.to_string(),
                    };
                    enum_def.borrow_mut().items.push(variable);
                }
                "union_item" => {
                    if language != "zig" {
                        continue;
                    }
                    if !zig_is_variable_declaration_public(&node, source.as_bytes()) {
                        continue;
                    }
                    let union_name =
                        zig_find_parent_variable_declaration_name(&node, source.as_bytes())
                            .unwrap_or_default();
                    ensure_union_def(&union_name, &mut union_def_map);
                    let union_def = union_def_map.get_mut(&union_name).unwrap();
                    let union_type_node = find_descendant_by_type(&node, "type_identifier");
                    let union_type = union_type_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");
                    let variable = Variable {
                        name: name.clone(),
                        value_type: union_type.to_string(),
                    };
                    union_def.borrow_mut().items.push(variable);
                }
                "method" => {
                    // TODO: C++: Skip private/protected class/struct methods
                    let visibility_modifier_node =
                        find_descendant_by_type(&node, "visibility_modifier");
                    let visibility_modifier = visibility_modifier_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");
                    if language == "swift" {
                        if visibility_modifier.contains("private") {
                            continue;
                        }
                    }
                    if language == "java" {
                        let modifier_node = find_descendant_by_type(&node, "modifiers");
                        if let Some(modifier_node) = modifier_node {
                            let modifier_text = modifier_node.utf8_text(source.as_bytes()).unwrap();
                            if modifier_text.contains("private") {
                                continue;
                            }
                        }
                    }
                    if language == "rust" && !visibility_modifier.contains("pub") {
                        continue;
                    }
                    if language == "zig"
                        && !(zig_is_function_declaration_public(&node, source.as_bytes())
                            && zig_is_variable_declaration_public(&node, source.as_bytes()))
                    {
                        continue;
                    }
                    if language == "cpp"
                        && find_descendant_by_type(&node, "destructor_name").is_some()
                    {
                        continue;
                    }

                    if !name.is_empty() && language == "go" && !is_first_letter_uppercase(&name) {
                        continue;
                    }

                    if language == "csharp" {
                        let csharp_visibility = find_descendant_by_type(&node, "modifier");
                        if csharp_visibility.is_none() && !csharp_is_primary_constructor(&node) {
                            continue;
                        }
                        if let Some(csharp_visibility) = csharp_visibility {
                            let csharp_visibility_text =
                                csharp_visibility.utf8_text(source.as_bytes()).unwrap();
                            if csharp_visibility_text == "private" {
                                continue;
                            }
                        }
                    }

                    let mut params_node = node
                        .child_by_field_name("parameters")
                        .or_else(|| find_descendant_by_type(&node, "parameter_list"));

                    let zig_function_node = find_ancestor_by_type(&node, "function_declaration");
                    if language == "zig" {
                        params_node = zig_function_node
                            .as_ref()
                            .and_then(|n| find_child_by_type(n, "parameters"));
                    }
                    let ex_function_node = find_ancestor_by_type(&node, "call");
                    if language == "elixir" {
                        params_node = ex_function_node
                            .as_ref()
                            .and_then(|n| find_child_by_type(n, "arguments"));
                    }

                    let params = params_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("()");
                    let mut return_type_node = match language {
                        "cpp" => node.child_by_field_name("type"),
                        "csharp" => node.child_by_field_name("returns"),
                        _ => node.child_by_field_name("return_type"),
                    };
                    if language == "cpp" {
                        let class_specifier_node = find_ancestor_by_type(&node, "class_specifier");
                        let type_identifier_node =
                            class_specifier_node.and_then(|n| n.child_by_field_name("name"));

                        if let Some(type_identifier_node) = type_identifier_node {
                            let type_identifier_text =
                                type_identifier_node.utf8_text(source.as_bytes()).unwrap();
                            if name == type_identifier_text {
                                return_type_node = Some(type_identifier_node);
                            }
                        }
                    }
                    if language == "csharp" {
                        let type_specifier_node = csharp_find_parent_type_node(&node);
                        let type_identifier_node =
                            type_specifier_node.and_then(|n| n.child_by_field_name("name"));

                        if let Some(type_identifier_node) = type_identifier_node {
                            let type_identifier_text =
                                type_identifier_node.utf8_text(source.as_bytes()).unwrap();
                            if name == type_identifier_text {
                                return_type_node = Some(type_identifier_node);
                            }
                        }
                    }
                    if return_type_node.is_none() {
                        return_type_node = node.child_by_field_name("result");
                    }
                    let mut return_type = "void".to_string();
                    if language == "elixir" {
                        return_type = String::new();
                    }
                    if let Some(return_type_node) = return_type_node {
                        return_type = get_node_type(&return_type_node, source.as_bytes());
                        if return_type.is_empty() {
                            return_type = return_type_node
                                .utf8_text(source.as_bytes())
                                .unwrap_or("void")
                                .to_string();
                        }
                    }

                    let impl_item_node = find_ancestor_by_type(&node, "impl_item");
                    let receiver_node = node.child_by_field_name("receiver");
                    let class_name = if language == "zig" {
                        zig_find_parent_variable_declaration_name(&node, source.as_bytes())
                            .unwrap_or_default()
                    } else if language == "elixir" {
                        ex_find_parent_module_declaration_name(&node, source.as_bytes())
                            .unwrap_or_default()
                    } else if language == "cpp" {
                        find_ancestor_by_type(&node, "class_specifier")
                            .or_else(|| find_ancestor_by_type(&node, "struct_specifier"))
                            .and_then(|n| n.child_by_field_name("name"))
                            .and_then(|n| n.utf8_text(source.as_bytes()).ok())
                            .unwrap_or("")
                            .to_string()
                    } else if language == "csharp" {
                        csharp_find_parent_type_node(&node)
                            .and_then(|n| n.child_by_field_name("name"))
                            .and_then(|n| n.utf8_text(source.as_bytes()).ok())
                            .unwrap_or("")
                            .to_string()
                    } else if language == "ruby" {
                        ruby_find_parent_module_declaration_name(&node, source.as_bytes())
                            .unwrap_or_default()
                    } else if let Some(impl_item) = impl_item_node {
                        let impl_type_node = impl_item.child_by_field_name("type");
                        impl_type_node
                            .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                            .unwrap_or("")
                            .to_string()
                    } else if let Some(receiver) = receiver_node {
                        let type_identifier_node =
                            find_descendant_by_type(&receiver, "type_identifier");
                        type_identifier_node
                            .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                            .unwrap_or("")
                            .to_string()
                    } else {
                        get_closest_ancestor_name(&node, source)
                    };

                    if language == "go" && !is_first_letter_uppercase(&class_name) {
                        continue;
                    }

                    ensure_class_def(language, &class_name, &mut class_def_map);
                    let class_def = class_def_map.get_mut(&class_name).unwrap();

                    let accessibility_modifier_node =
                        find_descendant_by_type(&node, "accessibility_modifier");
                    let accessibility_modifier = if language == "ruby" {
                        if ruby_method_is_private(&node, source.as_bytes()) {
                            "private"
                        } else {
                            ""
                        }
                    } else {
                        accessibility_modifier_node
                            .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                            .unwrap_or("")
                    };

                    let func = Func {
                        name: name.clone(),
                        params: params.to_string(),
                        return_type: return_type.clone(),
                        accessibility_modifier: if accessibility_modifier.is_empty() {
                            None
                        } else {
                            Some(accessibility_modifier.to_string())
                        },
                    };
                    class_def.borrow_mut().methods.push(func);
                }
                "class_assignment" => {
                    let visibility_modifier_node =
                        find_descendant_by_type(&node, "visibility_modifier");
                    let visibility_modifier = visibility_modifier_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");
                    if language == "swift" || language == "java" {
                        if visibility_modifier.contains("private") {
                            continue;
                        }
                    }
                    if language == "java" {
                        let modifier_node = find_descendant_by_type(&node, "modifiers");
                        if let Some(modifier_node) = modifier_node {
                            let modifier_text = modifier_node.utf8_text(source.as_bytes()).unwrap();
                            if modifier_text.contains("private") {
                                continue;
                            }
                        }
                    }
                    if language == "rust" && !visibility_modifier.contains("pub") {
                        continue;
                    }
                    let left_node = node.child_by_field_name("left");
                    let left = left_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");
                    let value_type = get_node_type(&node, source.as_bytes());
                    let mut class_name = get_closest_ancestor_name(&node, source);
                    if !class_name.is_empty() {
                        if language == "ruby" {
                            if let Some(namespaced_name) =
                                ruby_find_parent_module_declaration_name(&node, source.as_bytes())
                            {
                                class_name = namespaced_name;
                            }
                        } else if language == "go" && !is_first_letter_uppercase(&class_name) {
                            continue;
                        }
                    }
                    if class_name.is_empty() {
                        continue;
                    }
                    ensure_class_def(language, &class_name, &mut class_def_map);
                    let class_def = class_def_map.get_mut(&class_name).unwrap();
                    let variable = Variable {
                        name: left.to_string(),
                        value_type: value_type.clone(),
                    };
                    class_def.borrow_mut().properties.push(variable);
                }
                "class_variable" => {
                    // TODO: C++: Skip private/protected class/struct variables
                    let visibility_modifier_node =
                        find_descendant_by_type(&node, "visibility_modifier");
                    let visibility_modifier = visibility_modifier_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");
                    if language == "rust" && !visibility_modifier.contains("pub") {
                        continue;
                    }

                    if language == "swift" || language == "java" {
                        if visibility_modifier.contains("private") {
                            continue;
                        }
                    }

                    if language == "java" {
                        let modifier_node = find_descendant_by_type(&node, "modifiers");
                        if let Some(modifier_node) = modifier_node {
                            let modifier_text = modifier_node.utf8_text(source.as_bytes()).unwrap();
                            if modifier_text.contains("private") {
                                continue;
                            }
                        }
                    }

                    let value_type = get_node_type(&node, source.as_bytes());

                    if language == "zig" {
                        // when top level class is not public, skip
                        if !zig_is_variable_declaration_public(&node, source.as_bytes()) {
                            continue;
                        }
                    }

                    let mut class_name = get_closest_ancestor_name(&node, source);
                    if language == "cpp" {
                        class_name = find_ancestor_by_type(&node, "class_specifier")
                            .or_else(|| find_ancestor_by_type(&node, "struct_specifier"))
                            .and_then(|n| n.child_by_field_name("name"))
                            .and_then(|n| n.utf8_text(source.as_bytes()).ok())
                            .unwrap_or("")
                            .to_string();
                    }

                    if language == "csharp" {
                        let csharp_visibility = find_descendant_by_type(&node, "modifier");
                        let Some(csharp_visibility) = csharp_visibility else {
                            continue;
                        };
                        let csharp_visibility_text =
                            csharp_visibility.utf8_text(source.as_bytes()).unwrap();
                        if csharp_visibility_text == "private" {
                            continue;
                        }
                    }

                    if language == "zig" {
                        class_name =
                            zig_find_parent_variable_declaration_name(&node, source.as_bytes())
                                .unwrap_or_default();
                    }
                    if !class_name.is_empty()
                        && language == "go"
                        && !is_first_letter_uppercase(&class_name)
                    {
                        continue;
                    }
                    if class_name.is_empty() {
                        continue;
                    }
                    if !name.is_empty() && language == "go" && !is_first_letter_uppercase(&name) {
                        continue;
                    }
                    ensure_class_def(language, &class_name, &mut class_def_map);
                    let class_def = class_def_map.get_mut(&class_name).unwrap();
                    let variable = Variable {
                        name: name.clone(),
                        value_type: value_type.clone(),
                    };
                    class_def.borrow_mut().properties.push(variable);
                }
                "function" | "arrow_function" => {
                    let visibility_modifier_node =
                        find_descendant_by_type(&node, "visibility_modifier");
                    let visibility_modifier = visibility_modifier_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");

                    if language == "swift" || language == "java" {
                        if visibility_modifier.contains("private") {
                            continue;
                        }

                        if node.parent().is_some() {
                            continue;
                        }
                    }

                    if language == "java" {
                        let modifier_node = find_descendant_by_type(&node, "modifiers");
                        if let Some(modifier_node) = modifier_node {
                            let modifier_text = modifier_node.utf8_text(source.as_bytes()).unwrap();
                            if modifier_text.contains("private") {
                                continue;
                            }
                        }
                    }

                    if language == "rust" && !visibility_modifier.contains("pub") {
                        continue;
                    }

                    if language == "zig" {
                        let variable_declaration_text =
                            node.utf8_text(source.as_bytes()).unwrap_or("");
                        if !variable_declaration_text.contains("pub") {
                            continue;
                        }
                    }

                    if !name.is_empty() && language == "go" && !is_first_letter_uppercase(&name) {
                        continue;
                    }
                    let impl_item_node = find_ancestor_by_type(&node, "impl_item");
                    if impl_item_node.is_some() {
                        continue;
                    }
                    let class_specifier_node = find_ancestor_by_type(&node, "class_specifier");
                    if class_specifier_node.is_some() {
                        continue;
                    }
                    let struct_specifier_node = find_ancestor_by_type(&node, "struct_specifier");
                    if struct_specifier_node.is_some() {
                        continue;
                    }
                    let function_node = find_ancestor_by_type(&node, "function_declaration")
                        .or_else(|| find_ancestor_by_type(&node, "function_definition"));
                    if function_node.is_some() {
                        continue;
                    }
                    let params_node = node
                        .child_by_field_name("parameters")
                        .or_else(|| find_descendant_by_type(&node, "parameter_list"));
                    let params = params_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("()");

                    let mut return_type = "void".to_string();
                    let return_type_node = match language {
                        "cpp" => node.child_by_field_name("type"),
                        _ => node
                            .child_by_field_name("return_type")
                            .or_else(|| node.child_by_field_name("result")),
                    };
                    if let Some(return_type_node) = return_type_node {
                        return_type = get_node_type(&return_type_node, source.as_bytes());
                        if return_type.is_empty() {
                            return_type = return_type_node
                                .utf8_text(source.as_bytes())
                                .unwrap_or("void")
                                .to_string();
                        }
                    }

                    let accessibility_modifier_node =
                        find_descendant_by_type(&node, "accessibility_modifier");
                    let accessibility_modifier = accessibility_modifier_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");

                    let func = Func {
                        name: name.clone(),
                        params: params.to_string(),
                        return_type: return_type.clone(),
                        accessibility_modifier: if accessibility_modifier.is_empty() {
                            None
                        } else {
                            Some(accessibility_modifier.to_string())
                        },
                    };
                    definitions.push(Definition::Func(func));
                }
                "assignment" => {
                    let visibility_modifier_node =
                        find_descendant_by_type(&node, "visibility_modifier");
                    let visibility_modifier = visibility_modifier_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");
                    if language == "swift" || language == "java" {
                        if visibility_modifier.contains("private") {
                            continue;
                        }
                    }
                    if language == "java" {
                        let modifier_node = find_descendant_by_type(&node, "modifiers");
                        if let Some(modifier_node) = modifier_node {
                            let modifier_text = modifier_node.utf8_text(source.as_bytes()).unwrap();
                            if modifier_text.contains("private") {
                                continue;
                            }
                        }
                    }
                    if language == "rust" && !visibility_modifier.contains("pub") {
                        continue;
                    }
                    let impl_item_node = find_ancestor_by_type(&node, "impl_item")
                        .or_else(|| find_ancestor_by_type(&node, "class_declaration"))
                        .or_else(|| find_ancestor_by_type(&node, "class_definition"));
                    if impl_item_node.is_some() {
                        continue;
                    }
                    let function_node = find_ancestor_by_type(&node, "function_declaration")
                        .or_else(|| find_ancestor_by_type(&node, "function_definition"));
                    if function_node.is_some() {
                        continue;
                    }
                    let left_node = node.child_by_field_name("left");
                    let left = left_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");
                    if !left.is_empty() && language == "go" && !is_first_letter_uppercase(left) {
                        continue;
                    }

                    let value_type = get_node_type(&node, source.as_bytes());
                    let variable = Variable {
                        name: left.to_string(),
                        value_type: value_type.clone(),
                    };
                    definitions.push(Definition::Variable(variable));
                }
                "variable" => {
                    let visibility_modifier_node =
                        find_descendant_by_type(&node, "visibility_modifier");
                    let visibility_modifier = visibility_modifier_node
                        .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                        .unwrap_or("");

                    if language == "swift" {
                        if visibility_modifier.contains("private") {
                            continue;
                        }
                    }

                    if language == "java" {
                        let modifier_node = find_descendant_by_type(&node, "modifiers");
                        if let Some(modifier_node) = modifier_node {
                            let modifier_text = modifier_node.utf8_text(source.as_bytes()).unwrap();
                            if modifier_text.contains("private") {
                                continue;
                            }
                        }
                    }

                    if language == "rust" && !visibility_modifier.contains("pub") {
                        continue;
                    }

                    if language == "zig"
                        && !zig_is_variable_declaration_public(&node, source.as_bytes())
                    {
                        continue;
                    }

                    let impl_item_node = find_ancestor_by_type(&node, "impl_item")
                        .or_else(|| find_ancestor_by_type(&node, "class_declaration"))
                        .or_else(|| find_ancestor_by_type(&node, "class_definition"));
                    if impl_item_node.is_some() {
                        continue;
                    }
                    let function_node = find_ancestor_by_type(&node, "function_declaration")
                        .or_else(|| find_ancestor_by_type(&node, "function_definition"));
                    if function_node.is_some() {
                        continue;
                    }
                    let value_node = node.child_by_field_name("value");
                    if let Some(value_node) = value_node {
                        let value_type = value_node.kind();
                        if value_type == "arrow_function" {
                            let params_node = value_node.child_by_field_name("parameters");
                            let params = params_node
                                .map(|n| n.utf8_text(source.as_bytes()).unwrap())
                                .unwrap_or("()");
                            let mut return_type = "void".to_string();
                            let return_type_node = value_node.child_by_field_name("return_type");
                            if let Some(return_type_node) = return_type_node {
                                return_type = get_node_type(&return_type_node, source.as_bytes());
                            }
                            let func = Func {
                                name: name.clone(),
                                params: params.to_string(),
                                return_type,
                                accessibility_modifier: None,
                            };
                            definitions.push(Definition::Func(func));
                            continue;
                        }
                    }

                    let mut value_type = get_node_type(&node, source.as_bytes());
                    if language == "zig" {
                        if let Some(zig_type) = zig_find_type_in_parent(&node, source.as_bytes()) {
                            value_type = zig_type;
                        } else {
                            continue;
                        }
                    }
                    if !name.is_empty() && language == "go" && !is_first_letter_uppercase(&name) {
                        continue;
                    }
                    let variable = Variable {
                        name: name.clone(),
                        value_type: value_type.clone(),
                    };
                    definitions.push(Definition::Variable(variable));
                }
                _ => {}
            }
        }
    }

    for (_, def) in class_def_map {
        let class_def = def.into_inner();
        if language == "rust" {
            if let Some(visibility_modifier) = &class_def.visibility_modifier {
                if visibility_modifier.contains("pub") {
                    definitions.push(Definition::Class(class_def));
                }
            }
        } else {
            definitions.push(Definition::Class(class_def));
        }
    }

    for (_, def) in enum_def_map {
        definitions.push(Definition::Enum(def.into_inner()));
    }
    for (_, def) in union_def_map {
        definitions.push(Definition::Union(def.into_inner()));
    }

    Ok(definitions)
}

fn stringify_function(func: &Func) -> String {
    let mut res = format!("func {}", func.name);
    if func.params.is_empty() {
        res = format!("{res}()");
    } else {
        res = format!("{res}{}", func.params);
    }
    if !func.return_type.is_empty() {
        res = format!("{res} -> {}", func.return_type);
    }
    if let Some(modifier) = &func.accessibility_modifier {
        res = format!("{modifier} {res}");
    }
    format!("{res};")
}

fn stringify_variable(variable: &Variable) -> String {
    let mut res = format!("var {}", variable.name);
    if !variable.value_type.is_empty() {
        res = format!("{res}:{}", variable.value_type);
    }
    format!("{res};")
}

fn stringify_enum_item(item: &Variable) -> String {
    let mut res = item.name.clone();
    if !item.value_type.is_empty() {
        res = format!("{res}:{}", item.value_type);
    }
    format!("{res};")
}

fn stringify_union_item(item: &Variable) -> String {
    let mut res = item.name.clone();
    if !item.value_type.is_empty() {
        res = format!("{res}:{}", item.value_type);
    }
    format!("{res};")
}

fn stringify_class(class: &Class) -> String {
    let mut res = format!("{} {}{{", class.type_name, class.name);
    for method in &class.methods {
        let method_str = stringify_function(method);
        res = format!("{res}{method_str}");
    }
    for property in &class.properties {
        let property_str = stringify_variable(property);
        res = format!("{res}{property_str}");
    }
    format!("{res}}};")
}

fn stringify_enum(enum_def: &Enum) -> String {
    let mut res = format!("enum {}{{", enum_def.name);
    for item in &enum_def.items {
        let item_str = stringify_enum_item(item);
        res = format!("{res}{item_str}");
    }
    format!("{res}}};")
}
fn stringify_union(union_def: &Union) -> String {
    let mut res = format!("union {}{{", union_def.name);
    for item in &union_def.items {
        let item_str = stringify_union_item(item);
        res = format!("{res}{item_str}");
    }
    format!("{res}}};")
}

fn stringify_definitions(definitions: &Vec<Definition>) -> String {
    let mut res = String::new();
    for definition in definitions {
        match definition {
            Definition::Class(class) => res = format!("{res}{}", stringify_class(class)),
            Definition::Module(module) => res = format!("{res}{}", stringify_class(module)),
            Definition::Enum(enum_def) => res = format!("{res}{}", stringify_enum(enum_def)),
            Definition::Union(union_def) => res = format!("{res}{}", stringify_union(union_def)),
            Definition::Func(func) => res = format!("{res}{}", stringify_function(func)),
            Definition::Variable(variable) => {
                let variable_str = stringify_variable(variable);
                res = format!("{res}{variable_str}");
            }
        }
    }
    res
}

pub fn get_definitions_string(language: &str, source: &str) -> LuaResult<String> {
    let definitions = extract_definitions(language, source).map_err(LuaError::RuntimeError)?;
    let stringified = stringify_definitions(&definitions);
    Ok(stringified)
}

#[mlua::lua_module]
fn avante_repo_map(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;
    exports.set(
        "stringify_definitions",
        lua.create_function(move |_, (language, source): (String, String)| {
            get_definitions_string(language.as_str(), source.as_str())
        })?,
    )?;
    Ok(exports)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rust() {
        let source = r#"
        // This is a test comment
        pub const TEST_CONST: u32 = 1;
        pub static TEST_STATIC: u32 = 2;
        const INNER_TEST_CONST: u32 = 3;
        static INNER_TEST_STATIC: u32 = 4;
        pub(crate) struct TestStruct {
            pub test_field: String,
            inner_test_field: String,
        }
        impl TestStruct {
            pub fn test_method(&self, a: u32, b: u32) -> u32 {
                a + b
            }
            fn inner_test_method(&self, a: u32, b: u32) -> u32 {
                a + b
            }
        }
        struct InnerTestStruct {
            pub test_field: String,
            inner_test_field: String,
        }
        impl InnerTestStruct {
            pub fn test_method(&self, a: u32, b: u32) -> u32 {
                a + b
            }
            fn inner_test_method(&self, a: u32, b: u32) -> u32 {
                a + b
            }
        }
        pub enum TestEnum {
            TestEnumField1,
            TestEnumField2,
        }
        enum InnerTestEnum {
            InnerTestEnumField1,
            InnerTestEnumField2,
        }
        pub fn test_fn(a: u32, b: u32) -> u32 {
            let inner_var_in_func = 1;
            struct InnerStructInFunc {
                c: u32,
            }
            a + b + c
        }
        fn inner_test_fn(a: u32, b: u32) -> u32 {
            a + b
        }
        "#;
        let definitions = extract_definitions("rust", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var TEST_CONST:u32;var TEST_STATIC:u32;func test_fn(a: u32, b: u32) -> u32;class TestStruct{func test_method(&self, a: u32, b: u32) -> u32;var test_field:String;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_zig() {
        let source = r#"
          // This is a test comment
          pub const TEST_CONST: u32 = 1;
          pub var TEST_VAR: u32 = 2;
          const INNER_TEST_CONST: u32 = 3;
          var INNER_TEST_VAR: u32 = 4;
          pub const TestStruct = struct {
              test_field: []const u8,
              test_field2: u64,

              pub fn test_method(_: *TestStruct, a: u32, b: u32) u32 {
                  return a + b;
              }

              fn inner_test_method(_: *TestStruct, a: u32, b: u32) u32 {
                  return a + b;
              }
          };
          const InnerTestStruct = struct {
              test_field: []const u8,
              test_field2: u64,

              pub fn test_method(_: *InnerTestStruct, a: u32, b: u32) u32 {
                  return a + b;
              }

              fn inner_test_method(_: *InnerTestStruct, a: u32, b: u32) u32 {
                  return a + b;
              }
          };
          pub const TestEnum = enum {
              TestEnumField1,
              TestEnumField2,
          };
          const InnerTestEnum = enum {
              InnerTestEnumField1,
              InnerTestEnumField2,
          };

          pub const TestUnion = union {
              TestUnionField1: u32,
              TestUnionField2: u64,
          };

          const InnerTestUnion = union {
              InnerTestUnionField1: u32,
              InnerTestUnionField2: u64,
          };

          pub fn test_fn(a: u32, b: u32) u32 {
              const inner_var_in_func = 1;
              const InnerStructInFunc = struct {
                  c: u32,
              };
              _ = InnerStructInFunc;
              return a + b + inner_var_in_func;
          }
          fn inner_test_fn(a: u32, b: u32) u32 {
              return a + b;
          }
        "#;

        let definitions = extract_definitions("zig", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var TEST_CONST:u32;var TEST_VAR:u32;func test_fn() -> void;class TestStruct{func test_method(_: *TestStruct, a: u32, b: u32) -> void;var test_field:[]const u8;var test_field2:u64;};enum TestEnum{TestEnumField1;TestEnumField2;};union TestUnion{TestUnionField1;TestUnionField2;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_go() {
        let source = r#"
        // This is a test comment
        package main
        import "fmt"
        const TestConst string = "test"
        const innerTestConst string = "test"
        var TestVar string
        var innerTestVar string
        type TestStruct struct {
            TestField string
            innerTestField string
        }
        func (t *TestStruct) TestMethod(a int, b int) (int, error) {
            var InnerVarInFunc int = 1
            type InnerStructInFunc struct {
                C int
            }
            return a + b, nil
        }
        func (t *TestStruct) innerTestMethod(a int, b int) (int, error) {
            return a + b, nil
        }
        type innerTestStruct struct {
            innerTestField string
        }
        func (t *innerTestStruct) testMethod(a int, b int) (int, error) {
            return a + b, nil
        }
        func (t *innerTestStruct) innerTestMethod(a int, b int) (int, error) {
            return a + b, nil
        }
        func TestFunc(a int, b int) (int, error) {
            return a + b, nil
        }
        func innerTestFunc(a int, b int) (int, error) {
            return a + b, nil
        }
        "#;
        let definitions = extract_definitions("go", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var TestConst:string;var TestVar:string;func TestFunc(a int, b int) -> (int, error);class TestStruct{func TestMethod(a int, b int) -> (int, error);var TestField:string;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_python() {
        let source = r#"
        # This is a test comment
        test_var: str = "test"
        class TestClass:
            def __init__(self, a, b):
                self.a = a
                self.b = b
            def test_method(self, a: int, b: int) -> int:
                inner_var_in_method: int = 1
                return a + b
        def test_func(a: int, b: int) -> int:
            inner_var_in_func: str = "test"
            class InnerClassInFunc:
                def __init__(self, a, b):
                    self.a = a
                    self.b = b
                def test_method(self, a: int, b: int) -> int:
                    return a + b
            def inne_func_in_func(a: int, b: int) -> int:
                return a + b
            return a + b
        "#;
        let definitions = extract_definitions("python", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var test_var:str;func test_func(a: int, b: int) -> int;class TestClass{func __init__(self, a, b) -> void;func test_method(self, a: int, b: int) -> int;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_typescript() {
        let source = r#"
        // This is a test comment
        export const testVar: string = "test";
        const innerTestVar: string = "test";
        export class TestClass {
            a: number;
            b: number;
            constructor(a: number, b: number) {
                this.a = a;
                this.b = b;
            }
            testMethod(a: number, b: number): number {
                const innerConstInMethod: number = 1;
                function innerFuncInMethod(a: number, b: number): number {
                    return a + b;
                }
                return a + b;
            }
        }
        class InnerTestClass {
            a: number;
            b: number;
        }
        export function testFunc(a: number, b: number) {
            const innerConstInFunc: number = 1;
            function innerFuncInFunc(a: number, b: number): number {
                return a + b;
            }
            return a + b;
        }
        export const testFunc2 = (a: number, b: number) => {
            return a + b;
        }
        export const testFunc3 = (a: number, b: number): number => {
            return a + b;
        }
        function innerTestFunc(a: number, b: number) {
            return a + b;
        }
        "#;
        let definitions = extract_definitions("typescript", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var testVar:string;func testFunc(a: number, b: number) -> void;func testFunc2(a: number, b: number) -> void;func testFunc3(a: number, b: number) -> number;class TestClass{func constructor(a: number, b: number) -> void;func testMethod(a: number, b: number) -> number;var a:number;var b:number;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_javascript() {
        let source = r#"
        // This is a test comment
        export const testVar = "test";
        const innerTestVar = "test";
        export class TestClass {
            constructor(a, b) {
                this.a = a;
                this.b = b;
            }
            testMethod(a, b) {
                const innerConstInMethod = 1;
                function innerFuncInMethod(a, b) {
                    return a + b;
                }
                return a + b;
            }
        }
        class InnerTestClass {
            constructor(a, b) {
                this.a = a;
                this.b = b;
            }
        }
        export const testFunc = function(a, b) {
            const innerConstInFunc = 1;
            function innerFuncInFunc(a, b) {
                return a + b;
            }
            return a + b;
        }
        export const testFunc2 = (a, b) => {
            return a + b;
        }
        export const testFunc3 = (a, b) => a + b;
        function innerTestFunc(a, b) {
            return a + b;
        }
        "#;
        let definitions = extract_definitions("javascript", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var testVar;var testFunc;func testFunc2(a, b) -> void;func testFunc3(a, b) -> void;class TestClass{func constructor(a, b) -> void;func testMethod(a, b) -> void;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_ruby() {
        let source = r#"
        # This is a test comment
        test_var = "test"
        def test_func(a, b)
            inner_var_in_func = "test"
            class InnerClassInFunc
                attr_accessor :a, :b
                def initialize(a, b)
                    @a = a
                    @b = b
                end
                def test_method(a, b)
                    return a + b
                end
            end
            return a + b
        end
        class TestClass
            attr_accessor :a, :b
            def initialize(a, b)
                @a = a
                @b = b
            end
            def test_method(a, b)
                inner_var_in_method = 1
                def inner_func_in_method(a, b)
                    return a + b
                end
                return a + b
            end
        end
        "#;
        let definitions = extract_definitions("ruby", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        // FIXME:
        let expected = "var test_var;func test_func(a, b) -> void;class InnerClassInFunc{func initialize(a, b) -> void;func test_method(a, b) -> void;};class TestClass{func initialize(a, b) -> void;func test_method(a, b) -> void;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_ruby2() {
        let source = r#"
        # frozen_string_literal: true

        require('jwt')

        top_level_var = 1

        def top_level_func
          inner_var_in_func = 2
        end

        module A
          module B
            @module_var = :foo

            def module_method
              @module_var
            end

            class C < Base
              TEST_CONST = 1
              @class_var = :bar
              attr_accessor :a, :b

              def initialize(a, b)
                @a = a
                @b = b
                super
              end

              def bar
                inner_var_in_method = 1
                true
              end

              private

              def baz(request, params)
                auth_header = request.headers['Authorization']
                parts = auth_header.try(:split, /\s+/)
                JWT.decode(parts.last)
              end
            end
          end
        end
        "#;
        let definitions = extract_definitions("ruby", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var top_level_var;func top_level_func() -> void;module A{};module A::B{func module_method() -> void;var @module_var;};class A::B::C{func initialize(a, b) -> void;func bar() -> void;private func baz(request, params) -> void;var TEST_CONST;var @class_var;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_lua() {
        let source = r#"
        -- This is a test comment
        local test_var = "test"
        function test_func(a, b)
            local inner_var_in_func = 1
            function inner_func_in_func(a, b)
                return a + b
            end
            return a + b
        end
        "#;
        let definitions = extract_definitions("lua", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var test_var;func test_func(a, b) -> void;";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_c() {
        let source = r#"
        #include <stdio.h>

        int test_var = 2;
        extern int extern_test_var;

        int TestFunc(bool b) { return b ? 42 : -1; }
        extern void ExternTestFunc();

        struct Foo {
            int a;
            int b;
        };

        typedef int my_int;
        "#;
        let definitions = extract_definitions("c", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var extern int extern_test_var;:int;var extern void ExternTestFunc();:void;class Foo{var int a;:int;var int b;:int;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_cpp() {
        let source = r#"
        // This is a test comment
        #include <iostream>

        namespace {
        constexpr int TEST_CONSTEXPR = 1;
        const int TEST_CONST = 1;
        }; // namespace

        int test_var = 2;

        int TestFunc(bool b) { return b ? 42 : -1; }

        template <typename T> class TestClass {
        public:
          TestClass();
          TestClass(T a, T b);
          ~TestClass();
          bool operator==(const TestClass &other);
          T testMethod(T x, T y) { return x + y; }
          T c;

        private:
          void privateMethod();
          T a = 0;
          T b;
        };

        struct TestStruct {
        public:
          TestStruct(int a, int b);
          ~TestStruct();
          bool operator==(const TestStruct &other);
          int testMethod(int x, int y) { return x + y; }
          static int c;

        private:
          int a = 0;
          int b;
        };

        bool TestStruct::operator==(const TestStruct &other) { return true; }

        int TestStruct::c = 0;

        int testFunction(int a, int b) { return a + b; }

        namespace TestNamespace {
        class InnerClass {
        public:
          bool innerMethod(int a) const;
        };
        bool InnerClass::innerMethod(int a) const { return doSomething(a * 2); }
        } // namespace TestNamespace

        enum TestEnum { ENUM_VALUE_1, ENUM_VALUE_2 };
        "#;
        let definitions = extract_definitions("cpp", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{}", stringified);
        let expected = "var TEST_CONSTEXPR:int;var TEST_CONST:int;var test_var:int;func TestFunc(bool b) -> int;func TestStruct::operator==(const TestStruct &other) -> bool;var TestStruct::c:int;func testFunction(int a, int b) -> int;func InnerClass::innerMethod(int a) -> bool;class InnerClass{func innerMethod(int a) -> bool;};class TestClass{func TestClass() -> TestClass;func operator==(const TestClass &other) -> bool;func testMethod(T x, T y) -> T;func privateMethod() -> void;func TestClass(T a, T b) -> TestClass;var c:T;var a:T;var b:T;};class TestStruct{func TestStruct(int a, int b) -> void;func operator==(const TestStruct &other) -> bool;func testMethod(int x, int y) -> int;var c:int;var a:int;var b:int;};enum TestEnum{ENUM_VALUE_1;ENUM_VALUE_2;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_scala() {
        let source = r#"
        object Main {
          def main(args: Array[String]): Unit = {
            println("Hello, World!")
          }
        }

        class TestClass {
          val testVal: String = "test"
          var testVar = 42

          def testMethod(a: Int, b: Int): Int = {
            a + b
          }
        }

        // braceless syntax is also supported
        trait TestTrait:
          def abstractMethod(x: Int): Int
          def concreteMethod(y: Int): Int = y * 2

        case class TestCaseClass(name: String, age: Int)

        enum TestEnum {
          case First, Second, Third
        }

        val foo: TestClass = ???
        "#;

        let definitions = extract_definitions("scala", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var foo:TestClass;class Main{func main(args: Array[String]) -> Unit;};class TestCaseClass{};class TestClass{func testMethod(a: Int, b: Int) -> Int;var testVal:String;var testVar;};class TestTrait{func abstractMethod(x: Int) -> Int;func concreteMethod(y: Int) -> Int;};enum TestEnum{First;Second;Third;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_elixir() {
        let source = r#"
        defmodule TestModule do
          @moduledoc """
          This is a test module
          """

          @test_const "test"
          @other_const 123

          def test_func(a, b) do
            a + b
          end

          defp private_func(x) do
            x * 2
          end

          defmacro test_macro(expr) do
            quote do
              unquote(expr)
            end
          end
        end

        defmodule AnotherModule do
          def another_func() do
            :ok
          end
        end
        "#;
        let definitions = extract_definitions("elixir", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected =
            "module AnotherModule{func another_func();};module TestModule{func test_func(a, b);};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_csharp() {
        let source = r#"
      using System;

      namespace TestNamespace;

      public class TestClass(TestDependency m)
      {

        private int PrivateTestProperty { get; set; }

        private int _privateTestField;

        public int TestProperty { get; set; }

        public string TestField;

        public TestClass()
        {
          TestProperty = 0;
        }


        public void TestMethod(int a, int b)
        {
          var innerVarInMethod = 1;
          return a + b;
        }

        public int TestMethod(int a, int b, int c) => a + b + c;

        private void PrivateMethod()
        {
          return;
        }

        public class MyInnerClass(InnerClassDependency m) {}

        public record MyInnerRecord(int a);
      }

      public record TestRecord(int a, int b);

      public enum TestEnum { Value1, Value2 }
      "#;

        let definitions = extract_definitions("csharp", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "class MyInnerClass{func MyInnerClass(InnerClassDependency m) -> MyInnerClass;};class MyInnerRecord{func MyInnerRecord(int a) -> MyInnerRecord;};class TestClass{func TestClass(TestDependency m) -> TestClass;func TestClass() -> TestClass;func TestMethod(int a, int b) -> void;func TestMethod(int a, int b, int c) -> int;var TestProperty:int;var TestField:string;};class TestRecord{func TestRecord(int a, int b) -> TestRecord;};enum TestEnum{Value1;Value2;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_swift() {
        let source = r#"
            import Foundation

            private var myVariable = 0
            public var myPublicVariable = 0

            struct MyStruct {
              public var myPublicVariable = 0
              private var myPrivateVariable = 0

              func myPublicMethod(with parameter: Int) -> {
              }

              private func myPrivateMethod(with parameter: Int) -> {
              }
            }

            class MyClass {
                public var myPublicVariable = 0
                private var myPrivateVariable = 0

                init(myParameter: Int, myOtherParameter: Int) {
                }

                func myPublicMethod(with parameter: Int) -> {
                }

                private func myPrivateMethod(with parameter: Int) -> {
                }

                func myMethod() {
                    print("Hello, world!")
                }
            }
        "#;

        let definitions = extract_definitions("swift", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "var myPublicVariable;class MyClass{func init() -> void;func myPublicMethod() -> void;func myMethod() -> void;var myPublicVariable;};class MyStruct{func myPublicMethod() -> void;var myPublicVariable;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_php() {
        let source = r#"
        <?php
        class MyClass {
            public $myPublicVariable = 0;
            private $myPrivateVariable = 0;

            public function myPublicMethod($parameter) {
            }

            private function myPrivateMethod($parameter) {
            }

            function myMethod() {
                echo "Hello, world!";
            }
        }
        ?>
        "#;

        let definitions = extract_definitions("php", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "class MyClass{func myPublicMethod($parameter) -> void;func myPrivateMethod($parameter) -> void;func myMethod() -> void;var public $myPublicVariable = 0;;var private $myPrivateVariable = 0;;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_java() {
        let source = r#"
        public class MyClass {
            public void myPublicMethod(String parameter) {
                System.out.println("Hello, world!");
            }

            private void myPrivateMethod(String parameter) {
                System.out.println("Hello, world!");
            }

            void myMethod() {
                System.out.println("Hello, world!");
            }
        }
        "#;

        let definitions = extract_definitions("java", source).unwrap();
        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "class MyClass{func myPublicMethod(String parameter) -> void;func myMethod() -> void;};";
        assert_eq!(stringified, expected);
    }

    #[test]
    fn test_unsupported_language() {
        let source = "print('Hello, world!')";
        let definitions = extract_definitions("unknown", source).unwrap();

        let stringified = stringify_definitions(&definitions);
        println!("{stringified}");
        let expected = "";
        assert_eq!(stringified, expected);
    }
}
