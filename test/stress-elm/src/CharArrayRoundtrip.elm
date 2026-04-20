module CharArrayRoundtrip exposing (main)

-- CHECK: roundtrip: True

import Array exposing (Array)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildString : Int -> String -> String
buildString i acc =
    if i <= 0 then
        acc
    else
        buildString (i - 1) (acc ++ "x")


loop : String -> Int -> Bool -> Bool
loop original count ok =
    if count <= 0 then
        ok
    else
        let
            chars =
                original |> String.toList |> Array.fromList

            uppered =
                Array.map Char.toUpper chars

            lowered =
                Array.map Char.toLower uppered

            rebuilt =
                lowered |> Array.toList |> String.fromList
        in
        loop original (count - 1) (ok && rebuilt == original)


main =
    let
        original =
            buildString m ""

        result =
            loop original n True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
