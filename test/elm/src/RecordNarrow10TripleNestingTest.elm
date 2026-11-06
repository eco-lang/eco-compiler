module RecordNarrow10TripleNestingTest exposing (main)

{-| A let-bound helper with an inferred extensible-record argument, folded with `List.foldl`, reads a field three records deep.

The unannotated helper reads `member.mid.inner`, then `captures`, `params` and
`lambdaId` of it, so each level's inferred type names only some of that record's
fields. Both members hold `LambdaId 999`, so the sum is 1998.
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

        midVal =
            { inner = innerVal
            , midName = "mid"
            , midTag = 0
            , midSize = 0
            }

        outerVal =
            { mid = midVal
            , name = "outer"
            , body = 0
            , monoType = 0
            }

        members =
            [ ( 0, outerVal ), ( 1, outerVal ) ]

        buildSibling tup acc =
            let
                member =
                    Tuple.second tup

                inner =
                    member.mid.inner

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
