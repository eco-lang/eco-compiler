module DestructCaptureTest exposing (main)

{-| A tuple pattern in a `let` inside one function does not interfere with a
same-named variable in the function that calls it.

`swap` destructures its argument into `( x, y )`, and its caller `f` has its
own `x = a * 10` that it uses after the call. With `a = 5`, `mk 5` is `( 5, 6 )`,
so `swap` gives `( 6, 5 )` and `f` returns `6 + 50 = 56`. The pair comes from
`mk`, a recursive function, rather than from a tuple literal.

-}

import Html exposing (text)

-- CHECK: captured: 56


{-| Returns `( n, n + 1 )` for `n` up to 100, subtracting 100 first as often
as needed above that.
-}
mk : Int -> ( Int, Int )
mk n =
    if n > 100 then
        mk (n - 100)

    else
        ( n, n + 1 )


swap : ( Int, Int ) -> ( Int, Int )
swap pair =
    let
        ( x, y ) =
            pair
    in
    ( y, x )


f : Int -> Int
f a =
    let
        x =
            a * 10

        swapped =
            swap (mk a)
    in
    Tuple.first swapped + x


main =
    let
        _ =
            Debug.log "captured" (f 5)
    in
    text "done"
