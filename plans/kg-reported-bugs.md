---
status: done
updated: 2026-11-03
---

# Fix the bugs kg reported against eco 0.2.0

`eco-bugs.md` lists eleven bugs found while building kg. This plan fixes the ones that are eco's to
fix, plus one API gap the discussion of number 11 turned up. The numbers below are the ones in
`eco-bugs.md`.

**Out of scope.**

- **3, 64-bit `Bitwise`.** This is eco's intended semantics, not a bug.
- **11, the bundled `eco/kernel` being behind master.** kg built against the compiler's own sources.
  Real programs use `eco/system`, so this is not a user-facing problem.

## Method: reproduce first, then fix

Every bug is handled in two steps, in this order:

1. **Reproduce.** Add an E2E test that shows the bug, with its expectations recorded from Elm on
   node (`node test/scripts/run-js-e2e.js --project <name> --record <TestName>`). Mark it
   `-- XFAIL-NATIVE: bug, plans/kg-reported-bugs.md step N`, and check that it fails natively for the
   reason the report gives. If it passes on the current tree, the bug is already fixed on master: drop
   the XFAIL line, keep the test as a regression test and record that here. Performance bugs are
   reproduced with a benchmark and a recorded measurement instead of an XFAIL test.
2. **Fix.** Only after the reproduction is in. Remove the XFAIL line in the same change: the harness
   reports XPASS if a test passes while still marked.

Gate for each step: `cmake --build build --target full` (filtered with `TEST_FILTER` while
iterating, run in full once at the end of the step), and `elm-tests` for compiler changes. Read
`design_docs/invariants.csv` before any kernel or runtime change. The kernels touched here build heap
objects, so REP_HEAP_001, MONO_006, CGEN_026 and HEAP_019 apply.

## Step 1: `Regex.find` / `Regex.replace` records (bug 1, high)

**Cause, checked against the code.** `createMatch`
(`elm-kernel-cpp/src/regex/RegexExports.cpp:108-122`) writes the fields as
`(index, match, number, submatches)`. The compiler's `computeRecordLayout`
(`compiler/src/Compiler/Generate/MLIR/Types.elm:462`) puts the unboxed fields first, each group sorted
by name: `(index, number, match, submatches)`. The kind mask `0b0101` is a 2-bit-per-slot mask
meaning "slots 0 and 1 are Int". That is already right for the correct order, so only the field order
is wrong.

**Reproduce.** Add `test/elm-conformance/src/RegexMatchRecordTest.elm` covering every field of `Match` from
`find`, `findAtMost` and `replace` with a function, including a submatch that is `Nothing`. None of
the existing regex tests reads `.match` or `.number`.

**Fix.** Write the fields in layout order and fix the comment. Then audit every other kernel that
builds a record or a custom value by hand (`record(`, `custom(`, `eco_alloc_with_roots(Tag_Custom`
across `elm-kernel-cpp`, `eco-kernel-cpp` and `system-kernel-cpp`) against `computeRecordLayout`,
`computeCtorLayout` and the declaration-order constructor tags. The Http records were checked while
writing this plan and are correct. Any other mismatch the audit finds gets its own reproduction test
before it is fixed.

## Step 2: `Json.Decode.Error` (bug 2, high)

**Cause, checked against the code.** `makeErr`
(`elm-kernel-cpp/src/json/JsonExports.cpp:136`) builds every error as a custom value with tag 0 and
fields `(message, [])`. The comment says "Failure", but tag 0 is `Field String Error` (elm/json's
order is `Field | Index | OneOf | Failure`). The compiled code therefore reads `[]` as a nested
`Error`. `Failure` is tag 3 and holds `(String, Value)`. The kernel also never builds `Field`,
`Index` or `OneOf` context: all 18 call sites pass a flat message.

**Reproduce.** Add `test/elm-conformance/src/JsonDecodeErrorTest.elm` that runs `errorToString`, and a `case`
over the constructors, on the report's inputs: parse errors (`"not json"`, `"{\"a\":"`, `"[1,2"`),
`field "a" int` on `{"a":"x"}`, `index 1 int` on `[1]`, `oneOf` with two failing decoders, and
`Decode.fail`. All expectations are recorded from node.

**Fix.** Build real `Error` values:

- `Failure msg value` with tag 3 and the offending JSON value as a heap `Value`.
- `Field` and `Index` wrapping the inner error as the decoder runner unwinds through `DEC_FIELD`,
  `DEC_INDEX` and friends.
- `OneOf` holding the list of alternatives' errors.

Use elm/json's messages verbatim, including the `"This is not valid JSON! ..."` parse failure, so that
`errorToString` matches node byte for byte.

## Step 3: UTF-16 versus code points (bugs 4, 5, 9)

