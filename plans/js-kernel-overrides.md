---
status: done
updated: 2026-11-19
---

# JS kernel overrides: patch stock kernel code by rebinding, retire replacements.js

`G` = `compiler/src/Compiler/GenerateJs/Generate.elm`. `R` = `compiler/scripts/replacements.js`.
"Stage 1" = `guida.js`, the compiler built from `compiler/src` + `compiler/src-xhr` by stock
`elm make` (`compiler/CMakeLists.txt`, "step 1: XHR").

## 0. Problem, constraint and outcome

eco's JavaScript output sometimes needs a stock kernel function (elm/core, elm/bytes, elm/json) to
behave differently from its published source. Today the only way is `R`, a post-processing script that
searches compiled output for verbatim copies of stock source and replaces them. `R` makes three edits:

| edit | what | problem |
|---|---|---|
| `_Bytes_read_string` | elm/bytes' UTF-8 decoder builds an array and joins it instead of `+=`, so V8 does not keep long concatenated-string chains alive (OOM; guida issue 107) | `String.replace` against ~40 lines of copied stock text: a silent no-op if the text differs. Only the compiler's own builds get it; programs eco compiles to JS do not. |
| `_Json_decodeBytes` / `_Json_encodeBytes` | Bytes through ports | Unused in Stage 1 (stock `elm make` rejects Bytes in ports). eco's backend already emits them (`G`'s `bytesForPorts`), so `R` makes a second copy in `eco-boot*.js`. |
| `Eco.MVar` stash hooks | `stash`, `unstashing`, `unstashingTaken` (`compiler/src-xhr/Eco/MVar.elm`) keep MVar values as JS objects in `bin/eco-io-handler.js` (keep-MVars rule; front-end CPU 698 → 439 s) | Patches eco's own Elm, not a stock kernel. Throws on a mismatch. Unpatched, the hooks encode and decode: correct, only slower. |

`R` runs from eight places: the four JS stages in `compiler/CMakeLists.txt` (Stage 1 `guida.js`,
`eco-boot.js`, `eco-boot-2.js`, `eco-boot-3.js`), `compiler/scripts/build.sh` (`api|bin`),
`compiler/scripts/coverage/cov.py`, `test/scripts/dc-corpus.py` and `test/scripts/cli-errors.test.js`.
It is cited in `design_docs/theory/workflow/bootstrap.md`, `compiler/src-xhr/Eco/MVar.elm` (twice)
and `compiler/bin/eco-io-handler.js`.

**A bug found by this review: JS source maps are 18 lines off.** `G` emits `bytesForPorts` (18
lines) between the kernel code and the Elm code, but `generateSourceMaps` shifts mappings by the
kernel lines only. Checked on real output: `Main.elm` line 8 (`n * 7919`) is generated line 4441 and
its mapping says 4423. Whatever this plan inserts at that point must be counted, which fixes the bug.

**Constraint: Stage 1 must stay buildable with stock Elm.** It is the bootstrap's root, independent
of eco. Stock `elm make` knows nothing about overrides and rejects kernel code in the compiler's
project, so Stage 1 always needs a post-processing step for what it cannot express. This plan makes
that step generic and strict; it does not remove it.

**Outcome.** Stock kernel code is changed in one way everywhere: override files, emitted by eco's
backend natively and applied to Stage 1 by a small applier that carries no copies of stock source,
checks everything it touches and fails the build on any mismatch. `R` is deleted, the duplicate
Bytes-port definitions and the source-map offset go, and every program eco compiles to JS gets the
`_Bytes_read_string` OOM fix.

## 1. The mechanism: rebinding

