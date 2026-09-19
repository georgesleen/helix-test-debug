//! helix-dap-vars: a transparent Debug Adapter Protocol proxy that writes
//! the stopped frame's variables to a plain text file.
//!
//! SPDX-License-Identifier: LGPL-3.0-or-later
//!
//! Put it in front of any DAP adapter. Every byte the editor sends reaches
//! the adapter unchanged and every byte the adapter sends reaches the
//! editor unchanged; the proxy only adds requests of its own, in a sequence
//! number space the editor cannot reach, and swallows their responses. On
//! each `stopped` event it collects frame 0's scopes and variables and
//! rewrites one file atomically. An editor that can open a file can then
//! show a live variables panel with no support from the adapter and no
//! patch to the editor.
//!
//! The file existing is the signal that a session is live; it is deleted
//! when the session ends, which is how the panel knows to close.

mod frame;
mod model;

use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::PathBuf;
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use frame::{is_injected_response, read_frame, write_frame, INJECTED_BASE};
use model::{Frame, Scope};

/// The four POSIX calls std does not expose. Keeping their tiny ABI here
/// avoids a runtime dependency for an otherwise serde_json-only binary.
mod sys {
    use std::ffi::{c_char, c_int, c_uint};

    pub const SIGHUP: c_int = 1;
    pub const SIGINT: c_int = 2;
    pub const SIGTERM: c_int = 15;

    extern "C" {
        pub fn getuid() -> c_uint;
        pub fn signal(signal: c_int, handler: usize) -> usize;
        pub fn unlink(path: *const c_char) -> c_int;
        pub fn rmdir(path: *const c_char) -> c_int;
        pub fn _exit(status: c_int) -> !;
    }
}

/// A stop costs at most this many injected requests, however deep the
/// frame's state is. Without it a scope of a thousand expandable variables
/// would put a thousand round trips between the editor and every step.
const MAX_REQUESTS_PER_STOP: usize = 64;

const USAGE: &str = "\
usage: helix-dap-vars [--out <path>] [--max-children <n>] [--timeout-ms <n>] -- <adapter> [args...]

Proxies a DAP adapter over stdio and writes the stopped frame's variables to
a text file. Defaults: --max-children 32, --timeout-ms 2000, and an output
path of ${TMPDIR:-/tmp}/helix-dap-vars-<uid>/<pid>.log.
";

fn main() {
    let options = match Options::parse(std::env::args().skip(1)) {
        Ok(Some(options)) => options,
        Ok(None) => {
            print!("{USAGE}");
            std::process::exit(0);
        }
        Err(message) => {
            eprintln!("helix-dap-vars: {message}");
            eprint!("{USAGE}");
            std::process::exit(2);
        }
    };

    match run(options) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("helix-dap-vars: {error}");
            std::process::exit(1);
        }
    }
}

// ---------------------------------------------------------------- options

struct Options {
    out: Option<PathBuf>,
    max_children: usize,
    timeout: Duration,
    adapter: String,
    args: Vec<String>,
}

impl Options {
    /// `Ok(None)` means the caller asked for the usage text.
    fn parse<I: Iterator<Item = String>>(
        argv: I,
    ) -> Result<Option<Options>, String> {
        let mut out = None;
        let mut max_children = 32usize;
        let mut timeout_ms = 2000u64;
        let mut argv = argv.peekable();

        while let Some(argument) = argv.next() {
            match argument.as_str() {
                "--" => {
                    let Some(adapter) = argv.next() else {
                        return Err("no adapter command after --".to_string());
                    };
                    return Ok(Some(Options {
                        out,
                        max_children,
                        timeout: Duration::from_millis(timeout_ms),
                        adapter,
                        args: argv.collect(),
                    }));
                }
                "--help" | "-h" => return Ok(None),
                "--out" => {
                    out = Some(PathBuf::from(
                        argv.next().ok_or("--out needs a path".to_string())?,
                    ));
                }
                "--max-children" => {
                    max_children =
                        number(argv.next(), "--max-children")? as usize;
                }
                "--timeout-ms" => {
                    timeout_ms = number(argv.next(), "--timeout-ms")?;
                }
                other => return Err(format!("unknown option {other}")),
            }
        }
        Err("missing -- before the adapter command".to_string())
    }
}

