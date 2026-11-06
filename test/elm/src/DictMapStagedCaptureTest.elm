module DictMapStagedCaptureTest exposing (main)

{-| A two-argument function passed as a parameter and applied to both of its
arguments inside a `Dict.map` lambda receives both of them.

The function passed is `makeAdder`, whose definition takes one argument and
returns a lambda for the second. `mapTupleDict` hands it to `Dict.map` over a
dict whose values are `( String, Int )` pairs, and the lambda destructures each
pair and calls it with both parts. `"hello"` and `"world"` have length 5, so 10
and 20 become 15 and 25.

-}

-- CHECK: result: [("a",("hello",15)),("b",("world",25))]

import Dict
import Html exposing (text)


{-| Returns a function adding the length of `key` to its argument.
-}
makeAdder : String -> (Int -> Int)
makeAdder key =
    \value -> String.length key + value


{-| Replaces the `Int` in each value `( key, value )` of `dict` with
`alter key value`.
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
