// Fixture crate for tests/integration.sh. Its tests are selected by the cog
// under a real helix, so their names and nesting are part of that check.

pub mod inner {
    pub fn doubled(value: i32) -> i32 {
        value * 2
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        // Appends the test's own path to $FIXTURE_TEST_LOG, so the check can
        // tell which tests ran rather than reading the editor's screen. One
        // write_all per line, because tests that run at once interleave.
        fn record(name: &str) {
            use std::io::Write;
            let path = match std::env::var("FIXTURE_TEST_LOG") {
                Ok(path) => path,
                Err(_) => return,
            };
            let mut log = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .expect("open FIXTURE_TEST_LOG");
            log.write_all(format!("{name}\n").as_bytes())
                .expect("write FIXTURE_TEST_LOG");
        }

        #[test]
        fn doubles() {
            record("inner::tests::doubles");
            assert_eq!(doubled(2), 4);
        }

        // Name extends doubles, so a filter that is not --exact drags it along.
        #[test]
        fn doubles_negative_values() {
            record("inner::tests::doubles_negative_values");
            assert_eq!(doubled(-3), -6);
        }

        #[test]
        fn panics_with_a_clear_assertion() {
            record("inner::tests::panics_with_a_clear_assertion");
            eprintln!("\x1b[38;2;1;2;3mCOLOUR_SENTINEL\x1b[0m");
            assert_eq!(doubled(2), 5, "doubled(2) is 4, not 5");
        }

        #[test]
        #[ignore]
        fn ignored_by_default() {
            record("inner::tests::ignored_by_default");
            assert_eq!(doubled(0), 0);
        }
    }
}
