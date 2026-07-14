module AndThenProbe exposing (main)

{-| H2/H2.5 collapse witness
(plans/hof-elimination-closure-alloc-reduction.md): under the DEFAULT
config, BOTH the pipe-shaped and the direct `Maybe.andThen` chains compile
to straight-line nested cases with zero closure allocations. The pipe shape
needs H2.5 step 1 — the strictly-partial `Maybe.andThen λ` binding that apR
inlining leaves behind is forwarded and MERGED with its application into
one saturated call (partialMerges), which then inlines exactly; no partial
rebuild ever runs.
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
