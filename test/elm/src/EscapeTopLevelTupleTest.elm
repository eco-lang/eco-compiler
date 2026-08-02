module EscapeTopLevelTupleTest exposing (main)

{-| Phase 2 negative: a tuple bound at module scope cannot be
rewritten to eco.make.tuple2 (the value crosses a module-global
boundary, which the conservative escape classifier treats as
escaping). The program must still produce the correct projected
values via the heap path with -enable-unboxed-agg on (HISTORICAL — pass deleted 2026-06; kept as behavioral coverage, see plans/opt-tier1-aggregate-promotion.md U-T1.3).
-}

-- CHECK: a: 11
-- CHECK: b: 22


import Html exposing (text)


globalPair : ( Int, Int )
globalPair =
    ( 11, 22 )


main =
    let
        ( a, b ) =
            globalPair

        _ =
            Debug.log "a" a

        _ =
            Debug.log "b" b
    in
    text "done"
