---
status: done
updated: 2026-11-05
---

# Removing the dead code in plans/dead-code-report.md

This plan carries out the 433 dead items in `plans/dead-code-report.md` (the report). Items are
named `<area>#<n>` after the report's tables: `b1#4` is item 4 of "Area: b1-format", and `b6 L3`
is row L3 of "Area: b6-front". This plan does not repeat an item's evidence or proposal. It says
**when** each item is done, **which variant** is chosen where the report offers several, and
**what checks it**.

## 1. Why neither "all at once" nor "one at a time"

Removing an item can go wrong in two different ways, and they need different checks.

1. **Editing error.** The edit breaks live code: a restructure (fix option 2) rewrites a live
   function wrongly, or a deletion takes a live arm with it. The Elm compiler catches most of these
   at build time. A diff of the compiler's output over a large corpus catches the rest, because
   every item here must leave the output of every program unchanged (section 3).
2. **Wrong deadness claim.** The code was reachable after all, so the default (option 3) or crash
   (option 4) is now taken. No test can catch this: the code is unhit by every test, which is what
   put it in the report. The audit already found 15 exclusion reasons that were wrong. The defence is
   in the edit itself. Prefer a loud crash to a silent default when the evidence is `invariant
   (weak)`, and keep the report's "keep" verdicts.

So the size of a batch should follow how well the build and the output diff can localise an
editing error. It should not follow the item count.

- **One at a time** costs 433 gate runs. Each item would be checked as strictly as a batch is,
  because every item has the same oracle.
- **All at once** costs one gate run. A failure would then point into about 15,000 changed lines,
  and the shared IR changes (decision trees, typed graph, Mono IR) would interact with the local
  ones.
- **In between (this plan).** Make small edits, each followed by a cheap build check (G0). Take a
  snapshot per area or theme. Run the expensive gate once per **wave** of independent edits, and
  once per **theme** for each change to a shared IR type or codec. That is about 15 expensive gate
  runs in total. When one fails, the output diff, the failing test name or a bisection over the
  snapshots finds the edit.

## 2. Sequence at a glance

| Wave | What | Items | Gate |
|---|---|---|---|
| W0 | Setup: baselines, output corpora, determinism check, policy decisions | none | establishes the baselines |
| WF | Formatter track (`Common.Format.*`, self-contained, no tests today) | b1 except #4/#5/#8/#13 | G-format |
| W1 | Local deletions, defaults and crashes (fix options 1/3/4, one module, no shared type) | about 150 | G-wave per sub-wave: W1a front + builder, W1b mono, W1c codegen |
| W2 | Local restructures (option 2 inside one area, no shared IR type, no on-disk codec) | about 110 | G-wave per sub-wave: W2a, W2b, W2c |
| W3 | Cross-cutting themes A-P (shared IR types, codecs) | about 60 | G-wave per gate group (6 groups) |
| W4 | Changes that need a decision (tuple arity, untracked TOpt variants, warnings, public Http API, Char code point) | up to 15 | G-wave per decision taken |
| W5 | Closeout: exclusions, coverage re-baseline, invariants, final gates, report status | none | G-final |

The order is W0, WF, W1, W2, W3, W4, W5. WF may run alongside W1 because it touches only
`Common.Format.*`. Deletions come before restructures, and local changes before the themes,
because each wave shrinks the code the next one rewrites. For example, W1 deletes the Bool fan-out
(b4#4) before theme B rewrites FanOut.

The "keep" items (about 75, listed in section 9) need no code change. They are dealt with only in
W5's exclusions pass.

## 3. Gates

All test runs follow CLAUDE.md: run once, `2>&1 | tee` to a file under `/tmp/`, and read the
file; never run again just to see more output. `ulimit -c 0` always.

**G0: build check, after every item or small group (minutes).**
1. `cmake --build build --target guida`: the Elm type checker over `compiler/src`.
2. Only when the item touches an export that a test uses: compile the test tree. Use
   `build/toolchain/bin/elm-test-rs --project build/compiler/build-xhr --fuzz 1 --filter <Module>`,
   which also runs that module's tests (filtering is allowed, the "run once" rule is about a whole
   suite).
