# Runtime Data Structures

Strings, lists and byte sequences each have several heap forms, and the runtime picks one for every value it builds. A String is a flat array of UTF-16 code units, a large array whose payload is split from its header, a slice of another string, a rope joining two strings, or one of two all-ASCII UTF-8 forms. A List is a chain of cells that can mix single cons cells with views over dense arrays. Bytes is a flat buffer, a slice of one, or a large buffer split from its header. The empty value of all three is one shared constant, never a heap object. The forms exist so that the runtime can share structure where copying would cost too much and copy where sharing would cost more, under size thresholds that only ever change speed and memory, never results. Kernels depend only on a value's content and on the length recorded in its header, never on its form, and only the runtime's own operations look inside. Compiled code reads list cells inline as well, which is why a list form needs a program-wide switch. That boundary is what lets the runtime add a form without touching the kernels that use the type.

## One meaning, many layouts

Every form of a type means the same thing, and code outside the runtime cannot tell them apart. Two equal strings in different forms compare equal, order the same way, print the same and serialize the same. A list built from cons cells and the same list built as a chain of views behave identically everywhere. Any code that compares two values by their tags first must therefore send strings and lists on to a comparison of content, as the generic comparison in the Elm kernel does ([elm-kernel.md](../kernels/elm-kernel.md)).

A String's header records its length in UTF-16 code units, whatever its form. `String.length`, slice arithmetic and rope bookkeeping all count in those units, so making the header field mean exactly that lets compiled code read a string's length inline with no test of the form, and lets a rope add its children's lengths even when one child is UTF-8 and the other UTF-16. The UTF-8 forms hold only ASCII, so for them the code-unit count and the byte count are the same number.

The forms can share structure because no published object is ever written again ([garbage-collector.md](garbage-collector.md)). A slice can point into a buffer, a rope into its children and a chunk view into an array, because none of them will change underneath it. The same fact rules some things out. A widened copy of a UTF-8 string cannot be cached on the original, and a list's dense array cannot gain elements after the list is visible.

## Strings

Each string form answers a cost that a single flat array would pay.

| Form | Layout | Why it exists | Built by |
|---|---|---|---|
| UTF-16 leaf (`Tag_String`) | header and inline code units | the plain form; one contiguous buffer | compiled code for non-ASCII literals; every UTF-16 result of an operation |
| Large header (`Tag_LargeStringHeader`) | a 16-byte header in the nursery pointing at a payload that never moves | keeps large payloads out of the copying collector | allocation at the large-object threshold; operations treat it as a leaf |
| Slice (`Tag_StringSlice`) | base string and offset | `slice`, `trim` and `uncons` share the buffer rather than copy it | slicing a long range |
| Rope (`Tag_StringRope`) | left and right children, height, leaf count | repeated `++` on flat strings copies quadratically | `append`, `concat` and `join` above the flatten limit |
| UTF-8 leaf (`Tag_StringUtf8Leaf`) | header and inline ASCII bytes | half the memory of UTF-16 for ASCII, and already the bytes UTF-8 output needs | ASCII literals, number and character conversions, ASCII results of operations, ASCII text read by kernels |
| UTF-8 view (`Tag_StringUtf8View`) | base, offset and byte length | reading a string out of Bytes without a copy | the Bytes string decoder on long ASCII input; slices of UTF-8 strings; large ASCII results |

The large-object space that holds large payloads belongs to the collector, and [garbage-collector.md](garbage-collector.md) explains it. What matters here is that a slice or view over a large string points at its header, never at its payload, because the header is what keeps the payload alive.

A non-empty string literal is allocated once and interned in a permanent space outside the heap's address range, so an operation can be handed a string that is not in the heap ([elm-kernel.md](../kernels/elm-kernel.md)). The literal `""` is the empty constant.

Two rules keep slices shallow. A slice's base is always a leaf or a large header, and a UTF-8 view's base is always a byte buffer, a large byte header or a UTF-8 leaf. Slicing a slice adds the offsets and points at the deeper base, so a chain of slices never forms and a short slice never keeps a whole chain of objects alive.

