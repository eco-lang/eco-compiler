module EraseWrapperNullableDebugTest exposing (main)

{-| `Debug.log` and `Debug.toString` of an erased wrapper whose field is a
`Maybe` with its own representation print the constructor. `W` is erased
(`EraseWrappers`) and `Maybe String` is made nullable (`NullableMaybe`), or
tagged (`TaggedUnions`) with the nullable pass off. The debug type table used to
describe `W` by its erased form, so the printer dropped the `W` (`Just Nothing`
for `Just (W Nothing)`). Expected output from elm make + node.

-}

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
