module RULMinimal exposing (main)

-- CHECK: final: (-1, 2, 3)

import Html exposing (text)


type alias Rec =
    { a : Int
    , b : Int
    , c : Int
    }


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            { a = 1, b = 2, c = 3 }

        flip r =
            { r | a = -r.a }

        -- 1001 iterations: odd, so a should end negated.
        transformed =
            applyNTimes 1001 flip original

        _ =
            Debug.log "final" ( transformed.a, transformed.b, transformed.c )
    in
    text "done"
