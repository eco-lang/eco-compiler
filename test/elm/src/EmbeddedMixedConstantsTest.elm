module EmbeddedMixedConstantsTest exposing (main)

{-| A record holding `Nothing`, `[]`, `True`, `""` and `()` returns each value
unchanged when its field is read.
-}

-- CHECK: m: Nothing
-- CHECK: l: []
-- CHECK: b: True
-- CHECK: s: ""
-- CHECK: u: ()

import Html exposing (text)


type alias Bundle =
    { m : Maybe Int
    , l : List Int
    , b : Bool
    , s : String
    , u : ()
    }


main =
    let
        bundle =
            { m = Nothing, l = [], b = True, s = "", u = () }

        _ = Debug.log "m" bundle.m
        _ = Debug.log "l" bundle.l
        _ = Debug.log "b" bundle.b
        _ = Debug.log "s" bundle.s
        _ = Debug.log "u" bundle.u
    in
    text "done"