Every JS output, eco's and stock Elm's, is one `(function(scope){ 'use strict'; ... }(this))` (checked:
`guida.js` and eco's output). Every kernel function and Elm top-level value is a top-level binding in
that scope (`function` declaration or `var`). A later statement can therefore rebind one:

```js
_Bytes_read_string = F3(function(len, bytes, offset) { ... });
```

and every caller that looks the name up at call time gets the new function, recursive calls
included. Rebinding is sound when (1) the target is a top-level binding, (2) nothing captured the old
value first (a top-level Elm value built at load can hold a closure over it), and (3) the rebinding
runs before the first use.

**Placement guarantees (2) and (3) for kernel targets.** `G`'s `stateToBuilder` emits all kernel code
first (`revKernels`, oldest first), then `bytesForPorts`, then every Elm statement; stock Elm's
generator does the same (checked in `guida.js`: last kernel definition line 2904, first Elm
definition line 2919). Code placed after the last kernel chunk and before the first Elm statement runs
after every kernel definition and before any Elm value exists, so nothing can have used or captured a
kernel function yet. **Kernel overrides go exactly there.**

**Failing loudly.** The output is strict mode, so assigning to an undeclared name throws a
`ReferenceError` at load: an override whose target was renamed breaks every program that includes
it, at once. The applier (§4) checks targets before writing; the tests (§6) load programs that
include every override.

## 2. Override files

Directory `compiler/kernel-overrides/`, one file per override, named `<Name>.js`. A file is a
`/* ... */` header, then the body.

**Header grammar** (one directive per line, nothing else in the comment):

| directive | kind | meaning |
|---|---|---|
| `kind kernel` or `kind value` | both | required, first line |
| `requires <Prefix>.Kernel.<Home>` | kernel | one or more: the override is used only when every named kernel module is in the program |
| `package <author>/<name> <version>` | kernel | one or more: the stock package versions the body was written against (documentation, and checked by the generator against the compiler's own `elm.json` pins, §3.1) |
| `value <js global>` | value | exactly one: the Elm top-level value whose definition the body replaces, e.g. `$author$project$Eco$MVar$stash` |
| `group <name>` | value | exactly one: overrides in one group apply all-or-none (§4) |

**Body rules.**
- Plain JavaScript, emitted as written: it is **not** kernel-parsed, so there are no `__` tags. It
  uses the emitted names (`_Bytes_read_string`, `F3`, `_Utils_Tuple2`, `$elm$core$Result$Ok`).
- It must not read or write record fields: `--optimize` renames record fields (`Mode.shortenFieldNames`)
  and a plain body cannot follow the renaming. Constructor fields (`a`, `b`, ...) and globals are not
  renamed and may be used.
- A kernel body may rebind kernel functions (`_X_y = ...;` at column 0) and define new names
  (`var _X_z = ...;`). Every name it rebinds must be defined by a required kernel module.
- A value body is the complete replacement definition, `var <global> = ...;`, as `R` writes it today.
- Bodies end with a newline; the generator adds one if missing.
- Value overrides are **Stage-1-only**: eco's backend ignores them. Code eco builds itself changes its
  Elm source instead.

**Files after this plan:**

| file | kind | content |
|---|---|---|
| `BytesForPorts.js` | kernel; `requires Elm.Kernel.Json`; `package elm/json 1.1.4` | `var _Json_decodeBytes = ...; var _Json_encodeBytes = ...;`, text from `G`'s `bytesForPorts` |
| `BytesReadString.js` | kernel; `requires Elm.Kernel.Bytes`, `requires Elm.Kernel.Utils`; `package elm/bytes 1.0.8` | `_Bytes_read_string = F3(...)`, the second argument of `R`'s first `.replace`, with `var ` removed |
| `MVarStash.js`, `MVarUnstashing.js`, `MVarUnstashingTaken.js` | value; `group mvar-stash` | `R`'s `replaceDefinition` texts for `stash`, `unstashing`, `unstashingTaken` (expand `unstashingDefinition(name, taken)` into two literal files) |

## 3. eco's JS backend

### 3.1 Generator and generated module

New `compiler/scripts/gen-kernel-overrides.mjs`, modelled on `gen-casemap-tables.mjs`:
- `node compiler/scripts/gen-kernel-overrides.mjs > compiler/src/Compiler/GenerateJs/KernelOverride/Files.elm`
  writes the module; `--check <path>` exits 1 if the file differs from what it would write.
- Reads `compiler/kernel-overrides/*.js` sorted by file name; parses headers (§2), failing with
  file and line on any unknown directive, a missing `kind`, a kernel file without `requires`, a value
  file without exactly one `value` and one `group`, or a `requires` not of the form
  `Elm.Kernel.<Home>` / `Eco.Kernel.<Home>`.
- Checks each `package` line against the pins in `compiler/cmake/bootstrap/build-xhr/elm.json`
  (direct or indirect): a version mismatch fails, so a package bump forces a look at its overrides.
- Emits **kernel overrides only**, as Elm string literals with `\\`, `\"`, `\n`, `\r`, `\t` escaped
  and every other character outside printable ASCII as `\u{XXXX}`:

```elm
module Compiler.GenerateJs.KernelOverride.Files exposing (KernelOverride, all)

{-| GENERATED by compiler/scripts/gen-kernel-overrides.mjs from compiler/kernel-overrides/*.js.
Do not edit; regenerate (see plans/js-kernel-overrides.md). -}


type alias KernelOverride =
    { file : String
    , requires : List ( String, String ) -- ( prefix, home ), e.g. ( "Elm", "Bytes" )
    , text : String
    }


all : List KernelOverride
all =
    [ { file = "BytesForPorts.js", requires = [ ( "Elm", "Json" ) ], text = "..." }
    , { file = "BytesReadString.js", requires = [ ( "Elm", "Bytes" ), ( "Elm", "Utils" ) ], text = "..." }
    ]
```

The module is **committed** (as `CaseMapTables.hpp` is), so every way of building the compiler,
including `build.sh`, `cov.py` and `dc-corpus.py`, which bypass CMake, sees it.
`test/scripts/check-kernel-overrides.sh` runs `--check`; it joins the static checks of `check` and
`full` in `CMakeLists.txt`, next to `check-kernel-c-symbols.sh`.

### 3.2 Selection and section (new hand-written module)

`compiler/src/Compiler/GenerateJs/KernelOverride.elm`:

```elm
module Compiler.GenerateJs.KernelOverride exposing (section, marker)

import Compiler.GenerateJs.KernelOverride.Files as Files

{-| The comment line that opens the override section, in eco's output and in Stage 1's (§4). -}
marker : String
marker =
    "// KERNEL OVERRIDES (compiler/kernel-overrides)\n"


{-| The text emitted between the kernel code and the Elm code: `marker` and the text of every
override whose required kernels all satisfy `isPresent`, in the order of `overrides`; the empty
string when none is chosen. -}
section : (( String, String ) -> Bool) -> List Files.KernelOverride -> String
section isPresent overrides =
    case List.filter (\o -> List.all isPresent o.requires) overrides of
        [] ->
            ""

        chosen ->
            "\n" ++ marker ++ String.concat (List.map .text chosen)
```

### 3.3 Changes to `G`

1. Import `Compiler.GenerateJs.KernelOverride as KernelOverride` and
   `Compiler.GenerateJs.KernelOverride.Files as KernelOverrideFiles`, and add a function used by both
   the code and the source map, so the two cannot disagree again:

   ```elm
   {-| The text before the Elm code: the kernel code, oldest first, then the override section. -}
   kernelSection : State -> String
   kernelSection (State (JS.Builder b) seen) =
       String.concat (List.reverse b.revKernels)
           ++ KernelOverride.section (isKernelPresent seen) KernelOverrideFiles.all

   isKernelPresent : EverySet String Opt.Global -> ( String, String ) -> Bool
   isKernelPresent seen ( prefix, home ) =
       EverySet.member Opt.toComparableGlobal (Opt.toKernelGlobal prefix home) seen
   ```

   (`String.concat (List.reverse revKernels)` is what `prependBuilders b.revKernels` produces today.)
   A kernel global is in `seen` exactly when its text was emitted, except the debugger kernel in a
   non-debug build, which no override names.
2. `stateToBuilder (State (JS.Builder b) _ as state) = kernelSection state ++ b.revBuilders`.
3. In `generateSourceMaps`, `kernelLeadingLines` = the number of `'\n'` in `kernelSection state`
   (replacing the count over `stateKernels`). This removes the 18-line offset.
4. Delete `bytesForPorts`, its use and its docstring; it is now `BytesForPorts.js`. Update `generate`'s
   docstring ("a few definitions that let ports carry `Bytes`" → "the kernel overrides of
   `compiler/kernel-overrides`, `Compiler.GenerateJs.KernelOverride`").
5. Delete `stateKernels` if nothing else uses it.

Output change: `_Json_decodeBytes` moves after the marker; programs gain the `_Bytes_read_string`
rebinding whenever the Bytes kernel is present. No other output changes.

## 4. Stage 1: `compiler/scripts/apply-overrides.js`

`node compiler/scripts/apply-overrides.js <output.js>` rewrites one stock-Elm output in place
(write to `<output.js>.tmp`, then rename). It reads `compiler/kernel-overrides/*.js` itself with the
same header rules as §3.1 (factor the header parser into `compiler/scripts/kernel-overrides-lib.js`,
required by both scripts). It knows no stock source text. Steps, each failing with a message naming
the file and override:

1. **Not already applied:** fail if the output contains the marker (catches a double run).
2. **Value overrides, by group.** For each group: for each member, count lines matching
   `^var <global> = ` exactly. If every member has 0, skip the group (eco-built compilers have a
   native-style MVar). If every member has exactly 1, replace each definition span. Anything else
   (some 0, or any >1) fails. A **definition span** runs from the definition line up to, not
   including, the next line that starts with `var ` at column 0; every other line in it that starts
   at column 0 must consist only of closing brackets and `;` (e.g. `}`, `};`, `});`), otherwise fail.
3. **Boundary:** B = the first line matching `^var \$`. Fail if there is none.
4. **Kernel presence:** `<Prefix>.Kernel.<Home>` is present iff some line above B matches
   `^(var|function) _<Home>_` (for an `Eco` prefix, `_Eco_<Home>_`).
5. **Kernel overrides,** sorted by file name: keep those whose required kernels are all present. For
   each kept body, every column-0 assignment `^(_[A-Za-z0-9_]+) = ` must name something defined above
   B by `^var <name> =` or `^function <name>(`; otherwise fail.
6. **Insert** `"\n" + marker + bodies` immediately before line B (the same text eco's backend emits).

Callers, all switched from `R`: the Stage 1 command in `compiler/CMakeLists.txt`; `build.sh`;
`cov.py` (on `fake-elm` output; its coverage-fixture check stays after the call); `dc-corpus.py`;
`cli-errors.test.js`. `COMPILER_CONFIG_FILES` lists `apply-overrides.js`, `kernel-overrides-lib.js` and
the override files (`file(GLOB ... CONFIGURE_DEPENDS)`) instead of `R`.

The eco-built stages (`eco-boot.js`, `eco-boot-2.js`, `eco-boot-3.js`) get no post-processing at all:
eco's backend emits their kernel overrides, and they have no MVar hooks.

## 5. SeqDict `==` on JS (first package-side user; separate work)

eco/system's SeqDict needs `_Utils_eqHelp` to compare two SeqDicts by their entries on JS. It should
**not** be a compiler override: `Elm.Kernel.Utils` is in every program, so the wrapper would cost every
`==` in programs that never use SeqDict. It belongs in eco/system's own `src/Eco/Kernel/FNV.js`, which
is in a program exactly when SeqDict is, runs after Utils (it imports it) and, being kernel code,
before every Elm value (§1). There it is kernel-parsed, so it can use `__$field` tags for record
fields. Its prod-mode constructor tag comes from `ctorToInt` in `GenerateJs/Expression.elm`. Same
mechanism, different owner; tracked with the SeqDict JS work.

## 6. Steps

Each step leaves the build and bootstrap working.

1. **Failing tests first** (expose-bugs-as-tests rule).
   - `test/elm-conformance/src/BytesDecodeStringTest.elm`: encode and decode Strings with 1-, 2-, 3-
     and 4-byte UTF-8 characters (`"a"`, `"é"`, `"€"`, `"𝄞"`, a mix, and a 10,000-character String)
     through `Bytes.Encode.string` / `Bytes.Decode.string`; `-- CHECK:` lines recorded from node with
     `node test/scripts/run-js-e2e.js --project elm-conformance --record BytesDecodeStringTest`.
     Passes today natively and on JS; it pins behaviour across the change.
   - `test/scripts/js-kernel-overrides.test.js` (`node:test`), first part: compile a two-module
     program with `--sourcemaps`, as `cli-sourcemap-sources.test.js` does (private `ECO_HOME` with
     `st.src` links), and assert that the mapping of a marked Elm line points at the generated line
     holding it. **Fails today** (18-line offset).
   - New target `run-js-kernel-override-tests` (`node --test test/scripts/js-kernel-overrides.test.js`),
     added to `full` after `run-js-e2e`.
2. **Override files** (§2): the five files, bodies copied from `R` and `G`.
3. **Generator, check, generated module** (§3.1); commit `KernelOverride/Files.elm`; wire
   `check-kernel-overrides.sh` into `check` and `full`.
4. **Backend** (§3.2, §3.3). Unit tests `compiler/tests/Compiler/GenerateJs/KernelOverrideTest.elm`:
   `section` is empty when nothing is chosen; chooses an override only when all its `requires` are
   present; keeps input order; contains `marker` once. Extend the node test: the output of a program
   using Bytes and ports holds `marker` once, `_Bytes_read_string = F3(` once and
   `var _Json_decodeBytes =` once; a program without the Bytes kernel holds no
   `_Bytes_read_string = `; the source-map assertion of step 1 now passes. (`R` still runs on
   `eco-boot*.js` here: its `_Bytes_read_string` edit still matches the stock definition, which the
   rebinding then overrides, and its Json edit adds a harmless second copy. Both go in step 6.)
5. **Applier** (§4): `kernel-overrides-lib.js`, `apply-overrides.js`. Node tests on small synthetic
   outputs: success (kernel override inserted before the first `var $`, value group replaced); a
   second run fails; no boundary; an assignment to an undefined name; a value group with one member
   missing; a duplicated value definition; a definition span with a stray column-0 statement.
6. **Switch and remove `R`:** point the five callers at `apply-overrides.js`; delete the three
   `eco-boot*` `R` commands; delete `R`; update `COMPILER_CONFIG_FILES`; update the references in
   `design_docs/theory/workflow/bootstrap.md`, `compiler/src-xhr/Eco/MVar.elm` (both comments: "replaced
   by the value overrides `compiler/kernel-overrides/MVar*.js`, applied by
   `scripts/apply-overrides.js`"; the keep-name-and-arity rule stays) and `compiler/bin/eco-io-handler.js`.
   Check: `grep -c '^var _Json_decodeBytes = ' build/compiler/build-kernel/bin/eco-boot-2.js` is 1;
   `guida.js` holds `marker` once and the three MVar replacements.
7. **Invariant** `JSGEN_001` in `design_docs/invariants.csv` (category `JS_Codegen`, status
   `enforced`): stock kernel code in JS output is changed only by kernel overrides
   (`compiler/kernel-overrides`), emitted after all kernel code and before all Elm code, and counted in
   source-map offsets; value overrides apply only to Stage 1 outputs; no step edits compiled output by
   matching source text; Stage 1 is built by stock `elm make` with `apply-overrides.js` as its only
   post-processing. Enforced by `check-kernel-overrides.sh`, `apply-overrides.js` and
   `run-js-kernel-override-tests`.
8. **Gates**, once each, at the end: `cmake --build build --target full` (includes the new checks,
   JS E2E and the node tests), `cmake --build build --target bootstrap` (4b, 8c, 9b), `elm-tests`,
   one `python3 compiler/scripts/coverage/cov.py quick` run (its `build_instrumented_guida` applies the
overrides to `fake-elm` output),
   and `compiler/scripts/build.sh api` + `bin`. Compare Stage 2 (`eco-boot.js` build) peak RSS with
   today's (`/usr/bin/time -v`), to confirm the OOM fix still applies where it matters.

Rollback: steps 2–5 add files and leave `R` in place; step 6 is the only one that removes anything and
is reverted alone.

## 6a. Results (2026-11-19)

Implemented as §2–§6 describe; `compiler/scripts/replacements.js` is deleted.

| check | result |
|---|---|
| version check (§7) | `_Bytes_read_string` identical in elm/bytes 1.0.0–1.0.8; the three Json helpers identical in elm/json 1.1.0–1.1.4 |
| source-map test (written first) | failed before the change (Main.elm line 8 mapped to 4423, code on 4441); passes after |
| `run-js-kernel-override-tests` | 12/12: source map, a Bytes-ports round trip through both overrides, no Bytes override without the Bytes kernel, applier success and six refusals, header grammar |
| `KernelOverrideTest` (elm-test) | 5/5; `elm-tests` 21,515 + 918 pass |
| Stage 1 equivalence | from one stock `elm make` output, `replacements.js` and `apply-overrides.js` give identical MVar definitions; Stage 2 `eco-boot.js` byte-identical with either |
| Stage 2 peak RSS, alone, interleaved ×2 | old 1.91 / 1.95 GB, new 1.87 / 1.91 GB, new with the rebinding disabled 1.94 / 2.37 GB; wall 58–60 s each |
| `full` | pass: 3,100 unit + JIT E2E, JS E2E 270 (10 skipped), override tests, node addon, driver CLI, new `check-kernel-overrides.sh` |
| `bootstrap` | pass: 4b, 8c, 9b; `eco-boot.js`, `-2`, `-3` each hold the override section once and one `_Json_decodeBytes` (was two) |
| `build.sh api`, `build.sh bin`, `cov.py quick --e2e-js` | pass; the overrides applied to stock and `fake-elm` output |

One deviation from §6 step 6: `cli-errors.test.js` now also asserts that `apply-overrides.js` exits 0
(it ignored `replacements.js`'s status). The marker check in `apply-overrides.js` matches a whole line,
because the compiler's own output also holds the marker inside a string constant
(`Compiler.GenerateJs.KernelOverride.marker`).

## 7. Risks

- **Stock packages at other versions.** A user program may pin elm/bytes or elm/json at a version
  other than the `package` line, and eco's backend cannot see package versions when it emits code.
  The body reimplements `_Bytes_read_string(len, bytes, offset)` → `(offset, string)` rather than
  patching text, so it is right for any version with that contract. **Before step 2, diff
  `src/Elm/Kernel/Bytes.js` across the published elm/bytes 1.0.x releases** (and `Json.js`'s
  `_Json_decodePrim`, `_Json_expecting`, `_Json_wrap` across elm/json 1.1.x) and record the result
  here; if any release differs in that contract, add its version to the override's `package` lines
  only after checking it. `BytesDecodeStringTest` covers the pinned version only.
  **Checked 2026-11-19:** `_Bytes_read_string` is byte-identical in all nine elm/bytes releases
  (1.0.0–1.0.8), and `_Json_decodePrim`, `_Json_expecting` and `_Json_wrap` in all five elm/json 1.1.x
  releases (1.1.0–1.1.4), fetched from github.com/elm at each tag. Both overrides are right for any
  version a program can pin.
- **Boundary heuristic in Stage 1.** `^var \$` relies on stock Elm emitting no `$`-named top-level
  `var` inside kernel code, true of elm/core, elm/bytes and elm/json today; the applier fails, rather
  than mis-inserting, if a rebound name is not defined above the boundary.
- **Behaviour change for user programs:** they gain the `_Bytes_read_string` fix (same results, less
  memory) and correct source maps.

## 8. Non-goals

- Building Stage 1 with eco instead of stock Elm (§0 constraint).
- Overrides shipped by packages (a declarative header in a package's own kernel file). §5 shows a
  package can rebind from its own kernel today.
- Changing `Debug.toString` or any other elm/core behaviour beyond §0.
