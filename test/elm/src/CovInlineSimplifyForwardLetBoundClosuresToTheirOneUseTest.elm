module CovInlineSimplifyForwardLetBoundClosuresToTheirOneUseTest exposing (..)

{-| Forward let-bound closures to their one use.

From `SourceIR.CovInlineSimplifyCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k xs r =
    let
        f1 =
            \x -> x + k

        f2 =
            \x -> x * k

        f3 =
            \x -> x - k

        f4 =
            \x -> x + 2 * k

        f5 =
            \x -> x + 3 * k

        f6 =
            \x -> x + 4 * k

        f7 =
            \x -> x + 5 * k

        y =
            List.length xs
    in
    { a =
        if y > 0 then
            f1 y

        else
            0
    , b =
        case xs of
            [] ->
                0

            h :: _ ->
                f2 h
    , c = [ 1, f3 y ]
    , d = { r | s = f4 y }
    , e = ( f5 y, y )
    , g =
        let
            z =
                y + 1
        in
        f6 z
    , h = (f7 y |> (\v -> { s = v })).s
    , i = loop 3 0 k
    }


loop : Int -> Int -> Int -> Int
loop n acc k =
    let
        f =
            \x -> x + k
    in
    if n <= 0 then
        acc

    else
        loop (n - 1) (f acc) k


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
