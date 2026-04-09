module EmbeddedNothingPolymorphicTest exposing (main)

{-| Test embedded constants flowing through polymorphic identity.
-}

-- CHECK: r1: Nothing
-- CHECK: r2: []
-- CHECK: r3: ""

import Html exposing (text)


useNothing : Maybe Int -> Maybe Int
useNothing x =
    x


useNil : List Int -> List Int
useNil x =
    x


main =
    let
        r1 =
            identity Nothing |> useNothing

        r2 =
            identity [] |> useNil

        r3 =
            identity ""

        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
        _ = Debug.log "r3" r3
    in
    text "done"