**4: `Match.index`.** `byteOffsetToCharIndex` (`RegexExports.cpp:126`) counts code points. Elm counts
UTF-16 units, as eco's `String.slice` and `String.length` do.

- **Reproduce** in `RegexMatchRecordTest` (or a sibling test) with `"a😀b"`: the index should be 3
  rather than 2, and slicing at the index should give `"b"`. Cover `find` and `replace`.
- **Fix:** count 2 units for a 4-byte UTF-8 sequence and 1 otherwise, and rename the function to
  match.

**5: `String.toList` / `String.foldl`; 9: `'😀'` literal.** Master already steps by code point:
`String.foldl`/`foldr` use `nextCodePoint`/`prevCodePoint`, and the parser's `chompChar` counts a
2-unit character once. Both were probably fixed after 0.2.0 was built (the Char-is-one-code-point work
of 2026-10-30).

- **Reproduce** on the current tree: `String.length`, `String.toList`, `foldl`, `foldr`, `uncons`,
  `map` and `filter` on `"a😀b"`, plus a module containing `c = '😀'`. Add the `Char` literal case to
  the parser's front-end tests too.
- **If they pass,** keep them as regression tests and record "fixed on master" here.
- **If they fail,** fix them under this step.

## Step 4: `Json.Encode.object` key order (bug 10)

**Cause, checked against the code.** `elmToJson`'s `ENC_OBJECT` case
(`JsonExports.cpp:1380`) builds an `nlohmann::json::object()`, which is a `std::map` and so sorts by
key. `addField` conses onto the front, so the list is also in reverse order.

**Reproduce.** Add `test/elm-conformance/src/JsonObjectOrderTest.elm`, recorded from node, covering:

- the report's `[("b",1),("a",2)]` case;
- a duplicate key;
- integer-like keys (`"2"`, `"10"`), which JavaScript objects put first in numeric order: record
  what node really prints and match that;
- nested objects;
- `Encode.dict`;
- `encode` with indent 0 and with indent 4;
- the decode-then-encode round trip of a `Value`.

**Fix.** Emit keys in list order (walk the reversed cons list backwards), using `nlohmann::ordered_json`
or direct serialisation, with JavaScript's handling of duplicate and integer-like keys. Check that
`Json.Decode`'s object path (`keyValuePairs`, `dict`, decoded `Value`s) keeps source order the same
way.

## Step 5: `Terminal.isTerminal` (API gap from bug 11, option (a))

eco/system can only ask about stdout (`Terminal.configuration` gives `Nothing` unless `isatty(1)`). A
program can't tell whether stderr or stdin is a terminal, which the compiler itself needs to decide
on colour for stderr (`Builder/Reporting/Exit/Help.elm:186`).

**Reproduce.** This isn't a bug, so there is nothing to XFAIL. Write the test first instead: an
eco/system E2E test with each standard stream redirected to a pipe or file and checked, plus a pty
case if the harness can provide one (`test/scripts/cli-terminal-render.test.js` already drives a
terminal).

**Fix.** Add to `system-kernel-cpp/src/Terminal.elm`:

```elm
type StandardStream = Stdin | Stdout | Stderr

isTerminal : StandardStream -> Task x Bool
```

Implement it in both kernels (`isatty` in `Terminal.cpp`, `require('tty').isatty` in `Terminal.js`)
and document it next to `configuration`. Keep the module rule that a task fails on Windows native: a
Windows `_isatty` version is welcome but unverified, which is fine for Windows. Update the
`ecosyskernel` normative API copy and the docs synced from the stubs.

## Step 6: benchmark coverage for bugs 6, 7 and 8 (no fixes)

eco's performance here is already known to be weak. This plan doesn't fix it: it adds benchmark
coverage to `examples/benchmarks/` so the gaps are measured and tracked. Coverage before this plan:

- **6, lists from `List.take` walk slowly.** No workload walks a list built by `List.take`.
- **7, `Bytes.Decode` loops.** u8 count loops are covered (`bytes-static`, `base64`, `adler32`). Bulk
  `float32` rows and per-row nested decode loops are not.
- **8, decoded data is about 8 times its encoded size.** Nothing measures memory.

**Add:**

- **`list-walk-map` / `list-walk-take`** (`ListOrigin.elm`): the report's `dot` product walked over a
  `List Float` made by `List.map`, and over an equal list made by `List.take`. The two take the same
  work, so their ratio is the bug.
- **`bytes-f32-rows` / `bytes-u8-rows`** (`BytesRows.elm`): encode `size` rows of 384 values, then
  decode them into `List (List Float)` / `List (List Int)` with one `Decode.loop` per row, as kg
  does.
