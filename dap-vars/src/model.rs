//! Turning DAP response bodies into the panel's text. Every decision that
//! shapes the file lives here, as pure functions over `serde_json::Value`,
//! so the format is testable without a process on either side.
//!
//! SPDX-License-Identifier: LGPL-3.0-or-later

use std::fmt::Write as _;

use serde_json::Value;

/// A name, type or value longer than this is cut. A debugger will happily
/// report a megabyte-long summary of a vector, and the panel is a text file
/// somebody reads.
const MAX_TEXT: usize = 200;

/// The stopped frame. Only frame 0 is ever collected: the panel answers
/// "what is in scope right now", and walking the whole stack would cost a
/// request per frame on every step.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub id: Option<i64>,
    pub name: String,
    pub path: Option<String>,
    pub line: Option<i64>,
}

/// One variable, with at most one level of children.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Var {
    pub name: String,
    pub ty: Option<String>,
    pub value: String,
    /// Nonzero when the adapter says this variable can be expanded.
    pub reference: i64,
    pub children: Vec<Var>,
    /// Children exist that are not here, whether capped or never fetched.
    pub truncated: bool,
}

/// One scope of the stopped frame, minus the register scopes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scope {
    pub name: String,
    pub reference: i64,
    pub vars: Vec<Var>,
    pub truncated: bool,
}

/// Whether a scope is a register dump rather than program state.
///
/// This is the one adapter-shaped rule in the proxy, and it is deliberately
/// a property of the scope rather than of the adapter: lldb-dap reports
/// `Locals` / `Statics` / `Registers` with arguments folded into `Locals`,
/// probe-rs reports the same shape. An adapter that names its register scope
/// something else belongs in this predicate, not in a per-adapter branch.
pub fn skip_scope(name: &str, hint: Option<&str>) -> bool {
    hint == Some("registers") || name.to_lowercase().contains("register")
}

/// Collapse line breaks and cut to `MAX_TEXT` characters. A run of breaks
/// becomes one space, so a multi-line summary stays one line.
pub fn sanitize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_break = false;
    for character in text.chars() {
        if character == '\r' || character == '\n' {
            if !in_break {
                out.push(' ');
                in_break = true;
            }
            continue;
        }
        in_break = false;
        out.push(character);
    }

    if out.chars().count() > MAX_TEXT {
        let cut: String = out.chars().take(MAX_TEXT - 1).collect();
        return cut + "…";
    }
    out
}

fn text_at(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(sanitize)
        .filter(|found| !found.is_empty())
}

fn succeeded(response: &Value) -> bool {
    response.get("success").and_then(Value::as_bool) != Some(false)
}

/// Frame 0 of a `stackTrace` response, or `None` when the adapter reported
/// no frames.
pub fn parse_frame(response: &Value) -> Option<Frame> {
    if !succeeded(response) {
        return None;
    }
    let frame = response
        .get("body")?
        .get("stackFrames")?
        .as_array()?
        .first()?;
    Some(Frame {
        id: frame.get("id").and_then(Value::as_i64),
        name: text_at(frame, "name").unwrap_or_else(|| "<unnamed>".to_string()),
        path: frame
            .get("source")
            .and_then(|source| source.get("path"))
            .and_then(Value::as_str)
            .map(sanitize)
            .filter(|path| !path.is_empty()),
        line: frame.get("line").and_then(Value::as_i64),
    })
}

