---
status: done
updated: 2026-11-23
---

# Capture-qualified lambda members: split a shared higher-order copy per captured function

## 0. Goal

Give a lambda instance the identity the LSS paper gives it: the lambda **together with the lambda
sets of the function values it captures**. Two copies of one source lambda that capture functions
with different sets then become different members. A higher-order function that receives them is
demanded once per member, and each of its copies sees a one-member set whose only instance it can
call directly. This is the paper's "one copy per set argument", applied to the lambdas that a
higher-order function makes and passes on.

Eco today does the opposite on purpose (§2). A lambda's member is qualified by its enclosing spec's
type with the sets widened away, so every copy of one lambda at one layout shares an id. The callee
then keeps one copy, and AbiCloning declines the call because the copies differ.

### 0.1 The case that prompted this (measured 2026-11-22, default compiler)

`examples/benchmarks`, workload bytes-u8-rows. `List.map f xs = foldr (\x acc -> cons (f x) acc)
[] xs`. Four `List.map` copies in the program share the layout
`(Int -> Encoder) -> List Int -> List Encoder`, with four different `f`s:

- `Encode.unsignedInt8` (bytes-u8-rows, Base64, BinaryFormat, BytesCodec);
- `DecodedSnapshot.encodeRecord`;
- one lambda each in Adler32 and DecodedSnapshot.

Each copy builds its own inner lambda (`Bench_lambda_469`, `_386`, `_3095$cap`, `_3061$cap`). All
four get **one member, 4358**, because the key `l|<raw>|<widened key of the List.map spec>` drops
`f`'s set. So all four demand `List.foldrHelper` at one key, and there is one copy,
`List_foldrHelper_$_704` (four callers), with its `List_foldl_$_705`.

The census confirms it (`ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_CENSUS=1`, per-site rows
`host|spec|member|outcome`):

```
Gelm core List foldrHelper|704|4358|abiMismatch=10
Gelm core List foldl|705|4358|abiMismatch=1
```

The set at those 11 sites is the one-member `{4358}`, but its instances disagree on **capture
layout**: `_469` and `_386` capture nothing, while `_3095$cap` and `_3061$cap` capture one value.
So AbiCloning declines with `abiMismatch`, which is checked before the body fingerprint, and every
per-element call is `segmentation_unknown` / `generic_apply`. bytes-f32-rows avoids this only
because its `List.map` copy, at `(Float -> Encoder)`, is the only one at that layout, so its member
has one instance and its calls are `singleton_fast`.

The same program's totals (baseline for §5 step 0): `dispatchUpgraded=1218`,
`declinedBodyMismatch=125`, `declinedAbiMismatch=77`, `declinedBlocked=2`,
`declinedNoInstance=191`; `layoutQual: mints=3465 shared=508 fallback=0 tieBypass=301`;
`muTie: tied=0`; `join flush: rounds=1 retranslations=2`.

### 0.2 What done means

The mechanism is built as §3 describes. Every gate in §5 step 9 is green. The acceptance criteria
in §5 step 10 hold: the four `foldrHelper` copies split and stamp, no workload's and not the
self-compile's generic dispatch rises, and no wall regression of 5 % or more.

## 1. What the paper does, and where Eco deviates

Sources: `design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md` (rows 103, 107, 134,
228) and `design_docs/theory/compiler/lambda-set-specialization.md`. The paper PDF
(`design_docs/auto-borrow-inference/lambda-set-specialization.pdf`) could not be text-extracted in
the container, so its claims below come from the fidelity mapping's citations.

- **The paper.** A lambda-set element is the lambda term with the types of its captures,
  parameters and result (Fig. 2, 146:6; row 103). Specialization substitutes specialized
  definitions *into* lambda sets (Fig. 10, 146:15; row 134). The inner lambda of `map` specialized
  for `{U8}` and the one specialized for `{encodeRecord}` are different elements, so `foldr` is
  specialized once for each.
- **Eco.** Members are integers (row 103, "the founding decision"). A lambda's integer is
  qualified by `(raw lambda, annotation-widened key of the enclosing spec, local-multi tag)`
  (LSS_017, amended 2026-08-21 and 2026-09-05; row 228). The widened key removes every set, so
  `f`'s set never reaches the inner lambda's identity. Row 228 calls this "faithful in direction"
  because annotation sensitivity is enforced at the consumer by the fingerprint fence. That fence
  *declines*: it keeps correctness and gives up the direct call. The paper *splits* and keeps it.
- **What the paper relies on and Eco lacks.** A set with two or more members is lowered to a sum
  (a tag switch with direct calls), not to generic dispatch (`plans/lss-sum-lowering.md`,
  not-started). Not in scope here; see §3.8.

## 2. History that constrains the design (read before changing anything)

1. **LSS_017, Fix B (`plans/lss-fork-qualified-members.md`).** The key was first `l|<raw>|<SpecId>`.
   It is the sound answer to the E11 representative-hijack SIGSEGV
   (`plans/lss-dispatch-value-extraction.md` §11.7): two same-layout copies of one lambda whose
   bodies call different functions must never be stamped as one.
2. **Layout-qualified members (`plans/lss-layout-qualified-members.md`; LSS_017's 2026-08-21
   amendment, unconditional since 2026-09-18; the separate LSS_024 row no longer exists).** SpecId
   over-split annotation-only clones that compile to identical code (the sigFlow family:
   `variableToCanType` 1→2 specs, `UnionFind.get/modify` 10→14), turning consumer slots into
   2-sets and costing 23.2 M fast calls. The fix had two parts, which that plan says are neither
   sound nor useful alone:
   - C: the widened-key qualifier;
   - F: the fingerprint fence in AbiCloning (`fpUnanimous`, `joinGroup`, `AbiCloning.elm:565`).
3. **`plans/lss-body-mismatch-declines.md` (abandoned 2026-09-06).** Measured the `bodyMismatch`
   population on the self-compile. All of it is caused by C's sharing, all of it is `structural`
   (none `annoOnly`), and it is 1,173 sites carrying ~10.6 M generic dispatches, 0.97 %. Reverting
   to SpecId (its §4.C) cost `.mlir` +3.3 % and `declinedNoInstance` +5,568 for +276 stamps.
   `abiMismatch` (354 sites then) was noted as "the same shape one guard earlier" and never sized.
4. **`plans/lss-no-instance-declines.md` §11.2.** `declinedNoInstance` does not count dispatches:
   70.6 % of the *baseline* population (`g2global`) are calls mono already made direct. 4.C's
   +5,568 increase was never classified, so it is neither proven harmless nor proven costly.
   §5 step 10 records `noInstance` by category (`niGuard`), B against C.
5. **Pins that encode today's behaviour** (`compiler/tests/Compiler/Monomorphize/Solver/LayoutQualTest.elm`):
   - The split fixture (`mid f x = applyHof (\v -> f (v + x)) x`, called with `inc` and `dec`)
     asserts "the PROPAGATED applyHof split collapses to 1". That is the `List.map`/`foldrHelper`
     case in miniature, and this plan **deliberately inverts it**.
   - The budget-twins variant of it.
   - The spiral fixture (`blockedCount = 0`, `tieBypass >= 1`).

   §5 step 8 lists the new expectations.

## 3. Design

### 3.1 The key

```
today:  l|<raw>|<widenedKey>[|#<instTag>]
new:    l|<raw>|<widenedKey>[|#<instTag>][|c:<captureSig>]
```

The first part is unchanged: it is what `Engine.layoutQualKey` (`Engine.elm:815`) returns today,
and this plan calls it the lambda's **family key**. `captureSig` is empty when the lambda captures
no name whose type contains an arrow, and then the key is **byte-identical to today's**. That covers
most lambdas.

A definition's root lambda, whose key is folded to `g|<global>` (`rootLamOf`), gets no signature,
just as `instanceQualTagFor` already gives it no instance tag.

### 3.2 The capture signature

For a lambda with raw id `raw`, minted while translating spec S:

