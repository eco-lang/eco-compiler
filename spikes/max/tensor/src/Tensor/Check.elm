module Tensor.Check exposing (allClose)

{-| Floating-point results are rounded, so a computed value can differ from the value expected of
it in its last bits, and comparing the two needs a tolerance. This module compares two lists of
floats element by element under a tolerance, and describes a failure in a readable message.

The comparison is not symmetric. One list holds the _actual_ values and the other the _expected_
ones, and the expected value is the reference that the relative tolerance `rtol` scales with;
`atol` is an absolute tolerance. An actual value `a` is _close_ to a finite expected value `e`
unless `a` is NaN or

    abs (a - e) > atol + rtol * abs e

and to an infinite `e` only when it equals `e`. So a NaN is never close, not even to another NaN,
and an infinite `a` is close only to the same infinity. Both tolerances must be 0 or more.


# Comparing

@docs allClose

-}


{-| `allClose tolerances actual expected` checks that the two lists have the same length and that
each element of `actual` is close to the element of `expected` at the same index.

An `Err` says that a tolerance is negative or NaN, or gives both lengths when they differ.
Otherwise it says how many pairs are not close, as in `"1 element differs"` or
`"2 elements differ"`, and shows the first of them: its index, counting from 0, and its actual and
expected values.

-}
allClose : { rtol : Float, atol : Float } -> List Float -> List Float -> Result String ()
allClose tol actual expected =
    if not (tol.rtol >= 0 && tol.atol >= 0) || isNaN tol.rtol || isNaN tol.atol then
        Err ("tolerances must be 0 or more: rtol " ++ String.fromFloat tol.rtol ++ ", atol " ++ String.fromFloat tol.atol)

    else if List.length actual /= List.length expected then
        Err ("lengths differ: " ++ String.fromInt (List.length actual) ++ " and " ++ String.fromInt (List.length expected))

    else
        let
            bad =
                List.indexedMap Tuple.pair (List.map2 Tuple.pair actual expected)
                    |> List.filter (\( _, ( a, e ) ) -> not (close tol a e))
        in
        case bad of
            [] ->
                Ok ()

            ( i, ( a, e ) ) :: _ ->
                Err
                    (String.fromInt (List.length bad)
                        ++ (if List.length bad == 1 then
                                " element differs"

                            else
                                " elements differ"
                           )
                        ++ "; first at "
                        ++ String.fromInt i
                        ++ ": "
                        ++ String.fromFloat a
                        ++ " vs "
                        ++ String.fromFloat e
                    )


{-| Returns whether the actual value `a` is close to the expected value `e`, as the module
docstring defines it, for tolerances that are 0 or more.

Under JavaScript Elm's `>` is true when either side is NaN, so NaN is tested for before the
difference is compared.

-}
close : { rtol : Float, atol : Float } -> Float -> Float -> Bool
close tol a e =
    if isNaN a || isNaN e then
        False

    else if isInfinite e then
        a == e

    else
        not (abs (a - e) > tol.atol + tol.rtol * abs e)
