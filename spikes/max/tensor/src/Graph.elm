module Graph exposing (Graph, Spec, Role(..), build, function, name, inputs, outputs, toBytecode, toGenericText)

{-| A whole graph, lowered and checked: what the host compiles and runs.

    Graph.build "step" (Sig.pair inputsA inputsB) outputsSig (\( a, b ) -> ...)

`build` applies the function to the inputs the first signature declares, flattens its result with
the second, checks everything that can be checked before MAX sees the graph, and writes it as MAX's
IR. It returns every error at once.

-}

import Bytes exposing (Bytes)
import Signature exposing (Sig)
import Tensor exposing (Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Names exposing (names)
import Tensor.Internal.Lower as Lower
import Tensor.Internal.MlirBc as Bc
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I


type alias Graph =
    I.Graph


{-| `Resident name`: a host buffer that outlives one run (parameters, optimizer state); an output
with the same resident name replaces it after the run. `Fed`: sent with every run.
-}
type Role
    = Fed
    | Resident String


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


inputs : Graph -> List Spec
inputs (I.Graph g) =
    List.map (\s -> { name = s.name, dtype = s.dtype, shape = s.shape, role = publicRole s.role }) g.inputs


outputs : Graph -> List Spec
outputs (I.Graph g) =
    List.map (\s -> { name = s.name, dtype = s.dtype, shape = s.shape, role = publicRole s.role }) g.outputs


{-| MLIR bytecode, as MLIR 24 writes it (`Tensor.Internal.MlirBc`).
-}
toBytecode : Graph -> Bytes
toBytecode (I.Graph g) =
    Bc.encode g.ops


toGenericText : Graph -> String
toGenericText (I.Graph g) =
    Bc.printGeneric g.ops