- **`decoded-snapshot`** (`DecodedSnapshot.elm`): decode a binary snapshot of `size` records (a name,
  tags, and an `Array Float` vector) into a `Dict String` of records, and keep it live while it is
  checked.
- **A peak-RSS column in `run.mjs`**, per process, from `/usr/bin/time` where it exists (Linux). This
  is what makes bug 8 visible, and it covers every workload.

Each new workload is also registered in `elm/ElmBench.elm`, and checks its own result like the
others.

## Order

1. Steps 1 and 2: crashes, highest severity.
2. Step 4: a small, self-contained fix.
3. Step 3.
4. Step 5.
5. Step 6.

Each step lands on its own, with its reproduction and its fix as separate commits.

## Outcome (2026-11-03)

The reproduction tests went into `test/elm-conformance`, not the per-package suites: it is the one
suite that runs on both node (where the expectations were recorded) and native, so the JS run checks
the recorded expectations too. It now depends on elm/json and elm/regex as well as elm/core.
`test/CMakeLists.txt` now re-runs the configure step when a test package's `elm.json` changes;
before, the harness kept compiling against a stale copy.

Every reproduction failed natively for the reported reason before its fix: `RegexMatchRecordTest`
and `JsonDecodeErrorTest` segfaulted, `RegexUtf16IndexTest` gave code-point indexes, and
`JsonObjectOrderTest` gave sorted keys.

- **Step 1 (bug 1): fixed.** `createMatch` writes `(index, number, match, submatches)`. The fix
  exposed a further divergence: native `Debug.toString` printed a record's fields in layout order
  (unboxed first), where Elm sorts them by name. Reproduced with new rows in `DebugToStringTest`, and
  fixed in the typed printer (`print_typed_value`, `runtime/src/allocator/RuntimeExports.cpp`).

  **Kernel audit** (every record, custom and tuple a kernel builds or reads, in all three kernel
  trees): five more mismatches, the rest OK. Each real one was reproduced first:
  - `Json.Decode.array` took its elements' slot kind from the element decoder's constructor, so
    `array (map f int)` or `array (field "v" int)` stored boxed Ints where compiled code reads
    unboxed ones (a segfault). Now from the decoded values, as `list` already did, Chars included.
    Test: `elm-conformance/JsonDecodeArrayKindTest`.
  - `Bytes.getHostEndianness` took no arguments and returned a raw word, though elm/bytes calls it
    as `getHostEndianness LE BE` and expects a Task (a segfault). It now succeeds with the argument
    for the host's order. Test: `elm-conformance/BytesHostEndiannessTest` (the project now depends
    on elm/bytes too).
  - The Http response `Metadata.headers` Dict was a right-leaning chain with `()` as every node's
    colour, so `Dict.remove` on it gave wrong results. It is now a balanced, valid red-black tree.
    Test: `elm-http/HttpResponseHeadersDictTest`.
  - Latent, fixed without a behavioural test (only the heap validator or kind-aware code could see
    them): `Time.every`'s `Every` sub stored its Float interval with the Int kind, and the regex
    handle's three Int fields had kinds Char, Int and boxed.

  Left open, outside this plan (none is a layout mismatch), each looked into afterwards:
  - **Bug, reproduced, then fixed:** the Http kernel read every request body and multipart value
    as a String. `Http.bytesBody` sends NUL bytes of the right length (`"hello bytes"` arrives as 11
    NULs), and a `bytesPart` loses its content and Content-Type; `bytesToBlob` also names its
    parameters in the opposite order to the Elm call. `fileBody` / `filePart` read the same way but
    cannot be reached headless (a `File` only comes from a browser). Test:
    `elm-http/HttpBytesBodyTest`. Fixed: a body or part is read by its kind (a String's UTF-8, a
    Bytes value's raw bytes; a NUL byte arrives intact), a `bytesPart` is sent as a browser sends a
    Blob (`filename="blob"` and its own Content-Type), and `bytesToBlob` takes `(mime, bytes)`.
  - **Bug, dormant, reproduced, then fixed:** `Eco.Runtime.loadState` before any `saveState` answered
    the Empty constant (Nothing's word) where its doc and JS twin answer JSON `null`: it encodes as
    `null` but `Decode.null` rejects it. Nothing in the repository calls `loadState`. Test:
    `eco-kernel/RuntimeLoadStateEmptyTest` (the project now depends on elm/json directly). Fixed: it
    answers `Json.Encode.null`.
  - **Not a bug:** Html.Dom's opaque `Tagger` / `Handler` (declared nullary, holding a closure or
    handler at run time). No code outside the module can build or match them and the module never
    looks inside, so the declaration only shows through generic code. Checked on both backends:
    `Debug.toString` prints `<internals>` natively (`<function>` / `Normal <internals>` on JS),
    a rebuilt `Mapped` node renders the same, and `==` on two different taggers is `False` natively
    where JS throws, which is eco's documented `==`-on-functions divergence
    (`design_docs/elm-divergence.md` §4.1).

- **Step 2 (bug 2): fixed.** The kernel builds real `Error` values with elm/json's messages:
  `Failure` (tag 3) with the offending value, `Field` / `Index` as the runner unwinds, `OneOf` with
  every alternative's error, the first failing list element / object member (the list and key/value
  decoders rescan from the front on failure), and `"This is not valid JSON! "` plus the parser's
  message for a parse error. `JsonDecodeErrorTest` (28 rows) matches node byte for byte, except the
  JavaScript engine's own parse message, which it does not check.
