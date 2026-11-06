module CovTailRecPairParameterPassedUnchangedLetBoundAndRebuiltTest exposing (..)

{-| Self tail-recursive functions with a pair parameter that is destructured in a `let`, then
passed on unchanged, rebuilt with its components swapped, or replaced by a `let`-bound pair.

`testValue` takes arguments and is never applied, so the program logs it as `<function>`; the
test checks that these definitions compile and the program runs.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


type T
    = A
    | B Int
    | C


testValue k =
    ( loop k A ( 1, 2 ), jumpy k (Just 3) ( 3, 4 ) )


jumpy : Int -> Maybe Int -> ( Int, Int ) -> Int
jumpy n m p =
    let
        ( x, y ) =
            p
    in
    case m of
        Just 1 ->
            jumpy (n - 1) Nothing ( y, x )

        Just 2 ->
            jumpy (n - 1) (Just 1) ( 1, 2 )

        _ ->
            if n <= 0 then
                x + y

            else
                jumpy (n - 1) (Just 2) p


loop : Int -> T -> ( Int, Int ) -> Int
loop n t p =
    let
        ( x, y ) =
            p
    in
    case t of
        A ->
            if n <= 0 then
                x

            else
                loop (n - 1) C p

        B k ->
            let
                q =
                    ( k, y )
            in
            loop (n - 1) A q

        C ->
            loop (n - 1) (B n) ( y, x )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