The UTF-8 forms hold only bytes below 0x80. For ASCII text the index of a code unit equals its byte offset, so `length`, `slice` and `charAt` stay constant-time with no index translation. Byte order then equals UTF-16 order, so comparison can use `memcmp`. No lone surrogate can arise, and the bytes are already valid UTF-8, so a string moves between Bytes and String without a copy in either direction. Text containing anything outside ASCII stays UTF-16 and behaves exactly as it would without the UTF-8 forms. Creating a UTF-8 form requires bytes known to be ASCII, and the scanner in `Utf8.hpp` that checks them validates exactly as the Bytes decoder does, so a UTF-8 string never holds content the decoder would reject.

### When each form is built

The thresholds choose only between sharing and copying, and the build rules for `append` and `slice` show where each form comes from. The pseudocode is checked against `append` in `StringOps.hpp` and `slice` in `StringOps.cpp`.

```
append(a, b):
  if a or b is empty: return the other            # no new object
  n = len(a) + len(b)
  if n > string_flatten_limit: return makeRope(a, b)
  if a and b are UTF-8: return ASCII result of bytes(a) ++ bytes(b)
  data = units(a) ++ units(b)                      # C-heap buffer
  if every unit < 0x80: return ASCII result(data)  # chain healing
  return UTF-16 leaf(data)

slice(s, start, end):                              # after clamping
  empty range -> Empty;  whole range -> s
  if s is UTF-8: k <= tiny ? copy ASCII leaf : view over s's base
  if k <= string_tiny_slice_limit: copy (ASCII content -> UTF-8 leaf)
  leaf or large header: makeSlice(s, start, k)
  slice:  makeSlice(s.base, s.offset + start, k)   # no slice chains
  rope:   recurse into the child holding the range, or
          makeRope(slice(left, start, |left|), slice(right, 0, end - |left|))
```

Notice that a rope appears only above the flatten limit, which is 128 Ki code units by default. Below it, everyday strings stay on the flat path: `append`, `concat` and `join` copy into one leaf, and kernel loops, UTF-8 encoding and the parser get one contiguous buffer. Notice also that a slice of at most 128 code units is copied. Below that size a slice's own metadata is not worth having, and a short slice that is kept would otherwise hold a large buffer alive. The limit is low so that longer ranges, such as the substrings the parser takes, are shared rather than copied.

`concat` and `join` build a rope in one pass with a merge stack: each part is pushed, and the top two are merged while the top is no longer than the one below it. Folding left with `++` would give a rope that leans to one side, and walking that is quadratic, while the merge stack keeps the rope balanced in linear time. Ropes are not rebalanced afterward. The tests for rebalancing are evaluated in the one function that decides whether to flatten, but the branch that would act on them is empty, so a long chain of separate `++` calls can stay tall. The branch is also unreachable: it fires only for structural flattening, and the only caller, `ensureFlat`, asks for random access.

`uncons` always returns a slice or view for the rest of the string and skips the copy of short ranges. A fold that calls `uncons` repeatedly then allocates in proportion to the string's length in total, instead of copying the rest at every step.

The operations that make a new string out of an old one, such as `toUpper`, `reverse`, `repeat`, `pad`, `map`, `filter` and `cons`, allocate one flat result and fill it straight from the source's segments. When the source is ASCII the result is ASCII too, and it comes back as a UTF-8 string.

ASCII results are kept in UTF-8 wherever an operation can see that they are ASCII, including results computed from UTF-16 inputs. Without that, one UTF-16 operand in a chain of appends would widen every result after it. The narrowing happens in the constructors that see the content: character conversion, `cons`, short slices and the flat result of mixed inputs (the "chain healing" in the pseudocode).

### Reading a string

Readers switch on the header's tag. `charAt` follows a rope down by comparing the index with the left child's length, in a loop rather than by recursion, so a tall rope cannot overflow the C stack. The segment walker, `forEachSegmentEx`, hands the caller every contiguous run of the string in order, as UTF-16 or as ASCII bytes, and keeps an explicit stack for ropes. Its UTF-16-only wrapper, `forEachSegment`, widens ASCII runs through a small stack buffer, so the pointer it passes is valid only inside the callback.

