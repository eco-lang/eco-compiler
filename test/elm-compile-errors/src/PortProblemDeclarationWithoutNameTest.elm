port module PortProblemDeclarationWithoutNameTest exposing (..)

{-| A `port` keyword at the end of a module with no name or type after it is rejected with a PORT PROBLEM syntax error.

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