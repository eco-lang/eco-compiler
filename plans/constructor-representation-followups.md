---
status: not-started
updated: 2026-11-20
---

# Constructor representation: follow-up ideas

Ideas gathered after `plans/constructor-representation-levels.md` (R0–R4 done). Not lowered:
each needs a measurement before it is planned in detail.

## F1. The constructor index in every word of a union (tagged words)

**Problem.** Nullable `Maybe` (N1a) admits a payload only if its word can never be Empty, so
`Maybe String`, `Maybe (List a)`, `Maybe ()` and `Maybe {}` still allocate a `Just`. Maybe-shaped
user types (N1b, decision D2) are tighter still: the `None` test is "is the word a constant", so
`Bool`, enum, list and string payloads are excluded. N2 (multi-constructor one-field unions, e.g.
`Result`) was dropped because payloads such as `Leaf`/`SubTree` share a runtime tag. Every other
union allocates a `Custom` for each one-field constructor.

**Idea.** Every word of a union type carries its constructor's declaration index in
`null_cons_idx` (bits 43–52, `runtime/src/allocator/Heap.hpp`). The heap lies below
`HPOINTER_ADDRESS_LIMIT` = 2^43, so these bits are 0 in every heap pointer, and they are 0 in
False/True/Empty. Each constructor takes the cheapest form its shape allows:

```elm
type T
    = A SomeVal          -- bare: SomeVal's word, index 0
    | B OtherVal         -- bare: OtherVal's word, index 1
    | C                  -- null-cons word, index 2 (today's HEAP_044 encoding)
    | D One Two Three    -- Custom on the heap, its pointer tagged with index 3
```

| Constructor | Word | `ptr_ind` | `constant` | `null_cons_idx` |
|---|---|---|---|---|
| `A x` | x's word | 0 (heap) or 1 (False/True/Empty) | x's | 0 |
| `B y` | y's word | as for `x` | y's | 1 |
| `C` | null-cons word | 1 | 3 | 2 |
| `D 1 2 3` | pointer to a `Custom` | 0 | 0 | 3 |

The allocated constructors are tagged too: an untagged pointer would read as index 0, the same as
a bare `A x`. With every word tagged, a `case` reads bits 43–52 for every constructor: a shift and
a mask, no header load (today `get_tag` loads the header of a heap value). Building a bare value is
an OR, projecting its field an AND. An untagged dereference is a non-canonical address on x86-64, so
a missed mask crashes rather than corrupts.

**Which one-field constructors are bare.** Decided per constructor, not per type: its field must
be a boxed word whose index bits are always 0: heap objects (records, tuples, closures, strings,
lists, untagged `Custom`s) and False/True/Empty. A constructor allocates like `D` when its field is
an unboxed `Int`/`Float`/`Char`, a type with nullary constructors (null-cons words use the index),
or itself a tagged union (recursion such as `type Tree = Leaf | Node Tree`, nesting such as
`Maybe (Maybe a)`). Constructors with two or more fields always allocate.

**Special cases it covers, and so supersedes:** nullable `Maybe` (one bare and one nullary
constructor), now including `Maybe String`, `Maybe (List a)`, `Maybe ()`; Maybe-shaped user types
without the D2 restriction (payloads such as `Bool` and strings are fine); and N2's multi-constructor
unions such as `Result`, since the index travels in the word and a shared payload tag no longer
matters. N1a/N1b could become this scheme's two-constructor case, with one test path
(`eco.is_constant` and the Empty test retire).

**Still excluded:** kernel-visible instantiations (`KernelVisible`, per instantiation), meets with
an `MVar`, and types with more than 1,023 constructors (already the null-cons limit).

**Cost and risk.**
- The GC uses a heap pointer word as the address unchanged (`Allocator.hpp:671`, `:682`): marking,
  copying and forwarding must mask, and write back with the index kept. Read `test/tla/README.md`
  first.
- Invariants: HEAP_044 (second meaning of the field), FORBID_HEAP_001, CGEN_087, the "idx/padding
  are 0 in a heap pointer" layout comment and HPointerLayoutTest.
- `==` can stay untyped (different indices: unequal; same: mask and compare the fields); `compare`
  does not apply to unions; `Debug.toString` needs a type-table kind that says which constructors
  are bare.
- Kernels must never see a tagged word; a leak now crashes instead of misreading.
- The 11 `padding` bits stay free (e.g. a second tag level for nesting, if ever needed).

**First step: measure.** Run the constructor census (`ctorCensus`) with the passes on, on the
self-compile and on a few user-style programs (E2E and benchmark programs). Count the custom
allocations of one-field constructors that would become bare, split into the classes above
(kernel-visible, unboxed field, field with nullary constructors, tagged-union field). On the
self-compile much of the remainder looked kernel-visible (`Ok` 21.9M, `Array`'s `Leaf`/`SubTree`
55M); the gate should weigh user programs, not the compiler alone.

## F2. Fallback: a spare "empty" word only

If F1's GC change is judged too costly: give a nullable type's empty constructor its own reserved
constant word (an unused pattern with `ptr_ind` set), tested by exact word compare. Admits Maybe
payloads that can be Empty or a constant, and nested `Maybe`s (one spare word per level), with no
GC change. Needs an audit of every Empty check (`isEmpty` reads only the 2-bit constant field).
Covers only Maybe-shaped types, not multi-constructor unions.