Some callers need one contiguous UTF-16 array. They call `ensureFlat`, which goes through the single function that decides whether to flatten. Leaves and large headers pass through. UTF-8 forms are always widened, because these callers index UTF-16 code units. Slices and ropes up to the flatten limit are copied into a leaf, and larger ones are returned unchanged for the caller to walk. Because the widened copy cannot be cached on an immutable string, a caller that calls `ensureFlat` repeatedly on a UTF-8 string widens it every time. The parser would do that on every primitive, so it reads the bytes of a UTF-8 string directly instead.

Equality and comparison never allocate and never flatten. Two UTF-16 leaves, two UTF-8 strings, or two strings that are each one contiguous run are compared with `memcmp`. Any other pair is compared by walking both sides' segments together, unit by unit, widening ASCII bytes as it goes. That avoids both a copy and a call to `charAt` per character.

### The empty string

The empty string is the merged empty constant, the same word as `[]`, `Nothing`, `()`, `{}` and empty Bytes ([value-representation.md](../value-representation.md) gives its encoding). Every constructor returns that constant for a length of zero, and a rope with one empty side returns the other side. A zero-length heap object would consist of its 8-byte header alone, and the collector needs every object to be at least 16 bytes. Keeping one empty value also lets equality treat the constant as the only empty string: equality compares words when either side is the constant, so a heap string of length zero would compare unequal to `""`, and ordering puts the constant below any heap string. The type checker ensures that a shared constant is compared only with values of its own type.

## Lists

`::` always allocates a 24-byte cons cell. Functions that build a whole list at once may instead produce a chain of chunk views, each over a dense array called a backing, and a list's spine may mix cells and views freely.

```cpp
typedef struct {
    Header header;    // Header.unboxed bits 1:0 = element kind (mirror of backing).
    HPointer backing; // -> Tag_ListBacking.
    u32 offset;       // First live index in the backing.
    u32 len;          // Total logical length of this list value (>= 1).
    HPointer next;    // Rest of the spine after this chunk's run.
} ConsChunk;

typedef struct {
    Header header;  // header.size = capacity (element count); unboxed bits 1:0 = kind.
    ...
    Unboxable elems[];
} ListBacking;
```

From `runtime/src/allocator/Heap.hpp`. Notice that a view's `len` is the length of the whole list from that view onward, not the length of its own run. `length` can therefore stop at the first view it meets, and each view in a chain must carry a length that shrinks by the run before it. Notice also that a backing has one element kind for all its slots. The collector can then scan a backing from its header alone: a backing of pointers is scanned over every slot, and a backing of unboxed Int, Float or Char is never scanned.

Cons stays a cell because chunking `::` would cost more than it saves. A view is larger than a cell, and every compiled `x :: rest` pattern match would have to allocate a view for the tail. The savings, fewer spine objects and less copying in the nursery, come from bulk builders, and measurement shows that almost all cons cells in real programs are built by compiled loops that fold `::` over a list. So chunks come from compiled code as well as from kernel builders. The compiler rewrites elm/core's `reverse`, `append`, `concat`, `take` and `drop` into kernel calls, and loops that accumulate with `::` into pushes onto a rooted scratch stack that one runtime call turns into a list. [global-optimization.md](../compiler/global-optimization.md) explains why those elm/core functions are kept out of inlining, and [lowering-passes.md](../backend/lowering-passes.md) covers the loop rewrite.

A batch becomes a chain of views only when chunks are on for the program, it has at least four elements, every element has the same kind, and the whole chain fits in a quarter of the nursery. Otherwise it becomes cells. The builder `listChunkChain` splits a batch over as many backings as it needs, each below the large-object threshold, and links them from the tail forward. Every backing and view is created with the builder bit set. The caller then fills them through a chain writer with no allocation in between, and clears the bit with `finishChunkChain` before the list escapes.

The builder steps come from the absence of a write barrier. A minor collection in the middle of construction could age a backing, and a second could promote it, before it was filled, and filling it afterward would write nursery pointers into an old object that nothing records. The builder bit keeps the chain young until it is finished. Builders are never promoted, so a chain must fit in a fraction of the nursery, which is the quarter-of-the-nursery test. No reason is known for the cap that keeps each backing below the large-object threshold. The comment beside it says a larger backing would be born in the old generation, but the allocator places every large object that may hold pointers in young space ([garbage-collector.md](garbage-collector.md)).

