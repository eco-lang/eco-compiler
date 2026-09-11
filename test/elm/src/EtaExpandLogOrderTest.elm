module EtaExpandLogOrderTest exposing (main)

{-| η-expansion does not move observable evaluation
(`plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md` §2.5, §5).

The `CHECK-NEXT` chain pins the EXACT interleaving of `Debug.log` output, and
it must print identically with `etaExpand` on and off. That is the guard: the
transform reassociates nothing and re-times nothing.

**What this fixture MEASURED, and what it corrects.** It was written to pin
"`init` fires once, at CAF init, because the gate refuses this body" — and the
flag-OFF baseline printed `init` THREE times, once per call. The reason is
`MonoGlobalOptimize.ensureCallableForNode` (:584): every top-level node whose
MonoType is an `MFunction` is wrapped by `makeGeneralClosureGO` (:541) into
`MonoClosure params (MonoCall <original body> params)` — the original body sits
INSIDE the closure and runs per call. So a definition of alias-arrow type is
never a memoised CAF to begin with, and the plan's R1 ("an arity-0 spec is a
memoised CAF slot; after η it is evaluated per call") does not reach the
DEFINITION rule at all: GlobalOpt already performs that same η-expansion one
phase later. What η-expansion changes for a definition is WHERE the wrapping
happens — early enough for the new arguments to merge into the under-applied
call and for the analysis to see a saturated one — not how often the body runs.

The cheapness gate is kept regardless: it is still load-bearing for the
CONTINUATION rule, where a lambda's body genuinely moves from once per closure
application to once per SECOND application, and a continuation's result can be
shared. `counted` is the fixture that pins the definition-rule half.

`chained` is the positive arm: a cheap two-of-three chain the pass DOES expand,
printing the same numbers either way.

-}
import Html exposing (text)



-- CHECK: init: 0
-- CHECK-NEXT: a: 1
-- CHECK-NEXT: init: 0
-- CHECK-NEXT: b: 2
-- CHECK-NEXT: init: 0
-- CHECK-NEXT: c: 3
-- CHECK-NEXT: chained: [11, 12, 13]


type alias St a =
    Int -> ( Int, a )


andThen : (a -> St b) -> St a -> St b
andThen f ma s0 =
    let
        ( s1, a ) =
            ma s0
    in
    f a s1


pure : a -> St a
pure x s =
    ( s, x )


tick : St Int
tick s =
    ( s + 1, s )


{-| REFUSED by the gate (`Debug.log` is a `VarDebug` call and no cheap arm
admits one), so the pass leaves this definition exactly as written. The
per-call `init` in the expected output is `ensureCallableForNode`'s doing, not
this pass's — see the module comment.
-}
counted : St Int
counted =
    let
        _ =
            Debug.log "init" 0
    in
    tick


{-| ADMITTED by the gate: two of three arguments at `andThen`, and a
one-parameter continuation. Nothing left of the new binder but the PAP the call
was about to apply.
-}
chained : St Int
chained =
    tick |> andThen (\a -> pure (a + 10))


runChained : Int -> Int
runChained n =
    Tuple.second (chained n)


main =
    let
        _ =
            Debug.log "a" (Tuple.second (counted 1))

        _ =
            Debug.log "b" (Tuple.second (counted 2))

        _ =
            Debug.log "c" (Tuple.second (counted 3))

        _ =
            Debug.log "chained" (List.map runChained [ 1, 2, 3 ])
    in
    text "done"
