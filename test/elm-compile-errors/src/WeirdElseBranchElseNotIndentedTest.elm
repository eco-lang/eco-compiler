module WeirdElseBranchElseNotIndentedTest exposing (main)

{-| An `if` inside a `let` binding whose `else` sits at the binding's own column, to the left of
its `if`, is rejected with a WEIRD ELSE BRANCH error.

The `else` keyword has to be indented further than the start of the `let` binding `y`, and
here it is level with it.

-}

-- COMPILE-ERROR: WEIRD ELSE BRANCH
-- CHECK: -- WEIRD ELSE BRANCH -


main =
    let
        y =
            if True then
                1
        else
                2
    in
    y
