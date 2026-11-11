module Tensor.Check exposing (allClose)

{-| Numerical comparison of host results, as NumPy's `allclose`: |a - e| <= atol + rtol |e|.
-}


allClose : { rtol : Float, atol : Float } -> List Float -> List Float -> Result String ()
allClose tol actual expected =
    if List.length actual /= List.length expected then
        Err ("lengths differ: " ++ String.fromInt (List.length actual) ++ " and " ++ String.fromInt (List.length expected))

    else
        let
            bad =
                List.indexedMap Tuple.pair (List.map2 Tuple.pair actual expected)
                    |> List.filter (\( _, ( a, e ) ) -> isNaN a || isNaN e || abs (a - e) > tol.atol + tol.rtol * abs e)
        in
        case bad of
            [] ->
                Ok ()

            ( i, ( a, e ) ) :: _ ->
                Err (String.fromInt (List.length bad) ++ " elements differ; first at " ++ String.fromInt i ++ ": " ++ String.fromFloat a ++ " vs " ++ String.fromFloat e)
