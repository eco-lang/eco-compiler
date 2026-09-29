# Empty `Bytes` as the embedded Empty constant (no 8-byte heap objects)

Fixes bug 1 of `/work/2-gc-bugs.md`: under `shadow_granule_log2 = 4`, the gc-pressure stress
program `BytesRoundtripNestedBytes` aborts on an 8-byte (header-only) nursery survivor.

## Finding

Only three heap layouts can be header-only (`sizeof == sizeof(Header) == 8`) when empty:
`ElmString`, `ElmStringUtf8Leaf` and `ByteBuffer`. Every other variable-size layout has at least
one word after the header (`Custom`, `Record`, `ElmArray`, `ListBacking`, `FieldGroup`,
`DynRecord`), so it is at least 16 B even when it has no elements.

- `ElmString`: never allocated empty. `allocString`/`allocStringBlank` return `emptyString()`
  (see the note at `Heap.hpp:419`: an 8-byte string was once overwritten by a forward).
- `ElmStringUtf8Leaf`: never allocated empty. `makeUtf8LeafFromBytes`, `makeUtf8View` and
  `tryMakeAsciiString` all route length 0 to `emptyString()`. `allocAsciiOut` documents `len > 0`
  but does not assert it.
- `ByteBuffer`: **allocated empty on purpose.** `allocByteBuffer(nullptr, 0)` makes an 8-byte
  `Tag_ByteBuffer`. That covers `BytesOps::empty()`, `makeByteBufferSlice(..., 0)` (whose comment
  wrongly claims it returns an "embedded empty-byte-buffer constant"), `fromList []`, `concat` of
  empties, `slice` with `start >= end`, and `allocByteBufferBlank(0)`/`allocByteBufferZero(0)`,
  which is what `Bytes.Encode.encode (sequence [])` and a fused `bf.alloc 0` reach through
  `elm_alloc_bytebuffer`.

## Design

Represent empty `Bytes` the same way as `""`: as the merged Empty constant (word 0x6, HEAP_010).
`Bytes` is an opaque type and is not `comparable`, so the merged constant cannot be confused with
another type's empty value at a use site. It also cannot be pattern-matched.

The reader side is mostly ready already:
- **Generated code** reaches Bytes only through `elm_bytebuffer_len` and `elm_bytebuffer_data`
  (`ElmBytesRuntime.cpp`). Both already map any embedded constant to `(nullptr, 0)`.
- **Helpers:** `byteBufferView`, `byteBufferLength` and `BytesOps::{length,getAt,toVector,...}`
  already treat a `nullptr` object as empty.
- **Equality:** `Utils::eqHelp` resolves constants to `nullptr`, and `a == b` is true for two
  constants.

So the work is (1) producing the constant, and (2) every place that calls `Allocator::resolve` on
something that may be Bytes must not resolve a constant. `resolve` asserts `ptr_ind == 0` in
validate builds and returns garbage otherwise.

## Steps

0. **Confirm the tag.** Pass `hd.tag` to the `regionFatal` at `NurseryRegion.cpp` (the
   `size < 16` arm) and re-run the reproduction. Expect `Tag_ByteBuffer`.
1. **Producers** (`HeapHelpers.hpp`):
   - Add `emptyBytes()` (= `empty()`).
   - `allocByteBuffer`, `allocByteBufferBlank` and `allocByteBufferZero` return it for
     length 0. `Blank` returns `{emptyBytes(), nullptr, 0}`.
   - Fix the `makeByteBufferSlice` comment.
   - Add `resolveBytesOrNull(HPointer)`, a constant-safe resolve.
2. **Resolve sites that may see an empty Bytes.** Switch each to `resolveBytesOrNull`:
   - `BytesExports.cpp`: `resolveByteBufferView`, `encoderSize` ENC_BYTES, `writeEncoder`
     ENC_BYTES, and `read_string` (it resolves before its bounds check).
   - `BytesOps.cpp`: `concat` (both passes) and `decodeUtf8`'s re-resolve.
   - `BytesOps.hpp`: `append` re-resolve.
3. **`void*` APIs that `wrap()` their argument back into an HPointer** (`BytesOps::append`,
   `BytesOps::slice`, `Kernel::Bytes::write_bytes`) must not `wrap(nullptr)`. Return
   `emptyBytes()` for a null or empty input.
4. **Unit tests** that do `Allocator::resolve(BytesOps::empty())` switch to
   `resolveBytesOrNull`. Add assertions that `BytesOps::empty()`, `allocByteBuffer(nullptr, 0)`,
   `allocByteBufferBlank(0)`, `allocByteBufferZero(0)` and a zero-length slice are all
   `isConstant`.
5. **Guard.** Add `allocAsciiOut` `assert(len > 0)`. In `NurseryRegion.cpp`, make the `size < 16`
   survivor fatal unconditional in validate builds (not only when `shadow_shift > 3`), so a new
   header-only layout is caught by the validate gate at the default 8-byte granule.
6. **Invariant.** Amend HEAP_010 so Empty also denotes the empty `Bytes`. Add HEAP_071: every live
   heap object is at least 16 B, and there is no header-only heap object; empty
   String/UTF-8 leaf/Bytes are the Empty constant.

## Known behaviour change

The debug printer (`print_value`, used by `Debug.log`/`toString` for opaque types) printed an
empty Bytes as `<bytes:0>`. It will now print the generic `<empty>`. No test expects
`<bytes:0>`. The JS reference prints `<0 bytes>` and was never matched exactly anyway.

## Test gate

All of these run at the **current** default `shadow_granule_log2 = 3`, plus the one repro at 4:

1. `cmake --build build --target test` (unit tests) and `build-validate` unit tests.
2. The reproduction from `2-gc-bugs.md` with `shadow_granule_log2 = 4` must pass.
3. The whole gc-pressure stress suite with `shadow_granule_log2 = 4`.
4. E2E: `cmake --build build --target full`.

This plan does **not** change the `SHADOW_GRANULE_LOG2` default. Flipping it is a separate decision
taken after this gate (see `2-gc-bugs.md` bug 1, step 4).