Chunk production is one switch for the whole program, because compiled code reads list cells inline. A kernel that returned a view to compiled code that knows only cons cells would be misread. The program's entry point turns chunks on only when the program was compiled for them, and in such a program compiled head and tail projections test for a cell and call the runtime for a view. Kernels therefore produce views exactly when compiled code can read them.

Kernels walk lists through cursors in `HeapHelpers.hpp`: one for walks that do not allocate, one that roots the spine and re-reads it after every callback that may allocate, and one that collects spine nodes for `foldr`. `drop` skips a whole run per view and makes one view for a drop that stops inside a run. `reverse`, `append` and `concat` count their input first and fill one chain directly.

## Bytes

Bytes has three forms: a flat buffer whose header records the byte count, a slice with a base and an offset, and a large buffer split from its header like a large string. Empty Bytes is the shared empty constant. A slice of fewer than 32 bytes is copied, because below that size the slice header wastes more space than the copy, and a slice of a slice points at the deeper base. Readers resolve any form to a pointer and a length with `byteBufferView`, and the operations in `BytesOps` count first, allocate once and then fill.

Strings and Bytes meet without copying in two places. Decoding a string from ASCII bytes returns a UTF-8 view over the source buffer. Encoding a UTF-8 string is a `memcpy`, and its encoded width is its length. Compiled encoders and decoders that write and read buffers directly belong to [bytes-fusion.md](../compiler/bytes-fusion.md).

Arrays have one form, and their layout is described in [value-representation.md](../value-representation.md).

## Who may look inside

Outside the runtime, strings are reached only through the `StringOps` interface: length, `charAt`, conversion to a C++ string, `ensureFlat`, and the test for UTF-8 with access to its bytes, which the parser uses. A kernel may read a flat leaf's code units directly only after `ensureFlat`. Compiled code reads the length from the header inline and calls `charAt` as a call that cannot collect, fused encoders and decoders reach strings and Bytes through the helpers that [bytes-fusion.md](../compiler/bytes-fusion.md) describes, and every other string operation is a call into the kernel or the runtime. Lists are reached through the cursors and the list builders, and Bytes through `byteBufferView`.

The boundary is what makes an added form cheap. Because kernels read strings only through these functions, an added string form changes kernels only where they create strings. Lists keep the same boundary through the cursors and builders, and a list form that bypassed it would have to be taught to every kernel list walker and to the compiled projections together. Nothing checks the boundary mechanically; it is kept by review and by tests that run every operation on every form and require the results to agree.

The kernel decides what an operation means, and the runtime decides how the value is stored. [elm-kernel.md](../kernels/elm-kernel.md) covers the kernels themselves.

## Holding values across an allocation

Every operation here is C++ that the stack maps cannot see, so it must not keep a raw pointer to a heap object across an allocation: the allocation may collect and move the object. The parent document gives the general rule ([runtime.md](runtime.md)). The code keeps it with five idioms.

1. Pass the live handles to the allocation call itself, in an array of roots. The allocator roots them only on its slow path, and the caller reads the moved values back from the array. The slice, rope and view constructors, `concat` and `join` do this.
2. Wrap the raw pointer in a handle, root the handle with a stack guard for the allocation only, then resolve it again before reading. Every allocating string transform has this shape.
3. Copy what is needed to the C stack or the C heap before allocating.
4. Allocate everything first, then fill without allocating. The blank-string allocators and `listChunkChain` return raw write pointers that are valid only until the next allocation.
5. Root a buffer of heap values with one record for the whole buffer, never one per element. One record per element overflows the shadow stack of 65,536 records on a large list, and a build check rejects root pushes inside loops.

## Where rules and comments disagree

Some descriptions of these structures in the rules and the code comments would mislead a change.

