module LambdaBoundaryCaptureTest exposing (main)

{-| Checks that a lambda nested inside `case` branches refers to the variable it names, not to another binding that appears around it.

`f False True 5` takes the `False` branch, binding `b` to 5, then calls `apply`,
which passes 1 and 100 to a lambda that ignores its first argument and returns
`\a -> a + b` from an inner `case`. The result is `100 + 5`, which is 105; a
program that confused `b` with the lambda's parameter `a` would print 200.

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