fn number(argument: Option<String>, name: &str) -> Result<u64, String> {
    argument
        .ok_or_else(|| format!("{name} needs a number"))?
        .parse()
        .map_err(|_| format!("{name} needs a number"))
}

// ----------------------------------------------------------------- output

/// The file the editor reads, and the directory holding it.
struct Out {
    path: PathBuf,
    /// Written then renamed over `path`, so a reader never sees half a file.
    tmp: PathBuf,
    /// `Some` only when this process created it, so an explicit `--out`
    /// inside a directory of the user's never has that directory removed.
    dir: Option<PathBuf>,
}

impl Out {
    fn open(out: Option<PathBuf>) -> io::Result<Out> {
        let (path, dir) = match out {
            Some(path) => {
                if let Some(parent) = path
                    .parent()
                    .filter(|parent| !parent.as_os_str().is_empty())
                {
                    fs::DirBuilder::new()
                        .recursive(true)
                        .mode(0o700)
                        .create(parent)?;
                }
                (path, None)
            }
            None => {
                // XDG_RUNTIME_DIR first: it is tmpfs on a systemd machine,
                // already per-user and 0700, and cleared at logout. A panel
                // rewritten on every stop is scratch data, and the values in
                // it are whatever the debuggee holds in memory, so keeping it
                // out of persistent storage is both faster and tighter. On a
                // machine without one, TMPDIR is the fallback it always was.
                let root = std::env::var_os("XDG_RUNTIME_DIR")
                    .filter(|value| !value.is_empty())
                    .or_else(|| std::env::var_os("TMPDIR").filter(|v| !v.is_empty()))
                    .map(PathBuf::from)
                    .unwrap_or_else(|| PathBuf::from("/tmp"));
                // SAFETY: getuid cannot fail and touches no memory.
                let uid = unsafe { sys::getuid() };
                let dir = root.join(format!("helix-dap-vars-{uid}"));
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(&dir)?;
                // `.log` rather than `.txt`: helix picks the panel's
                // language from the file type, so the rendered frame gets
                // log highlighting without the editor half asking for it.
                let path = dir.join(format!("{}.log", std::process::id()));
                (path, Some(dir))
            }
        };

        let mut tmp = path.clone().into_os_string();
        tmp.push(".tmp");
        Ok(Out {
            path,
            tmp: PathBuf::from(tmp),
            dir,
        })
    }

    /// The rename is what the reader sees, and it is atomic on its own.
    /// There is deliberately no fsync: it would cost a disk flush per stop
    /// (~3 ms on btrfs, measured) to protect a file that the next stop
    /// overwrites and that is meaningless after a crash.
    fn write(&self, text: &str) -> io::Result<()> {
        let mut file = File::create(&self.tmp)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        file.write_all(text.as_bytes())?;
        drop(file);
        fs::rename(&self.tmp, &self.path)
    }

    /// Deleting the file is the panel's close signal, so every exit path
    /// runs this, signals included.
    fn remove(&self) {
        let _ = fs::remove_file(&self.tmp);
        let _ = fs::remove_file(&self.path);
        if let Some(dir) = &self.dir {
            let _ = fs::remove_dir(dir); // only when nothing else is in it
        }
    }
}

/// Paths for the signal handler, which cannot allocate or lock.
static SIGNAL_PATHS: OnceLock<(CString, Option<CString>)> = OnceLock::new();

extern "C" fn on_signal(signal: i32) {
    if let Some((file, dir)) = SIGNAL_PATHS.get() {
        // unlink, rmdir and _exit are async-signal-safe; nothing else here
        // may be called from a handler.
        unsafe {
            sys::unlink(file.as_ptr());
            if let Some(dir) = dir {
                sys::rmdir(dir.as_ptr());
            }
            sys::_exit(128 + signal);
        }
    }
    unsafe { sys::_exit(128 + signal) }
}

/// Helix kills an adapter on drop, and a killed proxy that leaves its file
/// behind leaves a panel open over a dead session. SIGKILL cannot be caught,
/// which is why the editor half also checks that the owning pid is alive.
fn install_signal_handlers(out: &Out) {
    let file =
        CString::new(out.path.as_os_str().as_encoded_bytes().to_vec()).ok();
    let dir = out.dir.as_ref().and_then(|dir| {
        CString::new(dir.as_os_str().as_encoded_bytes().to_vec()).ok()
    });
    let Some(file) = file else { return };
    let _ = SIGNAL_PATHS.set((file, dir));

    for signal in [sys::SIGTERM, sys::SIGINT, sys::SIGHUP] {
        // SAFETY: the handler only calls async-signal-safe functions.
        unsafe { sys::signal(signal, on_signal as *const () as usize) };
    }
}

