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
```

- `@resource` marks the aggregate declaration.
- `@owned(release_fn)` attaches one plain release-function identifier to one
  field. The parser rejects empty, qualified, string, expression, and
  multi-argument relations.
- `@acquires(release_fn)` attaches the same kind of release relation to a
  function return.
- `@retained_by_return` marks a parameter whose storage is retained by the
  acquired return value.
- Existing `@borrows`, `@borrows_mut`, and `@consumes` parameter contracts are
  unchanged and mutually exclusive with another contract on the same subject.

The AST stores `@resource` and `@acquires(...)` in declaration `annots`, and
stores `@owned(...)` / `@retained_by_return` in the existing `Param.contract`
slot. Formatter output, AST JSON, qualified imports, and semantic-manifest
identity preserve those exact relations. Qualified imports rewrite only a
module-local release-function identifier; extern/runtime identifiers remain
literal. Generic resource declarations retain the relation until the typed
frontend substitutes the concrete type arguments.
