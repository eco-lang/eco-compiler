module X7CtorOwnerTest exposing (main)

{-| X7 counterexample shape: values of X7.Lib.Op are constructed in BOTH
modules (X7.Lib.mkLib and here) and destructured in X7.Lib.run. A per-owner
ctor-row union for X7.Lib sees only X7.Lib's constructions.
-}

-- CHECK: ops: [15,7,10,4,25]

import Html exposing (text)
import X7.Lib as Lib exposing (Op(..))


double : Int -> Int
double x =
    x * 2


main =
    let
        ops =
            [ Op (\x -> x * 3), Lib.mkLib 2, Op double ]

        wrapped =
            List.map Op [ \x -> x - 1, \x -> x * x ]

        r =
            Lib.runAll (ops ++ wrapped) 5

        _ =
            Debug.log "ops" r

        _ =
            Debug.log "twice" ( Lib.applyTwice double 3, Lib.applyTwice (\s -> s ++ "!") "a" )
    in
    text "done"
