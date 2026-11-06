module AndThenProbe exposing (main)

{-| Chains of `Maybe.andThen` with lambda steps give the same result whether written with `|>` or as nested calls.

`chain` and `chainDirect` apply the same three steps to `parse n`, which is
`Nothing` unless `n` is positive. Starting from 5 both give `Just 108`, and
starting from 0 `chain` gives `Nothing`. `useInExpr` uses the result of `chain`
inside arithmetic.

## eco

Exercises closure elimination for `Maybe.andThen` chains from the higher-order function work
(plans/hof-elimination-closure-alloc-reduction.md): under the default config both the pipe and
the direct chains compile to straight-line nested cases with no closure allocation, which the
CHECK-MLIR-NOT line asserts (no `eco.papCreate`). The pipe shape relies on partial-application
merging in compiler/src/Compiler/MonoOpt/InlineSimplify.elm: the strictly partial
`Maybe.andThen` binding left by pipe inlining is merged with its application into one saturated
call, which then inlines exactly.

-}

import Html exposing (text)

-- CHECK: chain5: Just 108
-- CHECK: chain0: Nothing
-- CHECK: expr: 217
-- CHECK: direct: Just 108
-- CHECK-MLIR-NOT: eco.papCreate



parse : Int -> Maybe Int
parse n =
    if n > 0 then
        Just n

    else
        Nothing


chain : Int -> Maybe Int
chain n =
    parse n
        |> Maybe.andThen (\a -> parse (a - 1))
        |> Maybe.andThen (\b -> parse (b * 2))
        |> Maybe.andThen (\c -> Just (c + 100))


smallPick : Maybe Int -> Int
smallPick m =
    case m of
        Just v ->
            v

        Nothing ->
            0


useInExpr : Int -> Int
useInExpr n =
    1 + smallPick (chain n) * 2


main =
    let
        _ =
            Debug.log "chain5" (chain 5)

        _ =
            Debug.log "chain0" (chain 0)

        _ =
            Debug.log "expr" (useInExpr 5)

        _ =
            Debug.log "direct" (chainDirect 5)
    in
    text "done"


chainDirect : Int -> Maybe Int
chainDirect n =
    Maybe.andThen (\c -> Just (c + 100))
        (Maybe.andThen (\b -> parse (b * 2))
            (Maybe.andThen (\a -> parse (a - 1))
                (parse n)
            )
        )
