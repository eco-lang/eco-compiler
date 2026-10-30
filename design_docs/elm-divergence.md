# Where eco diverges from Elm 0.19.1

**Status: DRAFT.** Items marked *TODO* still need checking against the code or a decision.

eco aims to run Elm programs with the same results as the reference JavaScript compiler. In a
few places the reference behaviour is inconsistent, platform-dependent, or lets a value of one
type hold a value of another. In those places eco makes a deliberate choice instead of copying
JavaScript. This document lists every such choice, so they live in one place.

Three areas diverge so far:

1. **Int** is a real 64-bit two's-complement integer.
2. **Char** is exactly one Unicode code point, and its case mapping is the Unicode *simple* case
   mapping.
3. **Float** follows IEEE 754 consistently, including NaN, in every comparison path.

They share one principle:

> **Basic arithmetic is total.** Every `Basics` math function returns a value of its declared
> type for every input. It may return a *wrong answer* (wrapping, `x // 0 == 0`, NaN), but it
> never returns a value of a different type and never raises a runtime error.

---

## 1. Int: 64-bit, and never anything else

### Elm

Elm's `Int` is a JavaScript number, a double. This gives:

- **Int can hold non-integers.** `2 ^ -1` type-checks as `Int` and evaluates to `0.5`.
  This breaks the type system: the value is a Float at runtime.
- **Int can hold NaN and Infinity**, for example from `round (0/0)`, `floor (1/0)`, or
  `truncate` of a non-finite value. *TODO: list the minimal reproductions.*
- **Precision is 53 bits.** Above 2^53, integers are silently rounded.
- **`truncate` is 32-bit.** It compiles to `x | 0`, so `truncate 3e9 == -1294967296`, while
  `round`, `floor` and `ceiling` give the full 53-bit result.
- **Bitwise ops are 32-bit** (`Bitwise.and`, `shiftLeftBy`, and so on), while arithmetic is 53-bit.

### eco

- `Int` is `i64`, unboxed (see invariant REP_* on unboxed Int). Arithmetic wraps on overflow.
- `^` on Int is integer power. A negative exponent gives `0` (so `2 ^ -1 == 0`), never a
  fraction. *TODO: confirm what `0 ^ -1` gives and write it down.*
- `x // 0 == 0`, and `minInt // -1` wraps to `minInt` (CGEN_084, `elm-kernel-cpp/src/core/Basics.cpp`, `idiv`).
- `truncate`, `round`, `floor` and `ceiling` all return the full 64-bit result.
- Float → Int of NaN or ±Infinity, or of a value outside the i64 range: *TODO: decide the
  result.* Today `Basics::truncate` does `static_cast<long long>(std::trunc(x))`, which is
  undefined behaviour in C++ for those inputs. Suggested rule: NaN → 0, saturate to
  `minInt`/`maxInt`.
- Bitwise ops: *TODO: state whether they are 64-bit (likely) and note the difference from Elm's 32 bits.*

### Consequences for programs

Results agree with Elm for any integer that stays within ±2^31 (or ±2^53 for arithmetic).
Programs that rely on JS overflow behaviour, on 32-bit `truncate` used as a hash mix, or on
`Int` secretly holding a fraction will behave differently.

### Known exception to "never a runtime error"

`modBy 0 x` and `remainderBy 0 x` currently throw (`Basics.cpp`, `modBy`), which matches
Elm's crash. *TODO: decide whether to make these total (`modBy 0 x == 0`, in line with
`//`) or record them as the deliberate exceptions.*

---

## 2. Char: one code point, simple case mapping

### Elm

A `Char` is a JS string of one or two UTF-16 code units. `Char.toUpper` and `Char.toLower`
call `String.prototype.toUpperCase`/`toLowerCase`, which use the *full* Unicode case mapping.
That mapping can return **more than one code point**, for example `'ß'` → `"SS"` and `'ŉ'` →
`"ʼN"`. The result is still typed `Char`, so Elm has a Char that holds two characters. This
is another type-level hole of the same kind as `2 ^ -1`.

