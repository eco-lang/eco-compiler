module TypeMismatchRigidExtensionWhereFlexibleAfterAMismatchTest exposing (..)

{-| An extensible record argument placed in a list beside an unannotated local value is rejected with a TYPE MISMATCH.

Inside `g : { r | name : Int } -> Int`, a local `h a` uses `a.name ++ "s"` and builds `[ ( 1, a ), ( "s", r ) ]`. The list's tuples disagree on their first component (`Int` against `String`), and putting `a` beside `r` would also require `a.name`, already used as a `String`, to be the annotated `Int`.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid extension where flexible after a mismatch
-- CHECK: -- TYPE MISMATCH -

g : { r | name : Int } -> Int
g r =
    let
        h a =
            let
                z = a.name ++ "s"
            in
            [ ( 1, a ), ( "s", r ) ]
    in
    0
