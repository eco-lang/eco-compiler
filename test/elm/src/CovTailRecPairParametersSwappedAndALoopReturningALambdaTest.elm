module CovTailRecPairParametersSwappedAndALoopReturningALambdaTest exposing (..)

{-| Self tail-recursive functions over pair parameters: one that swaps a pair's components or
exchanges its two pair arguments, and one that returns a lambda in its base case.

`testValue` takes arguments and is never applied, so the program logs it as `<function>`; the
test checks that these definitions compile and the program runs.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k =
    ( alt k ( 1, 2 ) ( 3, 4 ), toFn k ( 5, 6 ) k )


toFn : Int -> ( Int, Int ) -> Int -> Int
toFn n p =
    let
        ( a, b ) =
            p
    in
    if n <= 0 then
        \z -> z + a + b

    else
        toFn (n - 1) ( b, a + 1 )


alt : Int -> ( Int, Int ) -> ( Int, Int ) -> Int
alt n p q =
    let
        ( a, b ) =
            p

        ( c, d ) =
            q
    in
    if n <= 0 then
        a + b + c + d

    else if n == 3 then
        alt (n - 1) ( b, a ) q

    else
        alt (n - 1) q p


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