Case mapping also depends on the JS engine's Unicode version.

### eco

- A `Char` is exactly one Unicode scalar value (stored as a 32-bit code point).
- `Char.toUpper`, `Char.toLower`, `toLocaleUpper` and `toLocaleLower` use the Unicode **simple
  case mapping** (`UnicodeData.txt` fields 12–14). This is always one code point, and a
  character with no simple mapping maps to itself (`'ß'` → `'ß'`).
- The earlier table of 146 special cases, which tried to imitate multi-code-point results,
  is removed. *TODO: link the commit once reverted.*
- `String.toUpper`/`String.toLower` are not affected and keep full case mapping
  (`"ß"` → `"SS"`), because a String may change length. *TODO: confirm this is what the
  String kernel does.*
- The Unicode version is fixed by eco's tables, not by the host. *TODO: state the version.*

### Consequences

Only the roughly 100 code points whose full mapping is longer than one code point give
different results. For these, `Char.toUpper c` in eco equals what
`String.toUpper (String.fromChar c)` would give in Elm only when the latter has length 1.

---

## 3. Float: IEEE 754, consistently

### Elm's inconsistencies

Elm's Float follows IEEE 754 in some code paths and not in others. With `nan = 0/0`:

1. **A comparison's result depends on syntax.** Comparisons on values whose type is known to
   be a number compile to raw JS `<`, `>`, `==`, while others go through `_Utils_cmp` /
   `_Utils_eq`. Whether you write the operator directly, pass it as a function (`(<)`), or
   compare inside a polymorphic helper changes the answer for NaN. *TODO: give the minimal
   pair, literal vs non-literal.*
2. **`>` and `<` are not mirror images.** `_Utils_cmp` returns `LT` only when `a < b`, and
   otherwise returns `GT` unless the values are equal. So with NaN both `compare nan 1` and
   `compare 1 nan` are `GT`, and `a > b` is not the same as `b < a`.
3. **`compare` is not antisymmetric**, as a result of (2). `Dict`, `Set`, `List.sort` and
   `List.sortBy` assume a total order. With NaN keys, a `Dict` can lose entries, keep
   duplicates, or fail to find a key that is present. Sorts give an order that depends on the
   input order.
4. **`max` and `min` depend on argument order.** `max nan 1 == 1` but `max 1 nan == nan`
   (or the reverse, depending on how the `>` is written). *TODO: check the exact direction.*
5. **`NaN /= NaN`, but `(NaN, NaN) == (NaN, NaN)`.** Top-level `==` on Floats is JS `===`
   (IEEE: false for NaN), but structural equality in `_Utils_eqHelp` starts with an identity
   check (`x === y` on the *object*). So containers holding the same NaN object compare equal.
   The result depends on whether the two sides are the same heap object.

### eco

eco treats Float as IEEE 754 binary64 everywhere, and makes every comparison path agree:

- `==` and `/=` on Float follow IEEE: `nan == nan` is `False`, and `0.0 == -0.0` is `True`.
  This holds the same way at the top level and inside tuples, records, custom types, lists,
  `Dict`, and so on. Equality never takes a shortcut based on pointer identity for values that
  may contain a Float. *TODO: check `Utils.cpp` equality for an identity shortcut, and decide.*
- `<`, `<=`, `>`, `>=` follow IEEE: every comparison with NaN is `False`. This is the same
  whether the operator is applied directly, passed as a function, or used at a polymorphic
  type after monomorphization.
- `compare` must return an `Order`, so it cannot follow IEEE for NaN. *Proposed:* `compare`
  uses the IEEE 754 `totalOrder` predicate (−NaN < −∞ < … < −0 < +0 < … < +∞ < +NaN). That is
  antisymmetric and transitive, so `Dict`, `Set` and `sort` behave correctly with NaN keys.
  The cost is that `compare a b == EQ` and `a == b` can disagree for NaN and ±0.
  *TODO: decide; the current `compareUnboxableSlot` does `a.f < b.f ? -1 : 1` after an equality
  test, which copies Elm's asymmetry.*
