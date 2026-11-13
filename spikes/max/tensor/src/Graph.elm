module Graph exposing
    ( Graph, Spec, Role(..)
    , build, function
    , name, inputs, outputs
    )

{-| A whole graph, built and checked: what `Tensor.Eval` runs in Elm, and what `Graph.Max` writes
for MAX.

    Graph.build "step" (Sig.pair inputsA inputsB) outputsSig (\( a, b ) -> ...)

`build` applies the function to the inputs the first signature declares, flattens its result with
the second, and checks everything that can be checked before the graph runs. It returns every error
at once.


# Types

@docs Graph, Spec, Role


# Building

@docs build, function


# Inspecting

@docs name, inputs, outputs

-}

import Signature exposing (Sig)
import Tensor exposing (Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Lower as Lower
import Tensor.Internal.Names exposing (names)
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I


{-| A graph that `build` accepted: its name, its inputs and outputs, its ops, and the expressions it
was built from (so `Tensor.Eval` can run it in Elm).

Because it keeps those expressions, `==` and `Debug.toString` on a `Graph` walk them as a tree,
which can take time exponential in the graph's depth: compare `Graph.Max.toBytecode` instead. A `Graph` kept
in a model keeps its expressions alive.

-}
type alias Graph =
    I.Graph


{-| `Resident name`: a buffer that outlives one run (parameters, optimizer state), kept by whatever
runs the graph; an output with the same resident name replaces it after the run. `Fed`: given with
every run.
-}
type Role
    = Fed
    | Resident String


{-| One input or output: its name, dtype (`"f32"`, `"bf16"` ..), shape and role.
-}
type alias Spec =
    { name : String, dtype : String, shape : List Int, role : Role }


{-| The graph `graphName`: `body` applied to the inputs `ins` declares, its result flattened by
`outs` into the outputs. Refused, with every error, when anything is wrong.
-}
build : String -> Sig a -> Sig b -> (a -> b) -> Result (List String) Graph
build graphName (I.SigBuilder ins) (I.SigBuilder outs) body =
    let
        inNames =
            names "arg" (List.map .label ins.slots)

        slotProblems =
            List.filterMap identity
                (List.indexedMap
                    (\i sl ->
                        case ( sl.dtype, sl.shape ) of
                            ( Just _, Just _ ) ->
                                Nothing

                            _ ->
                                Just ("input " ++ String.fromInt i ++ " has no shape (Signature.anyTensor cannot describe a graph input)")
                    )
                    ins.slots
                )

        inExprs =
            List.indexedMap
                (\i sl -> E.input graphName i (Maybe.withDefault P.F32 sl.dtype) (Maybe.withDefault [] sl.shape))
                ins.slots

        ( value, _ ) =
            ins.build inExprs

        inRoundTrip =
            roundTrip "the input signature" (List.map E.key inExprs) (List.map E.key (ins.flatten value))

        result =
            body value

        outExprs =
            outs.flatten result

        outRoundTrip =
            roundTrip "the output signature" (List.map E.key outExprs) (List.map E.key (outs.flatten (Tuple.first (outs.build outExprs))))

        outNames =
            names "result" (List.map .label outs.slots)

        arity =
            if List.length outNames /= List.length outExprs then
                [ "the output signature describes " ++ String.fromInt (List.length outNames) ++ " tensors, the result has " ++ String.fromInt (List.length outExprs) ]

            else
                []

        namedIn =
            List.map2 Tuple.pair inNames inExprs

        namedOut =
            List.map2 Tuple.pair outNames outExprs

        problems =
            List.map (\p -> graphName ++ ": " ++ p) (slotProblems ++ inRoundTrip ++ outRoundTrip ++ arity)
                ++ (if List.isEmpty slotProblems then
                        Lower.problems graphName inExprs namedOut

                    else
                        []
                   )

        spec ( n, e ) sl =
            { name = n, dtype = P.dtName (E.dtype e), shape = E.shape e, role = sl.role }
    in
    if List.isEmpty problems then
        Ok
            (I.Graph
                { name = graphName
                , inputs = List.map2 spec namedIn ins.slots
                , outputs = List.map2 spec namedOut outs.slots
                , ops = Lower.graph graphName namedIn namedOut
                , exprs = { inputs = inExprs, outputs = outExprs }
                }
            )

    else
        Err problems


roundTrip : String -> List ( Int, Int ) -> List ( Int, Int ) -> List String
roundTrip what expected got =
    if expected == got then
        []

    else
        let
            firstBad =
                List.map2 (/=) expected got |> List.indexedMap Tuple.pair |> List.filter Tuple.second |> List.head |> Maybe.map Tuple.first
        in
        [ what
            ++ " does not give back what it builds"
            ++ (case firstBad of
                    Just i ->
                        " at position " ++ String.fromInt i ++ " (a record field's accessor in the wrong place, or a map whose two functions are not inverses)"

                    Nothing ->
                        " (it flattens " ++ String.fromInt (List.length got) ++ " tensors, not " ++ String.fromInt (List.length expected) ++ ")"
               )
        ]


{-| A graph with one output, `result`.
-}
function : String -> Sig a -> (a -> Tensor k d s) -> Result (List String) Graph
function graphName ins body =
    build graphName ins (Signature.label "result" Signature.anyTensor) body


{-| The name the graph was built with.
-}
name : Graph -> String
name (I.Graph g) =
    g.name


publicRole : I.Role -> Role
publicRole r =
    case r of
        I.Fed ->
            Fed

        I.Resident n ->
            Resident n


{-| The graph's inputs, in order, named by the input signature's labels (`Signature.label`).
-}
inputs : Graph -> List Spec
inputs (I.Graph g) =
    List.map (\s -> { name = s.name, dtype = s.dtype, shape = s.shape, role = publicRole s.role }) g.inputs


{-| The graph's outputs, in order, named by the output signature's labels (`result`, or
`result0` .., when unlabelled).
-}
outputs : Graph -> List Spec
outputs (I.Graph g) =
    List.map (\s -> { name = s.name, dtype = s.dtype, shape = s.shape, role = publicRole s.role }) g.outputs
