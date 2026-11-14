module Infer exposing (step, initGraph)

{-| A model that is run again and again, such as one producing text a token at a time, reads the
same parameters on every run and carries a _state_ from one run to the next, such as key/value
caches or diffusion latents. Sending the parameters and the state with every run, and receiving the
state back, would move them for nothing. This module builds graphs that leave both where the graph
runs.

It does so with resident roles (see `Graph.Role`): an input with a resident name reads a buffer that
whatever runs the graph keeps between runs, and an output with the same resident name replaces that
buffer's contents after the run. A graph made by `step` reads the parameters and the state as
resident inputs, and takes the rest of its input as fed inputs, given with each run. It gives back
the new state as resident outputs under the state's own names, so the new state takes the old one's
place, and gives the rest of its output back as fed outputs. The graph has no output for the
parameters, and `step` refuses a state whose resident name is also a parameter's. A graph made by
`initGraph` has no inputs and writes given contents into the state's buffers.

The new state must have one tensor per state slot, and its tensors are matched to the state slots
in order; a new state with another number of tensors, or a tensor without the dtype and shape its
slot declares, is a build error. Every slot of the state signature and of the input signature must
declare a dtype and a shape, so `Signature.anyTensor` cannot be used there.

The parameters are resident under the names `Param.names` gives. Each state tensor is resident under
a name made from its slot's label: the labels of the state signature are numbered as `Graph`
describes, with `state` for a slot that has no label, and each is prefixed `infer.`. The state
names are distinct: a number whose name is one of the labels is skipped (the labels `w`, `w`, `w1`
give `infer.w0`, `infer.w2` and `infer.w1`). `step` and `initGraph` give one state signature the
same names.

A fed input whose slot declares the shape `[]` is declared with the shape `[1]`, and the function
given to `step` receives it reshaped to `[]`. The package assumes that MAX's C API takes no rank-0
inputs. Whatever runs the graph therefore gives such an input with the shape `[1]`. Parameter, state
and output slots are not widened in this way.

In this example, `Model.params` and `Model.step` stand for the user's own model, and the state is
two key/value caches (`Nn.KvCache`), whose slots are labelled `keys` and `values`. The state is
resident under `infer.keys0`, `infer.values0`, `infer.keys1` and `infer.values1`, and the rank-0
position is fed as `[1]`.

    decode =
        Infer.step "decode"
            Model.params
            (Sig.list 2 (KvCache.sig T.float32 kvHeads context headDim))
            (Sig.pair (Sig.i64 (T.r1 one)) (Sig.i64 T.scalar))
            (Sig.f32 (T.r2 one vocab))
            (\p caches ( token, position ) -> Model.step p caches token position)


# Graphs

@docs step, initGraph

-}

import Graph exposing (Graph)
import Param
import Signature exposing (Sig)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Io as Io
import Tensor.Internal.Names exposing (names)
import Tensor.Internal.ParamInit as ParamInit
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I


{-| Returns the resident name of each of the state slots `slots`, in order: the slots' labels
numbered by `Tensor.Internal.Names.names`, with `state` for the label `arg`, each prefixed `infer.`.
-}
stateNames : List I.Slot -> List String
stateNames slots =
    List.map (\n -> "infer." ++ n) (names "state" (List.map .label slots))


{-| Returns one error for each of `slots` that declares no dtype or no shape, naming the graph
`graphName`, and the slot by `what` and its position.
-}
shapeless : String -> String -> List I.Slot -> List String
shapeless graphName what slots =
    List.filterMap identity
        (List.indexedMap
            (\i sl ->
                if sl.dtype == Nothing || sl.shape == Nothing then
                    Just (graphName ++ ": Infer: " ++ what ++ " slot " ++ String.fromInt i ++ " has no dtype or shape (Signature.anyTensor cannot describe it)")

                else
                    Nothing
            )
            slots
        )


