module LambdaCaseBoundaryTest exposing (main)

{-| Checks functions whose body is a `case` on the first argument that returns a two-parameter lambda in each branch.

  - `add`, `sub` and `mul` call `getOp` with all three arguments, once per
    `Op` constructor.
  - `nested_add` and `nested_sub` call `nestedCaseOp`, whose first branch's
    lambda contains another `case` on its own parameter; with `a` = 1 that
    inner `case` takes its default branch.
  - `partial_add` applies `getOp Add` to one more argument, binds the
    resulting function in a `let`, and applies it to the last.

-}

-- CHECK: add: 7
-- CHECK: sub: 3
-- CHECK: mul: 20
-- CHECK: nested_add: 11
-- CHECK: nested_sub: 3
-- CHECK: partial_add: 15

import Html exposing (text)


type Op
    = Add
    | Sub
    | Mul


{-| Returns the arithmetic operation named by `op`, as a lambda chosen by a
`case`.
-}
getOp : Op -> Int -> Int -> Int
getOp op =
    case op of
        Add ->
            \a b -> a + b

        Sub ->
            \a b -> a - b

        Mul ->
            \a b -> a * b


{-| Returns `b` when `x` and `a` are both 0, `a + b` when only `x` is 0, and
`a - b` otherwise.
-}
nestedCaseOp : Int -> Int -> Int -> Int
nestedCaseOp x =
    case x of
        0 ->
            \a b ->
                case a of
                    0 ->
                        b

                    _ ->
                        a + b

        _ ->
            \a b -> a - b


{-| Applies `f` to `x` and 10. Nothing in `main` calls it.
-}
applyPartial : (Int -> Int -> Int) -> Int -> Int
applyPartial f x =
    f x 10


main =
    let
        _ = Debug.log "add" (getOp Add 3 4)
        _ = Debug.log "sub" (getOp Sub 5 2)
        _ = Debug.log "mul" (getOp Mul 4 5)

        _ = Debug.log "nested_add" (nestedCaseOp 0 1 10)
        _ = Debug.log "nested_sub" (nestedCaseOp 1 5 2)

        addFive = getOp Add 5
        _ = Debug.log "partial_add" (addFive 10)
    in
    text "done"