/// The scopes of a `scopes` response worth showing.
pub fn parse_scopes(response: &Value) -> Vec<Scope> {
    if !succeeded(response) {
        return Vec::new();
    }
    let Some(scopes) = response
        .get("body")
        .and_then(|body| body.get("scopes"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };

    scopes
        .iter()
        .filter_map(|scope| {
            let name = text_at(scope, "name")
                .unwrap_or_else(|| "<unnamed>".to_string());
            let hint = scope.get("presentationHint").and_then(Value::as_str);
            if skip_scope(&name, hint) {
                return None;
            }
            Some(Scope {
                name,
                reference: scope
                    .get("variablesReference")
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
                vars: Vec::new(),
                truncated: false,
            })
        })
        .collect()
}

/// The variables of a `variables` response, capped at `max`. The flag says
/// whether anything was dropped by that cap.
pub fn parse_variables(response: &Value, max: usize) -> (Vec<Var>, bool) {
    if !succeeded(response) {
        return (Vec::new(), false);
    }
    let Some(variables) = response
        .get("body")
        .and_then(|body| body.get("variables"))
        .and_then(Value::as_array)
    else {
        return (Vec::new(), false);
    };

    let truncated = variables.len() > max;
    let kept = variables
        .iter()
        .take(max)
        .map(|variable| Var {
            name: text_at(variable, "name")
                .unwrap_or_else(|| "<unnamed>".to_string()),
            ty: text_at(variable, "type"),
            value: text_at(variable, "value").unwrap_or_default(),
            reference: variable
                .get("variablesReference")
                .and_then(Value::as_i64)
                .unwrap_or(0),
            children: Vec::new(),
            truncated: false,
        })
        .collect();
    (kept, truncated)
}

/// The startup file: the panel opens on the file existing, so it has to say
/// something before the first stop.
pub fn render_waiting() -> String {
    "# dap-vars stop 0\nwaiting for first stop\n".to_string()
}

/// The whole file. Line one is the change token the editor half polls; it
/// changes on every stop, which is cheaper and better defined than trusting
/// a filesystem timestamp.
pub fn render(
    counter: u64,
    frame: Option<&Frame>,
    scopes: &[Scope],
    timed_out: bool,
) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "# dap-vars stop {counter}");
    match frame {
        Some(frame) => match (&frame.path, frame.line) {
            (Some(path), Some(line)) => {
                let _ = writeln!(
                    out,
                    "frame 0: {} at {}:{}",
                    frame.name, path, line
                );
            }
            (Some(path), None) => {
                let _ = writeln!(out, "frame 0: {} at {}", frame.name, path);
            }
            _ => {
                let _ = writeln!(out, "frame 0: {}", frame.name);
            }
        },
        None => out.push_str("(no stack frame)\n"),
    }

    for scope in scopes {
        out.push('\n');
        out.push_str(&scope.name);
        out.push('\n');
        for variable in &scope.vars {
            render_var(&mut out, variable, 1);
        }
        if scope.truncated {
            out.push_str("  …\n");
        }
    }

    // An empty panel is otherwise indistinguishable from a broken one. A
    // frame compiled without debug info -- std, libtest's runner, anything
    // reached by stepping out of your own code -- reports its scopes with
    // nothing in them, and that is what is being shown.
    if frame.is_some()
        && !timed_out
        && scopes.iter().all(|scope| scope.vars.is_empty() && !scope.truncated)
    {
        out.push_str("\n(no variables in scope: a frame without debug info,");
        out.push_str(" such as std or libtest, reports none)\n");
    }

    if timed_out {
        out.push_str("\n(variables timed out)\n");
    }
    out
}