// -------------------------------------------------------------- the proxy

/// What the stdout pump tells the collector about.
enum Msg {
    /// The adapter stopped, on this thread.
    Stopped(Option<i64>),
    /// A response to one of our own requests.
    Response(Value),
    /// `terminated` or `exited`: the debuggee is gone, close the panel.
    SessionEnded,
    /// The adapter's stdout closed.
    Eof,
}

fn run(options: Options) -> io::Result<i32> {
    // The file has to exist before the adapter does: its existence is what
    // tells the editor a session is live, and an adapter can stop on the
    // first instruction.
    let out = Arc::new(Out::open(options.out.clone())?);
    out.write(&model::render_waiting())?;
    install_signal_handlers(&out);

    let mut child = match Command::new(&options.adapter)
        .args(&options.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            out.remove();
            return Err(io::Error::new(
                error.kind(),
                format!("cannot run {}: {error}", options.adapter),
            ));
        }
    };

    let adapter_stdin =
        Arc::new(Mutex::new(Some(child.stdin.take().expect("piped"))));
    let adapter_stdout = child.stdout.take().expect("piped");
    let adapter_stderr = child.stderr.take().expect("piped");

    // Bounded, so a collector busy with one stop cannot let an adapter that
    // spews events grow this without limit.
    let (tx, rx) = mpsc::sync_channel::<Msg>(256);

    let stderr_pump = thread::spawn(move || {
        let mut source = adapter_stderr;
        let mut sink = io::stderr();
        let _ = io::copy(&mut source, &mut sink);
    });

    let client_pump = {
        let adapter_stdin = Arc::clone(&adapter_stdin);
        thread::spawn(move || pump_client(adapter_stdin))
    };

    let stdout_pump = {
        let tx = tx.clone();
        thread::spawn(move || pump_adapter(adapter_stdout, tx))
    };

    let collector = {
        let out = Arc::clone(&out);
        let adapter_stdin = Arc::clone(&adapter_stdin);
        let max_children = options.max_children;
        let timeout = options.timeout;
        thread::spawn(move || {
            Collector {
                rx,
                out,
                adapter_stdin,
                max_children,
                timeout,
                seq: 0,
                counter: 0,
            }
            .run()
        })
    };

    let status = child.wait()?;
    // The adapter is gone: its stdout is at EOF, which ends the stdout pump,
    // which ends the collector. The client pump may still be blocked on the
    // editor's stdin, so it is not joined.
    let _ = stdout_pump.join();
    let _ = collector.join();
    let _ = stderr_pump.join();
    drop(client_pump);
    out.remove();
    Ok(status.code().unwrap_or(0))
}

/// Editor to adapter. Frames are forwarded verbatim; the proxy parses
/// nothing the editor sends.
fn pump_client(adapter_stdin: Arc<Mutex<Option<ChildStdin>>>) {
    let stdin = io::stdin();
    let mut reader = BufReader::new(stdin.lock());
    while let Ok(Some(body)) = read_frame(&mut reader) {
        let mut guard = adapter_stdin.lock().expect("stdin mutex");
        let Some(writer) = guard.as_mut() else { return };
        if write_frame(writer, &body).is_err() {
            return;
        }
    }
    // The editor is gone: closing the adapter's stdin is how an adapter is
    // told to shut down.
    *adapter_stdin.lock().expect("stdin mutex") = None;
}

