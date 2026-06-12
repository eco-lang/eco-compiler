module LetNumberCustomTriple3Test exposing (main)

{-| Probe: a single constructor with THREE `number` fields sharing one type
parameter (`Tri number number number`), all projected at `Float`. Extends the
shared-param `Pair` (2 fields) case to 3. Correct: (30+40+50)*1.5 = 180.
-}

-- CHECK: tri3: 180

import Html exposing (text)


type Tri number
    = Tri number number number


main =
    let
        v =
            Tri 30 40 50

        result =
            case v of
                Tri a b c ->
                    round (a * 1.5) + round (b * 1.5) + round (c * 1.5)

        _ =
            Debug.log "tri3" result
    in
    text "done"
