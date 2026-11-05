module TypeMismatchRigidExtensionWhereFlexibleAfterAMismatchTest exposing (..)

{-| TYPE MISMATCH: rigid extension where flexible after a mismatch.

From `SourceIR.TypeCheckFailsCases` (`problemCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: TYPE MISMATCH, rigid extension where flexible after a mismatch
-- CHECK: -- TYPE MISMATCH -
-- CHECK: { r | name : Int }

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