/// Adapter to editor, plus the taps the collector runs on.
fn pump_adapter(
    adapter_stdout: std::process::ChildStdout,
    tx: SyncSender<Msg>,
) {
    let mut reader = BufReader::new(adapter_stdout);
    let stdout = io::stdout();
    let mut writer = stdout.lock();

    while let Ok(Some(body)) = read_frame(&mut reader) {
        let message: Option<Value> = serde_json::from_slice(&body).ok();
        let injected = message.as_ref().is_some_and(is_injected_response);

        // Forward first, always: collection must never delay the editor.
        if !injected && write_frame(&mut writer, &body).is_err() {
            break;
        }

        let Some(message) = message else { continue };
        if injected {
            let _ = tx.send(Msg::Response(message));
            continue;
        }
        if message.get("type").and_then(Value::as_str) != Some("event") {
            continue;
        }
        match message.get("event").and_then(Value::as_str) {
            Some("stopped") => {
                let thread_id = message
                    .get("body")
                    .and_then(|body| body.get("threadId"))
                    .and_then(Value::as_i64);
                let _ = tx.send(Msg::Stopped(thread_id));
            }
            Some("terminated") | Some("exited") => {
                let _ = tx.send(Msg::SessionEnded);
            }
            _ => {}
        }
    }
    let _ = tx.send(Msg::Eof);
}

// ------------------------------------------------------------- collection

/// Why a collection stopped early.
enum Interrupt {
    /// The adapter did not answer in time.
    Timeout,
    /// A newer stop arrived: the one in flight is stale, latest stop wins.
    Restart(Option<i64>),
    /// The session ended, or the adapter's stdout closed.
    Ended,
}

enum Outcome {
    Finished,
    Restart(Option<i64>),
    Ended,
}

struct Collector {
    rx: Receiver<Msg>,
    out: Arc<Out>,
    adapter_stdin: Arc<Mutex<Option<ChildStdin>>>,
    max_children: usize,
    timeout: Duration,
    seq: i64,
    counter: u64,
}

impl Collector {
    fn run(mut self) {
        let mut pending: Option<Option<i64>> = None;
        loop {
            let message = match pending.take() {
                Some(thread_id) => Msg::Stopped(thread_id),
                None => match self.rx.recv() {
                    Ok(message) => message,
                    Err(_) => return,
                },
            };

            match message {
                Msg::Stopped(thread_id) => match self.collect(thread_id) {
                    Outcome::Finished => {}
                    Outcome::Restart(next) => pending = Some(next),
                    Outcome::Ended => self.out.remove(),
                },
                // A `continued` is deliberately not handled: leaving the
                // last stop's text in place until the next one avoids a
                // blank panel between the two events every step emits.
                Msg::SessionEnded => self.out.remove(),
                Msg::Eof => return,
                Msg::Response(_) => {} // a straggler from an abandoned stop
            }
        }
    }

    fn collect(&mut self, thread_id: Option<i64>) -> Outcome {
        self.counter += 1;
        let counter = self.counter;
        let mut budget = MAX_REQUESTS_PER_STOP;
        let mut frame: Option<Frame> = None;
        let mut scopes: Vec<Scope> = Vec::new();
        let mut timed_out = false;

        // Each arm either has its value, gives up and writes what it has,
        // or hands control back to the run loop.
        macro_rules! ask {
            ($label:lifetime, $command:expr, $arguments:expr) => {
                match self.request(&mut budget, $command, $arguments) {
                    Ok(Some(response)) => response,
                    Ok(None) => {
                        // Out of budget: render what exists.
                        break $label;
                    }
                    Err(Interrupt::Timeout) => {
                        timed_out = true;
                        break $label;
                    }
                    Err(Interrupt::Restart(next)) => {
                        return Outcome::Restart(next)
                    }
                    Err(Interrupt::Ended) => return Outcome::Ended,
                }
            };
        }

        // `loop`/`break` gives every nested request one place to abandon the
        // rest of a stop. An adapter timeout never falls through to another
        // scope.
        #[allow(clippy::never_loop)]
        'collect: loop {
            let thread_id = thread_id.unwrap_or(1);
            let stack = ask!(
                'collect,
                "stackTrace",
                json!({"threadId": thread_id, "startFrame": 0, "levels": 1})
            );
            frame = model::parse_frame(&stack);

            let Some(frame_id) = frame.as_ref().and_then(|frame| frame.id)
            else {
                break;
            };
            let scopes_response =
                ask!('collect, "scopes", json!({"frameId": frame_id}));
            scopes = model::parse_scopes(&scopes_response);

            for scope in &mut scopes {
                let reference = scope.reference;
                if reference == 0 {
                    continue;
                }
                if budget == 0 {
                    scope.truncated = true;
                    break 'collect;
                }
                let response = ask!(
                    'collect,
                    "variables",
                    json!({"variablesReference": reference})
                );
                let (vars, truncated) =
                    model::parse_variables(&response, self.max_children);
                scope.vars = vars;
                scope.truncated = truncated;

                for variable in &mut scope.vars {
                    let reference = variable.reference;
                    if reference == 0 {
                        continue;
                    }
                    if budget == 0 {
                        // The variable is expandable and was not expanded:
                        // say so rather than implying it is a leaf.
                        variable.truncated = true;
                        break 'collect;
                    }
                    let response = ask!(
                        'collect,
                        "variables",
                        json!({"variablesReference": reference})
                    );
                    let (mut children, truncated) =
                        model::parse_variables(&response, self.max_children);
                    // One expansion is the depth limit. Mark retained
                    // children that could expand again so the rendering
                    // does not falsely imply they are leaves.
                    for child in &mut children {
                        child.truncated = child.reference != 0;
                    }
                    variable.children = children;
                    variable.truncated = truncated;
                }
            }
            break;
        }

        let text = model::render(counter, frame.as_ref(), &scopes, timed_out);
        if let Err(error) = self.out.write(&text) {
            eprintln!(
                "helix-dap-vars: cannot write {}: {error}",
                self.out.path.display()
            );
        }
        Outcome::Finished
    }

