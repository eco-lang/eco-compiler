# Duplicate-calls bug: the subst engine evaluates a `case` scrutinee more than once

Status: open. Found on 2026-11-05 while looking into the Windows Stage 7a hang from
October 2026. There is a workaround for the one place it bit (c4f8ba71). The engine
itself is not fixed.

## Summary

The `subst` monomorphization engine (`Compiler/Monomorphize/Subst/*`) can turn one
`case` on a function call into two or three calls to that function. It happens when
the value being matched has a type that contains a function and still has free type
variables. The engine copies that value once per type it is needed at, and each copy
makes its own call.

When this happens inside a combinator that nests, such as `Reporting.Result.apply`,
every level of nesting repeats the extra calls. Running time then grows
exponentially with the length of the chain.

The default engine, `solver` (`EngineSolver`, `Compiler/Config.elm:541`), does not
have this bug.

## Symptoms

- In October 2026 the Windows CI build hung in Stage 7a at
  "Verifying dependencies (28/29)". `Docs.checkNames` built a chain of
  `ReportingResult.apply` with one link per exported or documented name. For a
  package with a few dozen names, the Stage 6 native `eco-compiler` spun for hours.
  Linux and macOS had the docs cached, so they never reached `makeDocs`.
- c4f8ba71 rewrote `checkNames` to collect its checks in a list and run them with
  `ReportingResult.traverse`. That function runs each check once, so the chain is
  gone and the hang with it.
- **The c4f8ba71 commit message is wrong about the cause.** It says "the native
  build … calls its inner computation three times", which suggests a back-end
  problem. The duplication is actually in the front end's monomorphization, as
  described below. The C++ lowering only compiles faithfully what it is given.

## Where it happens

`Compiler/Monomorphize/Subst/Specialize.elm`:

- Module doc, lines 30–43. A local definition can be polymorphic and is copied per
  demand. That covers both "a let-bound value that is not a function, but whose type
  contains a function and a free type variable" and "destructuring a copied value
  chooses a copy through a *partial container*".
- `shouldUseValueMulti` (line 504) is the predicate:

  ```elm
  shouldUseValueMulti mvarEnv defCanType =
      typeContainsLambda defCanType
          && (hasNonNumberVar mvarEnv defCanType || hasUnresolvedNumberVar mvarEnv defCanType)
  ```

- The `let` case of `specializeExpr` (around lines 3305–3476) does the copying. It
  pushes the binding onto the `valueMulti` stack, lets each use record the copy it
  needs, and then emits one `MonoLet` per recorded copy using
  `renameMonoDef info.freshName`.

Copying is safe for a let-bound *function*, because a copy is just another closure.
For a non-function value whose definition is a computation, each copy runs that
computation again. In Elm the duplicate calls give the same result, so the output
is still correct, but the work is multiplied.

## Walkthrough: `Reporting.Result.apply`

```elm
apply : RResult i w x a -> RResult i w x (a -> b) -> RResult i w x b
apply (RResult kv) (RResult kf) =
    RResult
        (\i w ->
            case kf i w of
                ROk i1 w1 func ->
                    case kv i1 w1 of
                        ...
                RErr i1 w1 e1 ->
                    ...
        )
```

1. The canonical form of `case kf i w of ...` binds the scrutinee to a let-bound
   temporary and then destructures that temporary.
2. The temporary has type `RStep i w x (a -> b)`:
   - it is not a function, but contains one (`a -> b`);
   - when `apply` is called from a function that is itself polymorphic in `i` and
     `w` (`keepBoth` in `Docs.checkNames`), `i` and `w` are still free.

   So `shouldUseValueMulti` returns true.
3. Each pattern variable demands the temporary at a *partial container* type. That
   type is known only at the field being extracted:
   - `i1` demands one type;
   - `w1` and `func` demand another;
   - without `--optimize`, a third type is demanded.
4. One copy of the temporary is emitted per demanded type, and each copy is a call
   to `kf i w`.

This is the Stage 5 (subst, `--optimize`) MLIR for one specialization,
`Terminal_Main_lambda_11664$cap`, which is created in
`Compiler_Reporting_Result_apply_$_13784`:

