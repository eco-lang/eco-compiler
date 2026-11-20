module SretCtorTest exposing (main)

{-| Functions returning a value of a custom type with one constructor of two or
three fields, which `sretCtors` (plans/constructor-representation-levels.md S1)
returns through a `$sret` worker as separate results, the way `sretResults`
already returns tuples: the result taken apart by a `case` and by a `let`
destructuring, a result built in several branches, a tail-recursive function,
a Float field (an unboxed slot), a Bool field, a result that escapes into a
list (the shim rebuilds the value), and a function whose result spine calls
another such function.

-}

-- CHECK: case: 7
-- CHECK: let: "a3"
-- CHECK: branches: [10,-1]
-- CHECK: loop: 55
-- CHECK: float: 3.75
-- CHECK: bool: [True,False]
-- CHECK: escape: [Ok2 1 "x",Ok2 2 "y"]
-- CHECK: chain: 12

import Html exposing (text)


type Ok2
    = Ok2 Int String


type Vec
    = Vec Float Float Float


type Flag
    = Flag Bool Int


step : Int -> String -> Ok2
step n s =
    Ok2 (n + 1) (s ++ String.fromInt n)


pick : Int -> Ok2
pick n =
    if n > 0 then
        Ok2 (n * 10) "pos"

    else
        Ok2 -1 "neg"


sumTo : Int -> Int -> Ok2
sumTo acc n =
    if n == 0 then
        Ok2 acc "done"

    else
        sumTo (acc + n) (n - 1)


scale : Float -> Vec
scale k =
    Vec (k * 1.5) k 0


flag : Int -> Flag
flag n =
    Flag (n > 0) n


chained : Int -> Ok2
chained n =
    let
        (Ok2 m _) =
            step n ""
    in
    pick m |> (\(Ok2 v s) -> Ok2 (v // 5 + 2) s)


main =
    let
        _ =
            Debug.log "case"
                (case step 6 "" of
                    Ok2 n _ ->
                        n
                )

        (Ok2 _ s) =
            step 3 "a"

        _ =
            Debug.log "let" s

        _ =
            Debug.log "branches" (List.map (\n -> case pick n of Ok2 v _ -> v) [ 1, -5 ])

        _ =
            Debug.log "loop" (case sumTo 0 10 of Ok2 v _ -> v)

        (Vec x y _) =
            scale 1.5

        _ =
            Debug.log "float" (x + y)

        _ =
            Debug.log "bool" (List.map (\n -> case flag n of Flag b _ -> b) [ 1, -1 ])

        _ =
            Debug.log "escape" [ Ok2 1 "x", step 1 "y" |> (\(Ok2 _ t) -> Ok2 2 (String.left 1 t)) ]

        _ =
            Debug.log "chain" (case chained 4 of Ok2 v _ -> v)
    in
    text "done"
