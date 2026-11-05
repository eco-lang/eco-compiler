port module PortProblemDeclarationWithoutNameTest exposing (..)

{-| PORT PROBLEM: declaration without name.

From `SourceIR.CovPortCases` (`?`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: PORT PROBLEM
-- CHECK: -- PORT PROBLEM -
-- CHECK: I just saw the start of a `port` declaration, but then I got stuck here:
-- CHECK: I was expecting to see a name like send or receive next. Something that starts
-- CHECK: with a lower-case letter.

import Array
import Bytes
import Json.Decode
import Json.Encode


type alias Point =
    { x : Int }


port 