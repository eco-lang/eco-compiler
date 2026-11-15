module Graph exposing
    ( Graph, Spec, Role(..)
    , build, function
    , name, inputs, outputs
    )

{-| Before a computation written with tensors can be run as a graph, it has to be fixed: which
tensors it is given, which it gives back, what each of them is called, and whether it is well
formed. This module does that. `build` turns a function from tensors to tensors into a `Graph`, the
value that both ways of running a graph take: `Tensor.Eval` runs a graph in plain Elm, and
`Max` writes it out for MAX.

    Graph.build "step" (Sig.pair inputsA inputsB) outputsSig (\( a, b ) -> ...)

The inputs and outputs are described by signatures (`Signature`), each of which matches a
structured Elm value to an ordered list of tensors. `build` makes one input tensor for each slot of
the input signature, builds the function's argument from them, applies the function, and lists the
tensors of its result with the output signature. Each input and output then gets a _spec_: a name,
a dtype, a shape and a _role_, which says how it is passed between the graph and whatever runs it
(see `Role`). The names come from the slots' labels, as `Signature.label` describes. A slot that has
not been given a label carries `arg`, which stays `arg` in the input signature and becomes `result`
in the output signature. A label that several slots carry is then numbered across the whole
signature (`x0`, `x1` ..), so several unlabelled inputs are named `arg0`, `arg1` and so on, and
several unlabelled outputs, or an unlabelled output and one labelled `result`, are named `result0`,
`result1` and so on. A number whose name is one of the labels, or a name already given, is skipped,
so the labels `w`, `w`, `w1` give the names `w0`, `w2`, `w1`.

A tensor made from operands that do not fit carries a _build error_, as `Tensor` describes. `build`
returns either a `Graph` or the list of what it found wrong, which can include build errors, each
message starting with the graph's name. Some failures come only later. For example, `Max`
refuses some operations on a GPU, and `Tensor.Eval` refuses some index values when it runs the
graph, as `Tensor` describes.

Building a graph also translates it into the operations MAX reads, so that `Max` has only to
place them on a device and write them.


# Types

@docs Graph, Spec, Role


# Building

@docs build, function


# Inspecting

@docs name, inputs, outputs

-}

