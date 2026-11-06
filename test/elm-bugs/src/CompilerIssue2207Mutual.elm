module CompilerIssue2207Mutual exposing (..)

{-| Exposes a pair of mutually recursive functions with no type annotations, for
`CompilerIssue2207MutualRecursionSecondFunctionTest`.

`f` and `g` call each other. Using the second of them, `g`, from another module is what
Elm 0.19.1 fails to compile.

<https://github.com/elm/compiler/issues/2207>

-}


{-| Returns `g x`.
-}
f x =
    g x


{-| Counts a positive `x` down to 0 through `f`, and returns any other `x` unchanged.
-}
g x =
    if x > 0 then
        f (x - 1)

    else
        x