1. **Names.** `names` is the free-local list of the source lambda, read from the per-run table
   `Env.lambdaFreeLocals` (§3.5): the names its body uses that it does not bind itself, sorted.
2. **Types.** For each name:
   - if it is a local-multi function (`List.any (\e -> e.defName == name) s.localMulti`), or has
     no `s.varEnv` entry, it is **opaque**: omitted, and counted in `capOpaque`;
   - otherwise take its `MonoType` from `s.varEnv`, and omit it if the type contains no
     `MFunction`.
3. **Rendering.** Render each remaining name as `name=` followed by its type's **annotation
   vector**. The vector is the annotations of the type's arrows, in a fixed order (each arrow's own
   annotation, then its arguments left to right, then its result; through lists, tuples, record
   fields in key order and custom-type arguments), joined with `,`. Each annotation renders as:
   - `LSet ms` → `[` + members + `]`;
   - `LPartial ms` → `~[` + members + `]`;
   - `LTop _` and `LVar _` → `?`.

   Members are rendered through `memberToken`, then sorted and deduplicated as strings, and joined
   with `,`:
   - a lambda member (one with an entry in `LssMemberTable.familyOf`) renders as `f<family number>`,
     the number of its **family key**, and **not** its own id;
   - any other member (`g|`, `c|`, `k|`, `a|`, `p|`, raw inference ids) renders as its id.
4. **Joining.** `captureSig` is the rendered names joined with `;`.

Why each choice:

- **Lambda members render by family: this is what makes it terminate.** If a captured lambda were
  rendered by its own id, a lambda's identity could contain another lambda's identity without
  bound, and recursion would mint new ids forever. The μ-tie (LSS_018) does not stop this. It ties
  a mint only to an id of the *same* raw lambda that the spec's *own* stored demand already carries
  (`demandQualifiedFor`, `Solver/Monomorphize.elm:3904`). So two lambdas that alternate across
  recursion levels escape it. Example:

  ```elm
  alt n f = if n <= 0 then f 0 else alt (n - 1) (\x -> f x + 1) + alt (n - 2) (\x -> f x * 2)
  ```

  With ids: `alt[{I}]` mints A1 = (a, f=[I]) and B1. `alt[{A1}]` ties a, but mints a new B2 = (b,
  f=[A1]). `alt[{B2}]` ties b and mints A3 = (a, f=[B2]). And so on, until the 50,000-spec
  watchdog fails the compile. Mutual recursion (`ping`/`pong` each wrapping the other's function)
  diverges the same way.

  With families, a key's nesting depth is one. The set of possible keys is then finite: family keys
  are today's keys, the non-lambda ids are unchanged, and an annotation vector is bounded by the
  captured type's size, which `specTypeNodes` bounds. So the registry is finite and the drain
  terminates by LSS_010's finite-join argument, **with or without** the μ-tie. Traced for `alt`:
  the chain closes at 5 specs (§5 step 1, fixture T4).
- **What families cost.** Two lambdas that capture different *copies* of one family share an id.
  If their bodies differ, the fence declines, as today. The motivating case is unaffected: U8 is a
  `c|` member, `encodeRecord` is `g|`, and the two other `f`s are lambdas of two different families,
  so all four `List.map` copies get four keys.
- **Syntactic free locals, not `ClosureInfo.captures`.** The member is minted before the body is
  translated, at all four mint sites:
  - `classifyLambdaHead` (`Translate.elm:1384`, mint at :1447);
  - `injectArgLambdaMemberGo` (:3529);
  - the local-multi use (:3285);
  - `injectRetranslatingSelf` (:3484).

  The captures are only known after the body is translated (`Closure.computeClosureCaptures`,
  :1352). Devirtualization also drops the captured `f` in exactly the motivating case:
  `Bench_lambda_469` captures nothing because `{U8}` was inlined to a `U8` construction.
- **`LTop` and `LVar` render alike.** `LVar n` is numbered per zonk (`Store.elm:2135`). Neither
  licenses a stamp, so merging them can only leave a decline to the fence.
- **Opaque names are omitted, not marked.** Which instance a captured local-multi function is
  depends on its use inside the body, which is not translated yet. A mark would be the same in
  every spec, so it could not separate anything. Omitting it keeps the empty-signature-is-today's-key
  property. Recursive `let` names are opaque by this rule: the name is bound only for the `let`
  body (`translateLocalMultiLet`, `Translate.elm:5925`), so inside its own right-hand side it has no
  `varEnv` entry.

### 3.3 One id per lambda instance per spec: the first-mint memo

A new run-global table, `LssMemberTable.firstMint : Dict ( SpecId, qualifiedRawKey ) ( Int, String )`,
records the id (and key) of the first plain mint of each lambda instance in each spec. A later mint
of the same instance in the same spec **returns the memoized id without rendering a signature**.
This gives three guarantees by construction:

- **All mint sites agree.** Argument injection and the closure's own `lssMember` get the same id,
  whatever `varEnv` looked like at each. A disagreement here would not be a missed stamp. If the
  callee's demand held id A while the closure carried B, and A had fingerprint-equal instances
  elsewhere, the site could be stamped to A's code with B's closure flowing in: the E11 hijack.
  The existing LSS_002 check would not catch it, because it compares a closure with its *own* head
  arrow, which the closure's own mint wrote (LSS_002 runs only in
  `tests/TestLogic/Monomorphize/LambdaSetIntegrity.elm`). So the memo, not a validator, is the
  guarantee, and §5 step 1 test T3 checks the cross-site property directly.
- **Saturation passes agree.** `specializeNodeSaturating` (`Solver/Monomorphize.elm`, above :3915)
  translates one item up to `maxSaturationPasses` times. An early pass may see `LVar` where a later
  pass sees an `LSet`. The first pass's id stands.
- **Re-translations agree.** LSS_010 re-translates a spec whose stored type a join changed. This
  happens at default settings (`retranslations=2` on the benchmarks). Without the memo, the
  re-translation could render a different signature and mint a new id. That would orphan the old
  callee spec and grow the member universe. LSS_017 states "Interning is idempotent so LSS_010
  dirty-flush re-translations re-mint the same id", and the memo keeps that true.

Cost of the memo: the first mint's signature may be computed from a less complete `varEnv` than a
later pass would see. That can only make an id shared with a spec whose real captures differ, which
the fence turns into a decline. It is never a wrong stamp. `sigDrift` (report only) counts memo hits
whose freshly rendered key differs, to size this.

**The μ-tie runs before the memo is consulted.** `demandQualified` is rebuilt per item from the
joined registry type, so a re-translation can newly tie (LSS_018: "re-tie monotonically"). Ties are
never memoized. The equal-id bypass compares the tied id with the memoized id if there is one, and
otherwise with the id the new key already has in `byKey`.

### 3.4 Never coarser than today, never finer than SpecId

- **Not finer than SpecId.** Within one spec, the memo gives one id per `(raw, instTag)`, as
  SpecId qualification did.
- **Not coarser than today.** Every new key extends a family key, so two lambdas that today get
  different ids still do.
- **Annotation-only splits keep sharing.** Across specs, ids are shared exactly when family keys
  and signatures agree. So annotation-only splits that do not change a captured function's set keep
  sharing, and LSS_017's 2026-08-21 reason for sharing still holds there. The sigFlow family's
  lambda `\descProps -> ...` captures a `Variable`, with no arrow.

That the whole sigFlow family keeps sharing is **not** argued here. `IO.andThen`'s wrapper captures
`f` and `ma`, which are both function-typed. It is gated by measurement in §5 step 10.

### 3.5 The free-local table

Two mint sites hold only the `SrcLambdaId`, not the body (the local-multi use via `rhsLam`, and
`injectRetranslatingSelf`). So the free-local lists are computed **once per run**, by one walk over
every `Function`/`TrackedFunction` in the `TOpt` program, into
`Env.lambdaFreeLocals : CoreDict.Dict Int (List Name)`, keyed by `Id.toComparable` of the
`SrcLambdaId` (the same as `Engine.srcLambdaKey`). `Env` is per-run and immutable and already holds
`toptNodes` and `lamLabels`.

