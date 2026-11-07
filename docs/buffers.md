# Buffers and cursors

[lib/buffer.shen](../lib/buffer.shen) adds logical ranges over byte buffers and sized pointers. [lib/cursor.shen](../lib/cursor.shen), loaded
after it, adds a mutable position. Both are optional, outside the default image, and need no I/O library:

```sh
shen-jit eval -l lib/buffer.shen -l lib/cursor.shen \
  -e '(let C (cursor.new (buffer.from-string "tag=42")) Name (cursor.string C 3) Equals (cursor.read C) Val (cursor.string C 2) [Name Equals Val (cursor.peek C)])'
```

This returns the strings `"tag"` and `"42"`, byte 61 and the local end marker -1. A cursor's end is not a
transport EOF declaration. Failed captures and movement leave its position unchanged.

## Operations

| Operations | Meaning |
| --- | --- |
| `buffer.new N`, `buffer.from-string S` | A view over fresh managed bytes, zeroed or copied from S |
| `buffer.wrap Storage` | Borrow an existing managed buffer or sized pointer |
| `buffer.slice V Start Count` | A subview relative to V, bounded by V rather than the whole owner |
| `buffer.length V`, `buffer.owner V`, `buffer.offset V`, `buffer.end V` | Logical length, original owner and owner-relative start/exclusive end |
| `buffer.u8 V I`, `buffer.u8! V I Byte` | Checked relative byte access; a store returns V |
| `buffer.bytes V`, `buffer.string V` | Independent copies of the logical bytes; no UTF-8 validation |
| `buffer.copy! To I From J Count` | Checked overlapping copy, returning To |
| `buffer.equal? A B` | Compare logical bytes, without comparing owner margins |
| `cursor.new V`, `cursor.fork C` | New cursor or independent position sharing C's view |
| `cursor.buffer C`, `cursor.position C`, `cursor.offset C`, `cursor.remaining C` | View, relative position, owner-relative position and remaining count |
| `cursor.peek C`, `cursor.read C` | Next byte without/with movement; -1 at the view boundary |
| `cursor.skip C Count`, `cursor.seek C Position` | Checked forward or absolute relative movement, returning C |
| `cursor.view C Count`, `cursor.bytes C Count`, `cursor.string C Count` | Borrow or copy Count bytes, then advance |

Indices/counts must be nonnegative fixnums; an integral boxed real is refused. Empty views are valid.
Views share mutations; captures copy. Generic `=` on view records is not logical byte equality, and mutable
views should not be dictionary keys. Hot scanners can unpack owner/start/end once instead of using a cursor
for each byte.

## Ownership and lifetime

A view borrows the exact storage object; it never frees it or creates an independent pointer copy.
`memory.free`, `mmap.close` or `handle.close` on that owner makes subsequent operations raise, including empty
captures. Independent pointer copies are not invalidated together. One task must control native storage's
lifetime; do not close it during an active foreign call. Managed values persist in saved images; foreign
owners reload dead. Managed use also works in static builds, whose FFI allocators are unavailable.

## Typed clients

Load the libraries under `(tc -)`; their declarations expose opaque `buffer.view`, `buffer.cursor` and
`buffer.storage` types to typed clients. Normal clients can use `buffer.new` and `buffer.from-string` without
raw storage declarations. As with other opaque FFI values, a typed foreign allocator needs an explicit
compatible declaration at its boundary.

## Format examples

For two complete-input examples, load [tools/buffer-parsers.shen](../tools/buffer-parsers.shen) after the libraries. `buffer-example.json`
takes a view and returns arrays as lists, ordered `[object [Key Value] ...]` objects, strings, booleans and
`null`. Numbers remain exact `[number Token]` values. It validates UTF-8/escapes, rejects duplicate keys and
limits nesting to 128; diagnostics use backing-owner byte offsets. This is an example reader, not a numeric
conversion API. `buffer-example.packet View Limit` reads a two-byte big-endian tag, four-byte length and owned
payload, rejecting oversized, incomplete or trailing input. Neither example reads a stream.