- `max` and `min`: *Proposed:* NaN in either argument gives NaN (IEEE 754-2019
  `maximum`/`minimum`), so the result does not depend on argument order.
- `isNaN`, `isInfinite`, `sqrt`, `logBase`, `0/0` and so on behave as in C/IEEE. They give the
  same answers as JS, so nothing diverges there.

### NaN and constant extraction

The optimisation that lifts constant expressions to shared globals can turn two separately
built `(nan, nan)` values into one shared object. In Elm that changes the result of `==`,
because of the identity shortcut in item 5. Copying Elm exactly would mean the optimisation
changes program output.

eco's rule: **equality never depends on object identity**, so sharing a constant can never
change a result. Until the equality code is confirmed to follow that rule, constant
extraction stays disabled (it has never been switched on). *TODO: once the rule is
confirmed, add an E2E test (`(nan, nan) == (nan, nan)` is `False`, both shared and not).*

---

## 4. Other confirmed divergences

### 4.1 `==` on functions

Elm throws a runtime error ("Trying to use `(==)` on functions"). eco returns `False`
(`elm-kernel-cpp/src/core/Utils.cpp:728`, `Tag_Closure`). This fits the total-functions
principle, but a program that crashes in Elm runs on in eco. *TODO: check functions nested in
records, custom types and `Dict` values. Also decide whether the type checker should reject
this statically, as Elm's `comparable`/`equatable` cannot.*

### 4.2 `Debug.*` under `--optimize`

Elm refuses to compile a program that uses `Debug` with `--optimize`. eco's native path accepts
it and keeps the output. `Debug.log` writes `label: value` into the program's output stream
(`design_docs/debug-log-ordering-policy.md`). Its ordering rules (D-1 and the rest) are a
guarantee specific to eco. *TODO: decide whether `--optimize` should also reject `Debug` on
the native path, for parity.*

### 4.3 `String.toInt` range

eco parses into 64 bits (`runtime/src/allocator/StringOps.hpp:1205`). Elm gives a JS number,
so values above 2^53 lose precision. *TODO: overflow behaviour (`Nothing`, or wrap?).*

---

## 5. Suspected divergences (not yet checked)

### 5.1 `String.fromFloat` and `Debug.toString` on Float

eco uses its own `formatFloatShortest`. JS has specific rules: exponent form at `1e21` and
above and below `1e-7`, `-0` printed as `"0"`, `"NaN"`, `"Infinity"`, `"-Infinity"`. Any
difference shows directly in program output. *TODO: compare against JS
`Number.prototype.toString` on a fuzzed corpus.*

### 5.2 `String.toFloat` parsing

JS `Number()` accepts some odd forms (`"0x10"`, `"Infinity"`, `".5"`, `"5."`, `"1e5"`, and
surrounding whitespace). Elm's kernel filters some of these. eco's C++ parser almost certainly
differs at the edges. *TODO: build an accept/reject table for both.*

### 5.3 Regex engine

eco uses SRELL (`elm-kernel-cpp/src/regex/`). Elm uses the host JS engine. Both aim at
ECMAScript syntax, but they may differ on Unicode property escapes, lookbehind, `\w`/`\b`
with non-ASCII input, and the `u` flag. Elm's behaviour itself depends on the browser version.
*TODO: decide which ECMAScript edition eco promises.*

### 5.4 JSON

- `Json.Encode.float nan` (or ±Infinity) gives `null` in JS. *TODO: eco?*
- `Json.Decode.int` accepts `1.0` in JS, and integer range is 2^53 versus 64-bit.
- Duplicate object keys (JS keeps the last one) and the key order on encode.
- Number formatting on encode (see 5.1).

### 5.5 Bitwise width

