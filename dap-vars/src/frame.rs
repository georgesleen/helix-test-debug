//! `Content-Length` framing, the transport both halves of a DAP session
//! speak over stdio.
//!
//! SPDX-License-Identifier: LGPL-3.0-or-later

use std::io::{self, BufRead, Write};

use serde_json::Value;

/// Sequence numbers for requests this proxy injects are allocated from here
/// upward. Helix's own counter starts at 1 and increments once per request,
/// so it cannot reach this in any session a human is part of; that gap is
/// what lets the stdout pump recognise a response to one of our requests and
/// swallow it instead of confusing the editor with a reply it never asked
/// for.
pub const INJECTED_BASE: i64 = 1 << 30;

/// Whether a message is a response to a request this proxy injected.
pub fn is_injected_response(message: &Value) -> bool {
    message.get("type").and_then(Value::as_str) == Some("response")
        && message
            .get("request_seq")
            .and_then(Value::as_i64)
            .is_some_and(|seq| seq >= INJECTED_BASE)
}

/// Read one framed message body. `None` on EOF, on a truncated frame, or on
/// a header block carrying no usable `Content-Length`.
///
/// Headers are matched case-insensitively and every header other than
/// `content-length` is ignored, because an adapter may send `Content-Type`.
/// A blank line before any header is skipped rather than treated as the end
/// of the header block, which tolerates a writer that terminates a frame
/// with an extra newline.
pub fn read_frame<R: BufRead>(input: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut length: Option<usize> = None;
    loop {
        let mut line = Vec::new();
        if input.read_until(b'\n', &mut line)? == 0 {
            return Ok(None);
        }
        let line = trim(&line);
        if line.is_empty() {
            if length.is_none() {
                continue; // stray blank line between frames
            }
            break;
        }
        if let Some(colon) = line.iter().position(|byte| *byte == b':') {
            let (name, value) = (&line[..colon], trim(&line[colon + 1..]));
            if name.eq_ignore_ascii_case(b"content-length") {
                length = std::str::from_utf8(value)
                    .ok()
                    .and_then(|n| n.parse().ok());
            }
        }
    }

    let Some(length) = length else {
        return Ok(None);
    };
    let mut body = vec![0u8; length];
    match input.read_exact(&mut body) {
        Ok(()) => Ok(Some(body)),
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => Ok(None),
        Err(error) => Err(error),
    }
}

/// Write one framed message body and flush, since the peer is blocked on it.
pub fn write_frame<W: Write>(output: &mut W, body: &[u8]) -> io::Result<()> {
    write!(output, "Content-Length: {}\r\n\r\n", body.len())?;
    output.write_all(body)?;
    output.flush()
}

fn trim(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|byte| !byte.is_ascii_whitespace())
        .map_or(start, |index| index + 1);
    &bytes[start..end]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Cursor;

    #[test]
    fn round_trips_a_frame() {
        let mut wire = Vec::new();
        write_frame(&mut wire, br#"{"seq":1}"#).unwrap();
        assert_eq!(wire, b"Content-Length: 9\r\n\r\n{\"seq\":1}".to_vec());

        let mut reader = Cursor::new(wire);
        assert_eq!(read_frame(&mut reader).unwrap().unwrap(), br#"{"seq":1}"#);
        assert_eq!(read_frame(&mut reader).unwrap(), None);
    }

    #[test]
    fn tolerates_extra_headers_and_a_stray_blank_line() {
        let wire = b"\r\ncontent-type: application/vnd.dap\r\nCONTENT-LENGTH: 2\r\n\r\n{}\
                     \r\nContent-Length: 4\r\n\r\n[42]"
            .to_vec();
        let mut reader = Cursor::new(wire);
        assert_eq!(read_frame(&mut reader).unwrap().unwrap(), b"{}".to_vec());
        assert_eq!(read_frame(&mut reader).unwrap().unwrap(), b"[42]".to_vec());
        assert_eq!(read_frame(&mut reader).unwrap(), None);
    }

    #[test]
    fn a_truncated_body_reads_as_end_of_stream() {
        let mut reader =
            Cursor::new(b"Content-Length: 16\r\n\r\n{\"seq\"".to_vec());
        assert_eq!(read_frame(&mut reader).unwrap(), None);
    }

    #[test]
    fn only_our_own_sequence_space_is_swallowed() {
        let theirs =
            json!({"type": "response", "request_seq": 7, "command": "scopes"});
        let ours = json!({"type": "response", "request_seq": INJECTED_BASE, "command": "scopes"});
        let event = json!({"type": "event", "event": "stopped"});

        assert!(!is_injected_response(&theirs));
        assert!(is_injected_response(&ours));
        assert!(!is_injected_response(&event));
    }
}
