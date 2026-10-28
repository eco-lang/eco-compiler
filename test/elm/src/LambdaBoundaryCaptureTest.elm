module LambdaBoundaryCaptureTest exposing (main)

{-| Regression test: variable capture in
Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries (recomment-bugs.txt,
NormalizeLambdaBoundaries.elm line 885). The fresh-name counter restarts per
case boundary and renameExpr does not stop at binders, so merging the outer
case boundary renames `b` to `a_hl_0`, which the already-merged inner lambda's
parameter captures: `a + b` computes `100 + 100` instead of `100 + 5`.

EXPECTED TO FAIL until the bug is fixed.
-}

-- CHECK: result: 105

import Html exposing (text)


apply : (Int -> Int -> Int) -> Int -> Int
apply g n =
    g n 100


f : Bool -> Bool -> Int -> Int
f s t =
    case s of
        True ->
            \a -> a

        False ->
            \b ->
                apply
                    (\y ->
                        case t of
                            True ->
                                \a -> a + b

                            False ->
                                \a -> a
                    )
                    1


main =
    let
        _ =
            Debug.log "result" (f False True 5)
    in
    text "done"
