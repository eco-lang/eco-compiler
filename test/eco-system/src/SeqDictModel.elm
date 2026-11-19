module SeqDictModel exposing (run)

{-| Checks SeqDict and SeqSet against a plain list of pairs, with keys of many kinds.
`run` returns the failures: none when everything passes. `contentEquality` adds the checks of
`==` on SeqDicts, which need eco's SeqDict-aware `==` (`CtorTag.seqDict`, `seqDictEq` in
elm-kernel-cpp/src/core/Utils.cpp); elm/core's JavaScript `==` compares them structurally.
-}

import Dict
import SeqDict exposing (SeqDict)
import SeqSet


type Key
    = KInt Int
    | KStr String
    | KPair ( Int, String )
    | KRec { a : Int, b : Float }
    | KList (List Int)
    | KDict (Dict.Dict Int String)
    | KChar Char
    | KNothing


{-| A deterministic pseudo-random sequence, so the test needs no elm/random. -}
next : Int -> Int
next seed =
    modBy 2147483647 (seed * 48271)


keyFor : Int -> Key
keyFor n =
    let
        v =
            modBy 300 n
    in
    case modBy 8 n of
        0 ->
            KInt (v - 150)

        1 ->
            -- Built by ++, so the native backend holds some as ropes, others flat.
            KStr (String.repeat (modBy 3 v) "ab" ++ String.fromInt v)

        2 ->
            KPair ( v, String.fromInt (v * 7) )

        3 ->
            KRec { a = v, b = toFloat v / 4 }

        4 ->
            KList (List.range 0 (modBy 20 v))

        5 ->
            -- Same contents, built in different orders, so the trees differ in shape.
            if modBy 2 n == 0 then
                KDict (Dict.fromList (List.map (\i -> ( i, String.fromInt i )) (List.range 0 (modBy 9 v))))

            else
                KDict (Dict.fromList (List.reverse (List.map (\i -> ( i, String.fromInt i )) (List.range 0 (modBy 9 v)))))

        6 ->
            KChar (Char.fromCode (65 + modBy 50 v))

        _ ->
            KNothing


type alias Model =
    { dict : SeqDict Key Int, ref : List ( Key, Int ), seed : Int, errors : List String }


refInsert : Key -> Int -> List ( Key, Int ) -> List ( Key, Int )
refInsert k v ref =
    if List.any (\( k2, _ ) -> k2 == k) ref then
        List.map
            (\( k2, v2 ) ->
                if k2 == k then
                    ( k2, v )

                else
                    ( k2, v2 )
            )
            ref

    else
        ref ++ [ ( k, v ) ]


step : Int -> Model -> Model
step i model =
    let
        seed =
            next model.seed

        k =
            keyFor (seed // 7)

        m =
            if modBy 3 seed == 0 then
                { model | dict = SeqDict.remove k model.dict, ref = List.filter (\( k2, _ ) -> k2 /= k) model.ref, seed = seed }

            else
                { model | dict = SeqDict.insert k i model.dict, ref = refInsert k i model.ref, seed = seed }

        lookupOk =
            SeqDict.get k m.dict == (List.filter (\( k2, _ ) -> k2 == k) m.ref |> List.head |> Maybe.map Tuple.second)
    in
    if lookupOk && SeqDict.size m.dict == List.length m.ref then
        m

    else
        { m | errors = ("step " ++ String.fromInt i) :: m.errors }


run : { contentEquality : Bool } -> List String
run { contentEquality } =
    let
        final =
            List.foldl step { dict = SeqDict.empty, ref = [], seed = 12345, errors = [] } (List.range 1 3000)

        orderOk =
            SeqDict.toList final.dict == final.ref

        set =
            SeqSet.fromList [ "c", "a", "b", "a" ]

        bigDict =
            SeqDict.fromList (List.map (\i -> ( i, i * 2 )) (List.range 1 20000))

        -- Removing 1 of 10 entries leaves a hole: SeqDict only compacts below 80% full.
        withHole =
            SeqDict.fromList (List.map (\i -> ( i, String.fromInt i )) (List.range 1 10)) |> SeqDict.remove 1

        withoutHole =
            SeqDict.fromList (List.map (\i -> ( i, String.fromInt i )) (List.range 2 10))

        checks =
            [ ( "insertion order kept", orderOk )
            , ( "every key found", List.all (\( k, v ) -> SeqDict.get k final.dict == Just v) final.ref )
            , ( "SeqSet keeps order", SeqSet.toList set == [ "c", "a", "b" ] )
            , ( "big dict", SeqDict.size bigDict == 20000 && SeqDict.get 12345 bigDict == Just 24690 )
            , ( "big dict removes", SeqDict.size (List.foldl SeqDict.remove bigDict (List.range 1 19990)) == 10 )
            , ( "unorderedEquals"
              , SeqDict.unorderedEquals (SeqDict.fromList [ ( 1, "a" ), ( 2, "b" ) ]) (SeqDict.fromList [ ( 2, "b" ), ( 1, "a" ) ])
              )
            , ( "Dict keys by content"
              , SeqDict.get (Dict.fromList [ ( 1, 1 ), ( 2, 2 ), ( 3, 3 ) ])
                    (SeqDict.singleton (Dict.fromList [ ( 3, 3 ), ( 2, 2 ), ( 1, 1 ) ]) "found")
                    == Just "found"
              )
            , ( "== keeps insertion order", SeqDict.fromList [ ( 1, "a" ), ( 2, "b" ) ] /= SeqDict.fromList [ ( 2, "b" ), ( 1, "a" ) ] )
            , ( "empty string key", SeqDict.get ("a" ++ "" |> String.dropLeft 1) (SeqDict.singleton "" 1) == Just 1 )
            ]
                ++ (if contentEquality then
                        [ ( "== ignores removed entries", withHole == withoutHole )
                        , ( "== on SeqSet", SeqSet.remove 1 (SeqSet.fromList (List.range 1 10)) == SeqSet.fromList (List.range 2 10) )
                        , ( "SeqDict keys", SeqDict.get withHole (SeqDict.singleton withoutHole "found") == Just "found" )
                        ]

                    else
                        []
                   )
    in
    List.reverse final.errors
        ++ List.filterMap
            (\( name, ok ) ->
                if ok then
                    Nothing

                else
                    Just name
            )
            checks