    /// One injected request. `Ok(None)` when the per-stop budget is spent.
    fn request(
        &mut self,
        budget: &mut usize,
        command: &str,
        arguments: Value,
    ) -> Result<Option<Value>, Interrupt> {
        if *budget == 0 {
            return Ok(None);
        }
        *budget -= 1;

        self.seq += 1;
        let seq = INJECTED_BASE + self.seq;
        let body = serde_json::to_vec(&json!({
            "seq": seq,
            "type": "request",
            "command": command,
            "arguments": arguments,
        }))
        .expect("a request serialises");

        {
            let mut guard = self.adapter_stdin.lock().expect("stdin mutex");
            let Some(writer) = guard.as_mut() else {
                return Err(Interrupt::Ended);
            };
            if write_frame(writer, &body).is_err() {
                return Err(Interrupt::Ended);
            }
        }

        let deadline = Instant::now() + self.timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(Interrupt::Timeout);
            }
            match self.rx.recv_timeout(left) {
                Ok(Msg::Response(response)) => {
                    if response.get("request_seq").and_then(Value::as_i64)
                        == Some(seq)
                    {
                        return Ok(Some(response));
                    }
                }
                Ok(Msg::Stopped(next)) => return Err(Interrupt::Restart(next)),
                Ok(Msg::SessionEnded) | Ok(Msg::Eof) => {
                    return Err(Interrupt::Ended)
                }
                Err(RecvTimeoutError::Timeout) => {
                    return Err(Interrupt::Timeout)
                }
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(Interrupt::Ended)
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(arguments: &[&str]) -> Result<Option<Options>, String> {
        Options::parse(arguments.iter().map(|argument| argument.to_string()))
    }

    #[test]
    fn splits_proxy_options_from_the_adapter_command() {
        let options = argv(&[
            "--out",
            "/tmp/vars.txt",
            "--max-children",
            "4",
            "--timeout-ms",
            "50",
            "--",
            "probe-rs",
            "dap-server",
        ])
        .unwrap()
        .unwrap();

        assert_eq!(options.out, Some(PathBuf::from("/tmp/vars.txt")));
        assert_eq!(options.max_children, 4);
        assert_eq!(options.timeout, Duration::from_millis(50));
        assert_eq!(options.adapter, "probe-rs");
        assert_eq!(options.args, vec!["dap-server".to_string()]);
    }

    #[test]
    fn an_adapter_option_is_not_read_as_ours() {
        let options = argv(&["--", "lldb-dap", "--out", "x"]).unwrap().unwrap();
        assert_eq!(options.out, None);
        assert_eq!(options.args, vec!["--out".to_string(), "x".to_string()]);
    }

    #[test]
    fn rejects_a_command_line_with_no_adapter() {
        assert!(argv(&["--max-children", "8"]).is_err());
        assert!(argv(&["--"]).is_err());
        assert!(argv(&["--max-children", "many", "--", "lldb-dap"]).is_err());
        assert!(argv(&["--jump", "--", "lldb-dap"]).is_err());
    }

    #[test]
    fn asking_for_usage_is_not_an_error() {
        assert!(argv(&["--help"]).unwrap().is_none());
    }
}
