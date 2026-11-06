module CompilerIssue2338LambdaLetAnnotationTupleCrashTest exposing (main)

{-| A let annotation `( Int, x )` inside a lambda passed to a higher-order function crashes the compiler.

<https://github.com/elm/compiler/issues/2338>

`return : ( Int, x )` claims the second component is any type, but it is the lambda argument `b`: a TYPE MISMATCH. Elm 0.19.1 crashes ("x [rank = 2]", Type/Solve.hs:206, "thread blocked indefinitely in an MVar operation"). (`mapAccuml` is copied from elm-community/list-extra.)

-}

-- COMPILE-ERROR: TYPE MISMATCH, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: -- TYPE MISMATCH -

import Html exposing (text)


main =
    text "done"


mapAccuml : (a -> b -> ( a, c )) -> a -> List b -> ( a, List c )
mapAccuml f acc0 list =
    let
        ( accFinal, generatedL ) =
            List.foldl
                (\x ( acc1, ys ) ->
                    let
                        ( acc2, y ) =
                            f acc1 x
                    in
                    ( acc2, y :: ys )
                )
                ( acc0, [] )
                list
    in
    ( accFinal, List.reverse generatedL )


func =
    mapAccuml
        (\a b ->
            let
                return : ( Int, x )
                return =
                    ( a, b )
            in
            return
        )
        ( 0, 0 )