```mlir
^bb0(%kf: !eco.value, %kv: !eco.value, %i: !eco.value, %w: !eco.value):
  %86150 = "eco.papExtend"(%kf, %i, %w) ...      // copy 1 of `kf i w`
  %86151 = "eco.papExtend"(%kf, %i, %w) ...      // copy 2 of `kf i w`
  %86154 = "eco.get_tag"(%86150) ...
  %86192 = "eco.case"(...) ({
      %86157 = "eco.project.custom"(%86150) {field_index = 0}   // i1   from copy 1
      %86158 = "eco.project.custom"(%86151) {field_index = 1}   // w1   from copy 2
      %86159 = "eco.project.custom"(%86151) {field_index = 2}   // func from copy 2
      ...
```

The solver engine emits a single `papExtend(%kf, %i, %w)` and projects all three
fields from it.

### Why this grows exponentially

`kf` is itself the closure of the `apply` one level down. In a chain of `n` nested
`apply`s, each level calls the level below `c` times (`c` = 2 with `--optimize`, 3
without). The innermost computation therefore runs about `c^n` times.

The chain that `keepBoth` builds nests one level per name, so a module with a few
dozen names is enough to make the build never finish in practice.

## Reproduction

This repro uses no lists, so it runs under `ecoc --emit=jit`. (`ecoc`'s JIT symbol
map, `runtime/src/codegen/RuntimeSymbols.cpp`, lacks the `eco_scratch_*` helpers.)
Replace `NNN` with the chain length.

```elm
module TripleCallProbe exposing (main)

import Html exposing (text)

type OneOrMore a = One a | More (OneOrMore a) (OneOrMore a)
type R i w e a = R (i -> w -> Step i w e a)
type Step i w e a = SOk i w a | SErr i w (OneOrMore e)

ok : a -> R i w e a
ok a = R (\i w -> SOk i w a)

apply : R i w x a -> R i w x (a -> b) -> R i w x b
apply (R kv) (R kf) =
    R (\i w ->
        case kf i w of
            SOk i1 w1 func ->
                case kv i1 w1 of
                    SOk i2 w2 value -> SOk i2 w2 (func value)
                    SErr i2 w2 e2 -> SErr i2 w2 e2
            SErr i1 w1 e1 ->
                case kv i1 w1 of
                    SOk i2 w2 _ -> SErr i2 w2 e1
                    SErr i2 w2 e2 -> SErr i2 w2 e1
      )

run : R () (List w) e a -> Maybe a
run (R k) =
    case k () [] of
        SOk _ _ a -> Just a
        SErr _ _ _ -> Nothing

-- Polymorphic in i and w: this is what leaves type variables free inside apply.
keepBoth : R i w String Int -> R i w String Int -> R i w String Int
keepBoth acc next = ok (\_ r -> r) |> apply acc |> apply next

build : Int -> R i w String Int -> R i w String Int
build n acc = if n <= 0 then acc else build (n - 1) (keepBoth acc (ok n))

main =
    let _ = Debug.log "result" (run (build NNN (ok 0))) in
    text ""
```

Generate MLIR with `ECO_MONO_ENGINE=subst` and with `ECO_MONO_ENGINE=solver`, then run
each through `ecoc --emit=jit`. Wall-clock times, timeout 300 s:

| n  | subst      | solver |
|----|------------|--------|
| 12 | 0.18 s     | 0.10 s |
| 14 | 0.63 s     | 0.09 s |
| 16 | 4.8 s      | 0.09 s |
| 18 | 41 s       | 0.09 s |
| 20 | > 300 s    | 0.10 s |
| 22 | > 300 s    | 0.09 s |

Under subst, each step of 2 in `n` multiplies the time by about 8.6, so roughly
×2.9 per level. Solver stays flat.

Without the polymorphic `keepBoth`, for example with `i` and `w` fixed to concrete
types, the type variables are resolved, `shouldUseValueMulti` returns false, and
the bug does not trigger. That is why the simpler toy programs I tried first did
not reproduce it.

## How far it reaches

### Inside the compiler's own source

I generated the whole compiler as MLIR with both engines and scanned for this bug's
fingerprint: a call with arguments that is repeated in the same block, with each
copy's result destructured (`get_tag` / `project.custom`).

- **Under subst only:** exactly three functions, all specializations of
  `Reporting.Result.apply`:

  | lambda | created in |
  |---|---|
  | `Terminal_Main_lambda_11664$cap` | `Compiler_Reporting_Result_apply_$_13784` |
  | `Terminal_Main_lambda_11666$cap` | `Compiler_Reporting_Result_apply_$_13783` |
  | `Terminal_Main_lambda_11739$cap` | `Compiler_Reporting_Result_apply_$_13771` |

