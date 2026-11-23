module CaptureQualMapTest exposing (main)

{-| A user-written map over a user-written right fold, called with three
different functions, gives each function's results.

`myMap f xs` folds `xs` with `myFoldr`, a user-written right fold, passing
it the lambda `\x acc -> f x :: acc`. It is called with `double`, with
`square`, and, through `shiftAll 10`, with a lambda that captures `k`. Mapping
`[ 1, 2, 3 ]` gives `[2,4,6]`, `[1,4,9]` and `[11,12,13]`.

## eco

Exercises capture-qualified lambda members (plans/lss-capture-qualified-members.md):
`myFoldr` is specialized once for each of the three copies of the lambda
`myMap` passes it, and each copy calls its function directly. The results must
be the same as with one shared, generically dispatched `myFoldr`. The MLIR twin,
which checks the direct calls, is test/eco-mlir/src/CaptureQualFoldTest.elm.

-}

-- CHECK: doubled: [2,4,6]
-- CHECK: squared: [1,4,9]
-- CHECK: shifted: [11,12,13]

import Html exposing (text)


myFoldr : (a -> b -> b) -> b -> List a -> b
myFoldr fn acc xs =
    case xs of
        [] ->
            acc

        y :: ys ->
            fn y (myFoldr fn acc ys)


myMap : (a -> b) -> List a -> List b
myMap f xs =
    myFoldr (\x acc -> f x :: acc) [] xs


double : Int -> Int
double x =
    x * 2


square : Int -> Int
square x =
    x * x


shiftAll : Int -> List Int -> List Int
shiftAll k xs =
    myMap (\x -> x + k) xs


main =
    let
        _ =
            Debug.log "doubled" (myMap double [ 1, 2, 3 ])

        _ =
            Debug.log "squared" (myMap square [ 1, 2, 3 ])

        _ =
            Debug.log "shifted" (shiftAll 10 [ 1, 2, 3 ])
    in
    text "done"
