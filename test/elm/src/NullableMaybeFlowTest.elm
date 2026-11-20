module NullableMaybeFlowTest exposing (main)

{-| `Maybe` values flowing where `NullableMaybe`
(plans/constructor-representation-levels.md N1) must keep them consistent: a
`Maybe Rec` passed to a polymorphic helper, a `Maybe` in a `Dict` value and
from `Dict.get`, from `List.head` and `List.filterMap`, a `Maybe` in a record
field and a tuple, nested `case` on a pair of `Maybe`s, `Maybe.andThen`
chains, and a `Maybe` returned from a recursive function.

-}

-- CHECK: poly: 2
-- CHECK: dict: [10,0]
-- CHECK: head: 7
-- CHECK: filterMap: [1,3]
-- CHECK: recField: 4
-- CHECK: pair: ["both 3","first 1","second 2","neither"]
-- CHECK: andThen: Just { v = 9 }
-- CHECK: find: Just { k = 3, v = "c" }
-- CHECK: notFound: Nothing

import Dict
import Html exposing (text)


type alias Rec =
    { v : Int }


count : List (Maybe a) -> Int
count xs =
    List.length (List.filter (\x -> x /= Nothing) xs)


find : Int -> List { k : Int, v : String } -> Maybe { k : Int, v : String }
find k items =
    case items of
        [] ->
            Nothing

        x :: rest ->
            if x.k == k then
                Just x

            else
                find k rest


describe : ( Maybe Rec, Maybe Rec ) -> String
describe pair =
    case pair of
        ( Just a, Just b ) ->
            "both " ++ String.fromInt (a.v + b.v)

        ( Just a, Nothing ) ->
            "first " ++ String.fromInt a.v

        ( Nothing, Just b ) ->
            "second " ++ String.fromInt b.v

        ( Nothing, Nothing ) ->
            "neither"


main =
    let
        _ =
            Debug.log "poly" (count [ Just { v = 1 }, Nothing, Just { v = 2 } ])

        d =
            Dict.fromList [ ( "a", { v = 10 } ) ]

        _ =
            Debug.log "dict" (List.map (\k -> Dict.get k d |> Maybe.map .v |> Maybe.withDefault 0) [ "a", "b" ])

        _ =
            Debug.log "head" (List.head [ { v = 7 } ] |> Maybe.map .v |> Maybe.withDefault 0)

        _ =
            Debug.log "filterMap" (List.filterMap (\r -> if r.v > 0 then Just r.v else Nothing) [ { v = 1 }, { v = 0 }, { v = 3 } ])

        holder =
            { m = Just { v = 4 } }

        _ =
            Debug.log "recField" (holder.m |> Maybe.map .v |> Maybe.withDefault 0)

        _ =
            Debug.log "pair"
                (List.map describe
                    [ ( Just { v = 1 }, Just { v = 2 } )
                    , ( Just { v = 1 }, Nothing )
                    , ( Nothing, Just { v = 2 } )
                    , ( Nothing, Nothing )
                    ]
                )

        _ =
            Debug.log "andThen" (Just { v = 3 } |> Maybe.andThen (\r -> if r.v > 0 then Just { v = r.v * 3 } else Nothing))

        items =
            [ { k = 1, v = "a" }, { k = 2, v = "b" }, { k = 3, v = "c" } ]

        _ =
            Debug.log "find" (find 3 items)

        _ =
            Debug.log "notFound" (find 9 items)
    in
    text "done"
