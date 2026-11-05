port module PortProblemDeclarationWithoutNameTest exposing (..)

{-| PORT PROBLEM: declaration without name.

From `SourceIR.CovPortCases` (`?`), an elm-test program the compiler must reject.

-}

-- COMPILE-ERROR: PORT PROBLEM
-- CHECK: -- PORT PROBLEM -

import Array
import Bytes
import Json.Decode
import Json.Encode


type alias Point =
    { x : Int }


port 