Elm's `Bitwise` is 32-bit (`shiftRightZfBy` is a 32-bit logical shift, and results are
signed 32-bit). If eco is 64-bit, hash functions ported from JS (FNV, murmur, and those in
elm-community packages) give different results. *TODO: confirm eco's width. Consider making
`Bitwise` 32-bit to match Elm, since it is used almost only for hashing and bit tricks
written against 32 bits.*

### 5.6 `Random`

`elm/random` seeds are built from Int and Bitwise operations. Unless both match Elm exactly,
`Random.step` gives different sequences for the same seed. Tests that hard-code seeds would
break. *TODO: run elm/random's PCG implementation against JS output. Depends on 5.5.*

### 5.7 Unicode version of `Char` predicates

`Char.isUpper`, `isLower`, `isAlpha` and the rest use eco's fixed tables. In Elm they follow
the host JS engine. Linked to the Unicode version pin in §2.

### 5.8 Lone surrogates in String

eco keeps UTF-16 index semantics for `String.length`, `slice` and so on
(`design_docs/utf8-string-encoding-investigation.md`), so these match Elm. Lone surrogates are
the documented caveat: *TODO: state what `String.toList`, `Char.toCode`, `String.reverse` and
UTF-8 encoding (Bytes, I/O) do with them, compared with JS.*

### 5.9 Stack depth

Elm overflows the JS stack on deep non-tail recursion, at around 10k frames depending on the
engine, with a catchable `RangeError`. eco runs on the native stack: the limit is different
(usually far larger) and overflow is a hard crash (SIGSEGV). Programs can work in one and fail
in the other. *TODO: decide whether eco should detect stack overflow and report a clean error.*

### 5.10 Scheduler, Task, Cmd and Sub ordering

The order in which eco's scheduler runs Tasks, Cmds, subscriptions and `Process.sleep`
callbacks may differ from Elm's JS scheduler. It matters only for programs that depend on
that order (Elm does not guarantee it), but ported code can quietly rely on it. *TODO: list
what eco guarantees.*

---

## 6. Summary table

| Behaviour | Elm 0.19.1 (JS) | eco |
|---|---|---|
| `2 ^ -1 : Int` | `0.5` (a Float in an Int) | `0` |
| Int range | 53-bit, silent rounding | 64-bit, wrapping |
| `truncate 3e9` | `-1294967296` (32-bit) | `3000000000` |
| `x // 0` | `0` | `0` |
| `round (0/0)` | NaN in an Int | *TODO* (proposed `0`) |
| `Char.toUpper 'ß'` | `"SS"` in a Char | `'ß'` |
| `nan == nan` | `False` | `False` |
| `(nan, nan) == (nan, nan)` | `True` if same object | `False` |
| `nan < 1`, `nan > 1` | depends on syntax | `False`, `False` |
| `compare nan 1` / `compare 1 nan` | `GT` / `GT` | *proposed* totalOrder: `GT` / `LT` |
| `max nan 1` vs `max 1 nan` | differ | both NaN (proposed) |
| Dict/Set/sort with NaN keys | broken | correct (with totalOrder) |
| `(\x -> x) == (\x -> x)` | runtime error | `False` |
| `Debug.log` with `--optimize` | compile error | allowed, output kept |
| `String.toInt "9007199254740993"` | rounded | exact |
| `Bitwise` width | 32-bit | *TODO* |
| `Random` sequences for a seed | reference | *TODO* (may differ) |
| Deep recursion | `RangeError` at ~10k frames | larger limit, SIGSEGV |

## 7. Open items

- Float → Int conversion of NaN, Infinity and out-of-range values (currently C++ UB).
- `modBy 0` / `remainderBy 0`: make total, or document as exceptions.
- `compare` on Float: totalOrder or not.
- Remove any identity shortcut in structural equality, then allow constant extraction.
- Add E2E tests for every row in the table above.
- Bitwise op width.
- Pin the Unicode version.
- Function equality: keep `False`, or reject statically.
- `Debug` under `--optimize` on the native path.
- Every suspected item in §5: check it, then move it to §4 or delete it.
