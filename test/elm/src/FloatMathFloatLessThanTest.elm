module FloatMathFloatLessThanTest exposing (..)

{-| `<` on two Float literals, `1.5 < 2.5`, is True.
-}

-- CHECK: testValue: True

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


testValue : Bool
testValue =
    1.5 < 2.5


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