- **Under both engines:** eight more, all of which the source writes twice on
  purpose. Each call builds a small decoder value, and none of them sits in a nested
  chain. These are not bugs, at most a missed common-subexpression elimination
  (CSE). Examples:
  - `nameDecoderS` (`Compiler/Elm/Package.elm:626`) calls `stringDec st` once for
    the author and once for the project.
  - `typeDecoderS` (`Compiler/IR/Canonical.elm:893-894`, `915-916`) calls itself
    twice for two-child types such as `TLambda`.
  - `deciderDecoder` (`Compiler/IR/Optimized.elm:1164-1165`) calls itself twice for
    the two branches of `Chain`.

Caveat: the scan matches a textual pattern. It would miss a duplicate that the
optimizer has moved into different blocks, or one that is not destructured.

### In user programs

Any program compiled with subst can hit the bug. The conditions are:

- a `case` (or any destructuring) whose scrutinee is a computation;
- the scrutinee's type contains a function;
- the scrutinee's type still has free type variables at that point.

The usual shape is a CPS or state-monad combinator such as `apply`, `andThen` or
`map2` over a `(state -> Step state …)` wrapper, called from code that is still
polymorphic. Parser and decoder combinator libraries look exactly like this.

### Which builds are affected

- **Stage 5** is pinned to `ECO_MONO_ENGINE=subst` (`compiler/CMakeLists.txt:536`),
  because it uses the least Node heap. So the **Stage 6** native `eco-compiler` has
  the bug. Stage 6 is what runs the Stage 7a self-compile, and that is where Windows
  hung.
- **Stage 7a** re-emits the compiler with the default engine (solver), and
  **Stages 7b, 8 and 9a**, which produce the shipped binaries, lower that MLIR
  (comment at `compiler/CMakeLists.txt:520-535`). So shipped `eco` should not have
  the bug. I have not run the scan on shipped-binary MLIR to confirm this.
- **The E2E JIT tests are not affected.**
  - The harness (`test/ElmE2ETestBase.hpp`) runs `compiler/bin/index.js`, which
    wraps `guida.js`. `guida.js` is built by stock Elm (`compiler/CMakeLists.txt:177`),
    so the compiler's own code never goes through this monomorphizer.
  - The test MLIR it writes uses the default solver engine, because the harness does
    not set `ECO_MONO_ENGINE`.
  - The bug would show up only if `ECO_MONO_ENGINE=subst` were exported in the shell
    that runs the tests. Even then it would slow the tests while they run, not while
    they compile. **It does not explain slow E2E compile times.**

## Fix options

The fix belongs in the subst engine, not the back end. Options, from most targeted
to broadest:

1. **Never value-multi a destructuring scrutinee.** The temporary created for a
   `case` (or a destructuring `let`) has a single source expression. Specialize it
   once, at the most general type its uses agree on, and project fields from that one
   value. A destructured field with a function type that genuinely needs per-type
   copies can be copied *after* projection, where copying a closure is cheap.
2. **Share one evaluation between copies.** Keep the per-type copies, but bind the
   underlying computation once, for example as an outer `let` holding the boxed
   result. Then make each copy a re-typing or projection of that binding, not a
   re-evaluation. Every copy holds the same runtime value, so this is sound under the
   uniform boxed representation (`!eco.value`). Check that against
   `design_docs/invariants.csv` (REP_* / CGEN_*) before changing anything.
3. **Restrict `shouldUseValueMulti` to syntactic values.** Copy a non-function let
   only when its definition is a constructor application, a lambda or a literal, and
   never when it is a call. This is the broadest change and may lose specialization
   that some programs currently get.

Option 1 fixes the root cause most directly. Any fix should come with a regression
test:

- **E2E test:** the repro above with `n` around 20. Under the bug it times out;
  fixed, it finishes in milliseconds.
- **Front-end check (optional):** with subst, assert that the MLIR for `apply`
  contains exactly one call to `kf`.

A cheaper alternative is to switch Stage 5 to solver. CMake keeps it on subst only
for Node heap headroom: solver+LSS peaks at about 11.8 GB under V8. That would remove
the bug from the bootstrap, but subst would stay wrong for anyone who selects it.

## Related

- c4f8ba71: the `Docs.checkNames` workaround (`traverse` instead of an `apply` chain).
- 6203e87e: removes the hang diagnostics added while investigating.
- Separate small issue found along the way: `ecoc`'s JIT symbol map
  (`runtime/src/codegen/RuntimeSymbols.cpp`) lacks the `eco_scratch_*` symbols that
  the `EcoListTemplate` pass emits, so programs that use lists fail under
  `ecoc --emit=jit`.
