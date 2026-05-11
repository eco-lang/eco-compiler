module RecordNarrow05NoNestingTest exposing (main)

{-| Variation 28: NO outer record.

    The helper takes a 5-field record DIRECTLY (no nesting via an outer
    record). Still let-bound, still row-polymorphic, still passed to
    List.foldl.

    Tests whether the nesting in the original repro is essential or whether
    plain row polymorphism on a single record is sufficient.

    Expected (correct): uid: 1998
-}

-- CHECK: uid: 1998

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

        members =
            [ ( 0, innerVal ), ( 1, innerVal ) ]

        buildSibling tup acc =
            let
                inner =
                    Tuple.second tup

                _ =
                    List.length inner.captures

                _ =
                    List.length inner.params

                (LambdaId uid) =
                    inner.lambdaId
            in
            uid + acc

        result =
            List.foldl buildSibling 0 members

        _ =
            Debug.log "uid" result
    in
    text "done"
