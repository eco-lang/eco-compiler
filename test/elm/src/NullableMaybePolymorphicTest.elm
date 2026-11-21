module NullableMaybePolymorphicTest exposing (main)

{-| `Maybe` values through polymorphic helpers, `Maybe.map`/`andThen`/`withDefault`,
three levels of nesting, record, list, tuple, unit, Bool and function payloads,
inside a wrapper, and compared with `==`. elm/core's `Maybe` is never a tagged
union (MONO_035): its `Nothing` is the `eco.constant Nothing` word, which carries
no constructor index.

Expected output from elm make + node.

-}

-- CHECK: strs: ([Nothing,Just "",Just "a"],["N","J","Ja"])
-- CHECK: poly: ([Nothing,Just "",Just "a"],[Nothing,Just "y",Just "a"])
-- CHECK: map: ([Nothing,Just "",Just "A"],[Nothing,Nothing,Just "a"])
-- CHECK: with: (["d","","a"],["","a"])
-- CHECK: nested: ([Nothing,Just Nothing,Just (Just Nothing),Just (Just (Just "")),Just (Just (Just "x"))],["N","N","N","J","Jx"])
-- CHECK: recs: ([Nothing,Just { name = "", tags = [] },Just { name = "r", tags = ["t"] }],["N","J","Jr"])
-- CHECK: lists: ([Nothing,Just [],Just [""]],["N","J","J"])
-- CHECK: tuples: ([Nothing,Just ("",False)],["N","J"])
-- CHECK: units: ([Nothing,Just ()],["N","Ju"])
-- CHECK: bools: ([Nothing,Just True,Just False],["N","Jt","Jf"])
-- CHECK: fns: ["N","J2"]
-- CHECK: boxed: ([Box Nothing,Box (Just ""),Box (Just "a")],["N","J","Ja"])
-- CHECK: eq: ([True,False,False],[False,True,False])

import Html exposing (text)


type alias Rec =
    { name : String, tags : List String }


type Box a
    = Box a


unbox : Box a -> a
unbox (Box a) =
    a


pick : Int -> Maybe a -> Maybe a -> Maybe a
pick n x y =
    if n == 0 then
        x

    else
        y


describe : Maybe String -> String
describe m =
    case m of
        Nothing ->
            "N"

        Just s ->
            "J" ++ s


strs : List (Maybe String)
strs =
    [ Nothing, Just "", Just "a" ]


main =
    let
        nested : List (Maybe (Maybe (Maybe String)))
        nested =
            [ Nothing, Just Nothing, Just (Just Nothing), Just (Just (Just "")), Just (Just (Just "x")) ]

        recs : List (Maybe Rec)
        recs =
            [ Nothing, Just { name = "", tags = [] }, Just { name = "r", tags = [ "t" ] } ]

        lists : List (Maybe (List String))
        lists =
            [ Nothing, Just [], Just [ "" ] ]

        tuples : List (Maybe ( String, Bool ))
        tuples =
            [ Nothing, Just ( "", False ) ]

        units : List (Maybe ())
        units =
            [ Nothing, Just () ]

        bools : List (Maybe Bool)
        bools =
            [ Nothing, Just True, Just False ]

        fns : List (Maybe (Int -> Int))
        fns =
            [ Nothing, Just (\n -> n + 1) ]

        boxed : List (Box (Maybe String))
        boxed =
            List.map Box strs

        _ =
            Debug.log "strs" ( strs, List.map describe strs )

        _ =
            Debug.log "poly" ( List.map identity strs, List.map2 (\i m -> pick i m (Just "y")) [ 0, 1, 0 ] strs )

        _ =
            Debug.log "map" ( List.map (Maybe.map String.toUpper) strs, List.map (Maybe.andThen (\s -> if s == "" then Nothing else Just s)) strs )

        _ =
            Debug.log "with" ( List.map (Maybe.withDefault "d") strs, List.filterMap identity strs )

        _ =
            Debug.log "nested" ( nested, List.map (Maybe.andThen identity >> Maybe.andThen identity >> describe) nested )

        _ =
            Debug.log "recs" ( recs, List.map (Maybe.map .name >> describe) recs )

        _ =
            Debug.log "lists" ( lists, List.map (Maybe.map (String.join ",") >> describe) lists )

        _ =
            Debug.log "tuples" ( tuples, List.map (Maybe.map Tuple.first >> describe) tuples )

        _ =
            Debug.log "units" ( units, List.map (Maybe.map (\() -> "u") >> describe) units )

        _ =
            Debug.log "bools" ( bools, List.map (Maybe.map (\b -> if b then "t" else "f") >> describe) bools )

        _ =
            Debug.log "fns" (List.map (Maybe.map (\f -> String.fromInt (f 1)) >> describe) fns)

        _ =
            Debug.log "boxed" ( boxed, List.map (unbox >> describe) boxed )

        _ =
            Debug.log "eq" ( List.map (\m -> m == Nothing) strs, List.map (\m -> m == Just "") strs )
    in
    text ""
