module CovTailRecSplitATripleParameterTest exposing (..)

{-| A self tail-recursive function that destructures a triple of `Int`, `Int` and `Float` in its
parameter pattern and rebuilds it on each call.

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
    rot k ( 1, 2, 3.0 )


rot : Int -> ( Int, Int, Float ) -> Float
rot n ( a, b, c ) =
    if n <= 0 then
        toFloat (a + b) + c

    else
        rot (n - 1) ( b, a + 1, c * 2.0 )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