import Dict
import Signature exposing (Sig)
import Tensor exposing (Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Lower as Lower
import Tensor.Internal.Ir as Ir
import Tensor.Internal.Names exposing (names)
import Tensor.Internal.Prim as P
import Tensor.Internal.Shape as Shape
import Tensor.Internal.Types as I


{-| A computation that `build` accepted, with its inputs and outputs named and described: what
`Tensor.Eval` runs and what `Max` writes.

The only way to make one is `build`, or `function`, which calls it. Holding a `Graph` therefore
means that every check `build` makes has passed. What `build` does not check can still fail when
the graph is written for a device or run.

`==` and `Debug.toString` on a graph can go through the whole computation and visit a part once
for every use of it, which can take time exponential in the computation's depth. Comparing the bytes
`Max.toBytecode` writes for two graphs is far cheaper, but those bytes do not record the
roles of the inputs and outputs.

-}
type alias Graph =
    I.Graph


{-| How a graph's input or output is passed between the graph and whatever runs it.

A `Fed` input is given with every run, and a `Fed` output is handed back from every run.

`Resident` carries a _resident name_: the name of a buffer that whatever runs the graph keeps from
one run to the next, such as a model's parameters. An input with that role reads the buffer, and an
output with the same resident name replaces its contents after the run. The graph only records the
role; keeping the buffer is up to whatever runs it. `Tensor.Eval` takes and returns a resident
input or output under its resident name, and any other under its spec's name.

Every slot `Signature` makes is `Fed`. Resident roles come from the signatures that `Param`,
`Train` and `Infer` build.

-}
type Role
    = Fed
    | Resident String


{-| The description of one input or output of a graph: its name, its dtype, its shape and its role.

`dtype` is MAX's name for the element type: `"f16"`, `"bf16"`, `"f32"`, `"f64"`, `"si8"`, `"si32"`,
`"si64"`, `"ui8"`, `"ui64"` or `"bool"`, not the `I64` or `U8` of the dtype tags. `shape` lists the
size of each axis.

-}
type alias Spec =
    { name : String, dtype : String, shape : List Int, role : Role }


{-| Builds the graph `graphName`, whose inputs are the tensors `ins` describes and whose outputs are
those of `body`'s result, as `outs` lists them; or returns what it found wrong.

It refuses:

  - an input slot that declares no dtype or no shape, as `Signature.anyTensor` does, or one that
    declares a negative size;
  - two input slots, or two output slots, with one resident name (`Resident`); an input and an
    output may share one;
  - an input or output signature that does not give back what it builds (its round trip, as
    `Signature` describes it);
  - a result that `outs` lists as a different number of tensors from its slots;
  - the build errors of the tensors the outputs depend on, including those inside branches, loops
    and shared functions;
  - an output whose dtype or shape differs from what its slot declares, unless it has a build
    error;
  - an output that still has a broadcast axis, unless the output, or a tensor reached from it
    through its operands, their operands and so on, has a build error; the bodies of branches,
    loops and shared functions are not operands of the tensor that applies them;
  - a tensor that reads what the graph cannot supply there:
      - an input made for a graph of another name, or for another position, dtype or shape;
      - the argument of a function that a transform or `Tensor.Control` applies, outside that
        function;
      - inside a shared function, any input of the graph or argument of a function enclosing that
        shared function;
  - some cases of two different tensors sharing one key, reported as an internal error;
  - an operation written, while translating the graph for MAX, with an operand that names no
    value where it is read (`Tensor.Internal.Ir.unboundOperands`), reported as an internal
    error. This is looked for only when nothing else was found.

Every message starts with `graphName ++ ": "`, and a message found more than once is listed once.
A build error on a tensor that no output depends on is not reported. While any input slot lacks a
dtype or a shape or declares a negative size, only the first four kinds of error are looked for:
`body` is still applied, and its result's round trip and number of tensors are checked, but not the
build errors of its tensors or their dtypes and shapes.

Each input's dtype and shape are the ones its slot declares. Each output's are those of the tensor
`body` gave, which are those its slot declares where it declares them.

-}
build : String -> Sig a -> Sig b -> (a -> b) -> Result (List String) Graph
build graphName (I.SigBuilder ins) (I.SigBuilder outs) body =
    let
        inNames =
            names "arg" (List.map .label ins.slots)

        slotProblems =
            List.concat
                (List.map2
                    (\( i, n ) sl ->
                        case ( sl.dtype, sl.shape ) of
                            ( Just _, Just s ) ->
                                if List.any (\d -> d < 0) s then
                                    [ "input " ++ String.fromInt i ++ " (" ++ n ++ ") has a negative size: " ++ Shape.showShape s ]

                                else
                                    []

                            _ ->
                                [ "input " ++ String.fromInt i ++ " has no shape or dtype (Signature.anyTensor cannot describe a graph input)" ]
                    )
                    (List.indexedMap Tuple.pair inNames)
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

        undeclared =
            List.map3
                (\i ( n, e ) sl ->
                    if E.poisoned e || (Maybe.withDefault (E.dtype e) sl.dtype == E.dtype e && Maybe.withDefault (E.shape e) sl.shape == E.shape e) then
                        []

                    else
                        [ "output "
                            ++ String.fromInt i
                            ++ " ("
                            ++ n
                            ++ ") is "
                            ++ describe (E.dtype e) (E.shape e)
                            ++ ", its signature says "
                            ++ describe (Maybe.withDefault (E.dtype e) sl.dtype) (Maybe.withDefault (E.shape e) sl.shape)
                        ]
                )
                (List.range 0 (List.length outExprs - 1))
                namedOut
                outs.slots
                |> List.concat

        problems =
            List.map (\p -> graphName ++ ": " ++ p)
                (slotProblems
                    ++ sameResident "inputs" ins.slots
                    ++ sameResident "outputs" outs.slots
                    ++ inRoundTrip
                    ++ outRoundTrip
                    ++ arity
                )
                ++ (if List.isEmpty slotProblems then
                        Lower.problems graphName inExprs namedOut
                            ++ List.map (\p -> graphName ++ ": " ++ p) undeclared

                    else
                        []
                   )

        spec ( n, e ) sl =
            { name = n, dtype = P.dtName (E.dtype e), shape = E.shape e, role = sl.role }
    in
    if List.isEmpty problems then
        let
            ops =
                Lower.graph graphName namedIn namedOut
        in
        case Ir.unboundOperands ops of
            [] ->
                Ok
                    (I.Graph
                        { name = graphName
                        , inputs = List.map2 spec namedIn ins.slots
                        , outputs = List.map2 spec namedOut outs.slots
                        , ops = ops
                        , exprs = { inputs = inExprs, outputs = outExprs }
                        }
                    )

            ( opName, _ ) :: _ ->
                Err [ graphName ++ ": internal: the operation " ++ opName ++ " was written reading a value it cannot reach (please report)" ]

    else
        Err problems


{-| Returns a dtype and a shape as messages write them, such as `f32[2, 3]`.
-}
describe : P.DT -> List Int -> String
describe dt s =
    P.dtName dt ++ Shape.showShape s


{-| Returns an error for each pair of `slots` that share a resident name, naming the slots by their
positions as `what` (`"inputs"` or `"outputs"`) and the name. A name carried by several slots gives
one error for the first slot and each later one.
-}
sameResident : String -> List I.Slot -> List String
sameResident what slots =
    let
        step ( i, sl ) ( firsts, errs ) =
            case sl.role of
                I.Resident n ->
                    case Dict.get n firsts of
                        Just first ->
                            ( firsts, (what ++ " " ++ String.fromInt first ++ " and " ++ String.fromInt i ++ " have the same resident name " ++ n) :: errs )

                        Nothing ->
                            ( Dict.insert n i firsts, errs )

                I.Fed ->
                    ( firsts, errs )
    in
    List.foldl step ( Dict.empty, [] ) (List.indexedMap Tuple.pair slots) |> Tuple.second |> List.reverse


{-| Returns the error for the signature described by `what` when the keys `got` from its round trip
are not the keys `expected`, and nothing when they are. The message gives the first position where
the two differ or, when one list merely runs on past the other, the two lengths.
-}
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
                        " at position " ++ String.fromInt i ++ " (for example a record field's accessor in the wrong place, or a map whose two functions are not inverses)"

                    Nothing ->
                        " (it flattens " ++ String.fromInt (List.length got) ++ " tensors, not " ++ String.fromInt (List.length expected) ++ ")"
               )
        ]