{-| Builds the graph `graphName`, which applies `f` to the parameters the spec describes, the state
`Sig state` describes and the input `Sig input` describes, and gives back `f`'s new state and its
output as `Sig output` lists it; or returns what it found wrong.

The graph's inputs are, in order: one resident input for each tensor field of the spec, under its
name from `Param.names`; one resident input for each state slot, under the names the module
docstring describes; and one fed input for each input slot, a slot declaring `[]` being declared
`[1]` and reshaped to `[]` before `f` receives it. Its outputs are the new state's tensors, one per
state slot, resident under the state's names, followed by the output's tensors, which are fed. The
parameters are not outputs.

The new state must have as many tensors as the state signature has slots; otherwise the graph is
refused, every output that has not already failed carrying a build error that gives both counts.
Each tensor of the new state must have the dtype and shape of its state slot; one that differs is a
build error naming the state and both dtypes and shapes. A new state tensor that carries a build
error, or is built on one, keeps that error and gets none from this check. A `Signature.list`
state always gives as many tensors as it has slots, failing them instead when the list has
another length (see `Signature.list`); a count that differs comes from other signatures, such as
`Param.sig` over a `Param.list` of another length.

Before the graph is built, `step` refuses a state or input slot that declares no dtype or no shape,
with errors that name the slot's position, and a state whose resident name is also a parameter's
(see `Param.names`), with an error naming it; each error begins with the graph's name. Otherwise
the graph is built by `Graph.build`, and its errors are returned. `Graph.build`'s round-trip check
covers the parameter spec, `Sig state` and `Sig input` on the graph's inputs, but not `Sig output`,
nor `Sig state` on the new state. Its count of output tensors covers the new state and the output
together.

-}
step : String -> Param.Spec r -> Sig state -> Sig input -> Sig output -> (r -> state -> input -> ( state, output )) -> Result (List String) Graph
step graphName (I.ParamBuilder ps) (I.SigBuilder ss) (I.SigBuilder is) (I.SigBuilder os) f =
    let
        paramNames =
            ParamInit.residentNames ps.fields

        sNames =
            stateNames ss.slots

        paramSlots =
            List.map2 (\n fl -> { label = n, dtype = Just fl.dtype, shape = Just fl.shape, role = I.Resident n }) paramNames ps.fields

        stateSlots =
            List.map2 (\n sl -> { sl | label = n, role = I.Resident n }) sNames ss.slots

        inputSlots =
            List.map (\sl -> Io.widenSlot { sl | role = I.Fed }) is.slots

        inSig =
            I.SigBuilder
                { slots = paramSlots ++ stateSlots ++ inputSlots
                , build =
                    \es ->
                        let
                            ( params, r1 ) =
                                ps.build es

                            ( state, r2 ) =
                                ss.build r1

                            nIn =
                                List.length is.slots

                            narrowed =
                                List.map2 Io.narrowIn is.slots (List.take nIn r2)

                            ( input, _ ) =
                                is.build narrowed
                        in
                        ( { params = params, state = state, input = input }, List.drop nIn r2 )
                , flatten =
                    \i -> ps.flatten i.params ++ ss.flatten i.state ++ List.map Io.unnarrow (is.flatten i.input)
                }

        outSig =
            I.SigBuilder
                { slots =
                    List.map (\n -> { label = n, dtype = Nothing, shape = Nothing, role = I.Resident n }) sNames
                        ++ List.map (\sl -> { sl | role = I.Fed }) os.slots
                , build = \es -> ( es, [] )
                , flatten = identity
                }

        body i =
            let
                ( newState, output ) =
                    f i.params i.state i.input
            in
            checkState sNames ss.slots (ss.flatten newState) (os.flatten output)

        clashes =
            List.filterMap
                (\n ->
                    if List.member n paramNames then
                        Just (graphName ++ ": Infer: the state's resident name " ++ n ++ " is also a parameter's")

                    else
                        Nothing
                )
                sNames

        problems =
            shapeless graphName "state" ss.slots ++ shapeless graphName "input" is.slots ++ clashes
    in
    if List.isEmpty problems then
        Graph.build graphName inSig outSig body

    else
        Err problems


