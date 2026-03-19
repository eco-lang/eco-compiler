module CaseDeepNestTest exposing (main)

{-| Test deeply nested case expressions (case inside case branch) with int/string scrutinees. -}

-- CHECK: r1: "x=0,y=0"
-- CHECK: r2: "x=0,y=other"
-- CHECK: r3: "x=1,y=0"
-- CHECK: r4: "x=other"
-- CHECK: triple: "all zero"
-- CHECK: triple2: "z=other"

import Html exposing (text)


classify x y =
    case x of
        0 ->
            case y of
                0 ->
                    "x=0,y=0"

                _ ->
                    "x=0,y=other"

        1 ->
            case y of
                0 ->
                    "x=1,y=0"

                _ ->
                    "x=1,y=other"

        _ ->
            "x=other"


classifyTriple x y z =
    case x of
        0 ->
            case y of
                0 ->
                    case z of
                        0 ->
                            "all zero"

                        _ ->
                            "z=other"

                _ ->
                    "y=other"

        _ ->
            "x=other"


main =
    let
        _ = Debug.log "r1" (classify 0 0)
        _ = Debug.log "r2" (classify 0 5)
        _ = Debug.log "r3" (classify 1 0)
        _ = Debug.log "r4" (classify 9 0)
        _ = Debug.log "triple" (classifyTriple 0 0 0)
        _ = Debug.log "triple2" (classifyTriple 0 0 7)
    in
    text "done"
