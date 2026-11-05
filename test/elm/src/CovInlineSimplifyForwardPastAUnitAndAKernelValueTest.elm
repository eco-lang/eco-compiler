module CovInlineSimplifyForwardPastAUnitAndAKernelValueTest exposing (..)

{-| Forward past a unit and a kernel value.

From `SourceIR.CovInlineSimplifyCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k y =
    let
        f1 =
            \x -> x + k

        f2 =
            \x -> x * k
    in
    ( ( (), f1 y ), ( pi, f2 y ) )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
