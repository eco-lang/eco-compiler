module ClosureCaptureTupleTest exposing (main)

{-| Test closure capturing tuple values. -}

-- CHECK: add: 6
-- CHECK: nested: 10
-- CHECK: mixed: 9

import Html exposing (text)


addWithTuple : ( Int, Int ) -> Int -> Int
addWithTuple pair =
    \n ->
        let
            ( a, b ) =
                pair
        in
        a + b + n


nestedTuple : ( ( Int, Int ), Int ) -> Int -> Int
nestedTuple outer =
    \n ->
        let
            ( inner, c ) =
                outer

            ( a, b ) =
                inner
        in
        a + b + c + n


mixedCapture : Int -> ( Int, Int ) -> Int -> Int
mixedCapture x pair =
    \n ->
        let
            ( a, b ) =
                pair
        in
        x + a + b + n


main =
    let
        _ =
            Debug.log "add" (addWithTuple ( 1, 2 ) 3)

        _ =
            Debug.log "nested" (nestedTuple ( ( 1, 2 ), 3 ) 4)

        _ =
            Debug.log "mixed" (mixedCapture 1 ( 2, 3 ) 3)
    in
    text "done"
