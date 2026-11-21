module NullableMaybeMeetsTest exposing (main)

{-| `Maybe` values in an `Array` that is sliced (`Array.slice` reaches elm/core's
`sliceLeft`, whose let-bound helper keeps a type variable nothing fixes), pushed
and appended, and in `Dict` values, `Set`-built lists and `List.sortWith`.

Expected output from elm make + node.

-}

-- CHECK: sliced: (Array.fromList [Just "",Just "a"],["J","Ja"])
-- CHECK: slicedR: (Array.fromList [Just { n = 1 },Nothing],["N","J2"])
-- CHECK: pushed: ["J","Ja","N"]
-- CHECK: appended: ["J","Ja","N","J","Ja","N"]
-- CHECK: dictKeys: ["N","J"]
-- CHECK: set: ["Ja","Jb"]
-- CHECK: sortWith: ["J","Jb","N"]

import Array
import Dict
import Html exposing (text)
import Set


type alias Rec =
    { n : Int }


describe : Maybe String -> String
describe m =
    case m of
        Nothing ->
            "N"

        Just s ->
            "J" ++ s


describeR : Maybe Rec -> String
describeR m =
    case m of
        Nothing ->
            "N"

        Just r ->
            "J" ++ String.fromInt r.n


main =
    let
        arr =
            Array.fromList [ Nothing, Just "", Just "a", Nothing ]

        sliced =
            Array.slice 1 3 arr

        recs =
            Array.fromList [ Just { n = 1 }, Nothing, Just { n = 2 } ]

        _ =
            Debug.log "sliced" ( sliced, Array.toList sliced |> List.map describe )

        _ =
            Debug.log "slicedR" ( Array.slice 0 2 recs, Array.toList (Array.slice 1 3 recs) |> List.map describeR )

        _ =
            Debug.log "pushed" (Array.push Nothing sliced |> Array.toList |> List.map describe)

        _ =
            Debug.log "appended" (Array.append sliced arr |> Array.toList |> List.map describe)

        _ =
            Debug.log "dictKeys" (Dict.fromList [ ( "a", Nothing ), ( "b", Just "" ) ] |> Dict.values |> List.map describe)

        _ =
            Debug.log "set" (Set.fromList [ "b", "a" ] |> Set.toList |> List.map Just |> List.map describe)

        _ =
            Debug.log "sortWith" (List.sortWith (\a b -> compare (describe a) (describe b)) [ Just "b", Nothing, Just "" ] |> List.map describe)
    in
    text ""