3. For an item that touches `src-xhr`/`eco-kernel-cpp` twins (b8#4 only), also build `eco-boot`.

**G-wave: per sub-wave or theme group (the expensive gate).**
1. `cmake --build build --target elm-tests 2>&1 | tee /tmp/dc-elmtests.txt`
2. `sh compiler/scripts/coverage/e2e-after-compiler-change.sh`. It rebuilds guida.js, moves the
   `eco-stuff` and `~/.eco` artifact caches aside, and runs the JIT E2E once into
   `/tmp/test_output.txt`. It also regenerates every corpus `.mlir`.
3. **MLIR identity:** `test/scripts/dc-corpus.py mlir <dir>` copies
   `build/test/*/eco-stuff/mlir/*.mlir` (about 1,500 files) into `<dir>`, and the script then
   diffs against `/tmp/dc-baseline/mlir`. **Expected: no difference.** A difference is an editing
   error or a refuted deadness claim (section 8). It is never "expected churn".
4. **JS identity** (only if the wave touched `GenerateJs`, `LocalOpt/Erased`, `Nitpick`, `Docs`,
   `Json`, `Text.PrettyPrint`): `test/scripts/dc-corpus.py js <dir>`, then diff.
5. **CLI tests** (only if the wave touched `Builder.*`, `API.*`, `Terminal.*`, `Reporting`, error
   types): `node --test test/scripts/cli-*.test.js 2>&1 | tee /tmp/dc-cli.txt`.
6. **Format identity** (only for WF and theme L): `test/scripts/dc-corpus.py format <dir>`, then
   diff.

Expected counts are the W0 baseline counts, except for tests the wave deliberately deletes or
adapts. Each sub-wave's notes list those (section 7).

**G-format** (WF only): G0, elm-tests, and format identity. No E2E, because the formatter is not
on the MLIR path.

**G-final** (W5): G-wave, plus `cmake --build build --target bootstrap` (stages to 9b, about
47 min, run in the background), `run-aot-e2e`, the stress suite, and `cov.py baseline` (about
21 min).

## 4. W0: setup (no compiler changes)

W0.1 **Snapshot.** Run `benchmarks/lss-loop-snap.sh snap dc-base`. Snapshot again after each
area or theme in W1 to W4 (`dc-w1a-b6`, `dc-thmB`, ...). Git is not usable in this container, so
the snapshots are the rollback and bisection tool. Prune the snapshots of a wave once its gate is
green.

W0.2 **Write `test/scripts/dc-corpus.py`** (it is kept; later work that should not change the
output can use it too). Subcommands:
- `mlir <out>`: copy every `build/test/*/eco-stuff/mlir/*.mlir` to `<out>/<pkg>/`.
- `js <out>`: for every test that `test/scripts/run-js-e2e.js` builds, compile it with
  `build/compiler/build-xhr/bin/guida.js make` three times: plain, `--optimize`, and `--debug`.
  Write the outputs to `<out>/<mode>/<test>.js`. Also run `eco make --docs` on
  `eco-kernel-cpp` (the `eco-system-docs` target's command) and save `docs.json`. This
  covers b3's Prod-only arms (b3#9-#11) and the docs path (b3#14).
- `format <out>`: build `API.Main` to a temporary file the way `test/scripts/cli-errors.test.js:291-300`
  does, then run `{"command":"format","content":...}` over every `.elm` under `compiler/src`,
  `test/elm/src`, `eco-kernel-cpp/src` and `test/*/src`. Write each response to
  `<out>/<path>.json`. Error responses count as output too.
- `diff <a> <b>`: `diff -r --brief`, then the first 40 lines of the first three differing files.

W0.3 **Baseline and determinism.** Move the caches aside, run `e2e-after-compiler-change.sh` once,
and run `dc-corpus.py mlir /tmp/dc-baseline/mlir`. Then run `dc-corpus.py mlir` again **after
recompiling only the `.mlir` files** (delete `build/test/*/eco-stuff/mlir` and rebuild them with
`TEST_FILTER=` the same suite run once more; this one rerun is the determinism check, not a test
rerun). Diff the two. Do the same for `js` and `format`. If anything is nondeterministic,
normalise it in `dc-corpus.py` (for example, temp paths), or make it deterministic first. Record
the baseline counts: elm-tests, JIT E2E, JS E2E, CLI tests, `.mlir`/`.js`/format file counts.

W0.4 **Policy decisions** (defaults below; the user may override):
- **P1 test hooks** (b4#1, #53, #102, #135; b5#2, #3, #5, #97, #98, #112, #113; b6 T4, T5, M11,
  M12; b7#2, #3):
  - (a) A test that only tests the hook goes, together with the hook: b6 M11, b6 T4 test 6,
    b4#104 `grow`, b4#105 SkelFuzz properties.
  - (b) A hook that only builds fixtures for real tests moves into a test helper module under
    `tests/<same folder>/` (TEST LAYOUT RULE): b4#1 rewritten against `promotableCtorCall`, b4#53
    and #135 (`generateMlirModule`/`generateProgram`/`ppModule` to a test helper), b5#2, #3,
    #5 `assignIdsToType`, b5#97, #112, #113, b6 M12, b7#2, b7#3.
  - (c) A hook that exposes private state for an audit test stays, with a `-- test hook` doc line
    and an elm-review ignore: b5#98 `KernelSetFacts.rows`, b6 T5, b4#102 `analyzeDefForTest`.
- **P2 codec tags:** when a constructor goes, renumber the later tags (the codecs are MVar-only or
  versioned). Bump `typedGraphFormatVersion` (IR/Typed/Optimized.elm:1778) in every theme that
  changes the typed graph layout. For any other codec, first check whether it reaches disk: follow
  its encoder to a `File.writeBinary`/artifact writer. If it does and the format has no version
  byte, add one in that theme. If it does not, there is nothing more to do.
- **P3 fallback strength:** where the report gives "option 3 or option 4" and the evidence is
  `invariant (weak)`, choose the crash. Where it is `types` or `callers` (local, checkable), choose
  the default. Write each new crash message as `"<Module>.<fn>: <invariant id or one-line
  reason>"`.

## 5. WF: the formatter track (b1)

The formatter is reachable only through `API.Main format`, and no test covers it. Its oracle is the
format corpus. Order inside the track:

1. Deletions: b1#2, #9, #21, #22, #23, #24, #28, #29, #31, #32, #33, #34; the options 3 #3 and #11.
   For #2 and #3, delete the three `pleaseReport*` helpers once their last callers are gone. For
   #21, delete `RWS.error`. For #22, delete `showParseError`.
2. `Cheapskate` restructures: #20 (drop `Document` from `ContainerType`), #25, #26 (delete the
   `ReferenceMap`/`remap` pipeline; it is option 1 but a large edit, so take a snapshot before
   it), #27, #30.
3. `Box` and `ElmStructure` non-empty signatures: #10, #16, #17, #18, #19 (`stack1 : Box -> List
   Box -> Box`, about 50 call sites).
4. `Render.Box` local types: #1, #6, #7, #12, #14, #15. Do #1, #6 and #15 together, because
   `Ref.OpRef` disappears with the three.

b1#4, #5, #8 and #13 change `Src` types, so they go to theme L (W3). Until then they stay as they
are.

Gate: G-format once at the end of the track, plus a snapshot per step.

## 6. W1 and W2 item lists

The report's proposal is followed as written unless a note says otherwise.

### W1a: front end and builder (b2, b3, b6, b7, b8)
- b2#1, #6.
- b3#1 (also delete `Name.replValueToPrint` and collapse `CodeGen` to a function; keep `Output`
  as it is), #8 (option 3), #10 (fold into the Enum arm), #11, #14 (explicit crash).
- b6 C6 (light variant only: delete 720-722; the `Src.Binops` NonEmpty is theme L), L8, L9, L11,
  L15, L20 (crash), L21 (consolidate into `findAnnotation`), L23 (delete `catchMissing`); T4 and T5
  (by P1), T6, T10, T12, T13, T19, T27, T29, T30, T31, T35; M1, M2, M7, M8 (crash), M11, M12.
- b7#1, #2 and #3 (by P1; `varSupersOfType` goes with b5#5's `assignIdsToType`), #11, #12, #13,
  #14, #16.
- b8#1, #2, #6, #11, #13.

### W1b: mono and pre-mono (b5)
- b5#1, #3, #4, #5, #7, #10 (rewrite `lookupUnion` as the `Maybe.andThen`, keep the crash), #13,
  #15, #16, #17 (also remove the census line in Builder/Generate.elm:1097), #21 (1157 only), #22,
  #23, #28, #29, #30, #31, #32, #37, #38, #50, #52 (656-661 only), #53, #56, #59, #60, #62, #65,
  #66, #71 (5441 arm only), #72, #80, #81, #82, #86, #87, #92, #93, #94, #97, #105, #106, #112, #113.

### W1c: codegen and MonoOpt (b4)
- b4#1, #2, #4, #6, #7, #9, #15, #17 (crash), #22, #26, #27, #28, #29, #30 (#27/#28/#30 become one
  `layoutDisagreement` helper), #35, #38 together with #72, #39 (`Registry.keyOf`), #40, #41, #43,
  #49, #53, #59 (crash), #60, #66, #73, #78, #80 (also update the REP_SSA_001/CGEN_009 rows in
  `design_docs/invariants.csv`), #83, #84 (crash), #85 (also adapt
  `tests/SourceIR/CovBytesFusionCases.elm`), #86, #87 (`viewUnaryClosure`), #94 (crash), #95, #99
  (crash citing REP_SSA_001), #101 (deletes BorrowFenceTest's use, by P1), #102, #103, #104, #105,
  #107, #108, #113, #118, #125, #129, #131, #132, #133, #135.

### W2a: front end and builder restructures
- b2#2, #5.
- b3#3, #4 (full variant: `WhileTrue Stmt`), #5, #6, #7, #9, #16, #18, #19.
- b6 C4, L10, L17; T1, T2, T3, T14, T16, T18, T25, T26, T32, T37; M4 (`toKernel`), M5.
- b6 M6 only if T13's "no gaps" claim (SolverRoots:138) holds on inspection. Otherwise it moves to
  the keep list.
- b7#5, #15, #17 (`solved` carries deps).
- b8#7, #8, #10 (one `Maybe { typedGraph, typeEnv }`), #12, #15.

### W2b: mono and pre-mono restructures
- b5#2 and #43 together (`EntryPrep.Assigned` gets `entryHome : ModuleName.Canonical` and the
  `flags` record; update both engines and the three tests).
- b5#8, #9, #33, #34, #35 (`Registry.foldlLive`, which also absorbs #38's merge arm), #36, #39,
  #41, #51, #54 and #55 together, #61, #73, #77, #83, #84, #85, #88, #89 and #90 together (one
  `lambdaArity` helper), #99, #100, #102, #108, #109, #111.

### W2c: codegen and MonoOpt restructures
- b4#8, #10, #11, #12, #13, #16, #18.
- b4#19 small variant (one `uncons`), together with #25 (`StringLiteral.codePoints`). Use
  `codePoints` in `Expr` too where the Char text is in `writeCode` form. Check that it is before
  replacing `decodeEscape`.
- b4#34 (`TupleSlots`, codegen-local; it does not wait for theme C), #42 and #63 together
  (`compileTailFuncToWhile` returns body and terminator), #45, #50, #58, #62, #65, #67, #68, #74,
  #75 and #76 together (`SlotType`), #77, #79, #82, #88, #89, #92, #93, #97, #100, #106, #109,
  #110, #111, #112, #114, #115, #116, #119, #121, #122, #124, #127, #128, #130, #134.

## 7. W3: themes, in order

Each theme is one snapshot. Its sub-steps get a G0 each. Themes that share a gate group are
independent of each other and touch disjoint modules.

**Gate group 3.1: theme A, never-constructed typed-IR constructors.** b5#6, #42, #67, #91; b6 L16;
b7#6, #7, #8, #22. Remove `TOpt.Kernel`, `TOpt.ArrayIndex`, `TypedPath.HintUnknown`, and the
`EffectsType` payload of `TOpt.Manager`, with every arm the report lists. Delete
`computeArrayElementType`. Bump `typedGraphFormatVersion` 3 to 4. Wipe `~/.eco` artifacts before
the gate (the e2e script does).

**Gate group 3.2: theme B, decision trees.** Erased and Typed twins move together in every step.
- B1: in both `DecisionTree` modules, `flatten` yields a module-local `FlatPattern` without
  PTuple/PUnit/PAlias/one-alternative PCtor (b6 L3, L4, L6). Remove `Test.IsTuple` (b7#9) and its
  arms in GenerateJs (b3#12 part) and GenerateMlir/Patterns (b4#23).
- B2: `Decision Path (NonEmpty (Test, DecisionTree)) (Maybe DecisionTree)` and non-empty
  `checkForMatch`/`bests` (b6 L1, L2, L7).
- B3: FanOut edges are non-empty and use `FanTest = FCtor | FInt | FChr | FStr` in `Opt`, `TOpt`
  and `Mono` (b4#5, #24, #70; b3#12's `SwitchTest`). Chain tests are non-empty too.
- B4: drop `opts` from the `IsCtor` comparable key (b7#10).
- Bump `typedGraphFormatVersion` and apply P2 to the erased graph.

**Gate group 3.3: themes D and E, codegen.**
- D: drop `isTerminated` from `ExprResult`. Add `DeciderResult = Yielded | Valued` and
  `generateBodyExpr` (b4#3, #20, #36, #64). This removes `mkRegionTerminatedByOps` and TailRec's
  1047 crash.
- E: split `kernelConstant` from `kernelIntrinsic` (b4#54), add `GatedCons | GatedPlain` (#55),
  carry operands in the intrinsic (#56), and merge `generateIntrinsicOp` into
  `generateIntrinsicOps` (#57). Do #57 first: it is the smallest, and it deletes the arms that
  would emit wrong code.

**Gate group 3.4: theme F, Mono IR narrowing.** First confirm that Mono IR is never serialised to
disk (grep for Mono encoders reaching a file write). The order:
- F1: `MonoGraph.main : MainInfo` (b5#14). Remove the Backend/ConstThunks `Nothing` arms, give the
  roughly 9 hand-built test graphs a dummy main, and delete BackendNoMainTest. b4#47's no-main
  default stays (it is the bytecode path).
- F2: `MonoCall` with non-empty arguments (b4#117, preferred variant). Also removes Reify.elm:912.
- F3: ctor, enum and manager nodes carry their `Global`/`Canonical` (b4#37).
- F4: port nodes carry `ClosureInfo` and body; `MonoManagerLeaf` carries its function type
  (b4#51).
- F5: `MonoField` and `MonoIndex`/`MonoUnbox` carry the layout entry (b4#31, #32).
- F6: `MonoRecordUpdate` base is a variable (b4#120).
- F7: `OriginPap`/`OriginGlobal`/`OriginCtor` carry home and name (b4#136).

**Gate group 3.5: themes H and I, solver.**
- H: `Engine.withNumberMulti`/`withLocalMulti` (b5#44, #69).
- I: delete the kernel tunnels (b5#70, #78) and `KernelPlan.result` (b5#79, chosen: no
  non-opaque Positional row is planned). Update the `LSS_021` row in
  `design_docs/invariants.csv` and the docs at KernelSetFacts.elm:138.

**Gate group 3.6: small front-end and builder themes** (disjoint modules; run the CLI tests).
- J: `Data.Graph.SCC` with `CyclicSCC vertex (List vertex)` (b6 C7). Adapt the 8 consumers and
  Build.elm:1777.
- K: delete error constructors with no producer: b2#3, #4; b6 C1 (drop the PackageCompilation
  test arm), C2, C3; b8#5. Then narrow `Builder.Http.Error` to `BadHttp String Int String` (b8#3;
  independent of b8#4).
- L: `Src` AST, after checking by P2 whether `Src` reaches disk: remove the `FComment` trick
  constructors (b1#4), `BlockComment String (List String)` (b1#5), non-empty `Src.Union` variants
  (b1#8), non-empty `Src.Call` arguments (b1#13), and `Src.Binops` with its first `(expr, op)`
  separate (b6 C6). Run the format identity check too.
- M: port `Payload` ADT from `Effects.checkPayload`, used by both Port modules and EntryPrep (b6
  L13).
- N: drop `Report.suggestions` and the `suggestions` argument (b6 M14, 283 call sites,
  mechanical). Also delete suggestion lists that were computed only for it.
- O: replace `Extras` with a plain record and bump the `d.dat` format (b7#4).
- P: colours. `SSGR` carries `Leijen.Style`/`Color` (b6 M3), and `displayS` computes the code
  arithmetically (b3#20).

## 8. When a gate fails

1. Read the output file. Do not run again.
2. **An MLIR, JS or format diff:** the changed construct names the item. If the edit is wrong, fix
   it. If the edit is right and the code really was reached, the deadness claim is refuted. Then,
   by the EXPOSE BUGS AS TESTS FIRST rule: restore the item's code from the snapshot, add a test
   (or a `tests/SourceIR` case) that reaches it, add a "Refuted" note to the report row, and move
   the item to the keep list (or the reachable-findings list if the behaviour is wrong).
3. **A test failure with no diff:** the test name gives the module. Check whether it is a test
   that P1 meant to move or delete. If not, treat it as in step 2.
4. **Neither localises:** bisect over that wave's snapshots (restore, `guida`, rerun only the
   failing test with `TEST_FILTER` or `--filter`).

## 9. W4: changes that need a decision

Decided 2026-11-05: the user accepted every recommendation below (D1 do, D2 defer, D3 delete, D4 do,
D5 skip) and the W0.4 policy defaults P1-P3.

| Decision | Items | Recommendation |
|---|---|---|
| D1 tuple arity in the types (`Can.Tuple`/`PTuple`/`TTuple` as `a b (Maybe c)`, `MTuple a b rest`, `TupleShape` in `MonoTupleCreate`) | b3#2, b6 L12, b4#14, b5#101 | **Do it**, as one theme after W3. It touches the canonical AST and the interface format (`.eci`; bump the version). If **no**: apply the crash fallbacks (b3#2 option 4, L12 Erased crash, b4#14 and b5#101 crashes). |
| D2 remove the untracked `TOpt.Function`/`Define`/`VarLocal`/`Record` | b5#19 (+#50, #60, #65, #89, #90, #94, L9, L14, L15 already done in W1/W2) | **Defer.** It is wide (port codecs, record-alias ctors, EtaExpand) for little gain once W1/W2 have removed the dead arms. The arms kept by #19 stay. |
| D3 warnings (`Reporting.Warning`, `addUnusedWarning`, `MissingTypeAnnotation`) | b6 M13 | Delete (instantiate `w` as `()`), unless you want warnings surfaced. That would be a feature, with its own plan. |
| D4 narrow the public `Eco.Http.Error` to `Network | BadStatus` in both twins | b8#4 | Do it. The C++ side is unchanged. Needs the eco-kernel-cpp docs re-synced and the src-xhr twin diffed (ELM-REVIEW STRIPPED TWIN PARAMS memory). |
| D5 Char literal carries its code point from the parser | b4#19 full variant | Skip. W2c's small variant plus `codePoints` removes most of it. |

**Keep list** (no code change; W5 only adds or rewords exclusion rows): b3#13, #15, #17, #21, #22;
b4#21, #33, #44, #46, #47, #48, #52, #61, #69, #71, #81, #90, #91, #96, #98, #123, #126; b5#11,
#12, #18, #20, #24, #25, #26, #27, #40, #45, #46, #47, #48, #49, #57, #58, #63, #64, #68, #74, #75,
#76, #95, #96, #98, #103, #104, #107, #110; b6 C5, C8, L5, L14, L18, L19, L22, L24, T7, T8, T9,
T11, T15, T17, T20, T21, T22, T23, T24, T28, T33, T34, T36, M9, M10; b7#18, #19, #20, #21; b8#9,
#14, #16, #17. Their small optional tidy-ups (for example b5#40's default, b5#103's `errDeep`) are
not done.

## 10. W5: closeout

1. `cov.py exclusions --rewrite` relocates the anchored rows. Delete the rows whose code is gone
   (the script reports them as unmatched). Add the rows the report asks for (b6 C5, C8; b4#91),
   and reword the rows of the keep items whose reasons the report corrected.
2. Run `cov.py baseline` and record the new unhit counts in the report's Totals.
3. Check that `design_docs/invariants.csv` rows touched by b4#80 and theme I agree with the code.
4. Run G-final once.
5. Set the report's front matter to `status: done` (or `partial` with `remaining:` naming the
   deferred decisions), and set this plan's front matter to `done`. Write `commit.txt` per
   GITSTYLE.md, one paragraph per wave, with no attribution trailers.