The record-width concern from the layout plan does not apply: `monomorphization.md` states the
32-field comments are stale and wider records work.

A lambda with a `SrcLambdaId` but no table entry (for example in a definition synthesized during
monomorphization) gets an empty signature and is counted in `capMissing`. Expected: 0.

### 3.6 The μ-tie and the spiral fixture

The tie code is unchanged. Its behaviour changes for recursive families whose generations capture
different sets. Take the spiral fixture (`loop n f` calls itself with `\x -> f x + 1`):

- **Generation 1.** `loop[{I}]` mints W1 = (w, f=[family of I]) and demands `loop[{W1}]`.
- **Generation 2.** It would mint (w, f=[family of w]), a different key. But its demand carries W1
  for raw w, and the key is not yet interned, so the mint **ties** to W1: it records it as tied and
  blocks it. It demands `loop[{W1}]`, which is itself. The chain closes at 2 specs, and the closure
  in both specs carries W1.

Today the equal-id bypass closes the same spiral with nothing blocked. But W's two instances
(capturing `{I}` and `{W}`) have different bodies, so the call through `f` is already declined by
the fence. The outcome in kind is unchanged (generic dispatch), and the counter moves from
`declinedBodyMismatch` to `declinedBlocked`.

Blocking is wider than declining: a tied id is blocked everywhere, even at sites in specs where the
fence would have passed it, and even if the spec that tied it is later pruned. The tie population is
not small (`tieBypass=301` on the benchmarks), so §5 step 10 gates on it.

### 3.7 What stays as it is

- **The fingerprint fence**, which is still needed for parameter/result annotation divergence,
  family-level sharing, opaque captures and tied families.
- **Signature inference.** It mints raw `l|` ids (`LssInfer.injectLambdaMember`, `LssInfer.elm:196`)
  and never goes through `lambdaInstanceMemberId`.
- **The settle passes**, which never mint `l|` ids.
- **Stage hints (`MemberArity`), devirtualization and the borrow handshake (BORROW_006)**, which
  treat ids as opaque. Code that splits member keys on `|` reads only the prefix and `#` tags, so
  the `|c:` part does not disturb it.
- **No switch.** LSS_041 fixed the LSS flags at their defaults, and the theory doc lists adding a
  switch around a mechanism as a change that breaks the theory. The mechanism ships unconditionally
  under `lss.enabled`, and the A/B uses two compiler builds.
- **The key is still "identity up to what code generation can see"** (monomorphization.md). It
  splits a callee only where the copies' code differs, as in the motivating case (different capture
  layouts, different direct targets).

### 3.8 Deviations from the paper that remain

- **Parameter and result annotations are not in the identity.** Within one set the elements share
  the arrow's parameter and result types, so they never separate two elements of one set. Across
  specs they could, they are only partly known at mint time, and divergence stays a fence decline.
- **Depth-one identity.** Captured lambdas are named by family, not by their own identity (§3.2).
  The paper needs no such cut, because it unifies a recursive group's sets into one specialization.
- **Sets with several members still lower to generic dispatch** (`plans/lss-sum-lowering.md`).
- **`g|`/`c|` members are still named by family** (fidelity GAP-1).

## 4. Predicted effect

- **Benchmarks.** `List_foldrHelper_$_704` and `List_foldl_$_705` split into one copy per
  `List.map` copy at that layout (four), and each copy's per-element `fn` calls become
  `singleton_fast`. `List_map_$_793` stays one copy with seven callers, because they really pass
  the same `f`. Other `abiMismatch`/`bodyMismatch` sites in the program (77 and 125) of the same
  origin should convert too.
- **Self-compile.** The convertible population is at most the 1,173 `bodyMismatch` sites (~10.6 M
  dispatches, ~1 %) plus the unsized `abiMismatch` sites, and only the part caused by captured
  sets converts. A wall change of under 1 % is the expected outcome. A self-compile win is not an
  acceptance criterion; no self-compile loss is.
- **Cost.** More specs, more `.mlir`, more compile time. SpecId qualification measured +3.3 %
  `.mlir`, and this key is coarser than SpecId, so +3.3 % is the reference, not a bound: the code has
  changed since September. The memo rules out re-mint growth.

## 5. Implementation

Work in the order below. Temp files go only under `/tmp` (house rule); this plan uses
`/tmp/lss-cq/`. Test runs are once each, with output to a file
(`<cmd> 2>&1 | tee /tmp/lss-cq/<name>.txt`), then read from the file. The engine's functions are
written as explicit `case` chains on `( value, state )` pairs, not with combinators
(monomorphization.md, "Keeping self-compilation affordable"). Follow that style.

### Step 0: baseline compiler B and its numbers

1. **Build B from the current tree.** Run `cmake --build build --target bootstrap`. Copy
   `build/compiler/build-kernel/bin/eco-compiler-boot` to `/tmp/lss-cq/eco-B`.
   `build/runtime/src/codegen/eco-boot-native` lowers for both B and C; the runtime is not changed.
2. **Benchmarks under B.**
   - Wipe `examples/benchmarks/eco-stuff`.
   - In `examples/benchmarks`, run
     `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_CENSUS=1 /tmp/lss-cq/eco-B make src/Bench.elm --output=/tmp/lss-cq/B/bench.mlir 2> /tmp/lss-cq/B/census.txt`.
     Keep the report: `declined*`, `dispatchUpgraded`, `layoutQual`, `muTie`, `join flush` and the
     per-site rows.
   - Lower: `build/runtime/src/codegen/eco-boot-native /tmp/lss-cq/B/bench.mlir -o /tmp/lss-cq/B/bench`.
   - Timings: copy that binary to `examples/benchmarks/build/bench` (back up the existing one
     first), run `node run.mjs --no-build --skip-js --skip-elm`, keep `build/results.json` as
     `/tmp/lss-cq/B/results.json`, and restore the backup.
   - Dispatch: for each workload name from `./bench --list --json`, run
     `ECO_DISPATCH_STATS=1 /tmp/lss-cq/B/bench --json --warmup 0 --runs 1 <name>` and keep the
     `[dispatch-stats] sat=… gen=…` stderr line.
   - MLIR as text: `build/runtime/src/codegen/ecoc --emit=mlir /tmp/lss-cq/B/bench.mlir 2> /tmp/lss-cq/B/bench.txt.mlir`.
     ecoc writes this dump to stderr.
3. **Self-compile under B.** From `build/compiler/build-kernel`, run this 3 times, timed:
   `/tmp/lss-cq/eco-B make --optimize --no-cache --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp --output=/tmp/lss-cq/B/self.mlir /work/compiler/src/Terminal/Main.elm`.
   This is Stage 8a's command (`compiler/CMakeLists.txt:658`) with `--no-cache`. Then:
   - one more run with `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_CENSUS=1` for the counters, and record
     spec count and `.mlir` size;
   - one run with `ECO_DISPATCH_STATS=1` for `gen`. This counts the dispatches of **B's own code**
     compiling that input. Step 10 compares it with C's code compiling the same input.
4. **The rail.** Run `benchmarks/mlir-workload-rail.sh B`.

### Step 1: failing tests first (house rule)

Write these on the current tree and confirm the ones marked **fails today** fail. Use the AST
helpers in `compiler/tests/Compiler/AST/SourceBuilder.elm` (`makeModuleWithTypedDefs`, `define`,
`letExpr`, `lambdaExpr`, `callExpr`, `binopsExpr`, `tupleExpr`, `varExpr`, `intExpr`, `tLambda`,
`tType`) and the runner `TestLogic.TestPipeline.runSolverMonoWithReport limits lssConfig module`,
as LayoutQualTest does.

- **T1, the split (LayoutQualTest, fails today).** Existing `splitModule`. Expect
  `hofSpecs = 2`, and the inner lambda's ids differ between the two `mid` specs. Add
  `expectDifferentMembers`, the mirror of `expectSameMembers`.