- The invariant catalog's rule on string forms says there are four forms and that compiled code allocates only UTF-16 leaves. There are six, and ASCII literals become UTF-8 leaves.
- The same rule says that equality and comparison flatten both strings when they are below the flatten limit and use `charAt` above it. The code never flattens to compare. Making it do so would put an allocation, and so a possible collection, inside every string comparison.
- The flatten limit is a heap configuration setting, 128 Ki units by default, not a constant.
- A comment on the slice constructor says the caller must root the base. The constructors pass their arguments in the allocation call's roots array.
- The tiny-slice limit is described as a count of bytes. It is compared against a length in UTF-16 code units.
- A comment on the chunk view says `take` makes a view in constant time. `take` copies its elements; only `drop` makes a view.
- The invariant catalog's rule on the empty constant says it equals a zero-length heap string. Only the kernel's comparison of boxed slots treats them as equal; every other equality and ordering path treats them as different. The rule holds only because no constructor makes a zero-length string.

## Examples of changes that fit the theory

A change fits when every form still means the same content, the header still records the logical length, and only the runtime's own operations depend on which form a value has.

- An added string form is a tag placed before the free and forwarding tags, a structure, its size calculation and tracing in the collector, a case in each `StringOps` reader, and the sites that create it. The UTF-8 leaf and view have this shape, and they touch kernels only where kernels create strings, because no kernel reads string storage directly.
- Retuning the flatten limit, the tiny-slice limit, the minimum UTF-8 view length or the rope limits is a heap configuration change. It changes speed and memory, never results, and the tests size their ropes from the configured limit, so they keep testing ropes.
- Keeping more results in the cheaper ASCII form is a change to one constructor that can see the content, as character conversion, `cons`, short slices and mixed flattening are.
- Implementing rope rebalancing goes in the single function that decides whether to flatten, `maybeFlattenOrRebalance`, where its tests are already evaluated. Because that branch is unreachable, a rebalance needs a caller as well as a body.
- An added bulk list producer counts its input, tests whether a chain is eligible and fits, builds the chain, fills it with a chain writer and finishes it. Simpler still, it calls the existing builder that makes a list from a buffer of elements. Either way it produces cells or views under the same rules as `reverse` and `append`.
- An added kernel string or list operation reads through `charAt`, the segment walker, `ensureFlat` or a cursor, and builds through the blank-string allocators or the list builders. It then works for every form there is and every form added later.
- Allowing UTF-8 strings that are not all ASCII changes creation policy and index translation inside `StringOps`, not the layout of the view.

## Examples of changes that would break the theory

- Casting to the UTF-16 leaf's structure and reading its code units, or reading cons fields directly, in a kernel or in compiled code. It works on the commonest form and fails on a slice, a rope, a UTF-8 string or a chunk view. Go through `StringOps` after `ensureFlat`, or through a cursor.
- Producing a list view, or an added list form, without the program-wide switch. Compiled projections that know only cons cells would misread it. Gate the form like chunks, and teach the compiled projections to read it.
- Allocating a zero-length string, UTF-8 leaf or byte buffer. It would compare unequal to `""` and break the collector's 16-byte minimum. Return the empty constant.
- A slice or view whose base is another slice, or a large payload. Slice chains grow without bound, and a slice over a payload can outlive the header that keeps the payload alive. Collapse to the deepest base, and point at the large header.
- Writing into a backing or a string after it is published, such as consing into spare room in a backing or caching a widened copy on a UTF-8 view. Either creates old-to-young pointers that nothing records. Allocate a fresh object, or keep a side cache that is registered as a root.
- A chunk producer that allocates between building a chain and finishing its fill, or that never clears the builder bit. The writer's raw pointers go stale, or a builder escapes into the program. Allocate everything first, fill, then finish.
- Holding a raw pointer, or a pointer from the segment walker, across an allocation, or pushing one root record per element in a loop. Use one of the five idioms.
- Equality or ordering that compares tags or pointer words before content. Two equal strings in different forms, or one list split into chunks differently, must compare equal. Compare content.
- Creating a UTF-8 form from bytes that have not been checked, or that are not ASCII. Every constant-time shortcut assumes the byte count equals the code-unit count. Gate creation with the scanner in `Utf8.hpp`.

## References

