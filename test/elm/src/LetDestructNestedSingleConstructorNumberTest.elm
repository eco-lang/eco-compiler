module LetDestructNestedSingleConstructorNumberTest exposing (..)

{-| A `let` destructuring pattern through two nested single-constructor types reads
a number literal that is then used as a Float.

`Two (Inner 1) 3` is bound unannotated, then matched with `(Two (Inner y) _)`; since
`testValue : Float` returns `y + 0.5`, the `1` is a Float and the result is 1.5. The
type `Outer` is declared but not used.

-}

-- CHECK: testValue: 1.5

import Basics exposing (..)
import Html exposing (text)


type Two a
    = Two (Inner a) Int


type Inner a
    = Inner a


type Outer a
    = Outer (Inner a)


testValue : Float
testValue =
    let
        o =
            Two (Inner 1) 3

        (Two (Inner y) _) =
            o
    in
    y + 0.5


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
