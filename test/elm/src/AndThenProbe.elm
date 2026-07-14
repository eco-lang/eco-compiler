module AndThenProbe exposing (main)

{-| H2 collapse witness (plans/hof-elimination-closure-alloc-reduction.md):
under the DEFAULT config (hofThreshold=25 + case-body inlining + let-of-
closure flattening + let-callee forwarding), the DIRECT saturated
`Maybe.andThen` chain compiles to straight-line nested cases with zero
closure allocations. The PIPE-shaped chain does NOT collapse yet: it
partially applies `andThen`, and hofBudget-admitted candidates are
exact-application-only (the partial rebuild's re-staged closure trips the
runtime typed-apply arity assert — CombinatorB* pins). When the partial
rebuild is fixed, the pipe shape should collapse too and a module-wide
papCreate NOT-check can be added here.
-}

import Html exposing (text)

-- CHECK: chain5: Just 108
-- CHECK: chain0: Nothing
-- CHECK: expr: 217
-- CHECK: direct: Just 108



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