Parent: [runtime.md](runtime.md). Related: [garbage-collector.md](garbage-collector.md) (tracing, the large-object space, builders, rooting machinery), [value-representation.md](../value-representation.md) (embedded constants, element kinds, array layout), [elm-kernel.md](../kernels/elm-kernel.md) (kernel code, the JSON heap form), [bytes-fusion.md](../compiler/bytes-fusion.md) (fused encoders and decoders), [lowering-passes.md](../backend/lowering-passes.md), [global-optimization.md](../compiler/global-optimization.md), [mlir-generation.md](../compiler/mlir-generation.md) (compiled list producers).

Code (`runtime/src/allocator/` unless noted):

- `StringOps.hpp`: the tag helpers, `forEachSegmentEx`, `charAt`, `toStdU16String`, `append`, the transforms, inline `equal` and `compare`.
- `StringOps.cpp`: `makeSlice`, `makeRope`, `makeUtf8View`, `makeUtf8LeafFromBytes`, `allocAsciiOut`, `maybeFlattenOrRebalance`, `slice`, `buildBalancedRope`, `concat`, `join`, `uncons`, `equalSlow`, `compareSlow`.
- `ListOps.hpp`, `ListOps.cpp`: `chunkEligible`, the chain fills of `reverse`, `append` and `concat`, `drop` over views.
- `HeapHelpers.hpp`: the "GC Rooting Patterns" header, `listChunkChain`, `finishChunkChain`, the chain writers, `ListCursor`, `RootedListCursor`, `ListBackwardCursor`, `listFromUnboxables`, `makeByteBufferSlice`, `byteBufferView`, `flatStringView`.
- `BytesOps.hpp`, `BytesOps.cpp`: Bytes operations and UTF-8 encoding and decoding.
- `Utf8.hpp`: `scan`, `allAscii`, `widenAscii`.
- `Heap.hpp`: the tags and every structure above. `AllocatorCommon.hpp`: threshold defaults (`string_flatten_limit`, `string_tiny_slice_limit`, `utf8_view_min_len`, `rope_max_height`, `rope_leaf_count_limit`, `rope_min_leaf_size`, `utf8_strings_enabled`), settable from `heap-config.json`.
- `RuntimeExports.cpp`: `eco_enable_list_chunks`, `eco_scratch_finish`, `eco_list_head_hybrid`, `eco_list_tail_hybrid`. The compiler option `list.chunks` (`compiler/src/Compiler/Eco/Config.elm`) is on by default.
- `runtime/src/codegen/Ops.td`: `eco.string.length` and `eco.string.code_unit_at`.
- `elm-kernel-cpp/src/core/Utils.cpp`: the generic `compare`, which sends strings to `StringOps::compare`.
- Tests: `test/allocator/StringOpsTest.cpp`, `Utf8StringTest.cpp`, `Utf8Test.cpp`, `ListOpsTest.cpp`, `ChunkedListTest.cpp`, `BytesOpsTest.cpp`. `check-root-bounded.py` rejects root pushes in loops.

Documents:

- `design_docs/utf8-string-encoding-investigation.md`: the UTF-8 choices and the alternatives rejected.
- `plans/string-rope-slice-representation.md`, `plans/chunked-list-representation.md`, `plans/utf16-seed-elimination.md`: the design records.

Invariants (`design_docs/invariants.csv`):

- HEAP_025: string access through the runtime; out of date on the number of forms and on flattening for equality. HEAP_032: the UTF-8 forms.
- HEAP_010, REP_CONSTANT_003: the empty constant and its comparison. HEAP_071: no zero-length objects.
- HEAP_037, HEAP_038, HEAP_039, CGEN_070: chunked lists, backing size, the program-wide switch and compiled projections.
- HEAP_026, HEAP_081: large split payloads.
- HEAP_019, REP_HEAP_002: element kinds.
- HEAP_SNAPSHOT_001, HEAP_BUILDER_001 to HEAP_BUILDER_003, HEAP_040: immutability, builders and the list scratch stack.
- CGEN_039, BFOPS_030 to BFOPS_032: compiled code's access to strings and Bytes.
- FORBID_HEAP_005: no conclusion from differing pointer words.