{-| Builds, as `build` does, a graph whose one output is `body`'s result, named `result`. The
output's dtype and shape are those of the result.
-}
function : String -> Sig a -> (a -> Tensor k d s) -> Result (List String) Graph
function graphName ins body =
    build graphName ins (Signature.label "result" Signature.anyTensor) body


{-| Returns the name the graph was built with.
-}
name : Graph -> String
name (I.Graph g) =
    g.name


{-| Returns the public `Role` that matches a role the graph stores.
-}
publicRole : I.Role -> Role
publicRole r =
    case r of
        I.Fed ->
            Fed

        I.Resident n ->
            Resident n


{-| Returns the specs of the graph's inputs, in the order of the input signature's slots. The names
are made from the slots' labels, as the module docstring describes. A slot that has not been given
a label carries `arg`, so several such slots are named `arg0`, `arg1` and so on.
-}
inputs : Graph -> List Spec
inputs (I.Graph g) =
    List.map (\s -> { name = s.name, dtype = s.dtype, shape = s.shape, role = publicRole s.role }) g.inputs


{-| Returns the specs of the graph's outputs, in the order of the output signature's slots. The
names are made from the slots' labels, as the module docstring describes. A slot that has not been
given a label carries `arg`, which becomes `result`, so several such slots, or one such slot and one
labelled `result`, are named `result0`, `result1` and so on.
-}
outputs : Graph -> List Spec
outputs (I.Graph g) =
    List.map (\s -> { name = s.name, dtype = s.dtype, shape = s.shape, role = publicRole s.role }) g.outputs
