# Float semantics in eco

eco gives Elm's `Float` one IEEE-consistent semantics on every path: an operator or function
applied directly, inlined, through `case compare`, as a function value, inside tuples and lists,
and in `sort`, `Dict` and `Set`. The model is the one WebAssembly chose for a portable compiled
target: IEEE 754 comparisons, NaN-propagating `min`/`max`, saturating float-to-integer
conversion. Where Elm on JavaScript behaves differently, eco differs on purpose; the differences
are listed below.

This is the semantics of eco's NATIVE output. eco's JavaScript output is produced by Elm's own
JS generator, before monomorphization, so it keeps Elm's JS behaviour (the differences below).

The tests are the contract:

- `test/elm/src/FloatIeeeSemanticsTest.elm` (native): eco's semantics, every operation and path.
- `test/elm-conformance/src/FloatEdgeTest.elm`: rows where eco and Elm agree, recorded from Elm
  on node and run on both targets.
- `test/elm-conformance/src/Float*Divergence*.elm`, `FloatNaNOrderTest.elm`,
  `FloatToIntRangeTest.elm`: Elm's own behaviour where eco differs, recorded from Elm on node and
  marked `XFAIL-NATIVE` for good, so each difference stays visible.

## The semantics

| Operation | eco |
|---|---|
| `==` `/=` | IEEE 754: `nan == x` is False, `nan /= x` is True (`oeq`, `une`). |
| `<` `<=` `>` `>=` | IEEE 754 ordered comparisons: False whenever an operand is NaN, whatever the operands are (literal or not). |
| `compare` | A total order: NaN equals NaN and is greater than every number (including +∞); -0 equals +0. |
| `<` `<=` `>` `>=` on tuples and lists | By `compare`'s total order, element by element (IEEE has no order on aggregates). |
| `sort`, `sortBy`, `sortWith compare`, `Dict`, `Set` | `compare`'s total order, so they stay well defined with NaN (all NaNs sort last and are one key). |
| `max` `min` | IEEE 754-2019 `maximum` / `minimum`: NaN in either argument gives NaN; -0 < +0. |
| `clamp lo hi x` | `minimum(maximum(x, lo), hi)`: NaN in any argument gives NaN. |
| `round` | Elm's rule (JS `Math.round`): the nearest integer, ties toward +∞ (`round -2.5 == -2`). |
| `round` `floor` `ceiling` `truncate` to Int | The 64-bit integer result, saturating: NaN gives 0, values beyond the Int range give the Int bound. `truncate` rounds toward zero with no 32-bit wrap. |
| `/`, ∞, -0, `isNaN`, `isInfinite` | IEEE 754, as Elm. |

## Differences from Elm on JavaScript

Elm compiles comparisons on `Float` in two ways. When either operand of `<` `<=` `>` `>=` is a
source literal, the JS generator emits the raw JS operator (IEEE); otherwise it emits
`_Utils_cmp(a, b) <op> 0`, and `_Utils_cmp` returns GT whenever a NaN is involved. elm/core's
`max`, `min` and `clamp` are Elm functions over that comparison. Elm's `Int` is a JS number, and
`truncate` is `x | 0`.

| Case | Elm | eco |
|---|---|---|
| `one > nan`, `nan > one`, `nan >= nan` (no literal operand) | True | False |
| `compare 1 nan` / `compare nan nan` | GT / GT | LT / EQ |
| `max 1 nan` / `max nan 1` | 1 / NaN (depends on argument order) | NaN / NaN |
| `min 1 nan` / `min nan 1` | NaN / 1 | NaN / NaN |
| `max -0 0` / `max 0 -0` | depends on argument order | +0 / +0 |
| `clamp 0 1 nan` | 1 | NaN |
| `sort`, `Dict`, `Set` with NaN | inconsistent comparator: undefined | well defined (NaN last, one key) |
| `round nan`, `floor nan`, `round (1/0)` | NaN or Infinity as an "Int" | 0, or the Int bound |
| `truncate 3e10` | -64771072 (32-bit wrap) | 30000000000 |

Everything else agrees, including `==` and `/=` with NaN, comparisons with a literal operand,
`compare` with numbers, and `round`'s ties.

## Hardware cost

Every IEEE comparison predicate, ordered or unordered, is one instruction on x86-64, ARM64 and
GPUs. IEEE-2019 `minimum`/`maximum` is one instruction on ARM64 (`FMIN`/`FMAX`) and a few on
x86-64 (native only with AVX10.2). Saturating conversion is one instruction on ARM64 and GPUs
(`FCVTZS`) and a few on x86-64. `compare`'s total order is two comparisons and selects. Elm's
`round` is about four instructions on every target.
