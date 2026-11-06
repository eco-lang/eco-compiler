module CovInlineSimplifyLoopifyThroughRecordTupleAndListBodiesTest exposing (..)

{-| Self tail-recursive functions whose loop state is a record (updated, or built fresh) or a
tuple holding a list, each taking a function argument.

`testValue` takes arguments and is never applied, so the program logs it as `<function>`; the
test checks that these definitions compile and the program runs.

## eco

Taken from the program "Loopify through record, tuple and list bodies" in compiler/tests/SourceIR/CovInlineSimplifyCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises the inline/simplify pass on the shape the title names; only compiling and running matters, so the function is never applied.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k =
    ( recLoop (\x -> x + k) 3 { s = 0, t = 1 }
    , createLoop (\x -> x * k) 3 { s = 1 }
    , tupLoop (\x -> x - k) 3 ( 0, [] )
    )


tupLoop : (Int -> Int) -> Int -> ( Int, List Int ) -> ( Int, List Int )
tupLoop f n ( a, xs ) =
    if n <= 0 then
        ( a, xs )

    else
        tupLoop f (n - 1) ( f a, [ a, max a n ] )


createLoop : (Int -> Int) -> Int -> { s : Int } -> { s : Int }
createLoop f n r =
    if n <= 0 then
        r

    else
        createLoop f (n - 1) { s = f r.s }


recLoop : (Int -> Int) -> Int -> { s : Int, t : Int } -> { s : Int, t : Int }
recLoop f n r =
    if n <= 0 then
        r

    else
        recLoop f (n - 1) { r | s = f r.s }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
