# Bytes fusion: broader recognition without Eco-specific patterns

Two changes to extend the existing `Compiler.Generate.MLIR.BytesFusion` reifier
so it fires on a wider set of encoder shapes. Both stay strictly within the
public `elm/bytes` API surface — no Eco-internal helper modules in either the
inliner whitelist or the reifier pattern set.

The investigation in
[the encoder-fusion report](#) (sibling conversation, not yet a doc) showed
that the compiler's own bytecode and `.ecot` encoders are essentially
unfused — fusion fires at one site in the entire `eco-compiler.mlir`.
Three independent blockers were identified; this plan addresses two (fix 1
and fix 3 in that report). Fix 2 (recognise Eco-specific helpers in the
reifier) is explicitly out of scope per the design constraint that bytes
fusion must remain a general-purpose elm/bytes mechanism.

## Constraint

The **reifier's pattern set** must stay general: it may only match on
upstream `elm/bytes` API symbols (`Bytes`, `Bytes.Encode`, `Bytes.Decode`)
plus elm/core list primitives used in their idiomatic encoder shapes
(`List.map`, `(::)`, `List.length`). It must NOT match on Eco-internal
helper names like `Utils.Bytes.Encode.list`. The mechanism must work
identically for any program written against elm/bytes.

The **inliner's whitelist** has no such restriction. Inlining a helper
just substitutes its body at the call site; the resulting MonoExpr is
ordinary code that the general reifier may or may not recognise. We can
freely whitelist Eco-internal encoder helpers — and should, because that's
how their inlined bodies become reifiable via the general patterns added
in fix 3.

## Fix 1 — broaden the inliner whitelist + raise the threshold

### What

Two complementary changes in `Compiler.GlobalOpt.MonoInlineSimplify`:

1. **Populate `defaultWhitelist`** (`MonoInlineSimplify.elm:149`) with
   the elm/bytes public-API primitives **and** Eco-internal encoder /
   decoder helpers. Anything on the whitelist bypasses the cost threshold.
2. **Raise `inlineThreshold`** (`MonoInlineSimplify.elm:341`) from 10 to
   a value (40 is a reasonable starting point) high enough that the
   common encoder helpers pass the cost gate even without being whitelisted,
   so future helpers in the same style inline automatically.

The two are belt-and-braces. The whitelist is the surgical guarantee for
the helpers we *know* need to inline. The raised threshold catches future
helpers and reduces the maintenance burden of keeping the list complete.

### elm/bytes API entries (general)

`Bytes.Encode` side (each is a constructor or thin wrapper):

| Qualified name              | Body shape                                                      |
|-----------------------------|-----------------------------------------------------------------|
| `Bytes.Encode.signedInt8`   | `= I8`                                                          |
| `Bytes.Encode.signedInt16`  | `= I16`                                                         |
| `Bytes.Encode.signedInt32`  | `= I32`                                                         |
| `Bytes.Encode.unsignedInt8` | `= U8`                                                          |
| `Bytes.Encode.unsignedInt16`| `= U16`                                                         |
| `Bytes.Encode.unsignedInt32`| `= U32`                                                         |
| `Bytes.Encode.float32`      | `= F32`                                                         |
| `Bytes.Encode.float64`      | `= F64`                                                         |
| `Bytes.Encode.bytes`        | `= Bytes` (1-arg ctor wrapper)                                  |
| `Bytes.Encode.string`       | `\str -> Utf8 (Elm.Kernel.Bytes.getStringWidth str) str`        |
| `Bytes.Encode.sequence`     | `\builders -> Seq (getWidths 0 builders) builders`              |
| `Bytes.Encode.getStringWidth` | `= Elm.Kernel.Bytes.getStringWidth`                           |

`Bytes.Decode` side: same set of primitive wrappers and combinators
(`signedInt*`, `unsignedInt*`, `float*`, `string`, `bytes`, `succeed`,
`fail`, `map`, `map2..5`, `andThen`).

**Not** whitelisted: `Bytes.Encode.encode` and `Bytes.Decode.decode`.
These are the kernel boundaries the fusion recognizer fires on. Inlining
their bodies would replace them with the C++ runtime kernel calls,
defeating fusion. The recognizer must see a literal `Bytes.Encode.encode`
call to trigger.

### Eco-internal helper entries

These are *inlining-only* concessions. Adding them to the whitelist does
NOT couple the reifier to Eco internals — it just makes their bodies
visible at the call site, where the general reifier patterns operate on
the substituted MonoExpr.

`Utils.Bytes.Encode` (and symmetric `.Decode`) helpers in
`/work/compiler/src/Utils/Bytes/`:

| Qualified name                       | Body shape                                                       |
|--------------------------------------|------------------------------------------------------------------|
| `Utils.Bytes.Encode.unit`            | `\() -> BE.unsignedInt8 0`                                       |
| `Utils.Bytes.Encode.bool`            | `\b -> BE.unsignedInt8 (if b then 1 else 0)`                     |
| `Utils.Bytes.Encode.int`             | `toFloat >> BE.float64 BE`                                       |
| `Utils.Bytes.Encode.float`           | `BE.float64 BE`                                                  |
| `Utils.Bytes.Encode.string`          | `\str -> BE.sequence [BE.unsignedInt32 BE width, BE.string str]` |
| `Utils.Bytes.Encode.maybe`           | `\enc m -> case m of Just v -> BE.sequence [BE.unsignedInt8 1, enc v] / Nothing -> BE.unsignedInt8 0` |
| `Utils.Bytes.Encode.result`          | similar to maybe                                                 |
| `Utils.Bytes.Encode.list`            | `\enc xs -> BE.sequence (BE.unsignedInt32 BE (List.length xs) :: List.map enc xs)` |
| `Utils.Bytes.Encode.nonempty`        | wraps `list`                                                     |
| `Utils.Bytes.Encode.stdDict`         | `\kE vE -> Dict.toList >> list (jsonPair kE vE)`                 |
| `Utils.Bytes.Encode.assocListDict`   | similar                                                          |
| `Utils.Bytes.Encode.everySet`        | similar                                                          |
| `Utils.Bytes.Encode.jsonPair`        | `\eA eB (a, b) -> BE.sequence [eA a, eB b]`                      |
| `Utils.Bytes.Encode.oneOrMore`       | recursive — see "recursion" note below                           |

Also include any other Eco-side modules with the same pattern:
- `Mlir.Bytecode.VarInt.encodeVarInt` / `encodeSignedVarInt` (small
  switch-on-magnitude wrappers — would compose with fix 3 cleanly once
  inlined).
- `Mlir.Bytecode.Section.encodeSection` (literal-list `BE.sequence`).
- Any `*Encoder` / `*Decoder` aliases that are pure compositions.

### Recursion

`MonoInlineSimplify` already refuses to inline recursive functions
(`isRecursive` check at `MonoInlineSimplify.elm:467`). Functions like
`oneOrMore` (recursive on the `More` constructor) won't be inlined even
when whitelisted — the recursive call stays as a function call. The
non-recursive shell still inlines if the body cost permits, which is
adequate for now.

`Bytes.Decode.andThen` and `Bytes.Decode.loop` are not themselves
recursive in their definitions — they're recursive in their *usage*.
The inliner check should accept them; verify during implementation.

### Threshold raise

Current `inlineThreshold = 10`. The encoder helpers measure around 20–35
on the `computeCost` scale (e.g. `Utils.Bytes.Encode.list` is ~33,
`string` is ~30). Raising the threshold to **40** would let them pass
without whitelisting, with a margin for future helpers.

Caveat: the threshold is global. Bumping it inlines more functions
everywhere, not just bytes ones. Risks:
- Larger post-inline MLIR (every >10-cost function previously rejected
  now becomes eligible).
- Longer inliner passes.
- Possible code-size impact on Stage 7 binary (more inlining → larger ELF).

The whitelist is precisely scoped; the threshold raise is the safety net.
We can ship with just the whitelist first and only raise the threshold if
real-world programs we don't control are still missing fusion. Alternative
sequencing in the implementation steps below.

### Why this is safe

The whitelist bypasses only the *cost* gate. It does not change
inlinability eligibility (`getInlinableBody` still gates) and does not
fire on recursive functions (`isRecursive` check still applies). Per-call
expansion is bounded by the body cost (~30 for the largest entries).

### Implementation steps

1. Edit `MonoInlineSimplify.elm:149` `defaultWhitelist` to contain the
   full qualified-name list above.
2. **(Optional, deferred)** Raise `inlineThreshold` from 10 to 40 in
   `MonoInlineSimplify.elm:341`. Measure binary size + bootstrap wall time
   before keeping.
3. Verify by re-running Stage 7a and grepping `.mlir` for
   `@Utils_Bytes_Encode_list_` etc. — should drop substantially.
4. Run E2E + stress + Stage 7 bootstrap.

### Expected impact for the Eco compiler

**Now substantial**, because the helpers are in scope. After inlining,
`Utils.Bytes.Encode.list encoder xs` at a call site becomes

```elm
BE.sequence (BE.unsignedInt32 BE (List.length xs) :: List.map encoder xs)
```

which the general reifier's new `ELoop` pattern (fix 3) catches. Similarly
`Utils.Bytes.Encode.string str` becomes
`BE.sequence [BE.unsignedInt32 BE width, BE.string str]` — a literal list of
elm/bytes primitives, reified directly via the existing literal-list
pattern.

The chain holds for nested compositions: `assocListDict keyE valueE dict`
becomes `Dict.toList >> List.reverse >> list (jsonPair keyE valueE)` after
inlining each layer. Each composition step inlines, then the outermost
`list` matches the ELoop pattern.

The remaining gap after fixes 1+3 is **higher-order parametric encoders**:
`Utils.Bytes.Encode.list encoderFn xs` where `encoderFn` is a function
parameter (passed in by an outer helper, not a global). After inlining
`list`, the inner `List.map encoderFn xs` has `encoderFn` as a local
variable — the reifier can apply it to a synthetic var, but if the local
isn't bound to a known global or closure in `exprCache`, reification of
the body fails and the whole loop falls back. This is the
HO-specialisation gap noted in the open questions.

## Fix 3 — `EncoderLoop` for length-prefixed dynamic sequences

### What

The dominant pattern in real-world Bytes encoders is

```elm
BE.sequence
    ( BE.unsignedInt32 BE (List.length xs)
        :: List.map perElementEncoder xs
    )
```

— a length-prefixed list serialised by mapping a per-element encoder over
the inputs. The reifier currently rejects this because `reifyEncoderList`
(`Reify.elm:337`) only accepts a literal `MonoList`. `(::)` plus
`List.map` is dynamic structure.

The decoder side already has a parallel pattern handled —
`DCountLoop CountSource DecoderNode` (`Reify.elm:86`, fused-bytes-plan
Phase 4). This change adds the encoder counterpart.

### New `EncoderNode` variant

```elm
type EncoderNode
    = ... existing variants ...
    | ELoop
        { itemVar : String        -- name of the per-iteration item binding
        , itemNodes : List EncoderNode  -- encoder for one iteration
        , iterExpr : Mono.MonoExpr      -- the list expression (xs)
        , countExpr : Mono.MonoExpr     -- length expression (e.g. List.length xs)
        }
```

`itemNodes` is the encoder of one iteration, with the per-iteration item
referenced via `MonoVarLocal itemVar` inside. `iterExpr` is the source
list; `countExpr` is its length (used for the total-width pre-allocation,
typically `List.length iterExpr` but separated so the reifier can also
recognise a precomputed length).

### Reifier extension

Inside `reifyEncoderList`, before the literal-`MonoList` arm, add a pattern
that recognises:

```elm
Elm.Kernel.List.cons headerEncoder (Elm.Kernel.List.map mapFn iterExpr)
```

or the slightly different shape

```elm
Elm.Kernel.List.cons headerEncoder (List.map mapFn iterExpr)
```

depending on how the monomorphizer lowers `(::)` and `List.map`. (Both are
core elm/list operations, in the elm/core public API — within the
constraint.) The recognizer:

1. Reifies `headerEncoder` as a normal encoder (typically a 4-byte
   `EU32 BE (List.length xs)`).
2. Applies `mapFn` to a fresh local var (synthetic `_x` etc.), passes the
   result through `reifyEncoderHelp` recursively. If reification succeeds,
   you have the per-iteration encoder body.
3. Constructs `ELoop { itemVar = "_x", itemNodes = body, iterExpr = xs,
   countExpr = ... }`.
4. Returns `[headerNode, ELoop ...]` as the flattened sequence contribution.

Edge cases to think through:

- `mapFn` is a `MonoClosure (\x -> body)` — substitute `_x` for `x` in
  body and reify. Cleanest case.
- `mapFn` is a `MonoVarGlobal` to a named function — without
  HO-specialisation, the reifier can't see the body. Fall back to `Nothing`
  (no fusion). Higher-order specialisation in the monomorphizer would lift
  this case to a closure form per call site, but that's outside this plan.
- `mapFn` is a `MonoVarLocal` bound to a `MonoClosure` in `exprCache` —
  resolve and treat as the closure case.

The reifier already maintains an `exprCache` for `MonoLet`-bound locals
(`Reify.elm:194`), so the local-closure case is straightforward.

### LoopIR extension

Add an `Op` variant in `Compiler.Generate.MLIR.BytesFusion.LoopIR`:

```elm
type Op
    = ... existing ...
    | WriteEachItem
        { cursorVar : String
        , itemVar : String
        , bodyOps : List Op
        , iterExpr : Mono.MonoExpr
        , itemByteWidth : Int     -- compile-time-known per-iteration byte cost
        }
```

`itemByteWidth` is computable at reify time because the per-iteration body
contains only primitive writes (each with a constant byte width) — if the
body itself contains a nested `WriteEachItem` or a `Utf8`/`Bytes` write
with a dynamic width, fall back to unfused (`Nothing` from the reifier).

### `nodesToOps` extension

Extend `nodesToOps` (`Reify.elm:397`) to handle `ELoop`:

```elm
nodeToOp cursorName node =
    case node of
        ... existing ...
        ELoop r ->
            WriteEachItem
                { cursorVar = cursorName
                , itemVar = r.itemVar
                , bodyOps = List.map (nodeToOp cursorName) r.itemNodes
                , iterExpr = r.iterExpr
                , itemByteWidth = sumWidths r.itemNodes
                }
```

`sumWidths` returns `Just N` only when every node in the body has a
constant byte width; otherwise the loop can't be reified.

### Width pre-computation for the `bf.alloc`

`computeWidth` (in `nodesToOps`) currently sums per-node constants. For
`ELoop r` the contribution is `r.itemByteWidth * (List.length r.iterExpr)`.
At codegen time this becomes a runtime multiply: emit MLIR to call
`Elm.Kernel.List.length` on `iterExpr`, multiply by the constant
`itemByteWidth`, add to the running total.

The width expression therefore becomes a small SSA arithmetic tree rather
than a pure constant. The existing `WidthExpr` type (referenced in the
import list `Reify.elm:38`) likely already supports SSA mixes — extend it
if not.

### MLIR emit (`BytesFusion.Emit`)

For `WriteEachItem`:

1. Emit a call to `Elm.Kernel.List.length` on `iterExpr` to get the count.
2. Emit an `scf.for` loop from 0 to count, with the iteration variable
   stepping through the list (via repeated `Cons.head` / `Cons.tail` walks
   threaded as a loop-carried operand).
3. Inside the loop body, emit the body ops with the per-iteration item
   bound to the current list head.
4. The cursor is loop-carried — each iteration's `bf.write.*` returns a
   new cursor.

The decoder side's `DCountLoop` emit already builds an `scf.for` with
loop-carried cursor; mirror its structure. The encoder version is simpler
because the cursor monotonically advances (no decoder bookkeeping).

### Pattern coverage check

The fused-bytes-plan documents the recognition patterns the existing
recognizer handles. Adding `ELoop` covers:

| Source shape                                                     | Status |
|------------------------------------------------------------------|--------|
| `BE.sequence [literal primitive, literal primitive, ...]`        | Already fused |
| `BE.sequence (BE.unsignedInt32 BE (List.length xs) :: List.map BE.unsignedInt8 xs)` | **New: fuses via ELoop** |
| `BE.sequence (header :: List.map (\x -> BE.unsignedInt32 BE x) xs)` | **New: fuses via ELoop with lambda body** |
| `BE.sequence (header :: List.map myEncoder xs)` where `myEncoder` is global | Still unfused (HO-specialisation needed) |
| `Bytes.Decode.loop` over a count                                 | Already fused (DCountLoop) |
| `Bytes.Decode.map (\xs -> ...) (Bytes.Decode.loop ...)` reverse  | Already fused |

The new variant unlocks the encoder counterpart of length-prefixed-list
decoding — by far the most common dynamic-length encoder shape in
production elm/bytes code.

### Recognition through fix 1

Fix 1's whitelist makes `Bytes.Encode.sequence`, `Bytes.Encode.unsignedInt32`,
**and** Eco helpers like `Utils.Bytes.Encode.list` all inline at the call
site. After inlining a `Utils.Bytes.Encode.list encoder xs` call, the call
site contains

```elm
BE.sequence (BE.unsignedInt32 BE (List.length xs) :: List.map encoder xs)
```

— with `encoder` substituted to whatever was passed in (a global like
`Bytes.Encode.signedInt32`, a lambda, or a let-bound value). After the
nested `BE.sequence` and `BE.unsignedInt32` also inline (also whitelisted),
the call site reaches the constructor form
`Seq (getWidths 0 (U32 BE n :: List.map ...)) (U32 BE n :: List.map ...)`
which the reifier already recognises down to the body shape
`U32 BE n :: List.map ...`. The new `ELoop` pattern then fires on this
shape. Fixes 1 and 3 compose end-to-end.

The reifier never needs to know that `Utils.Bytes.Encode.list` exists. It
only sees `BE.sequence`, `BE.unsignedInt32`, `(::)`, `List.map`, and the
substituted per-element encoder expression — all in scope of its general
pattern set.

### Implementation steps

1. **Reifier extension** (`Reify.elm`):
   - Add `ELoop` to `EncoderNode`.
   - In `reifyEncoderList`, add a pattern arm matching the
     `cons :: List.map` shape using the `Elm.Kernel.List.cons` and
     `Elm.Kernel.List.map` recognisers (or stdlib `List.map` after
     monomorphization).
   - Handle the lambda and let-bound-lambda cases for the map fn.
2. **LoopIR extension** (`LoopIR.elm`):
   - Add `WriteEachItem` Op variant.
3. **`nodesToOps`** (`Reify.elm`):
   - Map `ELoop` to `WriteEachItem`.
   - Reject if any body node has non-constant byte width (no nested loops
     with non-constant inner bodies, no slice-width-dependent ops in this
     first pass).
4. **Width pre-computation**:
   - Extend `WidthExpr` if needed so the `bf.alloc` size can include a
     `count * constWidth` term per loop.
5. **Emit** (`Emit.elm`):
   - Emit `scf.for` over the list spine with loop-carried cursor.
   - Cursor return becomes the loop's iteration result, fed to the next op.
6. **bf MLIR dialect**:
   - No new dialect ops needed if `scf.for` + existing `bf.write.*` suffices
     (which mirrors how `DCountLoop` works on the decoder side).
7. Tests:
   - Add a representative Elm test that exercises
     `BE.sequence (header :: List.map BE.unsignedInt32 xs)` and verifies
     the round-trip plus the absence of `Elm_Kernel_Bytes_encode` in the
     generated MLIR for that function.
   - Re-run E2E + stress + Stage 7 bootstrap.

### Risk

Medium. The reifier addition is local and falls back to `Nothing` on any
case it can't handle — no behavioural regression risk. The emit side is
where bugs would manifest: the `scf.for` + loop-carried cursor needs to
match the existing decoder loop's calling conventions exactly. The
decoder side is a working template, so this is mostly mechanical.

The width pre-computation may need extension to handle non-constant
expressions in the alloc size; the existing decoder path already does this.

### Expected impact

Together with fix 1, this is the major unlock. The dominant unfused
pattern across both general elm/bytes code and the Eco compiler self-code
is length-prefixed dynamic arrays — every list-of-T encoder, every
collection serialiser, every length-prefixed buffer write. Fix 1 inlines
the helper that wraps this pattern (`Utils.Bytes.Encode.list` and
friends); fix 3 reifies the exposed pattern.

For the Eco compiler specifically: the 358 unfused
`@Utils_Bytes_Encode_list_*` call sites should largely disappear from the
generated MLIR, replaced by `bf.write.*` ops inside `scf.for` loops. The
1068 `@Bytes_Encode_sequence_*` calls will drop sharply because the
sequence wrapper inlines. The 240 `@Bytes_Encode_unsignedInt8_` calls
will collapse into direct `bf.write.u8` ops at the call site.

Caveat: higher-order parametric encoders (where the per-element encoder is
a function-typed parameter passed through a chain of helpers) still won't
fuse until the local-variable case in the reifier is extended to chase
through known-bound encoder values. Fix 3 lays the groundwork; the
follow-on HO-specialisation work is tracked under open question 4 below.

## Empirical findings from the first implementation pass

Fix 1 and Fix 3 scaffolding both landed and pass E2E + stress + bootstrap
(green; 12:38 wall, 4.17 GB peak — within ±2 % of baseline). However the
observable fusion footprint is unchanged: the compiler's self-MLIR has 8
fused `bf.write.*` ops both before and after, and zero `bf.write.*` ops
inside any `scf.while`. The fusion entry never fires on the helper-rich
paths.

Two independent reasons surfaced:

1. **The fusion entry is unreachable for the inlined `BE.encode` shape.**
   `Bytes.Encode.encode = Elm.Kernel.Bytes.encode` is a 1-cost wrapper,
   well under `inlineThreshold = 10`. The inliner replaces every
   `BE.encode (...)` call with a direct `Elm.Kernel.Bytes.encode (...)`
   call. At codegen time the function position is a `MonoVarKernel`, but
   the fusion entry at `Compiler.Generate.MLIR.Expr.generateSaturatedCall`
   only matches `MonoVarGlobal` resolving to `Bytes.Encode.encode`. So
   fusion is never *attempted* on the typical post-inline shape, and the
   `ELoop` pattern matcher has no chance to fire.

2. **Even if the entry fired, `ELoop` doesn't catch the compiler's
   helper-pattern callers.** The dominant inline shape (post-Fix-1) is
   `BE.sequence (BE.unsignedInt32 BE (List.length xs) :: List.map encoder xs)`,
   where `encoder` is the parameter of `Utils.Bytes.Encode.list`
   substituted with whatever the caller passed. The compiler's self-code
   passes *global function references* (`Utils.Bytes.Encode.string`,
   `Compiler.AST.Optimized.exprEncoder`, …) for `encoder`, not inline
   lambdas. `reifyMapBody` only handles the `MonoClosure` case and
   returns `Nothing` for `MonoVarGlobal`, so the loop reifier bails.

The "natural" first fix — an inliner blacklist preventing
`BE.encode`/`BD.decode` from being inlined — was attempted twice and
both times crashed Stage 7a with SIGSEGV very early in execution. Tests
and stress passed; the bootstrap-only failure indicates a latent ABI bug
in the fall-back path at `Expr.elm:2516` that gets exercised at high
volume once the blacklist is in place. Reverted; Fix 1 + Fix 3
scaffolding shipped without the blacklist.

The two follow-up phases below address these two blockers in order.

## Phase 4 — fall-back path audit — DROPPED after diagnostic investigation

Phase 4's original premise was that the inliner blacklist was needed
to make the fusion entry reachable for `Bytes.Encode.encode` calls.
**That premise is wrong.** Investigation via small diagnostic tests
(`/work/test/elm-bytes/src/EncodeLoopFusionTest.elm` and friends —
since deleted after they served their purpose) plus inspection of the
generated MLIR established two facts:

1. **The fusion entry IS reachable for the inlined form.** There are
   *two* fusion entries in `Compiler.Generate.MLIR.Expr` —
   `:2429` matches `MonoCall (MonoVarGlobal _ specId _)` resolving to
   `Bytes.Encode.encode`, and `:2953` matches `MonoCall (MonoVarKernel
   _ _ "Bytes" "encode" _)` (the post-inline form, dispatched from the
   `MonoVarKernel` arm of `generateSaturatedCall` at `:2772`). The
   inliner expands `BE.encode = Elm.Kernel.Bytes.encode` to the kernel
   form, but the `:2953` entry catches it and attempts fusion. So
   fusion IS attempted on the typical post-inline shape — the original
   Phase 4 diagnosis missed this entry.

2. **The reifier bails at `reifyMapBody` even for inline lambdas.** A
   focused test that writes
   `E.encode (E.sequence (E.unsignedInt32 BE (List.length ns) :: List.map (\n -> ...) ns))`
   directly at the call site (no helper, no whitelist gymnastics)
   reaches the reifier, matches every layer of the ELoop pattern (cons
   ✓, List.map ✓, length-prefix header ✓), then bails at the mapFn
   step because the lambda has been *closure-converted* to a
   `MonoVarGlobal @<module>_lambda_N` reference, not a `MonoClosure`.
   The MonoClosure case `reifyMapBody` was written for **never occurs
   in monomorphized production code** — closure conversion always
   intervenes.

The blacklist's actual effect was orthogonal to fusion: with only
`Bytes.Encode.encode` blacklisted, Stage 5 (JS-bootstrap compiling
Elm source) hits a JS stack overflow during compilation; with both
`Bytes.Encode.encode` and `Bytes.Decode.decode` blacklisted, Stage 7a
hits a SIGSEGV very early in the freshly-built compiler's first
compile attempt. Neither failure was localised to the bytes-fusion
fall-back path — both indicated that the inliner has implicit
dependencies on these specific functions being inlined for some
downstream invariant (likely a fix-point or PAP-related interaction).
Rather than spelunking deeper into the blacklist's side effects, the
right move is to skip Phase 4 entirely and head straight for Phase 5
— closing the `reifyMapBody` gap, which gates fusion regardless of
the blacklist.

The latent typo fix at `Expr.elm:2516` (the *other* fall-back path,
which becomes reachable only when the inliner blacklist is enabled)
remains in tree as a defensive correction. It does no harm in the
current configuration — the path it lives on is still unreachable.

## Phase 4 — (HISTORICAL, RETAINED FOR REFERENCE) audit and harden the fusion fall-back path

### Symptom

When the inliner blacklist for `Bytes.Encode.encode` / `Bytes.Decode.decode`
is enabled, the bootstrap crashes in Stage 7a with `Segmentation fault
(core dumped)` very early — about 1500 nursery `Custom` allocations into
the freshly-built `eco-compiler` binary's first compile attempt. No
error message from the compiler itself; the runtime dies before
producing any output. The Stage 5 `eco-compiler.mlir` has the same
`bf.*` op footprint as without the blacklist, so the issue is not
mis-emitted fusion ops — it's the *fall-back* path emitting bad MLIR
that ld-succeeds but segfaults at runtime.

The fall-back path is at `Compiler.Generate.MLIR.Expr.generateSaturatedCall`
around line 2516 (the `Nothing` arm of `case BFReify.reifyEncoder ... of`):

```elm
sig : Ctx.FuncSignature
sig =
    Ctx.kernelFuncSignatureFromType funcType

( boxOps, argVarPairs, ctx1b ) =
    boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

( resVar, ctx2 ) =
    Ctx.freshVar ctx1b

kernelName : String
kernelName =
    "Elm_Kernel_Bytes_encode"

callResultType =
    Types.monoTypeToAbi sig.returnType

( ctx3, callOp ) =
    Ops.ecoCallNamed ctx2 (emitSafepointHints ctx2) resVar kernelName argVarPairs callResultType
```

Pre-blacklist this path was unreachable (every `BE.encode` inlined to a
direct kernel call). Post-blacklist it becomes the dominant emit for
the unfusable encoders.

### Diagnostic hypotheses

The two `Bytes.Encode.encode`-shaped fall-back sites elsewhere in the
same file (`Expr.elm:2988` and `:3007`) use a hand-rolled
`[Mono.MUnit]` paramTypes shape and `Types.ecoValue` result type rather
than running everything through `kernelFuncSignatureFromType`. The first
fix attempt was to align line 2516 with that hand-rolled shape; the
crash persisted, suggesting the issue is **not** purely the ABI shape
chosen.

Plausible culprits, ranked by likelihood:

1. **PAP-creation paths preserve `Bytes.Encode.encode` as a curried
   function value.** With the blacklist, `Bytes.Encode.encode` survives
   as `@Bytes_Encode_encode_$_NNN` and call sites use `eco.papCreate`
   to construct partial applications (observed in the MLIR — 3 PAP-create
   ops, 0 direct calls). The fusion entry only fires for *saturated*
   calls; PAP construction bypasses it entirely. The wrapper function
   `@Bytes_Encode_encode_$_NNN` itself calls `@Elm_Kernel_Bytes_encode`
   via line 2988's path. So fusion never even attempts on the PAP-built
   call sites, and the line 2516 path is irrelevant there. If line 2516
   is being hit *only* for the few non-PAP saturated callers that
   survive the inliner, that's a small population — yet the crash is
   early and deterministic, suggesting another path.

2. **Closure-related ABI mismatch in `boxToMatchSignatureTyped`.** This
   helper boxes each arg to match the kernel's expected paramTypes. If
   `argsWithTypes` includes a value that's already an `eco.value` but
   `boxToMatchSignatureTyped` re-wraps it (e.g. via `eco.construct.custom`
   for `Mono.MUnit`), the result might be a double-boxed encoder that
   the kernel dereferences as a single-boxed value, producing a wild
   pointer at runtime.

3. **Safepoint-hint emission interaction.** `emitSafepointHints ctx2`
   may need updated ctx state after the boxToMatch step; if it captures
   stale state (e.g., misses the new arg vars in the GC root set), the
   kernel call could observe stale-pointer values on entry.

4. **`Types.monoTypeToAbi sig.returnType` vs hardcoded `Types.ecoValue`.**
   For `Bytes.Encode.encode : Encoder -> Bytes`, the return is a
   `Bytes` MonoType. If `monoTypeToAbi` maps `Bytes` to something
   other than `Types.ecoValue` (e.g. a struct-by-value), the call op
   declares the wrong return type and the SSA value is read as the
   wrong shape downstream.

### Diagnostic plan

Step-by-step, smallest reproducer first:

1. **Reproduce minimally.** Add the blacklist for *only* `Bytes.Encode.encode`
   (not `Bytes.Decode.decode`). Re-run the bootstrap. If it still
   crashes, the crash is in an encoder fall-back; if it stops, both
   sides contribute and we need a smaller blacklist. (This isolates
   encoder vs decoder fall-back paths.)

2. **Dump the failing site's MLIR.** With the blacklist enabled, add
   stderr logging to `Expr.elm:2516` that prints the function name +
   arg count + paramTypes whenever the fall-back fires. Compare with
   `:2988`/`:3007` for the same fall-back. If the paramTypes differ in
   shape or count, that's the bug. If they're identical, look further
   afield.

3. **Hardcode the hand-rolled shape and the symbol.** If step 2 shows
   identical shapes, replace the `kernelFuncSignatureFromType` /
   `monoTypeToAbi` calls with `[Mono.MUnit]` and `Types.ecoValue`
   verbatim (the line 2988 shape). This was attempted once and failed
   — but a second iteration with stderr diagnostics would tell us
   whether the shape match is exact or whether there's an interaction
   with `argsWithTypes` (which differs between contexts) or
   `emitSafepointHints` (which depends on the surrounding ctx).

4. **Inspect the generated ops at the crash site.** Build a small Elm
   test program that triggers a fall-back call (e.g.
   `BE.encode (someEncoderFn x)` where the helper isn't inlinable), and
   dump the produced MLIR for that function. Compare with a same-shape
   non-bytes call (e.g. any other 1-arg kernel call). Spot the
   difference.

5. **Trace the crash post-mortem.** Build the Stage 6 ELF with
   `-g` debug symbols; run Stage 7a under `gdb`; capture the stack
   trace at SIGSEGV. The trace will name the function that crashed,
   making it possible to grep back through the MLIR for the offending
   op shape.

### Acceptance for Phase 4

- The inliner blacklist `["Bytes.Encode.encode", "Bytes.Decode.decode"]`
  can be added to `MonoInlineSimplify.defaultBlacklist` (newly introduced
  alongside `defaultWhitelist`) without crashing the bootstrap.
- Stage 7a bootstrap is green; wall-time and RSS within ±5 % of the
  current Fix-1+Fix-3 baseline (12:38 wall, 4.17 GB peak).
- E2E + stress + elm-test stay 100 % green.
- The fall-back path at `Expr.elm:2516` either (a) is corrected to
  match the working path's ABI shape, or (b) is replaced by sharing the
  same kernel-call construction code with `:2988`/`:3007` so future
  drift is impossible.
- Diagnostic logging added in step 2 is reverted or gated behind a
  trace flag before landing.

### Risk

Medium-high. The path was unreachable until now, and once enabled it
fires on the most encoder-heavy code in the compiler. Even a single
wrong SSA type assignment causes segfaults that aren't visible until
runtime, after a clean MLIR verification pass. The diagnostic plan
favours reproducer-first to surface the bug at minimal scale, and
post-mortem gdb to localise the crash precisely.

## Phase 5 — extend `reifyMapBody` to handle `MonoVarGlobal` mapFn

### Goal

Make `ELoop` fusion fire on `Utils.Bytes.Encode.list myEncoderFn xs`
where `myEncoderFn` is a *named function reference* (the dominant
compiler-self-code pattern), not just an inline lambda.

This is the second of the two follow-up items identified during the
Fix 3 attempt. The reifier currently rejects `MonoVarGlobal` mapFns —
not because the body is unknowable, but because we'd need to construct
the equivalent of `MonoCall mapFn [synthVar]` and have the reifier
walk into the result. Since the mapFn's body lives in another spec's
node, we need access to the inliner's body cache.

### Design

The `MonoInlineSimplify` pass produces a `Dict SpecId (List (Name,
MonoType), MonoExpr)` mapping every spec it considered inlinable (i.e.
non-recursive and `getInlinableBody`-eligible) to its params + body.
That table is consumed by the inliner itself and then discarded.

Phase 5 plumbs the same table — or a leaner read-only view of it —
through to `BFReify.reifyEncoder`. The reifier extension:

```elm
-- New shape for reifyMapBody — receives a body lookup callback.
type alias BodyLookup =
    Mono.SpecId -> Maybe (List ( Name, Mono.MonoType ), Mono.MonoExpr)

reifyMapBody : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> BodyLookup -> Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe EncoderNode
reifyMapBody registry exprCache bodyLookup mapFn iterExpr countExpr =
    case mapFn of
        Mono.MonoClosure info body _ ->
            -- existing case
            ...

        Mono.MonoVarGlobal _ specId _ ->
            -- new case: look up the global's body, beta-reduce against
            -- a synthetic var, and reify the result.
            case bodyLookup specId of
                Just ( [ ( paramName, _ ) ], body ) ->
                    case reifyEncoderHelp registry exprCache body of
                        Just bodyNodes ->
                            if List.all hasConstantWidth bodyNodes then
                                Just (ELoop { itemVar = paramName, ... })

                            else
                                Nothing

                        Nothing ->
                            Nothing

                _ ->
                    Nothing  -- non-arity-1 or not in the inlinable set

        _ ->
            Nothing
```

The beta-reduction is *implicit*: `reifyEncoderHelp` is called on the
body unchanged. The body references its original parameter name (e.g.
`str` for `Utils.Bytes.Encode.string`); the emit module already binds
`itemVar` (which is `paramName` here) to the per-iteration head SSA via
`Context.addVarMapping`. So as long as `paramName` matches what the body
expects, the references resolve at emit time.

### Plumbing

The reifier is currently called from `Compiler.Generate.MLIR.Expr.generateSaturatedCall`:

```elm
case BFReify.reifyEncoder ctx.registry ctx.decoderExprs encoderExpr of
```

The codegen `Context` (`ctx`) does not currently carry the inliner's
body table — that table is produced inside `MonoInlineSimplify.simplifyAll`
and discarded after the inlining rewrite. Two plumbing options:

**Option A — pass the table through codegen.** Modify the codegen
pipeline so the body table survives MonoGlobalOptimize and reaches the
codegen `Context`. Reifier signature grows by one argument. Touches:

- `Compiler.GlobalOpt.MonoGlobalOptimize` — surface the table on its
  return type.
- `Compiler.Generate.MLIR.Context` — add an `inlineBodies : Dict SpecId
  ...` field.
- `Compiler.Generate.MLIR.Expr.generateSaturatedCall` — pass
  `ctx.inlineBodies` to `BFReify.reifyEncoder`.
- `Compiler.Generate.MLIR.BytesFusion.Reify` — accept the new argument
  and pass it down to `reifyMapBody`.

**Option B — recompute the table at the reifier.** The reifier already
has the SpecializationRegistry and the nodes array (via the registry).
It could re-run a stripped-down `getInlinableBody` over `nodes` to build
its own lookup. Avoids cross-pass plumbing but duplicates the inliner's
eligibility logic and burns extra compile time.

Option A is cleaner; Option B is less invasive. Prefer A.

### What this unlocks

Per the post-Fix-3 MLIR analysis, the dominant unfused-encoder shape
is calls like:

```elm
Utils.Bytes.Encode.list Utils.Bytes.Encode.string names
```

After Fix 1 inlining: `BE.sequence (BE.unsignedInt32 BE (List.length names) :: List.map Utils.Bytes.Encode.string names)`.

With Phase 5: the reifier looks up the body of
`Utils.Bytes.Encode.string`, which (after Fix 1 inlining its own
sub-helpers) reifies to a constant-width body. The whole call site
fuses into an `scf.while` with `bf.write.*` ops inside.

Estimated impact (extrapolating from current counts): the ~218
remaining `@Utils_Bytes_Encode_list_*` callsites and the ~261
`@Utils_Bytes_Encode_string_*` calls become candidates. Many will
fuse end-to-end. The compiler self-MLIR should show its first non-trivial
`bf.write.*` ops nested inside `scf.while` loops.

### Constraints and edge cases

- **Recursion**: the body of `Utils.Bytes.Encode.list` *itself* contains
  a call to `List.map`, which after monomorphization may be either a
  user-level recursive function or a kernel call. If the lookup
  recurses into a recursive function, the reifier must detect the cycle
  and bail. Easy: use `isRecursive` from the existing call graph (already
  computed by the inliner).
- **Non-arity-1 mapFn**: `List.map` expects `(a -> b)`. The mapFn must
  have exactly 1 parameter. The lookup must return arity-1 to proceed.
- **Body that contains a `MonoVarLocal` for *another* let-binding**:
  inside the body, `MonoLet`/`MonoVarLocal` references already get
  resolved through the existing `exprCache`. As long as the body is
  closed over `paramName` and uses no other free vars, reification
  proceeds; otherwise it bails.
- **Body too complex (multi-statement, branching, etc.)**: the reifier
  returns `Nothing` from `reifyEncoderHelp` on shapes it doesn't
  recognise, which is the existing fall-back behaviour. No correctness
  risk.

### Acceptance for Phase 5

- The body-lookup mechanism is in place (Option A: plumbing through
  Context, or Option B: re-derivation at the reifier).
- `reifyMapBody` accepts `MonoVarGlobal` mapFns and successfully
  reifies the body of common helpers (`Utils.Bytes.Encode.string`,
  `int`, `unit`, `bool`, `result`, `maybe`).
- Stage 7 bootstrap is green; the `eco-compiler-boot.mlir` shows
  meaningful new fusion firing — target: ≥ 100 `bf.write.*` ops nested
  inside `scf.while` loops, drawn from the ~358 (now 218 post-Fix-1)
  `@Utils_Bytes_Encode_list_*` call sites.
- Wall-time and RSS remain within ±5 % of the Fix-1+Fix-3 baseline.

### Risk

Medium. The plumbing is mechanical; the reifier change is small. The
real risk is mis-categorising what counts as "inlinable" — the same
eligibility logic the inliner uses must apply here, or we'll try to
beta-reduce a body that the inliner correctly rejected (e.g.
recursive, MonoCase-bodied, MonoTailFunc) and produce incorrect emit.
Reusing `getInlinableBody` + `isRecursive` from `MonoInlineSimplify`
guarantees consistency.

## Revised sequencing (after Phase 4 investigation)

Originally:

> Fix 1 first ... Fix 3 second ...

Then revised after observing Fix-1 + Fix-3 fusion-firing was zero:

> ... Phase 4 (fall-back audit) → blacklist → Phase 5 ...

After the Phase 4 diagnostic walk-through (see Phase 4 section above),
the blacklist+audit path is dropped — the fusion entry at `:2953` is
already reachable for inlined `BE.encode` calls. The actual gate is
`reifyMapBody`'s `MonoVarGlobal`/`MonoClosure` mismatch, and inline
lambdas suffer it too because of closure conversion.

Final order:

1. **Fix 1 + Fix 3 scaffolding + typo fix** — *landed*. Dormant.
2. **Phase 5 — `reifyMapBody` body-lookup extension** — the
   actual unlock. Covers both the helper-pattern case (the
   `MonoVarGlobal` references named functions) and the inline-lambda
   case (closure-converted to `MonoVarGlobal @<module>_lambda_N`).
   This is now the next step.

Each step still gates on:
- E2E suite (`cmake --build build --target full`).
- Stress suite (`cmake --build build --target stress`).
- Stage 7 bootstrap (`cmake --build build --target eco-compiler-boot`).

Bootstrap must remain green at each step; wall-time and RSS within ±5 %
of the current baseline (12:38 wall, 4.17 GB peak per the recent run).

## Phase 5 — current position (2026-05-23)

Phase 5 is fully landed and green. The smoke fixture
`FusionGlobalMapFnTest` now fuses end-to-end (`scf.while` +
`bf.write.u8` both present in lowered MLIR; stdout `FusionGlobalMapFnTest: 7`
passes). The previously-blocked Phase 4 walk in `reifyEncoderList`
landed alongside, via the Option A `compileSkippedBindings` mechanism.

**Gates (2026-05-23 evening)**:
- E2E (`cmake --build build --target full`): 1410/1410 green.
- Stress (`cmake --build build --target stress`): 100/100 green
  (improved from 99/99 baseline).
- Stage 7 bootstrap (`cmake --build build --target eco-compiler-boot`):
  green; all 8 stages reached (JS fixed-point check, Stage 5/6/7a/7b).
  Stage 7b LLVM lowering dominates at 192 s; total bootstrap budget
  on par with the recent baseline.

The remaining `Phase 5 — current position (2026-05-23)` content below
is preserved for historical context.

### Resume-step (1) finding

The Phase 5 `Debug.log` trace from the resume checklist showed the
chain bailing not at `reifyMapBody`, `matchLengthPrefixHeader`, or
`reifyListMapCall` — those all succeeded. It bailed one level higher
at `reifyEncoderList`. With the monomorphizer's let-hoisting of the
cons expression (`MonoLet mono_inline_0 = List.cons ... in
Bytes.Encode.sequence mono_inline_0`), `reifyEncoderList` received a
`MonoVarLocal mono_inline_0` argument and had no arm to resolve it
through `exprCache`. That short-circuited fusion before `ELoop`
recognition ever ran.

### The Phase 4 + Phase 5 unlock

Re-attempting Phase 4 (`MonoLet`/`MonoVarLocal` walking in
`reifyEncoderList`) by adding the two new arms was sufficient to
make the reifier reach `reifyMapBody`, which then resolved through
`bodyLookup` and produced the `ELoop` node. But the `DecodeAndThenTest`
crash (`lookupVar: unbound variable mono_inline_7`) returned, exactly
as the previous attempt predicted: the encoder argument's let-bindings
get compiled via `argOps`, then immediately scoped out by
`generateLet`'s `scopedCtx`, so the BF emit's `exprCompiler` can't
resolve the `MonoVarLocal mono_inline_N` references that survived in
the `EncoderNode`s.

Option A from the plan resolved this: thread the
`compileSkippedBindings` mechanism through the encoder fusion success
path, exactly mirroring the decoder side's `tryDecodeFusionWithBindings`
(`Expr.elm:2207`). Two new helpers in `Expr.elm`:

| Helper | Role |
| --- | --- |
| `tryEncoderFusionWithBindings` | Walks the encoder argument's top-level `MonoLet` chain accumulating bindings, calls `reifyEncoderWith` on the non-`MonoLet` body with a local cache, and on fusion success emits `compileSkippedBindings(accumulated) ++ emitFusedEncoder(...)`. Skips `argOps` entirely so the inner bindings don't get scoped out. |
| `tryBytesEncodeFusion` | Pre-check at the top of `generateSaturatedCall` that handles both forms of `Bytes.Encode.encode` (the `MonoVarGlobal` spec and the post-inline `MonoVarKernel "Bytes" "encode"`). On a match, dispatches to `tryEncoderFusionWithBindings`. |

The existing in-line fusion attempts in `generateSaturatedCallNoFusion`
(at the two `BFReify.reifyEncoderWith ...` sites) remain as harmless
backstops — when the pre-check returns `Nothing` they receive the
same `encoderExpr` and produce the same `Nothing`, falling through to
the kernel-call path.

### Verified test results

| Suite | Result |
| --- | --- |
| `FusionGlobalMapFnTest` (smoke fixture) | passes; `scf.while` + `bf.write.u8` both present in MLIR; stdout matches `FusionGlobalMapFnTest: 7` |
| `DecodeAndThenTest` (previously broken) | passes; no more `lookupVar: unbound variable mono_inline_7` |
| Full `elm-bytes` suite | 77/77 |
| Full E2E | 1410/1410 |
| Stress | 100/100 |

### Remaining gap

`tryEncoderFusionWithBindings` only accumulates **top-level** `MonoLet`
chains directly on the encoder argument. `MonoLet`s nested deeper
inside the encoder body are walked by `reifyEncoderHelp`'s own
`MonoLet` arm but their bindings are discarded after reification
finishes — so if an `EncoderNode` ends up carrying a `MonoVarLocal`
reference to one of those discarded bindings, BF emit will still
crash. None of the current tests hit this; the cases where the
reifier walks past an inner `MonoLet` are width-arg-style throwaways
(e.g. `Utf8 width "Hi"` where the `width` arg is dropped to `_` in
`reifyBytesEncodeCall("Utf8", [_, stringExpr])`). If a future test
exercises a value expression that references an inner-let binding, the
fix is to thread accumulated bindings back from `reifyEncoderHelp` so
`compileSkippedBindings` sees them too — a small extension of the
existing mechanism.

### What landed and is verified

The compiler / runtime side is in place under flag-free defaults:

| Change | File | Status |
| --- | --- | --- |
| `BodyLookup` type + `reifyEncoderWith` public API | `compiler/src/Compiler/Generate/MLIR/BytesFusion/Reify.elm` | landed |
| `reifyMapBody` — `MonoVarGlobal` arm via body lookup | same | landed |
| Body-lookup install on codegen `Context` | `compiler/src/Compiler/Generate/MLIR/Backend.elm` (3 entry points) | landed |
| Pass `ctx.inlineBodies` to fusion | `compiler/src/Compiler/Generate/MLIR/Expr.elm` (2 sites) | landed |
| `ensureUnboxed` (emit `eco.unbox` before `bf.write.{u8,u16,u32,f32,f64}`) | `compiler/src/Compiler/Generate/MLIR/BytesFusion/Emit.elm` | landed |
| `bf::CursorType → struct<ptr,ptr>` conversion on `EcoTypeConverter` | `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | landed |
| Bytes-decode fall-back projection + bounds-check kernels (separate work that unblocked the baseline) | `compiler/src/Compiler/Generate/MLIR/Expr.elm`, `elm-kernel-cpp/src/bytes/BytesExports.cpp` | landed |

Smoke-test infrastructure is also in:

| Change | File | Status |
| --- | --- | --- |
| `-- CHECK-MLIR:` / `-- CHECK-MLIR-NOT:` directive parser | `test/ElmE2ETestBase.hpp` (`extractCheckMlirPatterns`) | landed |
| `ecoc --emit=mlir` invoker for bytecode → text MLIR | same (`getEcocPath`, `readMlirAsText`) | landed |
| Smoke-test fixture for the Phase 5 fusion shape | `test/elm-bytes/src/FusionGlobalMapFnTest.elm` | landed — currently failing |

The cursor-type conversion was needed because `EcoToLLVMPass` marks the
entire SCF dialect illegal (`Passes/EcoToLLVM.cpp:298`), and the SCF
structural type-conversion patterns it populates need a converter for
every iter-arg type. `!bf.cursor` shows up on the iter-arg of the
`scf.while` emitted by `WriteEachItem` and was the only missing entry.

The unbox-before-write change was needed because the per-iteration
list head crosses the `scf.while` boundary as `!eco.value`; the BF
write ops require `I64`/`F64`. `ensureUnboxed` is a no-op on the
non-loop encoder shapes (the value already arrives unboxed there), so
it doesn't affect Fix-1/Fix-3 paths.

### (HISTORICAL — pre-2026-05-23-PM) What was broken at the trace-and-inspect pause

**(a) Phase 4 — `MonoLet` / `MonoVarLocal` walking in
`reifyEncoderList` — is currently REVERTED** because every form of it
(both the let-walk and the var-resolve-via-`exprCache` variants
individually) crashes `DecodeAndThenTest` during MLIR generation with
`lookupVar: unbound variable mono_inline_7`. The crash is
deterministic on a clean `eco-stuff/` cache. The fixture is the
`E.encode (E.sequence [E.unsignedInt8 2, E.string "Hi"])` plus
`D.decode decoder bytes` pair — no `List.map`, so the loop reifier is
not even involved. Hypothesis (unproven): the encoder fusion path
emits ops whose value expression references a `mono_inline_N` that
was eligible-for-fusion via Phase 4 but whose enclosing `MonoLet`
binding got "consumed" by the walk and then later scoped out of
`varMappings` by `generateLetSingle`'s `scopedCtx` (`Expr.elm:4197–
4239`), so emit's `compileExpr` can't find it.

The reifier docstring in `reifyEncoderList` describes Phase 4 as if
it is in place; the actual body has only `MonoList` and `MonoCall`
arms. Re-aligning the docstring or removing it is a follow-up.

**(b) Phase 5 by itself does NOT fire on the smoke-test fixture.**
The fixture is `BE.sequence (BE.unsignedInt32 BE (List.length xs) ::
List.map encodeByte xs)` where `encodeByte` is a top-level arity-1
named function. The generated MLIR shows the kernel call
`Elm_Kernel_Bytes_encode` and a regular `eco.call @List_map_$_5` — no
`bf.*` ops, no `scf.while` in the main function. So the chain

> `reifyEncoderWith` → `reifyEncoderHelp` (Seq) → `reifyEncoderList`
> (cons) → `reifyLengthPrefixedLoop` → `reifyListMapCall` →
> `reifyMapBody` (MonoVarGlobal) → `Dict.get specId bodyLookup`

bails somewhere. Phase-5-specific `Debug.log` calls were inserted at
`reifyEncoderWith`, `reifyLengthPrefixedLoop`, both arms of
`reifyListMapCall`, `matchLengthPrefixHeader`, `reifyMapBody` Nothing,
and `reifyMapBody`'s `MonoVarGlobal` arm — see the list of nine
`Debug.log` sites below. The next debug run was about to print which
of those steps the smoke test reaches; that print run is the *first*
thing to do when resuming.

**(c) In-flight `Debug.log` instrumentation** is currently present in
`Reify.elm`:
- `reifyEncoderWith` — line 175 (entry, expr-shape summary).
- `reifyLengthPrefixedLoop` — line 549 (entry); 553 (`reifyListMapCall
  Nothing`); 557 (success + mapFn kind); 565 (`matchLengthPrefixHeader
  Nothing`); 571 (`reifyMapBody Nothing`).
- `reifyMapBody`'s `MonoVarGlobal` arm — lines 658, 661, 664 (specId,
  `bodyLookup` keys, lookup result).

These print on every encoder fusion attempt during *every* compile
and are noise on the E2E run. They must be removed before any
non-Phase-5 work; they are intentionally left for the next debug pass.

### (HISTORICAL — pre-2026-05-23-PM) How to continue (resume checklist)

This checklist was executed in the 2026-05-23-PM session. The
findings — and the resulting fix — are summarized at the top of this
section under "The Phase 4 + Phase 5 unlock".

The next debug pass is the smallest unit of forward progress. Order:

1. **Confirm the failing step inside Phase 5's chain.** With the
   `Debug.log` instrumentation already in place and the
   `FusionGlobalMapFnTest.elm` fixture in `test/elm-bytes/src/`, run

   ```bash
   cmake --build build && \
     cd /work/build/test/elm-bytes && rm -rf eco-stuff/* && \
     node /work/compiler/bin/index.js make src/FusionGlobalMapFnTest.elm \
       --output=eco-stuff/mlir/FusionGlobalMapFnTest.mlir \
       --builddir=FusionGlobalMapFnTest 2>&1 | grep Phase5
   ```

   The `Phase5.*` log lines pinpoint where the chain bails. Most
   likely candidates:
   - `reifyEncoderWith` is never called → encoder doesn't go through
     the kernel-call fusion arm; check Expr.elm:2978's match.
   - `reifyEncoderWith` is called but on a non-`Seq` MonoExpr (the
     inliner replaced `Bytes.Encode.Seq` with something else).
   - `reifyListMapCall returned Nothing` → `List.map` isn't a
     `MonoVarGlobal` with `Mono.Global … "List" "map"` and
     `pkg == Pkg.core`. The inliner may have substituted it.
   - `matchLengthPrefixHeader Nothing` → header isn't recognised as
     `U32 BE (List.length xs)` after the inliner's transforms.
   - `reifyMapBody MonoVarGlobal specId` prints but `lookup result`
     is `Nothing` → `encodeByte` is recursive (not in `bodyLookup`),
     or its `MonoNode` isn't `getInlinableBody`-eligible (e.g.
     `MonoTailFunc`).
   - `lookup result` is `Just 1` (arity-1 inlinable body found) but
     `buildLoopNode` returns `Nothing` because the body doesn't
     reify to a constant-width run (likely if `E.unsignedInt8 n`
     after inlining isn't recognised as a single `EU8` node).

2. **Fix whatever step (1) identifies.** Each candidate above has a
   focused fix — e.g. teach `matchLengthPrefixHeader` about a
   post-inline header shape, or relax `reifyListMapCall` to accept the
   substituted form. Keep fixes small and per-step.

3. **Remove the `Debug.log` traces** in `Reify.elm` (all 9 sites
   listed in (c) above) once Phase 5 is firing for the fixture.

4. **Re-attempt Phase 4 (`MonoVarLocal` walking in
   `reifyEncoderList`)** — Phase 5 alone is the unlock for the
   "helper-as-named-function" case, but the "helper-list-wrapped-by-
   inliner" case (the `Utils.Bytes.Encode.list xs` shape) still
   needs `MonoVarLocal` resolution in `reifyEncoderList` to feed the
   reifier the actual list. Two options for handling the
   `DecodeAndThenTest` regression that previously blocked it:

   - **Option A — the bigger fix:** thread a
     `compileSkippedBindings`-style mechanism through the encoder
     fusion success path (analogous to `tryInlinedDecodeFusion`'s
     `compileSkippedBindings` use in `Expr.elm:2220`). Whenever
     `reifyEncoderList` walks past a `MonoLet`/`MonoVarLocal`, record
     the binding name; emit compiles those names into `varMappings`
     before any `bf.write.*` op's value expression is reduced. This is
     the correct fix and unblocks all let-wrapped encoder shapes the
     inliner produces.

   - **Option B — narrower:** only walk `MonoVarLocal` (not
     `MonoLet`) and only when the resolved expression has no free
     `MonoVarLocal` references at all (a pure literal list). This
     dodges the `mono_inline_N` reference issue at the cost of
     missing fusion sites whose elements reference outer vars. Cheap
     to implement; safe; weaker.

   Option A is preferred — confirms what the decoder path already
   does — but Option B is acceptable as a stepping stone if Option A
   proves invasive.

5. **Re-verify the FusionGlobalMapFnTest smoke fixture passes** once
   Phase 4+5 are both in: `CHECK-MLIR: scf.while` and `CHECK-MLIR:
   bf.write.u8` must both match the lowered MLIR. The test's
   stdout-side `-- CHECK: FusionGlobalMapFnTest: 7` was already
   passing via the kernel path, so a green run there is necessary
   but not sufficient — the MLIR-shape checks are the real signal.

6. **Run the gates** (E2E + stress + Stage 7 bootstrap) per the
   existing sequencing rule.

### Hot-spots to keep in mind

- `eco-stuff/` cache poisoning: changing the compiler's Elm code
  changes the cache format, and stale caches surface as
  `CORRUPT CACHE` or `lookupVar: unbound variable …` rather than
  honest test failures. After any Reify/Backend/Expr change in the
  compiler, `rm -rf /work/build/test/elm-bytes/eco-stuff/*` before
  re-running tests. The CMake `clean` target does not do this.
- `EcoToLLVMPass` marks the SCF dialect illegal. Any new dialect
  type that lands on an `scf.while` iter-arg needs a matching
  `addConversion` in `EcoTypeConverter` or `EcoToLLVM` will fail to
  legalize the `scf.while`. The `bf::CursorType` entry added here is
  the template; future ELoop variants (e.g. ELoop carrying a
  per-iteration cursor pair) may need similar entries.
- The `ensureUnboxed` helper only handles `!eco.value → I64/F64`. If
  the per-iteration value is unboxed already (e.g. an `i64` from a
  primitive return), it's a no-op. If the body composes the head
  through arithmetic, generateExpr handles the unbox via the normal
  intrinsic path. The fusion-only path is the single boundary where
  the head crosses `scf.while` as `!eco.value`.

## Open questions

1. **Inliner whitelist matching**: `isWhitelisted` (`MonoInlineSimplify.elm:167`)
   matches on `globalToQualifiedName`, which returns `"ModuleName.functionName"`.
   For elm/bytes the qualified names are `Bytes.Encode.signedInt16`,
   `Bytes.signedInt16`, etc. Confirm the exact module-path string format
   Eco's `Mono.Global` uses for elm/bytes module names — there's a chance
   it includes package qualifiers (e.g. `elm/bytes/Bytes.Encode.signedInt16`)
   in some encodings, and the whitelist needs the right form.

2. **List.map source location after monomorphization**: `List.map` from
   elm/core is sometimes inlined to its body, sometimes preserved as a
   kernel call (`Elm.Kernel.List.map`). The reifier pattern needs to match
   whichever form lands in the post-mono MonoExpr. If it's typically inlined
   to a recursive case-of body, the pattern is harder to recognise and we
   may need to instead match the recursive structure or whitelist
   `List.map` too. Investigate during reifier implementation.

3. **`Bytes.Decode.*` whitelist scope**: are all decoder combinators safe
   to inline (some recursion concerns for `loop`, `andThen`)? `loop` and
   `andThen` are recursive in their *use*, not their definition — should
   still be inlinable. Confirm via `isRecursive` check in MonoInlineSimplify.

4. **HO-specialisation gap**: after fix 1 inlines `Utils.Bytes.Encode.list`,
   the call site exposes `List.map encoder xs` where `encoder` is either
   substituted to a known value (if the call site passed a global, lambda,
   or let-bound function) or remains as a local-variable reference (if the
   helper was itself called through another higher-order helper that
   passed `encoder` through as a function parameter). The reifier already
   walks `MonoLet` and `MonoVarLocal` via `exprCache`; with fix 3 it would
   try to apply `encoder` to a synthetic var and reify. When `encoder` is
   a global, that resolves through `lookupSpecKey`; when it's bound to a
   `MonoClosure` in `exprCache`, beta-reduction produces a reifiable body.
   When `encoder` is a *function parameter* of the enclosing function (no
   binding visible), reification fails — that's the gap. Closing it
   requires a higher-order specialisation pass in the monomorphizer that
   produces per-call-site specialisations of helpers with function-typed
   parameters. Out of scope for this plan; tracked as a future follow-up
   alongside `let-bound-ho-arg-specialization.md`.

5. **Loop body width constraint**: `ELoop`'s body must have a constant
   total byte width. This rules out fusing `List.map BE.string xs` (each
   string has a different width). Length-prefixed-string-in-loop patterns
   would need either per-iteration width recomputation (complex) or
   fall-back to unfused. First pass: reject and fall back; document the
   restriction.