fn render_var(out: &mut String, variable: &Var, depth: usize) {
    let indent = "  ".repeat(depth);
    let value = if variable.value.is_empty() {
        "<no value>"
    } else {
        &variable.value
    };
    match &variable.ty {
        Some(ty) => {
            let _ =
                writeln!(out, "{indent}{}: {} = {}", variable.name, ty, value);
        }
        None => {
            let _ = writeln!(out, "{indent}{} = {}", variable.name, value);
        }
    }
    for child in &variable.children {
        render_var(out, child, depth + 1);
    }
    if variable.truncated {
        let _ = writeln!(out, "{}…", "  ".repeat(depth + 1));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn stack_trace() -> Value {
        json!({
            "type": "response",
            "success": true,
            "command": "stackTrace",
            "body": {
                "stackFrames": [
                    {
                        "id": 1000,
                        "name": "kitest::run",
                        "line": 42,
                        "source": {"name": "lib.rs", "path": "/home/u/p/src/lib.rs"}
                    },
                    {"id": 1001, "name": "main", "line": 7}
                ]
            }
        })
    }

    fn scopes_response() -> Value {
        json!({
            "type": "response",
            "success": true,
            "command": "scopes",
            "body": {
                "scopes": [
                    {"name": "Locals", "variablesReference": 2, "presentationHint": "locals"},
                    {"name": "Registers", "variablesReference": 3, "presentationHint": "registers"},
                    {"name": "CPU registers", "variablesReference": 4}
                ]
            }
        })
    }

    fn variables(entries: Value) -> Value {
        json!({
            "type": "response",
            "success": true,
            "command": "variables",
            "body": {"variables": entries}
        })
    }

    #[test]
    fn takes_frame_zero_only() {
        let frame = parse_frame(&stack_trace()).unwrap();
        assert_eq!(
            frame,
            Frame {
                id: Some(1000),
                name: "kitest::run".to_string(),
                path: Some("/home/u/p/src/lib.rs".to_string()),
                line: Some(42),
            }
        );
    }

    #[test]
    fn drops_every_register_scope() {
        let kept = parse_scopes(&scopes_response());
        let names: Vec<_> =
            kept.iter().map(|scope| scope.name.as_str()).collect();
        assert_eq!(names, vec!["Locals"]);
        assert_eq!(kept[0].reference, 2);
    }

    #[test]
    fn caps_children_and_flags_the_drop() {
        let response = variables(json!([
            {"name": "a", "value": "1"},
            {"name": "b", "value": "2"},
            {"name": "c", "value": "3"}
        ]));
        let (kept, truncated) = parse_variables(&response, 2);
        assert_eq!(kept.len(), 2);
        assert!(truncated);

        let (all, truncated) = parse_variables(&response, 3);
        assert_eq!(all.len(), 3);
        assert!(!truncated);
    }

    #[test]
    fn collapses_line_breaks_and_cuts_long_text() {
        assert_eq!(sanitize("a\r\nb\n\nc"), "a b c");

        let long = sanitize(&"x".repeat(MAX_TEXT + 50));
        assert_eq!(long.chars().count(), MAX_TEXT);
        assert!(long.ends_with('…'));
    }

    #[test]
    fn renders_the_documented_file() {
        let frame = parse_frame(&stack_trace()).unwrap();
        let mut scopes = parse_scopes(&scopes_response());

        let (mut vars, truncated) = parse_variables(
            &variables(json!([
                {"name": "count", "type": "usize", "value": "3"},
                {
                    "name": "cfg",
                    "type": "Config",
                    "value": "Config { name: \"a\", retries: 2 }",
                    "variablesReference": 5
                }
            ])),
            32,
        );
        assert!(!truncated);

        let (children, child_truncated) = parse_variables(
            &variables(json!([
                {"name": "name", "type": "String", "value": "\"a\""},
                {"name": "retries", "type": "u32", "value": "2"},
                {"name": "spare", "type": "u32", "value": "0"}
            ])),
            2,
        );
        vars[1].children = children;
        vars[1].truncated = child_truncated;
        scopes[0].vars = vars;

        assert_eq!(
            render(3, Some(&frame), &scopes, false),
            "# dap-vars stop 3\n\
             frame 0: kitest::run at /home/u/p/src/lib.rs:42\n\
             \n\
             Locals\n\
             \x20 count: usize = 3\n\
             \x20 cfg: Config = Config { name: \"a\", retries: 2 }\n\
             \x20   name: String = \"a\"\n\
             \x20   retries: u32 = 2\n\
             \x20   …\n"
        );
    }

    #[test]
    fn renders_a_capped_scope_a_missing_type_and_a_timeout() {
        let scopes = vec![Scope {
            name: "Locals".to_string(),
            reference: 2,
            vars: vec![Var {
                name: "opaque".to_string(),
                ty: None,
                value: String::new(),
                reference: 0,
                children: Vec::new(),
                truncated: false,
            }],
            truncated: true,
        }];

        assert_eq!(
            render(1, None, &scopes, true),
            "# dap-vars stop 1\n\
             (no stack frame)\n\
             \n\
             Locals\n\
             \x20 opaque = <no value>\n\
             \x20 …\n\
             \n\
             (variables timed out)\n"
        );
    }

    /// Stepping out of your own code lands in libtest or std, whose frames
    /// carry no debug info: the adapter answers with scopes that hold
    /// nothing. Bare empty scopes read as a broken panel, so the reason is
    /// spelled out.
    #[test]
    fn explains_a_frame_that_has_no_variables() {
        let frame = Frame {
            id: Some(4),
            name: "<test::types::RunnableTest>::run".to_string(),
            path: None,
            line: None,
        };
        let scopes = vec![
            Scope { name: "Locals".to_string(), reference: 2, vars: Vec::new(), truncated: false },
            Scope { name: "Globals".to_string(), reference: 3, vars: Vec::new(), truncated: false },
        ];

        let empty = render(12, Some(&frame), &scopes, false);
        assert!(
            empty.ends_with(
                "\n(no variables in scope: a frame without debug info, \
                 such as std or libtest, reports none)\n"
            ),
            "{empty}"
        );

        // A frame that does report variables says nothing of the sort.
        let mut populated = scopes.clone();
        populated[0].vars = vec![Var {
            name: "n".to_string(),
            ty: Some("usize".to_string()),
            value: "11".to_string(),
            reference: 0,
            children: Vec::new(),
            truncated: false,
        }];
        assert!(!render(12, Some(&frame), &populated, false).contains("no variables in scope"));
    }
}