- **T2, the sharing guard (LayoutQualTest, passes today, must keep passing).** New fixture:
  `mid2 f x = f x + applyHof (\v -> v + x) x`, with `testValue = mid2 inc 1 + mid2 dec 2`. The
  inner lambda captures only `x : Int`, so expect `mid2Specs = 2`, `hofSpecs = 1`, and the inner
  lambda's ids equal (`expectSameMembers 2`).
- **T3, cross-site agreement (new test module `CaptureQualTest`, passes today, must keep passing).**
  A graph check, `argMembersAgree : Mono.MonoGraph -> List String`. For every `MonoCall` whose
  callee is a `MonoVarGlobal specId calleeType` and whose argument i is a `MonoClosure` with
  `lssMember = Just m`, parameter i of `calleeType` must be an `MFunction` whose annotation is an
  `LSet` containing m; otherwise return a violation string. Walk the graph like
  `LayoutQualTest.closureMembersIn` does (`Compiler.IR.Mono.Traverse`). Run it on four fixtures,
  one per mint site:
  - T1's module (argument injection and plain translation);
  - a local-multi function capturing `f`. It must be used at two different types, or it is not
    local-multi: `wrap f = let g y = tupleExpr (f 1) y in ( apply g 1, apply g "s" )`, with
    `apply h z = h z`. Confirm in the graph that `g` has two instances (`g` and `g$1`);
  - a recursive `let` function capturing `f`:
    `rec f n = let go k = if k <= 0 then f 0 else go (k - 1) in applyHof go n`;
  - T1's module again with `testValue` calling `mid` three times with three functions.

  Expect zero violations.
- **T4, termination at the default unlimited budget (new, in `CaptureQualTest`).** Pass limits
  `{ Config.defaultLimits | specBreadth = 64 }`. This is the *watchdog*: a divergence becomes a
  pipeline error and the test fails fast. It is not `maxSpecsPerGlobal`, which would widen and
  hide the divergence. Leave `maxSpecsPerGlobal` at its default, unlimited. Fixtures:
  - `alt` (§3.2) with `testValue = alt 3 (\x -> x)`: expect success and `altSpecs <= 5`. The
    trace in §3.2 gives exactly 5 (`{I}`, `{A1}`, `{B1}`, `{B2}`, `{A3}`); explain any other count
    before accepting it;
  - `ping n f = if n <= 0 then f 0 else pong (n - 1) (\x -> f x + 1)` with
    `pong n g = if n <= 0 then g 0 else ping (n - 1) (\y -> g y * 2)`, `testValue = ping 4 inc`:
    expect success and at most 3 specs of each.

  These pass today, which is fine, and must keep passing. They are the blocker's regression pins.
- **T5, rendering (new, pure, in `CaptureQualTest`).** On the exposed pure renderer (step 5):
  - an empty name list gives `""`;
  - a name whose type has no arrow is omitted;
  - `LTop` and `LVar` both render `?`;
  - members are sorted and deduplicated;
  - a member with a family renders `f<n>`;
  - names come out sorted;
  - `withCaptureSig base ""` is `base`.
