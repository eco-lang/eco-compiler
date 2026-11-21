module NullableSpareWordTest exposing (main)

{-| `Maybe` and Maybe-shaped user types whose payload can be the word a
`Nothing` would otherwise take: `Maybe String` (with `Just ""`),
`Maybe (List Int)` (with `Just []`), `Maybe ()`, `Maybe {}`, three nested
levels of `Maybe String`, `Maybe (Maybe Rec)`, a user `Opt` at `Bool`, at an
enum and at `String`, and `Maybe (Opt String)`. Each value is matched with
`case`, mapped, defaulted, compared with `==`, kept as a `Dict` value and
printed; some are produced by a top-level constant, a function result, and
`List.map (always Nothing)`.

## eco

These types are nullable with exact null words
(plans/constructor-representation-followups.md F2): a `Nothing` whose payload
can be Empty is a spare word, one level per nested layer, so `Nothing`,
`Just Nothing` and `Just (Just "")` stay three different words.

-}

-- CHECK: strings: ["N","J \"\"","J \"a\""]
-- CHECK: lists: ["N","J 0","J 2"]
-- CHECK: units: [Nothing,Just ()]
-- CHECK: emptyRecs: [Nothing,Just {}]
-- CHECK: nested: ["0","1","2","3:","3:x"]
-- CHECK: nestedEq: [True,False,False,True,False]
-- CHECK: maybeRec: [Nothing,Just Nothing,Just (Just { n = 1 })]
-- CHECK: optBool: [None,Some True,Some False]
-- CHECK: optColor: [None,Some Red,Some Blue]
-- CHECK: optString: [None,Some "",Some "s"]
-- CHECK: maybeOpt: [Nothing,Just None,Just (Some ""),Just (Some "t")]
-- CHECK: defaults: ["d","","a"]
-- CHECK: mapped: [Nothing,Just 0,Just 1]
-- CHECK: dict: [(1,Nothing),(2,Just ""),(3,Just "x")]
-- CHECK: dictGet: [Just Nothing,Just (Just ""),Nothing]
-- CHECK: eqEmpty: [False,True,False]
-- CHECK: always: [Nothing,Nothing]
-- CHECK: topLevel: Just Nothing

import Dict
import Html exposing (text)


type Opt a
    = None
    | Some a


type Color
    = Red
    | Blue


topLevel : Maybe (Maybe String)
topLevel =
    Just Nothing


emptyOrNot : String -> Maybe String
emptyOrNot s =
    if s == "none" then
        Nothing

    else
        Just s


showString : Maybe String -> String
showString m =
    case m of
        Nothing ->
            "N"

        Just s ->
            "J " ++ Debug.toString s


showList : Maybe (List Int) -> String
showList m =
    case m of
        Nothing ->
            "N"

        Just xs ->
            "J " ++ String.fromInt (List.length xs)


showNested : Maybe (Maybe (Maybe String)) -> String
showNested m =
    case m of
        Nothing ->
            "0"

        Just Nothing ->
            "1"

        Just (Just Nothing) ->
            "2"

        Just (Just (Just s)) ->
            "3:" ++ s


main =
    let
        strings =
            [ emptyOrNot "none", emptyOrNot "", emptyOrNot "a" ]

        a0 : Maybe (Maybe (Maybe String))
        a0 =
            Nothing

        a1 : Maybe (Maybe (Maybe String))
        a1 =
            Just Nothing

        a2 : Maybe (Maybe (Maybe String))
        a2 =
            Just (Just Nothing)

        a3 : Maybe (Maybe (Maybe String))
        a3 =
            Just (Just (Just ""))

        nested =
            [ a0, a1, a2, a3, Just (Just (Just "x")) ]

        alwaysNothing : List (Maybe String)
        alwaysNothing =
            List.map (always Nothing) [ Just "", Just "y" ]

        _ =
            Debug.log "strings" (List.map showString strings)

        _ =
            Debug.log "lists" (List.map showList [ Nothing, Just [], Just [ 1, 2 ] ])

        _ =
            Debug.log "units" [ Nothing, Just () ]

        _ =
            Debug.log "emptyRecs" [ Nothing, Just {} ]

        _ =
            Debug.log "nested" (List.map showNested nested)

        _ =
            Debug.log "nestedEq"
                [ a2 == Just (Just Nothing)
                , a0 == a1
                , a1 == a3
                , a3 == Just (Just (Just ""))
                , a3 == a2
                ]

        _ =
            Debug.log "maybeRec" [ Nothing, Just Nothing, Just (Just { n = 1 }) ]

        _ =
            Debug.log "optBool" [ None, Some True, Some False ]

        _ =
            Debug.log "optColor" [ None, Some Red, Some Blue ]

        _ =
            Debug.log "optString" [ None, Some "", Some "s" ]

        _ =
            Debug.log "maybeOpt" [ Nothing, Just None, Just (Some ""), Just (Some "t") ]

        _ =
            Debug.log "defaults" (List.map (Maybe.withDefault "d") strings)

        _ =
            Debug.log "mapped" (List.map (Maybe.map String.length) strings)

        d =
            Dict.fromList [ ( 1, Nothing ), ( 2, Just "" ), ( 3, Just "x" ) ]

        _ =
            Debug.log "dict" (Dict.toList d)

        _ =
            Debug.log "dictGet" [ Dict.get 1 d, Dict.get 2 d, Dict.get 4 d ]

        _ =
            Debug.log "eqEmpty" [ emptyOrNot "none" == Just "", emptyOrNot "" == Just "", Just "" == Nothing ]

        _ =
            Debug.log "always" alwaysNothing

        _ =
            Debug.log "topLevel" topLevel
    in
    text "done"
