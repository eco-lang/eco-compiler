module NullableMaybeKernelTest exposing (main)

{-| `Maybe` values made or read by kernels and elm/core: `String.toInt`,
`List.head`, `String.uncons`, `Dict.get`, `Array.get`, the JSON `nullable` and
`maybe` decoders, and `List.sortBy`.

Expected output from elm make + node.

-}

-- CHECK: toInt: [Nothing,Just 1]
-- CHECK: head: (Nothing,Just "",Just Nothing)
-- CHECK: uncons: (Nothing,Just ('a',"b"))
-- CHECK: dict: (Just (Just ""),Just Nothing,Nothing)
-- CHECK: dictd: ["J","N","Jc","N"]
-- CHECK: arr: (Array.fromList [Nothing,Just ""],["N","J","N"])
-- CHECK: json: ["N","J","Jj"]
-- CHECK: jsonm: [Ok "N",Ok "J"]
-- CHECK: sort: [Nothing,Just "",Just "b"]

import Array
import Dict
import Html exposing (text)
import Json.Decode as D


describe : Maybe String -> String
describe m =
    case m of
        Nothing ->
            "N"

        Just s ->
            "J" ++ s


main =
    let
        dict =
            Dict.fromList [ ( 1, Just "" ), ( 2, Nothing ), ( 3, Just "c" ) ]

        arr =
            Array.fromList [ Nothing, Just "" ]

        _ =
            Debug.log "toInt" (List.map String.toInt [ "", "1" ])

        _ =
            Debug.log "head" ( List.head (List.drop 1 [ "" ]), List.head [ "" ], List.head [ Nothing, Just "" ] )

        _ =
            Debug.log "uncons" ( String.uncons "", String.uncons "ab" )

        _ =
            Debug.log "dict" ( Dict.get 1 dict, Dict.get 2 dict, Dict.get 9 dict )

        _ =
            Debug.log "dictd" (List.map (\k -> Dict.get k dict |> Maybe.andThen identity |> describe) [ 1, 2, 3, 9 ])

        _ =
            Debug.log "arr" ( arr, List.map (\i -> Array.get i arr |> Maybe.andThen identity |> describe) [ 0, 1, 2 ] )

        _ =
            Debug.log "json" (List.map (D.decodeString (D.nullable D.string) >> Result.toMaybe >> Maybe.andThen identity >> describe) [ "null", "\"\"", "\"j\"" ])

        _ =
            Debug.log "jsonm" (List.map (D.decodeString (D.maybe (D.field "a" D.string)) >> Result.map describe) [ "{}", "{\"a\":\"\"}" ])

        _ =
            Debug.log "sort" (List.sortBy (Maybe.withDefault "") [ Just "b", Nothing, Just "" ])
    in
    text ""