- **T6, end to end (fails natively today).** `test/eco-elm/src/CaptureQualMapTest.elm`, not
  `test/elm`, which is synced to the shared suite and is the rail's workload set. A module with a
  user-written `myFoldr` (not `List.foldr`, so the test does not depend on elm/core's inlining) and
  `myMap f xs = myFoldr (\x acc -> f x :: acc) [] xs`, called with two named functions and one
  capturing lambda. `-- CHECK:` the printed results. Add `-- XFAIL-NATIVE: plans/lss-capture-qualified-members.md`
  until step 6 lands; the harness then reports XPASS, which forces removing it.
- **T7, MLIR (fails today).** `test/eco-mlir/src/CaptureQualFoldTest.elm`, the same program, with
  `-- CHECK-MLIR-NOT: generic_apply` and `-- CHECK-MLIR-NOT: segmentation_unknown`. These match
  anywhere in the output. Existing Html fixtures emit neither, so the fixture needs no other
  higher-order call. Confirm it fails today, and mark it `-- XFAIL-NATIVE:` the same way.

### Step 2: the free-local module

1. Create `compiler/src/Compiler/IR/Typed/FreeLocals.elm`. Move into it from
   `Compiler/PreMono/LiftClosedArgs.elm`: `freeLocals` (:717), `freeGo`, `use` and `children` (:832).
   Expose `freeLocals` and `children`. Make `LiftClosedArgs` import them; its census behaviour must
   not change.
2. Add and expose
   `lambdaTable : DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> CoreDict.Dict Int (List Name)`.
   - **The walk.** Visit node bodies as `LiftClosedArgs.walkNode` does (`Define`, `TrackedDefine`,
     `PortIncoming`, `PortOutgoing`, `Cycle` value defs and func defs), then every sub-expression
     through `children`.
   - **What to record.** For each `TOpt.Function (Just lam) _ _ _` or
     `TOpt.TrackedFunction (Just lam) _ _ _` expression `e`, insert
     `Id.toComparable lam ↦ CoreDict.keys (freeLocals e)`. `freeLocals` of the whole `Function`
     expression excludes its parameters, and `CoreDict.keys` is sorted.
   - **Nested lambdas.** Keep walking into the body, since nested lambdas need entries too.
3. Check the folder-dependency script (the `full` target runs the layer checks) accepts
   `IR/Typed` importing `Core`. It should, since `IR` already depends on `Core`.

### Step 3: `Env` field

In `Solver/Engine.elm`, add `lambdaFreeLocals : CoreDict.Dict Int (List Name)` to `Env` (:1535). In
`Solver/Monomorphize.elm` `initState` (:3495), set it to
`if lssConfig.enabled then FreeLocals.lambdaTable nodes else CoreDict.empty`. `nodes` is the same
map `toptNodes` is built from.

### Step 4: member-table fields and counters

In `Solver/Engine.elm`:

- **New `LssMemberTable` fields** (:427), each set to empty in `emptyMemberTable` (:519):
  - `firstMint : CoreDict.Dict ( Int, Int ) ( Int, String )`: `(specId, qualifiedRawKey raw instTag)`
    to `(member id, key)`;
  - `familyOf : CoreDict.Dict Int Int`: lambda member id to family number;
  - `families : CoreDict.Dict String Int`: family key to family number. Numbers are given in order
    of first use, as `CoreDict.size families`.
- **New `LayoutQualStats` fields** (:253), each initialized to 0 in the `layoutQual` record of
  `emptyLssStats` (:557):
  - `capQualified`: mints with a non-empty signature;
  - `capOpaque`: names omitted as opaque;
  - `capMissing`: lambdas with no table entry;
  - `memoHit`;
  - `sigDrift`: memo hits whose freshly rendered key differs, counted only when `env.lss.report` is
    on.

  Bump them with the existing `bumpInstanceQual` (:647), which already updates `layoutQual`.

### Step 5: signature rendering

1. **In `Compiler/IR/Mono.elm`**, next to `collectAnnoMembers` (:1592), add and expose
   `arrowAnnosInOrder : MonoType -> List LambdaSetAnno`. Use the traversal order of §3.2 step 3:
   for `MFunction _ anno args ret`, emit `anno`, then the annotations of `args` left to right, then
   `ret`'s; recurse through `MList`, `MTuple` (`tupleToList`), `MRecord` (`Dict.foldl`, key order)
   and `MCustom` arguments; anything else contributes nothing.
2. **In `Solver/Engine.elm`**, add and expose pure functions (T5 tests them):

   ```elm
   renderCaptureSig : CoreDict.Dict Int Int -> List ( Name, Mono.MonoType ) -> String
   -- for each (name, type) with a non-empty arrowAnnosInOrder:
   --   name ++ "=" ++ String.join "," (List.map (annoToken familyOf) annos)
   -- joined with ";"; the input list is already sorted by name

   annoToken : CoreDict.Dict Int Int -> Mono.LambdaSetAnno -> String
   -- LSet ms     -> "[" ++ memberTokens familyOf ms ++ "]"
   -- LPartial ms -> "~[" ++ memberTokens familyOf ms ++ "]"
   -- LTop _      -> "?"
   -- LVar _      -> "?"

   memberTokens : CoreDict.Dict Int Int -> List Int -> String
   -- List.map (\m -> case CoreDict.get m familyOf of
   --                     Just fam -> "f" ++ String.fromInt fam
   --                     Nothing  -> String.fromInt m) ms
   --   |> Set.fromList |> Set.toList |> String.join ","

   withCaptureSig : String -> String -> String
   -- withCaptureSig base sig = if sig == "" then base else base ++ "|c:" ++ sig
   ```

3. **Add the impure glue**, `captureSigFor : Int -> S -> ( String, S )`:
   - look up `raw` in `s.env.lambdaFreeLocals`; if missing, bump `capMissing` and return `""`;
   - otherwise, for each name, decide opaque (local-multi or no `varEnv` entry; bump `capOpaque`)
     or take `( name, type )`;
   - return `renderCaptureSig s.lssMemberTable.familyOf` of the kept pairs.

### Step 6: key, memo and tie in `lambdaMemberLayoutQualified` (`Engine.elm:776`)

Keep `layoutQualKey` (:815) unchanged: it returns the family key, and its pure pins in
LayoutQualTest stay valid. Restructure `lambdaMemberLayoutQualified raw instTag specId s0`:

```
qrk     = qualifiedRawKey raw instTag
memoKey = ( specId, qrk )
isRoot  = CoreDict.member raw s0.lssMemberTable.rootLamOf

case CoreDict.get memoKey s0.lssMemberTable.firstMint of
    Just ( mid, mintedKey ) ->
        -- Fixed at first mint. Only the μ-tie can override it (§3.3).
        case CoreDict.get qrk s0.itemAux.demandQualified of
            Just tiedId ->
                if tiedId == mid then ( mid, bump tieBypass and memoHit )
                else ( tiedId, recordMuTied tiedId s0 )
            Nothing ->
                ( mid, bump memoHit; under lss.report, render the key afresh and bump
                  sigDrift if it differs from mintedKey )

    Nothing ->
        ( familyKey, isFallback ) = layoutQualKey s0.lssMemberTable.specWidenedKeys raw instTag specId
        ( sig, s1 ) = if isRoot then ( "", s0 ) else captureSigFor raw s0
        plainKey = withCaptureSig familyKey sig
        -- From here on, exactly today's code with `plainKey` in place of today's plain key:
        -- the root fold (g| key), the demandQualified tie with the equal-id bypass
        -- (CoreDict.get key byKey == Just tiedId), and mintLayoutQualifiedFold.
        -- On the PLAIN-mint paths (not the tie):
        --   * firstMint := insert memoKey ( mid, key )
        --   * if not isRoot: familyOf := insert mid (family number of familyKey,
        --     allocating it in `families` if new)
        --   * if sig /= "": bump capQualified
```

Points to get right:

- **The `g|` root key.** Today it is built from the plain key by swapping the `l|<raw>` head for
  `g|<global>`. Build it from `familyKey`; `isRoot` lambdas have `sig = ""` anyway.
- **Ties are never memoized**, and tied mints record nothing in `familyOf`.
- **`lambdaQualified`** still records `(qrk, specId)` at first mint, as today. `demandQualifiedFor`
  still keys by raw; it needs no change.
- **The fallback path** (`l|<raw>|<specId>`, expected 0) takes the signature too.

### Step 7: report line

Append ` capQual=… capOpaque=… capMissing=… memoHit=… sigDrift=…` to the `layoutQual:` report line
(`Solver/Monomorphize.elm:3410`). Add `capFamiliesSplit=<n>`: the number of family numbers held by
two or more member ids in `familyOf`, computed at report time.

### Step 8: update the pins that encode today's behaviour

Each update carries a comment naming this plan and the reason. Any other pin that moves is a finding
to explain, not to re-baseline.

- **LayoutQualTest, split pin.** It becomes T1. Drop its `shared >= 1` line: root folds also bump
  `shared`, so it says nothing here.
- **LayoutQualTest, budget-twins pin (budget 1).** `mid`'s second spec is past the budget, but its
  stored type still carries `f:{dec}` (`Registry.getOrCreateSpecIdKeyed` stores the demand), so the
  inner ids now differ. `applyHof`'s second demand is past its budget: it is keyed widened, so it
  creates a new spec (a widened key matches no spec created under the budget), and the two stored
  types (`{L1}`, `{L2}`) do not converge, so `mergeConvergedSpecs` does not merge them.
  Expected: different inner ids, `hofSpecs = 2`. If the run shows otherwise, explain it before
  changing the pin.
- **LayoutQualTest, spiral pin.** `blockedCount = 1` (W1 tied), `loopSpecs <= 3` (expect 2),
  `expectSameMembers` still holds (the tie gives generation 2's closure W1). Drop `tieBypass >= 1`.
- **Docstrings.** LayoutQualTest's module docstring and the split fixture's docstring describe the
  shared id and the equal-id bypass. Rewrite them. MuTieTest's pin (`loopSpecs <= 3`) still holds;
  update its docstring's account of what closes the spiral.
- **Remove `-- XFAIL-NATIVE`** from T6 and T7.

### Step 9: correctness gates (each once, output to a file)

Before E2E, wipe `examples/benchmarks/eco-stuff`, every `test/*/eco-stuff`, and the `~/.eco/<ver>`
package `*artifacts.dat` (stale caches survive a compiler change).

1. `cmake --build build --target elm-tests`: T1–T5 and every existing suite.
2. `cmake --build build --target full`: E2E Gate A, including T6 and T7.
3. `cmake --build build --target bootstrap`: a separate target, which `full` does not run. It builds
   C and checks the 8c fixed point.
4. `cmake --build build --target stress`.
5. `DIFF=B benchmarks/mlir-workload-rail.sh C`. Emission diffs are expected; any crash or
   `EngineBug` is a failure. Diff the census on the `layoutQual`, `muTie` and `declined*` lines.
6. Once, at the very end of the plan: the heap-validate build's unit, E2E and GC-pressure stress
   gate (house rule: validate once at plan end). No runtime code changes, but the generated code
   does.

### Step 10: measurement and acceptance

Copy C's `eco-compiler-boot` to `/tmp/lss-cq/eco-C` and repeat step 0's protocol into
`/tmp/lss-cq/C/`. Self-compile wall: 3 runs each, alternating B and C in one session. Dispatch:
compile the **same** input (the C tree) with B's binary and with C's binary under
`ECO_DISPATCH_STATS=1`.

**Accept** when all of these hold:

1. Step 9 is green.
2. In C's benchmark MLIR, `List.foldrHelper` has one copy per `List.map` copy at
   `(Int -> Encoder)` (four), their per-element calls are `singleton_fast`, and the census rows
   for those hosts show `stamp`, not `abiMismatch`/`bodyMismatch`.
3. bytes-u8-rows' total generic dispatch falls, and no benchmark workload's total generic dispatch
   rises. **Total generic dispatch** is `helper` + `indirect` from the call census
   (`ECO_CALL_CENSUS=1` given to `eco-boot-native` when lowering, counts printed under
   `ECO_DISPATCH_STATS=1`): one logical generic dispatch is either a trampoline entry (`helper`) or
   an inline call through an evaluator pointer (`indirect`). *Corrected 2026-11-22:* this criterion
   first named `ECO_DISPATCH_STATS`'s `gen`, which counts only the trampoline path; the inline
   path, where the converted calls live, is several times larger (§9.4).
4. The self-compile's total generic dispatch (as in 3) with C's code is not higher than with B's,
   on the same input. *Corrected 2026-11-22* for the same reason.
5. **The sigFlow family keeps its stamps.** In the self-compile census, the `stamp` counts of the
   hosts `System.TypeCheck.IO andThen`, `IO pure`, `Compiler.Type.Type variableToCanType`,
   `variableToErrorType`, `getVarNames`, `Compiler.Type.UnionFind get`/`modify` and
   `Compiler.Type.Solve restore` are not lower in C than in B.
6. No benchmark or self-compile wall regression of 5 % or more (user tolerance; smaller ones are
   recorded). Benchmark noise is about ±5 % per workload on one run, so a workload over the line is
   re-run three times before it counts.

**Record and report, without gating:**

- `.mlir` size, spec count, front-end time;
- `declinedBodyMismatch`, `declinedAbiMismatch`, `declinedBlocked`, and `declinedNoInstance` by
  `niGuard` category;
- `muTie tied`, `tieBypass`, the new `layoutQual` counters, `capFamiliesSplit`;
- the benchmark table B against C.

Growth in `.mlir` or front-end time beyond the 3.3 % reference is reported with the top globals by
added specs before the plan is called done.

### Step 11: conditional follow-ups (only if step 10's numbers ask)

- **Lost stamps.** If sites stamped under B are generic under C, attribute them by host. If the cause
  is copies whose bodies are identical but whose signatures differ, meeting in one slot as a 2-set,
  consider stamping a multi-member set whose members share one family and whose instances are
  fingerprint-unanimous. AbiCloning would need `familyOf` exported in the `MonoGraph`:
  `lssMemberKinds` is filled only under `lss.report`.
- **Many new ties** (`muTie tied` up, `declinedBlocked` up). Check whether blocking a tied id
  everywhere costs stamps that a per-spec block would keep.
- **Residual `bodyMismatch`/`abiMismatch`.** Classify what is left (family-level sharing, opaque
  captures, parameter/result annotations). Extend the identity only where one class dominates and
  carries weight.

### Step 12: documents

- **`design_docs/invariants.csv`.**
  - Amend LSS_017: the key gains `|c:<captureSig>`, captured lambdas render by family, and there
    is one id per `(spec, lambda instance)` by the first-mint memo.
  - Amend LSS_018: the equal-id bypass no longer closes capture-divergent spirals. The tie or the
    family bound does, and tied ids are not memoized.
  - Add a row at the next free id after the highest LSS row (LSS_041 today) for this mechanism:
    the signature definition, the family rendering and its termination argument, the memo, and the
    cross-site test T3.
- **`design_docs/theory/compiler/lambda-set-specialization.md`.** "Members name code, not
  captures" (around lines 40–53): members still carry no captured *values*, but a lambda's member
  now names the families of the function values it captures, and nesting stops at depth one, so
  recursive set descriptions still never arise. Update the termination paragraph, which starts
  "Termination is not automatic".
- **`design_docs/theory/compiler/monomorphization.md`.** The paragraph on keying as a source of
  non-termination.
- **`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`.** Rows 103 and 228 (element
  identity), 107 ("μ cannot arise": still true, by depth-one identity) and 134 (ψ inside sets).
- **This plan's front matter**, at each status change.

## 6. Risks

| # | risk | handling |
|---|---|---|
| R1 | Different ids for one lambda instance at different mint sites. That is a possible wrong stamp (E11), not just a missed one | The first-mint memo makes it impossible within a spec (§3.3); T3 checks the cross-site property directly. LSS_002 cannot catch this class |
| R2 | Non-termination from nested identities | Family rendering bounds nesting at depth one (§3.2); T4 pins `alt` and `ping`/`pong` at the default unlimited budget with a small watchdog |
| R3 | A wrong stamp from finer ids | The change never merges copies that today's key separates (§3.4), and the fence is unchanged |
| R4 | Lost stamps: identical bodies with different signatures meeting as a 2-set; tied ids blocked everywhere | Acceptance 3–5; step 11 |
| R5 | Spec and code growth, compile time | Measured and reported (step 10). No cap is added: LSS caps are policy, never a terminator |
| R6 | Re-mints after joins or saturation passes | The memo fixes the id at first mint; `sigDrift` sizes the precision cost |
| R7 | Rendering cost | Signatures are built only at first mint per `(spec, instance)` and only for lambdas with a non-opaque, arrow-typed free local; free-local lists are computed once per run |
| R8 | `noInstance` growth hiding lost dispatch | Recorded by `niGuard` category, B against C |

## 7. Review record (2026-11-22)

An independent adversarial review of the first draft found the following; each is resolved in the
text above.

| # | severity | finding | resolution |
|---|---|---|---|
| 1 | blocker | Capture signatures over member ids diverge on alternating or mutual recursion; the μ-tie (same raw, own demand only) does not stop them | Captured lambdas render by family (§3.2); T4 |
| 2 | major | "LSS_002 under validate" does not exist as a compile-time check and cannot see cross-site disagreement; the consequence is a possible hijack, not a missed stamp | First-mint memo (§3.3); T3; R1 restated |
| 3 | major | Re-translation is not stable at default settings (`retranslations=2`), and saturation passes re-mint; the join analysis was wrong | First-mint memo; §3.6 of the draft removed |
| 4 | major | The tie population is large (`tieBypass=301`), and the gates could pass a net loss | Acceptance 3–5; tie counters recorded |
| 5 | minor | The 70.6 % `g2global` share is of the baseline, not of 4.C's increase | §2.4 corrected; `niGuard` recorded |
| 6 | minor | Budget-twins pin, `layoutQualKey` pure pins, docstrings, `Tuple.pair`, `test/elm` placement | Step 8; `layoutQualKey` kept unchanged; `tupleExpr`/binops; T6 in `test/eco-elm` |
| 7 | minor | The record-width reason for `LssMemberTable` was stale | The table is in `Env` (§3.5) |
| 8 | minor | Let recursion and "written once" were described wrongly | §3.2 opaque rule; the memo removes the need for write-once |
| 9 | nit | The stage hint shows arity agreement, not one member | Replaced by the census row: one member, `abiMismatch` (§0.1) |
| 10 | nit | §4 contradicted §3.1 | §4 rewritten |
| 11 | nit | The LSS_024 row no longer exists; drop the signature for root folds | Cites LSS_017's amendment; root lambdas get no signature |

## 8. Not in scope

- Lowering sets with several members to sums (`plans/lss-sum-lowering.md`).
- Grounding `g|`/`c|` members per instantiation (fidelity GAP-1).
- A runtime guard at declined sites, and splitting members after monomorphization
  (`lss-body-mismatch-declines.md` §4.B and §4.D). Both act after the paper's point of decision.

## 9. Implementation record (2026-11-22)

Built as §5 describes, on snapshot `snapshots/lss-loop/cq-base` (the base tree). Base compiler B =
`build/compiler/build-kernel/bin/eco-optNOW`; candidate C = `eco-optCQ` (same directory; a native
compiler must live there to find `share/eco/system`).

### 9.1 What was built

- `Compiler.IR.Typed.FreeLocals` (new; `freeLocals`/`children` moved from `LiftClosedArgs`,
  `lambdaTable` added); `Env.lambdaFreeLocals` built in `initState`.
- `Engine.lambdaMemberLayoutQualified` rewritten around `mintKeyFor`, `recordFirstMint`,
  `noteMemoHit`, `captureSigFor`, `renderCaptureSig`, `annoToken`, `memberTokens`,
  `withCaptureSig`; `LssMemberTable.firstMint/familyOf/families`; `LayoutQualStats` capture
  counters; `Mono.arrowAnnosInOrder`; the `layoutQual:` report line gains `capQual capOpaque
  capMissing memoHit sigDrift capFamiliesSplit`.
- Tests: `CaptureQualTest` (T3 agreement over all four mint sites incl. a two-instance local-multi
  check, T4 `alt`/`ping`-`pong` termination at the unlimited budget with `specBreadth = 64`, T5
  rendering); `LayoutQualTest` split/budget-twins/spiral pins re-baselined and T2
  (`mid2`, sharing kept) added; `test/eco-mlir/src/CaptureQualFoldTest.elm` (T7) and
  `test/eco-elm/src/CaptureQualMapTest.elm` (T6). T7 was shown to fail on B (one `myFoldr` spec,
  `segmentation_unknown`) and passes on C (three specs, all `singleton_fast`); T6 passes on both
  (it guards results, not dispatch — §5 step 1 was wrong that it fails today).
- **Negative control for the blocker:** with `memberTokens` rendering captured lambdas by their own
  id instead of by family, T4's `alt` and `ping`/`pong` both hit the 64-spec watchdog; with
  families they close (`alt` ≤ 5 specs).
- LSS_017 and LSS_018 amended, LSS_042 added; theory docs (`lambda-set-specialization.md`,
  `monomorphization.md`) and fidelity rows 103/107/134/228 updated (step 12).

### 9.2 A pre-existing miscompile this change exposed, and its fix

The first bootstrap passed, yet the native C compiler **segfaulted on every cold compile**
(`Terminal_Main_lambda_N$cap` in `Compiler.Type.State.Vector.imapM_`, reached from the type
solver). Root cause, reproduced on a 40-line program that **also segfaults under B**
(`test/eco-elm/src/FoldPureAccumulatorTest.elm`):

    steps action xs = List.foldl (\x ioAcc -> andThen (\_ -> action x) ioAcc) (pure ()) xs

Call arguments were translated left to right. The step lambda (argument 1) was translated, its
parameter types read back and its body's `andThen` demand filed, before the call `pure ()`
(argument 2) put `p|pure|1` into the accumulator's set. So `andThen`'s `ma` set was the one-member
`{step lambda}`, AbiCloning stamped `ma s` as a direct call to the step lambda, and the first
iteration ran it on `pure ()`'s closure. In the self-compile under B the same false singleton
existed but was *declined* by the fingerprint fence, because B's shared step-lambda member had
several differing instances; capture qualification gave each `imapM_` copy its own member, the
fence passed, and the latent bug fired.

**Fix:** `Translate.traverseLambdasLast` — with LSS on, a call's lambda-literal arguments are
translated after its other arguments (results kept in position), at the indirect, fast and slow
global-call paths and `translateArgsWith`; the rule `translateLocalMultiLet` already follows for
let-bound functions. Pinned by `LambdaArgOrderTest` (fails with the reordering disabled: `ma` set
`{22}`) and the E2E fixture. After the fix C compiles the benchmarks, the reproductions, and the
compiler itself from a **cold** cache, and the cold self-compile output is byte-identical to the
bootstrap's MLIR.

**Trap recorded:** the bootstrap's Stage 8 self-compile runs on the warm `build-kernel/eco-stuff`
cache left by Stage 7a, so it never type-checks and the 8c fixed point did **not** exercise the
type solver: a compiler that crashes in `Compiler.Type.Solve` passed 8c. A cold self-compile
(`--no-cache` with `eco-stuff` moved aside) is the real check.

### 9.3 Gates (all on the final tree)

| gate | result |
|---|---|
| elm-tests | 22,081 passed, 0 failed |
| `full` (E2E) | 3,155 passed, 0 failed; eco-system 239/239; conformance 35/35; node-addon, driver-cli pass |
| `bootstrap` | 4b and 8c fixed points pass; plus a cold self-compile fixed point by hand |
| `stress` | 114/114 |
| rail (`DIFF=B`) | 649 hashed; the same 4 compile failures as B (pre-existing); 36 workloads' emission differs; no `EngineBug`; summed census `bodyMismatch` 102→3, `abiMismatch` 55→0, stamps 2,025→2,422, `noInstance` 268→267, `blocked` 17→17 |
| heap-validate | see §9.5: no validation failure |

### 9.4 Measurements (step 10)

**Benchmark compile (census).** `bodyMismatch` 125→0, `abiMismatch` 77→0, stamps 1,218→2,237,
`blocked` 2→2, `noInstance` 191→191, `muTie tied` 0→0; generic call sites in the MLIR
(`generic_apply` + `segmentation_unknown`) 604→405; `List.fold*` hosts 738 stamps + 198 declines →
1,750 stamps + 0; `foldrHelper` copies 93→167; `.mlir` 813,647→878,163 B (+7.9 %).

**Benchmark timings** (native, one run each, then three alternating re-runs of every workload past
±5 %): geomean C/B **0.998**, peak RSS C/B 1.001. Confirmed by the re-runs: fasta +8 %, sha256 +8 %,
levenshtein +8 %, revcomp +6 %, kernel-callbacks +5 %, string-callbacks +4 %; hot-lambda −9 %,
merkletrees −4 %. The regressed workloads' own code is identical (kernel-callbacks: every reachable
function equal once symbols are erased) or strictly more direct (fasta, levenshtein: the differing
functions are split fold copies whose calls went from generic to `singleton_fast`), so these are
attributed to code placement, not code; not otherwise proven.

**Acceptance 3 — met (measured with the call census).** `gen` is 460,835 in B and C for
bytes-u8-rows because it counts only the trampoline path, here the byte decoder's per-element
`read_u8` kernel-closure call, which this change does not touch. With the call census, its inline
generic dispatch (`indirect`) falls **1,387,205 → 464,405 (−67 %)** and direct calls to `$cap`
closures rise by 462,000: the `foldrHelper` split. Over all 80 workloads, total generic dispatch
(`helper` + `indirect`) **rises in none, falls in 49**, and in sum falls 102,678,472 → 69,107,230
(−32.7 %); hot-lambda 12.0 M → 5, list-map and list-filter 2.0 M → 5
(`/tmp/lss-cq/runs/cc-compare.txt`).

**Self-compile** (cold, `--no-cache`, 3 alternating runs): wall B 68.58 s → C 68.10 s (median,
−0.7 %), peak RSS +1 %; `.mlir` 12,827,371 → 13,395,924 B (+4.4 %, above the 3.3 % reference);
census `bodyMismatch` 1,618→512, `abiMismatch` 329→0, stamps 18,419→24,890, `noInstance`
6,779→6,859, `blocked` 7→7, `muTie tied` 0→1, `capFamiliesSplit` 699, `sigDrift` 0.

**Acceptance 4 — met (measured with the call census).** The trampoline path alone (`gen`) rose
49,796,615 → 51,770,522 (+3.96 %; `helper` 21.30 M → 22.57 M in the instrumented builds),
concentrated in anonymous `$cap` lambdas, `IO.andThen` wrappers and `Tuple.pair`. But that path is
the smaller part: inline generic dispatch fell 308.88 M → 242.56 M, so the self-compile's **total
generic dispatch fell 330.18 M → 265.13 M (−19.7 %)**, and direct calls to `$cap` closures rose
253.25 M → 300.44 M (+18.6 %). (Instrumented compilers: B's `ecoNOW.mlir` and C's bootstrap MLIR
lowered with `ECO_CALL_CENSUS=1`, both compiling the current tree cold.)

**Acceptance 6 — first measured NOT met; met after §9.6.** With the original link, four workloads
stayed 5 % or more slower after three alternating re-runs: fasta +8 %, sha256 +8 %, levenshtein
+8 %, revcomp +6 % (kernel-callbacks +5 %); self-compile wall −0.7 %. The user chose to stabilize
the runtime's placement first (§9.6); measured again with both B and C linked that way, every
workload is under 5 % (§9.6). The evidence that the original gaps were placement: fasta, sha256, levenshtein
(+8 %), revcomp (+6 %) and kernel-callbacks (+5 %) retire the same number of instructions in B and
C (`perf stat`, within 0.1 %) with 3–10 % more cycles. Lowered with forced 64-byte function and
block alignment, fasta and sha256 fall to 1.03, revcomp 1.01, kernel-callbacks 1.00,
string-callbacks 1.01 (hot-lambda keeps its win, 0.87). levenshtein stays slower (1.17 aligned),
but ~90 % of its cycles are in runtime C++ (`Allocator::resolve`, `ListOps::probeShape`,
`GCStats::recordAllocation`, `alloc::listTailOf`, …), byte-identical object code in both binaries
whose placement moves with the size of the generated code and which the alignment flags do not
touch; its one generated hot function is ~10 % of samples in both.

**Acceptance 5 — met.** In the self-compile census no host of the sigFlow family has fewer
`stamp` outcomes in C: `Compiler.Type.State.IO.andThen` 170→205 (declines 3→0), `IO.map` 87→87,
`IO.mapMGo_` 10→10, `UnionFind.modifyS` 25→33 (declines 2→0), `UnionFind.getS`, `Solve.restore`,
`Solve.restoreContent`, `Type.variableToCanTypeMiss`, `variableToErrorType` unchanged. Across all
2,908 hosts only one loses stamps (`Compiler.IR.Mono.tupleMapAccum` 100→95, risk R4); total
per-site stamps 21,934→28,467.

**Acceptance 1 and 2 — met:** §9.3, and in C's benchmark MLIR every `List.fold*` census row is
`stamp`, `arityOver` or `ni:g1kernel` (no `abiMismatch`/`bodyMismatch`); the census row for
`foldrHelper_$_704`'s successors is `stamp`.

**Constructor-representation flags on vs off, under C** (user request): geomean time off/on
1.031, peak RSS off/on 1.076 — the same picture as on B (ctor-wrapper 2.24×, ctor-maybe 1.34×,
ctor-step 1.34× slower off; ctor-tokens RSS 537→1,654 MiB off; bytes-u8-rows again faster off,
0.89). Tables: `/tmp/lss-cq/runs/compare.txt`.

### 9.5 Heap-validate gate (`build-validate`, once at plan end)

- `full` (E2E): **3,156 passed, 0 failed**; eco-system 239/239; conformance 35/35. The target's
  exit status is 1 because of one failure outside the E2E suite, `node-addon/cpp-ports-example`:
  it compares the example's whole stderr with one summary line, and in a validate build the
  runtime's P1 tripwire (`P1Census.cpp`: `env_mode = ECO_HEAP_VALIDATE ? 2 : 1`) appends its
  `[p1-census]`/`[survivor-write-census]` report at exit (`mismatched=0`, `violations=0`). The
  summary line itself is exactly the expected one. **Reproduced identically on the base sources**
  (`cq-base` restored, `build-validate` Stage-1 rebuilt, `run-node-addon-tests.sh` rerun):
  pre-existing, unrelated to this plan. **Checker fixed** (house rule: an artificial blocker
  in our own checker is fixed, keeping its intent): `test/embed/run-node-addon-tests.sh` now leaves
  `[p1-census]`/`[survivor-write-census]` lines out of the stderr comparison; the node-addon suite
  then passes in both `build-validate` and `build` ("node-addon: all passed"). The six `[heap-validate]` lines in the E2E log come from the
  runtime unit tests' negative controls ("PM1 / PM3 / PM4 fire on a double copy ...", IM1, TV2).
- `stress` under `benchmarks/heap-config-gc-pressure.json` with the watchdog raised as previously
  recorded (`ECO_TEST_TIMEOUT_SECONDS=5400`), one run of the whole suite: **113/114**, no
  `[heap-validate]` line. (With the default 60 s watchdog the two eco/system socket programs time
  out, 111/114.) The one failure, `JsonLargeArray` ("out of memory: cannot allocate 8184 bytes
  for an object in the nursery"), **fails identically on the base sources in the validate tree**
  and in the normal tree under the same config, and passes at the default config: pre-existing,
  unrelated.
- Cold self-compile identity: three separate cold self-compiles of the final tree by C are each
  byte-identical to the bootstrap's MLIR.

### 9.6 Stable runtime placement, and acceptance 6 re-measured (2026-11-23)

The user chose to stabilize placement before judging acceptance 6. `EcoNativeDriver.cpp` now gives
every executable link an augmenting script,
`SECTIONS { .text.eco_runtime : { *<archive>:*(.text .text.*) ... } } INSERT BEFORE .text;`,
over the project archives (entry, runtime, Elm kernels, eco kernels and system). Their code then
precedes the program's, right after the fixed-size PLT sections, instead of following it in input
order. Checked: both `ld.bfd` 2.40 (host) and `ld.lld` (bundle) accept it on a synthetic archive
link; in the benchmark binaries every runtime function sits at the same offset modulo 4,096 in B
and C (`Allocator::resolve` …330, `alloc::listTailOf` …b50, `eco_alloc_with_roots` …780), where
before they were displaced by the difference in generated-code size. Documented in
`design_docs/theory/backend/native-drivers.md` ("The link").

Re-measured with both builds relinked (`/tmp/lss-cq/runs/compare-st.txt`, `st-reruns.txt`):
benchmark geomean C/B **0.992**; one full run flagged only binary-trees (1.06), and three
alternating re-runs of it and of the former regressors give binary-trees 1.04, fasta 1.02, sha256
1.00, levenshtein 0.96, revcomp 0.99, kernel-callbacks 1.00 — **no workload 5 % or more slower**.
Self-compile, both compilers relinked, three alternating cold runs: B 68.66 s, C 68.36 s median
(−0.4 %); the relinked C's output is byte-identical to the bootstrap MLIR. **Acceptance 6 is met.**

### 9.7 Not fixed here: `JsonLargeArray` under GC pressure

Recorded for a separate task (user decision 2026-11-23): `test/stress-elm/src/JsonLargeArray.elm`
aborts under `benchmarks/heap-config-gc-pressure.json` with "eco: out of memory: cannot allocate
8184 bytes for an object in the nursery (old generation 18792448 of 21474836480 bytes in use)", in
the normal and the validate tree, with the base sources (`cq-base`) as with this plan's; it passes
at the default heap config. The old generation is nearly empty when it fails, so the nursery
(capped at 4 blocks by that config) cannot place an 8,184-byte object, just under the 8K
large-object threshold, after a minor GC; a runtime allocation bug, not a compiler one.

### 9.8 Final gates (tree after §9.6; snapshot `cq-final`)

| gate | result |
|---|---|
| elm-tests | 22,081 passed, 0 failed (no Elm change after §9.2) |
| `bootstrap` | 4b and 8c fixed points pass; three cold self-compiles byte-identical to the bootstrap MLIR |
| `full` (E2E) | 3,155 passed, 0 failed; eco-system 239/239; conformance 35/35; node-addon all passed; driver-cli all passed |
| `stress` | 114/114 |
| rail (`DIFF=B`) | only the 4 compile failures B has |
| heap-validate `full` | **rc 0**: 3,156 passed, 0 failed; eco-system 239/239; conformance 35/35; node-addon (with the §9.5 checker fix) and driver-cli all passed. One earlier run lost the runtime unit test "PM1 / PM3 / PM4 fire on a double copy ..." (a negative control whose child did not abort); it passed six times alone, the whole unit suite passed 3,156/3,156 alone, and the full re-run passed. |
| heap-validate `stress` under the pressure config (`ECO_TEST_TIMEOUT_SECONDS=5400`) | 113/114, no `[heap-validate]` line; the one failure is `JsonLargeArray`, pre-existing (§9.7, `plans/jsonlargearray-nursery-oom-under-pressure.md`) |

All six acceptance criteria hold (§9.4, §9.6).

### 9.9 User decisions (2026-11-23)

- **Criteria 3 and 4:** the user accepted the measurement correction: total generic dispatch
  (call-census `helper` + `indirect`) is the measure, not `ECO_DISPATCH_STATS`'s trampoline-only
  `gen` (which rose +3.96 % on the self-compile while the total fell 19.7 %).
- **Criterion 6:** the user chose to stabilize the runtime's placement first (§9.6), after which it
  holds as written.
- **`JsonLargeArray` under GC pressure:** the user chose to record it and fix it separately
  (`plans/jsonlargearray-nursery-oom-under-pressure.md`); it is pre-existing (§9.7).
- **The runtime negative control "PM1 / PM3 / PM4 fire on a double copy ..."** (failed once under
  load in a heap-validate run, then passed 6/6 alone, the unit suite 3,156/3,156 alone and the full
  re-run): the user chose to record it as flaky, for separate investigation.

- **Closing (2026-11-23):** the user chose to stop with `JsonLargeArray` and the flaky negative control recorded as above, outside this plan.
