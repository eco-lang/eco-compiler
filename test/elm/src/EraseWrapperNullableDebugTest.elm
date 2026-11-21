module EraseWrapperNullableDebugTest exposing (main)

{-| `Debug.log` and `Debug.toString` of an erased wrapper whose field is a
`Maybe` with its own representation print the constructor. `W` is erased
(`EraseWrappers`) and `Maybe String` is made nullable (`NullableMaybe`), or
tagged (`TaggedUnions`) with the nullable pass off; either way the printer drops
the `W` (`Just Nothing` for `Just (W Nothing)`). With wrapper erasure off, or
both other passes off, the output is right. Expected output from elm make + node.

-}

-- XFAIL-NATIVE: an erased wrapper over a nullable or tagged Maybe prints without its constructor
-- CHECK: ws: [Nothing,Just (W Nothing),Just (W (Just "2"))]
-- CHECK: str: ["Nothing","Just (W Nothing)","Just (W (Just \"2\"))"]
-- CHECK: w: [W Nothing,W (Just "2")]

import Html exposing (text)


type W
    = W (Maybe String)


mk : Int -> Maybe W
mk n =
    if n == 0 then
        Nothing

    else if n == 1 then
        Just (W Nothing)

    else
        Just (W (Just (String.fromInt n)))


main =
    let
        ws =
            List.map mk [ 0, 1, 2 ]

        _ =
            Debug.log "ws" ws

        _ =
            Debug.log "str" (List.map Debug.toString ws)

        _ =
            Debug.log "w" (List.map (\(W m) -> W m) (List.filterMap identity ws))
    in
    text "done"
