module FunctionCompappendWithStringTest exposing (..)

{-| A function whose arguments have the `compappend` constraint (comparable and appendable) works when called with `String`s.

`zsortConcat` compares its two arguments with `<` and appends them smaller
first, so `zsortConcat "hello" "world"` is `"helloworld"`.

-}

-- CHECK: testValue: "helloworld"

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


zsortConcat : compappend -> compappend -> compappend
zsortConcat a b =
    if a < b then
        a ++ b

    else
        b ++ a


testValue : String
testValue =
    zsortConcat "hello" "world"


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
