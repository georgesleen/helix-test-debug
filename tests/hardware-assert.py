#!/usr/bin/env python3
"""Assert what a real adapter and a real target did, from the DAP exchange.

Used by tests/hardware-check.sh. Nothing here knows the fixture: the image
that should have been flashed is derived from CMake's file API the same way
the cog derives it, but implemented independently, so the two agreeing is
evidence rather than a tautology.
"""

import glob
import json
import os
import sys


def messages(path):
    """The DAP messages in a tee'd stream, which is Content-Length framed."""
    data = open(path, "rb").read()
    out, index = [], 0
    while True:
        head = data.find(b"\r\n\r\n", index)
        if head < 0:
            return out
        length = None
        for field in data[index:head].decode("ascii", "replace").split("\r\n"):
            if field.lower().startswith("content-length:"):
                length = int(field.split(":", 1)[1])
        if length is None:
            return out
        start = head + 4
        try:
            out.append(json.loads(data[start:start + length]))
        except ValueError:
            pass
        index = start + length


def fail(message):
    print("hardware-check: " + message, file=sys.stderr)
    sys.exit(1)


def read_json(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def executables(build, source):
    """Every non-imported executable that reaches `source`.

    Derived from CMake's file API the same way the cog derives it, but
    implemented separately, so the two agreeing is evidence.

    A real SDK build has several executables -- the Pico SDK's codemodel
    also names picotool, pioasm and a boot stage -- so the one to flash is
    the one that compiles the file being debugged. And a build system may
    compile that file into a library instead: ESP-IDF puts main.c in its
    __idf_main component and builds the ELF from a generated empty source,
    so the link graph is what connects them.
    """
    reply = os.path.join(build, ".cmake", "api", "v1", "reply")
    indexes = sorted(glob.glob(os.path.join(reply, "index-*.json")))
    if not indexes:
        fail("no file API reply in %s; the cog never queried it" % build)
    index = read_json(indexes[-1]) or {}
    named = [o for o in index.get("objects", []) if o.get("kind") == "codemodel"]
    if not named:
        fail("the file API index names no codemodel")
    codemodel = read_json(os.path.join(reply, named[0]["jsonFile"])) or {}

    found = []
    for configuration in codemodel.get("configurations", []):
        targets = {}
        for entry in configuration.get("targets", []):
            target = read_json(os.path.join(reply, entry.get("jsonFile", ""))) or {}
            if target.get("id"):
                targets[target["id"]] = target

        def reaches(target):
            seen, pending = set(), [target]
            while pending:
                current = pending.pop()
                identifier = current.get("id")
                if identifier in seen:
                    continue
                seen.add(identifier)
                if any(s.get("path") == source for s in current.get("sources", [])):
                    return True
                for dependency in current.get("dependencies", []):
                    linked = targets.get(dependency.get("id"))
                    if linked:
                        pending.append(linked)
            return False

        for target in targets.values():
            if target.get("type") != "EXECUTABLE" or target.get("imported"):
                continue
            artifacts = target.get("artifacts", [])
            if artifacts and reaches(target):
                found.append((target.get("name"), artifacts[0].get("path")))
        # Configurations are alternatives, not additions: a multi-config
        # generator describes the same target in each, so the first that
        # answers is the answer.
        if found:
            return found
    return found


def main():
    requests_path, responses_path, build, source_file, line = sys.argv[1:6]
    line = int(line)
    source = os.path.relpath(source_file, os.path.dirname(build.rstrip("/")))

    requests, responses = messages(requests_path), messages(responses_path)
    if not responses:
        fail("the adapter said nothing; it may not have started")

    owners = executables(build, source)
    if len(owners) != 1:
        fail("%d executables reach %s, so this check cannot say which is right"
             % (len(owners), source))
    expected = os.path.join(build, owners[0][1])

    # An attach carries the same image and core configuration as a launch;
    # only whether the adapter flashes it differs, which is the template's
    # business and not this check's.
    starts = [m for m in requests if m.get("command") in ("launch", "attach")]
    if not starts:
        fail("helix sent neither a launch nor an attach")
    cores = starts[-1].get("arguments", {}).get("coreConfigs", [])
    if not cores:
        fail("the %s named no core: %r"
             % (starts[-1].get("command"), starts[-1].get("arguments")))
    named = cores[0].get("programBinary")
    if named != expected:
        fail("the %s named %s, but the file API says %s reaches %s"
             % (starts[-1].get("command"), named, expected, source))

    verified = [
        breakpoint
        for m in responses
        if m.get("command") == "setBreakpoints" and m.get("success")
        for breakpoint in m.get("body", {}).get("breakpoints", [])
    ]
    if not verified:
        fail("the adapter verified no breakpoint; helix sent none, or it did not bind")
    bound = [b for b in verified if b.get("line") == line and b.get("verified")]
    if not bound:
        fail("no verified breakpoint on line %d: %r" % (line, verified))
    address = bound[-1].get("instructionReference")

    stops = [m.get("body", {}) for m in responses if m.get("event") == "stopped"]
    # The first stop is the reset halt the template asks for, so only a
    # later breakpoint stop shows the breakpoint actually fired.
    hits = [s for s in stops if s.get("reason") == "breakpoint"]
    if not hits:
        fail("the core never stopped on the breakpoint: %r" % stops)
    if address and address.lower() not in hits[-1].get("description", "").lower():
        fail("stopped somewhere other than %s: %r" % (address, hits[-1]))

    frames = [
        frame
        for m in responses
        if m.get("command") == "stackTrace" and m.get("success")
        for frame in m.get("body", {}).get("stackFrames", [])
    ]
    # The frame has to be in the file under the cursor: that is what proves
    # the core stopped in the user's own code. Its line is reported rather
    # than asserted, because the line table is the compiler's business -- an
    # ESP-IDF build is -Og by default, and the increment inside a loop maps
    # to the loop head. The address equality above is the exact check.
    here = [
        frame
        for frame in frames
        if frame.get("source", {}).get("path") == source_file
    ]
    if not here:
        fail("no frame reported %s; the core stopped outside the file under the cursor: %r"
             % (source_file, [(f.get("name"), (f.get("source") or {}).get("path")) for f in frames]))
    reported = here[-1].get("line")

    variables = [
        variable
        for m in responses
        if m.get("command") == "variables" and m.get("success")
        for variable in m.get("body", {}).get("variables", [])
    ]
    readable = [v for v in variables if v.get("value") not in (None, "")]
    if not readable:
        fail("no variable was readable from the target")

    print("hardware-check: %s %s, bound %s:%d at %s, stopped in %s at line %s, read %s"
          % (starts[-1].get("command"),
             os.path.basename(named),
             os.path.basename(source_file),
             line,
             address,
             here[-1].get("name"),
             reported,
             ", ".join("%s = %s" % (v["name"], v["value"]) for v in readable[:2])))


if __name__ == "__main__":
    main()
