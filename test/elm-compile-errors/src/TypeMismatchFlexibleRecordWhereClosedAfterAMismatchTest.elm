module TypeMismatchFlexibleRecordWhereClosedAfterAMismatchTest exposing (..)

{-| The compiler rejects passing a tuple whose two components both disagree with the annotation, with a TYPE MISMATCH error.

`g` expects `( Int, { name : Int } )`. `h` passes `( "s", a )`, where the first component is a
`String`, and `a` is a record whose `name` is a `String`, since `a.name ++ "s"` uses it as one.

-}

-- COMPILE-ERROR: TYPE MISMATCH, flexible record where closed after a mismatch
-- CHECK: -- TYPE MISMATCH -

g : ( Int, { name : Int } ) -> Int
g p = 0

h a =
    let
        z = a.name ++ "s"
    in
    g ( "s", a )