{-| Returns the new state's tensors `state`, each checked against its slot by `keepShape`, followed
by the output's tensors `output`. When `state` has another number of tensors than there are
`slots`, it returns every tensor of `state` and `output` failed with an error giving both counts,
except that a tensor that has already failed keeps its own error (`Tensor.Internal.Expr.failWith`).
-}
checkState : List String -> List I.Slot -> List Expr -> List Expr -> List Expr
checkState sNames slots state output =
    let
        got =
            List.length state

        want =
            List.length slots
    in
    if got /= want then
        List.map (E.failWith ("Infer: the new state has " ++ tensors got ++ ", but the state signature has " ++ String.fromInt want ++ " slots")) (state ++ output)

    else
        List.map3 keepShape sNames slots state ++ output


{-| Returns `n` followed by "tensor" or "tensors", as the count needs.
-}
tensors : Int -> String
tensors n =
    String.fromInt n
        ++ (if n == 1 then
                " tensor"

            else
                " tensors"
           )


{-| Returns `e`, the new value of the state named `n`, when it has the dtype and shape that its slot
`sl` declares, and otherwise `e` failed with an error naming `n` and both dtypes and shapes.

An `e` that has already failed keeps its own error (`Tensor.Internal.Expr.failWith` records nothing
on it), even when its guessed dtype and shape differ from the slot's.

-}
keepShape : String -> I.Slot -> Expr -> Expr
keepShape n sl e =
    if Just (E.dtype e) == sl.dtype && Just (E.shape e) == sl.shape then
        e

    else
        E.failWith ("Infer: state " ++ n ++ " changes from " ++ describeSlot sl ++ " to " ++ describe (E.dtype e) (E.shape e)) e


{-| Returns the dtype and shape `sl` declares, written as `describe` writes them, or "an unknown
shape" when it lacks either. `step` and `initGraph` refuse such slots before they are checked, so
the second case does not arise from them.
-}
describeSlot : I.Slot -> String
describeSlot sl =
    case ( sl.dtype, sl.shape ) of
        ( Just dt, Just s ) ->
            describe dt s

        _ ->
            "an unknown shape"


{-| Returns the dtype `dt` by its MAX name followed by `shape` in brackets, as in `f32[2,3]`.
-}
describe : P.DT -> List Int -> String
describe dt shape =
    P.dtName dt ++ "[" ++ String.join "," (List.map String.fromInt shape) ++ "]"


{-| Builds the graph `graphName`, which has no inputs and whose outputs are the tensors of `value`,
resident under the names `step` gives the state `Sig state` describes; or returns what it found
wrong. Running it fills, where the graph runs, the buffers from which a graph made by `step` with
the same state signature reads its state.

The graph has no inputs, so a tensor of `value` that reads another graph's input is refused, as
`Graph.build` describes.

The tensors of `value` are checked against the state slots as `step` checks a new state: there
must be one per slot, and each must have its slot's dtype and shape, with the same caveats. A state
slot that declares no dtype or no shape is refused before the graph is built, with an error that
begins with the graph's name.

-}
initGraph : String -> Sig state -> state -> Result (List String) Graph
initGraph graphName (I.SigBuilder ss) value =
    let
        sNames =
            stateNames ss.slots

        outSig =
            I.SigBuilder
                { slots = List.map2 (\n sl -> { sl | label = n, role = I.Resident n }) sNames ss.slots
                , build = \es -> ( es, [] )
                , flatten = identity
                }

        body _ =
            checkState sNames ss.slots (ss.flatten value) []

        problems =
            shapeless graphName "state" ss.slots
    in
    if List.isEmpty problems then
        Graph.build graphName Signature.unit outSig body

    else
        Err problems
