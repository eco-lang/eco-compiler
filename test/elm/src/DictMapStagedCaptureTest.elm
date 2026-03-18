module DictMapStagedCaptureTest exposing (main)

{-| Test: captured function parameter applied to multiple args inside Dict.map lambda.

Reproduces a bug where a captured function with staged type (returns a function)
is only partially applied inside a closure — the second arg is silently dropped.

The pattern mirrors Data.Map.map: Dict stores (k, v) tuples, and the mapping
lambda destructures the tuple and applies the captured function to both parts.
-}

-- CHECK: result: [("a",("hello",15)),("b",("world",25))]

import Dict
import Html exposing (text)


{-| A function that returns another function (naturally staged).
makeAdder "hello" returns (\value -> 5 + value).
-}
makeAdder : String -> (Int -> Int)
makeAdder key =
    \value -> String.length key + value


{-| Dict.map wrapper: captures 'alter' in a lambda that applies it to 2 args.
This is the pattern from Data.Map.map.
-}
mapTupleDict : (String -> Int -> Int) -> Dict.Dict String ( String, Int ) -> Dict.Dict String ( String, Int )
mapTupleDict alter dict =
    Dict.map (\_ ( key, value ) -> ( key, alter key value )) dict


main =
    let
        d =
            Dict.fromList
                [ ( "a", ( "hello", 10 ) )
                , ( "b", ( "world", 20 ) )
                ]

        result =
            mapTupleDict makeAdder d

        _ =
            Debug.log "result" (Dict.toList result)
    in
    text "done"
