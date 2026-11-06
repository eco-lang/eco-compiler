module CompilerIssue2207Mutual exposing (..)

{-| Helper module for CompilerIssue2207MutualRecursionSecondFunctionTest. -}


f x =
    g x


g x =
    if x > 0 then
        f (x - 1)

    else
        x
