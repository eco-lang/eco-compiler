module GradSolve exposing (Compiled, Problem, Solution, compile, evaluate, solve)

{-| Levenberg–Marquardt with exact Jacobians from the tensor package.

A `Problem` is a graph built and prepared once (`compile`, at top level): its first input is the
parameter vector (f64, P values), its other inputs are fixed for the problem (`fixed`), and its two
outputs are the model's point (k values) and the Jacobian of that point with respect to the
parameters (k × P). Each iteration runs it once with `Tensor.Eval`, then takes the damped
least-squares step

    δ = Jᵀ (J Jᵀ + λ I)⁻¹ (target − point)      when k ≤ P
    δ = (Jᵀ J + λ I)⁻¹ Jᵀ (target − point)      when k > P

(the same step, solved in the smaller dimension): with more parameters than outputs it is the
minimum-norm step, which suits redundant problems (a 12-joint arm reaching a point); with more
outputs it is Levenberg–Marquardt's least-squares step (a lens focusing many rays). The result is
clamped to the box `lower`/`upper`. λ adapts: it shrinks after a step that brings the point closer
and grows (the step is retried) after one that does not.

-}

import Dict exposing (Dict)
import Graph exposing (Graph)
import Tensor.Eval as Eval


{-| A problem's graph, prepared to run: build it once, at top level.
-}
type alias Compiled =
    Result String { prepared : Eval.Prepared, params : String, point : String, jacobian : String }


compile : Result (List String) Graph -> Compiled
compile graph =
    case graph of
        Err es ->
            Err (String.join "; " es)

        Ok g ->
            case ( Graph.inputs g, Graph.outputs g ) of
                ( first :: _, [ point, jac ] ) ->
                    Ok { prepared = Eval.prepare g, params = first.name, point = point.name, jacobian = jac.name }

                _ ->
                    Err "the graph must take the parameters first, and return a point and its Jacobian"


type alias Problem =
    { compiled : Compiled
    , fixed : Dict String Eval.Value
    , lower : List Float
    , upper : List Float
    }


type alias Solution =
    { params : List Float
    , error : Float
    , evaluations : Int
    }


{-| The model's point and Jacobian at these parameters.
-}
evaluate : Problem -> List Float -> Result String ( List Float, List (List Float) )
evaluate problem params =
    case problem.compiled of
        Err e ->
            Err e

        Ok c ->
            let
                p =
                    List.length params
            in
            case Eval.runPrepared c.prepared (Dict.insert c.params { dtype = "f64", shape = [ p ], data = Eval.Floats params } problem.fixed) of
                Err es ->
                    Err (String.join "; " es)

                Ok outs ->
                    case ( Dict.get c.point outs, Dict.get c.jacobian outs ) of
                        ( Just point, Just jac ) ->
                            Ok ( floats point, rows p (floats jac) )

                        _ ->
                            Err "the graph must return a point and its Jacobian"


floats : Eval.Value -> List Float
floats v =
    case v.data of
        Eval.Floats l ->
            l

        _ ->
            []


rows : Int -> List Float -> List (List Float)
rows n l =
    if List.isEmpty l || n <= 0 then
        []

    else
        List.take n l :: rows n (List.drop n l)


{-| Move the parameters so the model's point reaches `target`, starting from `start`: at most
`maxEvaluations` runs of the graph, stopping within `tolerance` of the target.
-}
solve : { maxEvaluations : Int, tolerance : Float } -> Problem -> List Float -> List Float -> Solution
solve cfg problem target start =
    let
        clamp x =
            List.map3 (\v lo hi -> Basics.clamp lo hi v) x problem.lower problem.upper

        x0 =
            clamp start

        go evals lambda x ( point, jac ) err =
            if err <= cfg.tolerance || evals >= cfg.maxEvaluations then
                { params = x, error = err, evaluations = evals }

            else
                let
                    e =
                        List.map2 (-) target point

                    damped rs =
                        List.map (\ri -> List.map (\rj -> dot ri rj) rs) rs
                            |> List.indexedMap
                                (\i row ->
                                    List.indexedMap
                                        (\j v ->
                                            if i == j then
                                                v + lambda

                                            else
                                                v
                                        )
                                        row
                                )

                    delta =
                        if List.length jac <= List.length x then
                            -- Jᵀ (J Jᵀ + λI)⁻¹ e
                            List.foldl (\( yi, ri ) acc -> List.map2 (\d r -> d + yi * r) acc ri) (List.map (\_ -> 0) x) (List.map2 Tuple.pair (solveLinear (damped jac) e) jac)

                        else
                            -- (Jᵀ J + λI)⁻¹ Jᵀ e, with the columns of J as rows
                            let
                                cols =
                                    transpose jac
                            in
                            solveLinear (damped cols) (List.map (\c -> dot c e) cols)

                    x1 =
                        clamp (List.map2 (+) x delta)
                in
                case evaluate problem x1 of
                    Ok ( p1, j1 ) ->
                        let
                            err1 =
                                distance target p1
                        in
                        if err1 < err then
                            go (evals + 1) (lambda / 3) x1 ( p1, j1 ) err1

                        else
                            go (evals + 1) (lambda * 4) x ( point, jac ) err

                    Err _ ->
                        { params = x, error = err, evaluations = evals + 1 }
    in
    case evaluate problem x0 of
        Ok ( p0, j0 ) ->
            let
                scale =
                    List.sum (List.map (\r -> dot r r) j0)
            in
            go 1 (1.0e-3 * scale + 1.0e-9) x0 ( p0, j0 ) (distance target p0)

        Err _ ->
            { params = x0, error = 1 / 0, evaluations = 1 }


dot : List Float -> List Float -> Float
dot a b =
    List.sum (List.map2 (*) a b)


distance : List Float -> List Float -> Float
distance a b =
    sqrt (List.sum (List.map2 (\u v -> (u - v) ^ 2) a b))


transpose : List (List Float) -> List (List Float)
transpose m =
    case m of
        [] ->
            []

        first :: _ ->
            List.indexedMap (\j _ -> List.filterMap (\row -> List.drop j row |> List.head) m) first


{-| A x = b for a small symmetric positive-definite A, by Gaussian elimination.
-}
solveLinear : List (List Float) -> List Float -> List Float
solveLinear a b =
    case ( a, b ) of
        ( [ [ a11 ] ], [ b1 ] ) ->
            [ b1 / a11 ]

        ( [ [ a11, a12 ], [ a21, a22 ] ], [ b1, b2 ] ) ->
            let
                det =
                    a11 * a22 - a12 * a21
            in
            [ (a22 * b1 - a12 * b2) / det, (a11 * b2 - a21 * b1) / det ]

        _ ->
            eliminate (List.map2 (\row bi -> row ++ [ bi ]) a b)


eliminate : List (List Float) -> List Float
eliminate rowsIn =
    case rowsIn of
        [] ->
            []

        pivot :: rest ->
            case pivot of
                p :: pRest ->
                    let
                        reduced =
                            List.map
                                (\row ->
                                    case row of
                                        r :: rRest ->
                                            List.map2 (\x y -> x - (r / p) * y) rRest pRest

                                        [] ->
                                            []
                                )
                                rest

                        tailSolution =
                            eliminate reduced

                        coeffs =
                            List.take (List.length pRest - 1) pRest

                        rhs =
                            List.drop (List.length pRest - 1) pRest |> List.head |> Maybe.withDefault 0
                    in
                    ((rhs - dot coeffs tailSolution) / p) :: tailSolution

                [] ->
                    []
