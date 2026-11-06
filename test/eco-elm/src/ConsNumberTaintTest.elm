module ConsNumberTaintTest exposing (main)

{-| Two unrelated uses of `::` in one program, one consing tuples with a
polymorphic field and one consing number literals, each keep their own element
type.

`rebuild` copies a `List ( String, Maybe a, Bool )` with `::`, where the
`Maybe a` field is `Nothing` in every element, so `a` is never fixed to a
concrete type. `trigger` conses the literals `1` and `2`, whose type is left as
`number` because `List.length` does not constrain it. Neither definition may
influence how the other's list elements are treated: the rebuilt list has two
elements and its first element's string is `"a"`.

## eco

Regression gate (first written as a crashing repro) for a solver bug that crashed the self-compile bootstrap: the two definitions are related only through the shared annotation variable of `List.cons`.

`rebuild`'s element type still contains an unresolved variable (the `Maybe a`), so `deriveKernelAbiTypeWith` in compiler/src/Compiler/Monomorphize/Solver/Translate.elm kept the `List.cons` annotation variable in the kernel ABI instead of the concrete tuple. `trigger`'s literals stay `number`, and `harvestSuperTable` in compiler/src/Compiler/Monomorphize/Solver/Engine.elm then marked that same `List.cons` variable as Number globally. The victim's cons resolved to Int, so compiler/src/Compiler/GenerateMlir/KernelAbi.elm selected `Elm_Kernel_List_cons_Int` and the tuple pointer was unboxed to i64; reading the head crashed. The substitution-based engine (`ECO_MONO_ENGINE=subst`) was unaffected.

The program must not be changed to make the test pass; the fix belongs in the solver.

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
