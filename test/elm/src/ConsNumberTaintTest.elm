module ConsNumberTaintTest exposing (main)

{-| KNOWN-FAILING repro (SIGSEGV) of the solver's cross-item Number-taint bug —
the isolated form of the Stage-7a self-compile bootstrap crash (Jul 2026).

Mechanism (EngineSolver only; `ECO_MONO_ENGINE=subst` compiles this correctly):

1.  VICTIM: `rebuild`'s `x :: rest` conses a tuple3 whose middle field is
    `Maybe a` with `a` never determined (every value is `Nothing`). The
    residual `MVar CEcoValue` leaf inside the otherwise-concrete element makes
    `containsAnyMVar` fail the suffix-selection gate in
    `MonoSolver/Translate.deriveKernelAbiTypeWith`, so the PreserveVars arm
    DISCARDS the concrete tuple3 element and keeps `List.cons`'s annotation
    var `a` in the kernel ABI.

2.  TRIGGER: `trigger`'s `1 :: 2 :: []` element is a `number` that is never
    pinned to Int (`List.length` doesn't constrain it), so its store point is
    still `FlexSuper Number` when the item finishes. `Engine.harvestSuperTable`
    then stamps `List.cons`'s annotation var Number in the GLOBAL superTable —
    the per-item `annIds` exclusion covers only the item's OWN annotation vars,
    not the callee scheme vars loaded into its store.

3.  CLOSE: shared Prune closes the victim's `MVar a CEcoValue -> MInt`,
    `Generate/MLIR/KernelAbi` selects `Elm_Kernel_List_cons_Int`, and codegen
    `eco.unbox`es the boxed tuple3 pointer to i64 — the cons cell holds a raw
    heap pointer with head-kind Int. Projecting the head (`first`) walks a
    16-byte `Tag_Int` as a tuple3 → SIGSEGV.

The two definitions are UNRELATED except through `List.cons`'s shared
annotation-var id — that is the bug. Un-red this test by fixing the solver
(harvest must not stamp callee-scheme vars / the suffix gate must honour a
structurally concrete element); do not "fix" it by changing this program.

-}

-- CHECK: count: 2
-- CHECK: first: "a"
-- CHECK: trigger: 2

import Html exposing (text)


rebuild : List ( String, Maybe a, Bool ) -> List ( String, Maybe a, Bool )
rebuild items =
    case items of
        [] ->
            []

        x :: rest ->
            x :: rebuild rest


trigger : Int
trigger =
    List.length (1 :: 2 :: [])


main =
    let
        out =
            rebuild [ ( "a", Nothing, True ), ( "b", Nothing, False ) ]

        first =
            case out of
                ( nm, _, _ ) :: _ ->
                    nm

                [] ->
                    "none"

        _ =
            Debug.log "count" (List.length out)

        _ =
            Debug.log "first" first

        _ =
            Debug.log "trigger" trigger
    in
    text "done"
