module RecordNarrow05NoNestingTest exposing (main)

{-| A let-bound helper with an inferred extensible-record argument, folded with `List.foldl`, reads the right field of a record that is not nested in another.

The unannotated helper takes the five-field record directly from each tuple and
reads `captures`, `params` and `lambdaId`. Both members hold `LambdaId 999`, so
the sum is 1998.
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
