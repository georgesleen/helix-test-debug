# Path arithmetic

## `(parent-directory path)`

The path with its last segment removed, or the empty string when there is no
parent. An absolute path keeps its leading separator.

## `(base-name path)`

The last segment of the path.

## `(join-path dir name)`

`dir` and `name` joined by a single separator. The filesystem root already
ends in one and must not gain a second.

## `(path-within root path)`

`path` with the `root` prefix and its separator removed. A path outside
`root` is returned unchanged.

## `(crate-root path exists?)`

The nearest ancestor directory of `path` holding a `Cargo.toml`, or `#f`
when there is none. `exists?` is injected, which is what keeps this pure and
testable.

When a workspace member has no manifest of its own, the workspace root is
found instead, since the search simply continues upward.
