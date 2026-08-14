# Edition-2027 resource contract syntax

This document covers the parsed and serialized contract. Ownership flow and
release-signature validation remain typed-frontend responsibilities; accepting
this syntax alone is not proof that a resource program is valid.

```zag
@resource
pub struct Buffer[T] {
    data: @owned(release_buffer) *T,
    len: i32,
}

pub extern fn map_buffer(
    bytes: @retained_by_return []u8,
) ?*Buffer[u8] @cabi @acquires(release_buffer);

pub struct LabelView {
    text: []u8,
}

pub fn label_view(text: @retained_by_return []u8) LabelView {
    return LabelView{ .text = text };
}
```

- `@resource` marks the aggregate declaration.
- `@owned(release_fn)` attaches one plain release-function identifier to one
  field. The parser rejects empty, qualified, string, expression, and
  multi-argument relations.
- `@acquires(release_fn)` attaches the same kind of release relation to a
  function return.
- `@retained_by_return` marks a pointer-bearing parameter whose storage is
  retained by the return value. It applies to ordinary Zag constructors as
  well as foreign acquisition boundaries; it does not imply
  `@acquires(release_fn)`.
- Existing `@borrows`, `@borrows_mut`, and `@consumes` parameter contracts are
  unchanged and mutually exclusive with another contract on the same subject.

The AST stores `@resource` and `@acquires(...)` in declaration `annots`, and
stores `@owned(...)` / `@retained_by_return` in the existing `Param.contract`
slot. Formatter output, AST JSON, qualified imports, and semantic-manifest
identity preserve those exact relations. Qualified imports rewrite only a
module-local release-function identifier; extern/runtime identifiers remain
literal. Generic resource declarations retain the relation until the typed
frontend substitutes the concrete type arguments.

Typed analysis treats every retained parameter as a shared input borrow and
propagates every retained root into the complete returned value. For visible
pure-Zag bodies it may infer the same relation only when a direct pointer or
slice parameter is structurally projected into the return (for example, a
field of a returned literal). Calls, copies, and computed results do not gain a
relation merely because they mention the parameter. Public APIs should spell
the contract explicitly. A caller cannot release a backing `@resource` while
that result, or a container holding it, remains live.

## Affine behavior

An `@resource` value is moved by an uncontracted by-value call, assignment, or
return. Every owned field must be initialized exactly once and then released,
moved, or returned on every control-flow path. Reading or writing any field
after a move/release, reviving a moved name through another assignment,
overwriting a live resource, and consuming through an untracked pointer alias
are rejected.

Generic functions whose bare type parameter is instantiated with an
`@resource` fail closed unless the parameter has an explicit
lifetime/resource contract. The current `ArrayList[T]` element operations
accept only non-resource `T`; resource-valued `push`, `set`, `get`, and `pop`
remain unavailable until dedicated move-aware element APIs can state
destruction and transfer semantics without ambiguity. Scalar and ordinary
aggregate element operations are unchanged.
