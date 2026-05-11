module RecordNarrow10TripleNestingTest exposing (main)

{-| Variation 29: triple nesting.

    Outermost { mid : Middle { inner : Inner } }. The helper reads through
    three layers: `member.mid.inner.lambdaId`. Each layer uses only one or
    a few fields, so narrowing could chain through.

    Tests whether the bug surface scales with nesting depth.

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
