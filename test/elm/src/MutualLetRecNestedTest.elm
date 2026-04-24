module MutualLetRecNestedTest exposing (main)

{-| Bootstrap-stage regression: mutually-recursive closure group created
INSIDE another closure, where the outer closure's captures flow into the
inner closures' non-sibling captures. This exercises the case where the
group op's non-sibling capture operands are themselves captures of the
enclosing $cap function (i.e. !eco.value ABI-ptr arguments), not freshly
generated heap pointers.

Ran at bootstrap stage 6 the symptom was
    'llvm.call' op operand type mismatch for operand 1:
    'i64' != '!llvm.ptr<1>'

-}

-- CHECK: run 3: 42
-- CHECK: run 2: 84
-- CHECK: run 1: 42
-- CHECK: run 0: 84


import Html exposing (text)


makeClassifier : Int -> Int -> Int -> Int -> (Int -> Int)
makeClassifier extA extB extC extD =
    \n ->
        let
            innerSmall k =
                if k <= 0 then
                    extA + extB + extC + extD

                else
                    innerBig (k - 1)

            innerBig k =
                if k <= 0 then
                    2 * (extA + extB + extC + extD)

                else
                    innerSmall (k - 1)
        in
        innerBig n


main =
    let
        classifier =
            makeClassifier 10 11 12 9

        _ =
            Debug.log "run 3" (classifier 3)

        _ =
            Debug.log "run 2" (classifier 2)

        _ =
            Debug.log "run 1" (classifier 1)

        _ =
            Debug.log "run 0" (classifier 0)
    in
    text "done"
