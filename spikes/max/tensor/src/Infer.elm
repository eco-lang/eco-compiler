module Infer exposing (step, initGraph)

{-| Graphs that run a model, `Train`'s counterpart: the parameters and a state (KV caches, diffusion
latents) are **resident**, host buffers that outlive a run, and the new state replaces the old after
each run; only the inputs cross from Elm and only the outputs come back.

    decode =
        Infer.step "decode" Model.params (Sig.list 2 (KvCache.sig T.float32 kvHeads context headDim))
            (Sig.pair (Sig.i64 (T.r1 one)) (Sig.i64 T.scalar))
            (Sig.f32 (T.r2 one vocab))
            (\p caches ( token, position ) -> Model.step p caches token position)

The parameters are resident under `Param.names`; the state under its signature's labels prefixed
`infer.` (a label used once is the name, repeated ones are numbered: `infer.keys0` ..). Rank-0
inputs travel as `[1]`, which MAX's C API needs.

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


type alias Inputs r state input =
    { params : r, state : state, input : input }


stateNames : List I.Slot -> List String
stateNames slots =
    List.map (\n -> "infer." ++ n) (names "state" (List.map .label slots))


{-| A state slot without a dtype or shape cannot be a resident buffer.
-}
shapeless : String -> List I.Slot -> List String
shapeless what slots =
    List.filterMap identity
        (List.indexedMap
            (\i sl ->
                if sl.dtype == Nothing || sl.shape == Nothing then
                    Just ("Infer: " ++ what ++ " slot " ++ String.fromInt i ++ " has no shape (Signature.anyTensor cannot describe it)")

                else
                    Nothing
            )
            slots
        )


{-| The graph `name`: `f` applied to the resident parameters, the resident state and the fed input;
it returns the new state (replacing the old) and the output (sent back).
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

                checked =
                    List.map3 keepShape sNames ss.slots (ss.flatten newState)
            in
            checked ++ os.flatten output

        problems =
            shapeless "state" ss.slots ++ shapeless "input" is.slots
    in
    if List.isEmpty problems then
        Graph.build graphName inSig outSig body

    else
        Err problems


{-| The new state must have the old state's dtype and shape: it replaces that buffer.
-}
keepShape : String -> I.Slot -> Expr -> Expr
keepShape n sl e =
    if Just (E.dtype e) == sl.dtype && Just (E.shape e) == sl.shape then
        e

    else
        E.failWith ("Infer: state " ++ n ++ " changes from " ++ describeSlot sl ++ " to " ++ describe (E.dtype e) (E.shape e)) e


describeSlot : I.Slot -> String
describeSlot sl =
    case ( sl.dtype, sl.shape ) of
        ( Just dt, Just s ) ->
            describe dt s

        _ ->
            "an unknown shape"


describe : P.DT -> List Int -> String
describe dt shape =
    P.dtName dt ++ "[" ++ String.join "," (List.map String.fromInt shape) ++ "]"


{-| A graph with no inputs that writes `value` (usually zeros) into the state's resident buffers,
named as `step` names them: the state is made on the host, never sent from Elm.
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
            List.map3 keepShape sNames ss.slots (ss.flatten value)

        problems =
            shapeless "state" ss.slots
    in
    if List.isEmpty problems then
        Graph.build graphName Signature.unit outSig body

    else
        Err problems
