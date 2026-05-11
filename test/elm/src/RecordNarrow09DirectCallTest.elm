module RecordNarrow09DirectCallTest exposing (main)

{-| Variation 19: let-bound helper called DIRECTLY (no higher-order).

    The helper is still let-bound and row-polymorphic, but called directly
    rather than passed to List.foldl. Tests whether the higher-order
    pass-through is essential to triggering the bug, or whether any row-poly
    let-bound call site reproduces it.

    Expected (correct): uid: 999
-}

-- CHECK: uid: 999

import Html exposing (text)


type LambdaId
    = LambdaId Int


main =
    let
        innerVal =
            { lambdaId = LambdaId 999
            , captures = []
            , params = []
            , closureKind = Nothing
            , captureAbi = Nothing
            }

        outer =
            { name = "test", inner = innerVal, body = 0, monoType = 0 }

        buildSibling tup acc =
            let
                member =
                    Tuple.second tup

                inner =
                    member.inner

                _ =
                    List.length inner.captures

                _ =
                    List.length inner.params

                (LambdaId uid) =
                    inner.lambdaId
            in
            uid + acc

        result =
            buildSibling ( 0, outer ) 0

        _ =
            Debug.log "uid" result
    in
    text "done"