- **Step 3: bug 4 fixed; bugs 5 and 9 were already fixed on master.** `Match.index` counts UTF-16
  units, with an incremental counter (the old code rescanned from the string's start for every
  match). `NonBmpStringTest` and the new character-literal cases in
  `compiler/tests/Parse/StringTests.elm` passed before any change and stay as regression tests.
- **Step 4 (bug 10): fixed, on decode as well as encode.** `json::parse` sorted keys too, so
  `keyValuePairs`, `dict` and a decoded `Value` were also in sorted order. The kernel now uses
  `nlohmann::ordered_json` and puts every object into JavaScript's key order (array-index keys
  first, numerically; a repeated key keeps its first position and its last value). Parsing goes
  through a SAX builder that appends members, because `ordered_json`'s own parser looks every key
  up linearly: `RootStackJsonLargeKeyValueTest` (4.3 M keys) timed out until then.
- **Step 5: done.** `Terminal.StandardStream` and `Terminal.isTerminal` in both kernels.
  `TerminalTest` checks all three are `False` under the harness. Checked by hand under a pty
  (`script -qec`), native and JS: `True` for each stream on the terminal and `False` for one
  redirected to a file or pipe. The `ecosyskernel` stubs repository is not in this tree, so its copy
  of `Terminal` still needs the new API.
- **Step 6: done.** Workloads `list-walk-map`, `list-walk-take`, `bytes-f32-rows`, `bytes-u8-rows`
  and `decoded-snapshot`, and a peak-RSS column in `run.mjs`. First run (warmup 1, runs 3, dev
  build of master):

  | workload | elm ms | eco-native ms | elm MiB | native MiB |
  |---|---|---|---|---|
  | list-walk-map | 206 | 197 | 60 | 24 |
  | list-walk-take | 206 | 329 | 60 | 24 |
  | bytes-f32-rows | 219 | 55 | 264 | 319 |
  | bytes-u8-rows | 243 | 59 | 528 | 295 |
  | decoded-snapshot | 241 | 121 | 227 | 355 |

  A `List.take` list walks 1.7 times slower than an equal `List.map` one (the report measured 4 to 12
  times inside kg). Native peak memory is above Elm's on `bytes-f32-rows` and `decoded-snapshot`.

**Gates.** `elm-tests` 14,577 + 918 passed. `full`: native E2E 2,583/2,583, eco/system core tests,
JS E2E 229/229, node-addon and driver-cli all passed. Three E2E tests (`elm/TypeAliasCtorTest`,
`WideRecord33Test`, `WideRecord40Test`) had pinned the old layout-order `Debug.toString` output; their
CHECK lines now hold Elm's order, checked against the official compiler on node. The changed kernel
files moved their license pins: every kernel they hold was re-audited (70 lines in
`kernel-license-audit.csv`; `Bytes.getHostEndianness` only now meets A3, its arity) and the manifest
updated.

**Left for later, outside the code:** the changes are not committed (git cannot run in this
worktree), and the `ecosyskernel` stubs repository, not present here, needs `Terminal.StandardStream`
and `Terminal.isTerminal`.

## What this plan achieves

- **Regex and JSON errors work.** `Regex.find`/`replace` and `Json.Decode.Error` give correct values
  instead of crashing, and `errorToString` output matches Elm exactly. kg's workarounds in
  `Kg/Re.elm`, `Mcp/Protocol.elm` and `Kg/Args.elm` can then go.
- **The kernel-layout class of bug is audited once,** across all three kernel trees, rather than found
  one crash at a time.
- **Strings match Elm outside the BMP:** match indexes are UTF-16 units, and `String` walking and
  `Char` literals are confirmed on master.
- **JSON output keeps the order the program gave,** so golden files and signatures over JSON match
  Elm's output.
- **eco/system programs can ask whether any standard stream is a terminal.**
- **The three performance reports become benchmark workloads,** with peak memory reported, so they
  can be tracked without being fixed here.
- **Every bug fixed here has a permanent E2E test.** These are the tests kg's notes say to rerun
  before removing a workaround.
