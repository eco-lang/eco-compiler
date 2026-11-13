module Evg.Internal.Optimize exposing (leastSquares)

{-| A small nonlinear least-squares solver for `Evg.Drag.vary`.

`vary` wants the parameters that put the dragged element under the pointer.
That's a least-squares problem: the residuals are the element's offset from
the pointer in x and y, plus a penalty term for every violated constraint.
Levenberg–Marquardt suits it well: it behaves like Gauss–Newton (very few
steps) when the problem is nearly linear, which dragging usually is, and
falls back to cautious gradient steps when it isn't. Derivatives are
estimated by finite differences, since all we can do with a parameter set is
render it and look.

Each drag frame starts from the previous frame's answer, so typically only a
couple of iterations are needed.

-}


{-| Minimise the sum of squares of `residuals`, starting from `init`.
-}
leastSquares : { maxIterations : Int } -> (List Float -> List Float) -> List Float -> List Float
leastSquares { maxIterations } residuals init =
    case init of
        [] ->
            []

        _ ->
            let
                r0 =
                    residuals init
            in
            iterate residuals maxIterations 1.0e-3 init r0 (sumSquares r0)


sumSquares : List Float -> Float
sumSquares =
    List.foldl (\r acc -> acc + r * r) 0


iterate : (List Float -> List Float) -> Int -> Float -> List Float -> List Float -> Float -> List Float
iterate residuals remaining lambda x r cost =
    if remaining <= 0 || cost < 1.0e-8 || lambda > 1.0e10 || isNaN cost then
        x

    else
        let
            jacobianColumns =
                List.indexedMap
                    (\j xj ->
                        let
                            h =
                                1.0e-6 * max 1 (abs xj)

                            rj =
                                residuals
                                    (List.indexedMap
                                        (\k xk ->
                                            if k == j then
                                                xk + h

                                            else
                                                xk
                                        )
                                        x
                                    )
                        in
                        List.map2 (\a b -> (a - b) / h) rj r
                    )
                    x

            -- JᵀJ and Jᵀr, with J stored column by column.
            jtj =
                List.map (\ci -> List.map (\cj -> dotList ci cj) jacobianColumns) jacobianColumns

            jtr =
                List.map (\ci -> dotList ci r) jacobianColumns

            damped =
                List.indexedMap
                    (\i row ->
                        List.indexedMap
                            (\j v ->
                                if i == j then
                                    v + lambda * max v 1.0e-9

                                else
                                    v
                            )
                            row
                    )
                    jtj
        in
        case solve damped (List.map negate jtr) of
            Just step ->
                let
                    candidate =
                        List.map2 (+) x step

                    rc =
                        residuals candidate

                    costC =
                        sumSquares rc
                in
                if costC < cost then
                    let
                        stepSize =
                            List.foldl (\s acc -> max acc (abs s)) 0 step
                    in
                    if (cost - costC) < 1.0e-10 * cost || stepSize < 1.0e-9 then
                        candidate

                    else
                        iterate residuals (remaining - 1) (lambda / 3) candidate rc costC

                else
                    iterate residuals (remaining - 1) (lambda * 4) x r cost

            Nothing ->
                iterate residuals (remaining - 1) (lambda * 4) x r cost


dotList : List Float -> List Float -> Float
dotList a b =
    List.sum (List.map2 (*) a b)


{-| Solve `A x = b` by Gaussian elimination with partial pivoting. `Nothing`
for a singular system.
-}
solve : List (List Float) -> List Float -> Maybe (List Float)
solve matrix rhs =
    let
        augmented =
            List.map2 (\row b -> row ++ [ b ]) matrix rhs
    in
    eliminate augmented []
        |> Maybe.map backSubstitute


eliminate : List (List Float) -> List (List Float) -> Maybe (List (List Float))
eliminate rows done =
    case rows of
        [] ->
            Just (List.reverse done)

        _ ->
            let
                column =
                    List.length done

                pivotValue row =
                    abs (List.drop column row |> List.head |> Maybe.withDefault 0)

                pivot =
                    rows
                        |> List.foldl
                            (\row best ->
                                case best of
                                    Nothing ->
                                        Just row

                                    Just b ->
                                        if pivotValue row > pivotValue b then
                                            Just row

                                        else
                                            best
                            )
                            Nothing
            in
            case pivot of
                Just p ->
                    let
                        pv =
                            List.drop column p |> List.head |> Maybe.withDefault 0
                    in
                    if abs pv < 1.0e-14 then
                        Nothing

                    else
                        let
                            others =
                                removeFirst p rows

                            reduced =
                                List.map
                                    (\row ->
                                        let
                                            factor =
                                                (List.drop column row |> List.head |> Maybe.withDefault 0) / pv
                                        in
                                        List.map2 (\a b -> a - factor * b) row p
                                    )
                                    others
                        in
                        eliminate reduced (p :: done)

                Nothing ->
                    Nothing


removeFirst : a -> List a -> List a
removeFirst item list =
    -- IGNORE TCO: the systems solved here have a handful of rows
    case list of
        [] ->
            []

        x :: rest ->
            if x == item then
                rest

            else
                x :: removeFirst item rest


{-| Rows are in upper-triangular order (row `i` has its pivot in column `i`).
-}
backSubstitute : List (List Float) -> List Float
backSubstitute rows =
    let
        n =
            List.length rows
    in
    List.foldr
        (\( i, row ) solved ->
            let
                coeffs =
                    List.take n row

                b =
                    List.drop n row |> List.head |> Maybe.withDefault 0

                diag =
                    List.drop i coeffs |> List.head |> Maybe.withDefault 1

                known =
                    List.map2 (*) (List.drop (i + 1) coeffs) solved |> List.sum
            in
            ((b - known) / diag) :: solved
        )
        []
        (List.indexedMap Tuple.pair rows)
