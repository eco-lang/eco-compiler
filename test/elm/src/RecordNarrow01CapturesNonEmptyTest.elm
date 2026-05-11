module RecordNarrow01CapturesNonEmptyTest exposing (main)

{-| Variation 14: captures is non-empty.

    The misread slot still reads from the wrong field, but the value is a
    non-Nil List Cons (not an embedded constant). The destructure
    `(LambdaId uid) = inner.lambdaId` won't fail in eco_resolve_hptr
    (the HPointer is real), but `uid` will be garbage — whatever bits sit
    at the projected slot of a List Cons interpreted as a LambdaId.

    Confirms the misread slot identity by varying its value.

    Expected (correct): uid: 1998 (= 999 + 999)
    Buggy outcome: a different uid value (silent miscompile, no crash).
-}

-- CHECK: uid: 1998

import Html exposing (text)


type LambdaId
    = LambdaId Int


main =
    let
        innerVal =
            { lambdaId = LambdaId 999
            , captures = [ 1, 2, 3 ]
            , params = []
            , closureKind = Nothing
            , captureAbi = Nothing
            }

        outer1 =
            { name = "test1", inner = innerVal, body = 0, monoType = 0 }

        outer2 =
            { name = "test2", inner = innerVal, body = 0, monoType = 0 }

        members =
            [ ( 0, outer1 ), ( 1, outer2 ) ]

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
            List.foldl buildSibling 0 members

        _ =
            Debug.log "uid" result
    in
    text "done"
