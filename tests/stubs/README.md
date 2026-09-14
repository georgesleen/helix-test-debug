# Stub helix modules

Helix registers `helix/commands.scm`, `helix/editor.scm` and friends as virtual
modules inside its own Steel engine, so they do not exist on disk and the editor
half of the cog cannot be loaded by a bare `steel`.

These stubs stand in for them during `make compile-check`, which loads
`test-debug.scm` and therefore forces every identifier it uses to resolve. That
catches the failure this check was added for: a name that exists in Helix but in
a module the cog never required, which Helix reports as `FreeIdentifier` when it
loads the cog, long after any test has run.

Each stub provides exactly the names the cog uses from that module, and each
name is checked against the real module's `provide` list in
`helix-term/src/commands/engine/steel/`. A name present here but absent there
would pass the check and still fail in Helix, so the stubs are a guard against
forgetting a `require`, not a substitute for reading the real API.
