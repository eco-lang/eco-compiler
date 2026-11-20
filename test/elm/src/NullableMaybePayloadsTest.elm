module NullableMaybePayloadsTest exposing (main)

{-| `Maybe` of each kind of payload, built, matched, mapped, compared and
printed. Under `NullableMaybe` (plans/constructor-representation-levels.md N1)
a `Maybe` whose payload can never be the Empty constant is represented as the
payload itself, with `Nothing` the Empty constant: a record, a tuple, a
function, a `Bool` (both values), an enum, and a custom type with fields. The
payloads that can be Empty (`Int` is unboxed, `String`, `List`, `()`) keep the
heap `Just`. The results are the same either way.

-}

-- CHECK: rec: [1,0]
-- CHECK: tuple: ["a","none"]
-- CHECK: fn: [11,0]
-- CHECK: bool: ["T","F","N"]
-- CHECK: enum: ["Red","none"]
-- CHECK: shape: [6,0]
-- CHECK: int: [3,0]
-- CHECK: str: ["s",""]
-- CHECK: list: [2,0]
-- CHECK: unit: [1,0]
-- CHECK: eq: [True,False,True,False]
-- CHECK: show: [Just { n = 1 },Nothing]
-- CHECK: showBool: [Just True,Just False,Nothing]
-- CHECK: showNested: Just (Just { n = 2 })
-- CHECK: showTuple: Just ("a",1)
-- CHECK: withDefault: 5

import Html exposing (text)


type Color
    = Red
    | Green


type Shape
    = Circle Int
    | Square Int Int


area : Shape -> Int
area s =
    case s of
        Circle r ->
            r * 3

        Square a b ->
            a * b


noRec : Maybe { n : Int }
noRec =
    Nothing


recN : Maybe { n : Int } -> Int
recN m =
    case m of
        Just r ->
            r.n

        Nothing ->
            0


boolS : Maybe Bool -> String
boolS m =
    case m of
        Just True ->
            "T"

        Just False ->
            "F"

        Nothing ->
            "N"


colorS : Maybe Color -> String
colorS m =
    case m of
        Just Red ->
            "Red"

        Just Green ->
            "Green"

        Nothing ->
            "none"


main =
    let
        _ =
            Debug.log "rec" (List.map recN [ Just { n = 1 }, Nothing ])

        _ =
            Debug.log "tuple" (List.map (Maybe.map Tuple.first >> Maybe.withDefault "none") [ Just ( "a", 1 ), Nothing ])

        _ =
            Debug.log "fn" (List.map (\m -> Maybe.map (\f -> f 10) m |> Maybe.withDefault 0) [ Just (\x -> x + 1), Nothing ])

        _ =
            Debug.log "bool" (List.map boolS [ Just True, Just False, Nothing ])

        _ =
            Debug.log "enum" (List.map colorS [ Just Red, Nothing ])

        _ =
            Debug.log "shape" (List.map (Maybe.map area >> Maybe.withDefault 0) [ Just (Square 2 3), Nothing ])

        _ =
            Debug.log "int" (List.map (Maybe.withDefault 0) [ Just 3, Nothing ])

        _ =
            Debug.log "str" (List.map (Maybe.withDefault "") [ Just "s", Nothing ])

        _ =
            Debug.log "list" (List.map (Maybe.map List.length >> Maybe.withDefault 0) [ Just [ 1, 2 ], Nothing ])

        _ =
            Debug.log "unit" (List.map (\m -> if m == Just () then 1 else 0) [ Just (), Nothing ])

        _ =
            Debug.log "eq" [ Just { n = 1 } == Just { n = 1 }, Just { n = 1 } == Nothing, noRec == Nothing, Just True == Just False ]

        _ =
            Debug.log "show" [ Just { n = 1 }, Nothing ]

        _ =
            Debug.log "showBool" [ Just True, Just False, Nothing ]

        _ =
            Debug.log "showNested" (Just (Just { n = 2 }))

        _ =
            Debug.log "showTuple" (Just ( "a", 1 ))

        _ =
            Debug.log "withDefault" (Maybe.withDefault { n = 5 } Nothing).n
    in
    text "done"
