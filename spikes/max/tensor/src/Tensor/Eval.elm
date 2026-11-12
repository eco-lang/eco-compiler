module Tensor.Eval exposing
    ( Data(..), Value
    , floats, ints, mask
    , run, runWith, residentZeros
    )

{-| Runs graphs and tensors in Elm, with no MAX: a pure-Elm evaluator of every operation the package
builds, gradients, `vmap`, branches, loops and shared functions included.

It is for small graphs (up to about 10⁵–10⁶ element operations a run): tests that check values,
examples, teaching, and a second reference for the operations MAX runs. It is not a fast backend.

    x = T.fromList T.float32 (T.r1 three) [ 1, 2, 3 ]

    Eval.floats (x |> T.times x |> T.plus x)    --> Ok [ 2, 6, 12 ]
    Eval.ints (T.argMax Axis.last1 x)           --> Ok [ 2 ]


# What it computes

  - **Integers** (and masks) are exact and wrap as MAX's do: i8, u8 and i32 by their width, i64
    and u64 by eco's 64-bit `Int`. A u64 element is the `Int` with the same 64 bits (see `Tensor`).
    Under JavaScript an `Int` is exact only to 2⁵³, so integers beyond that come out wrong there.
  - **Floating** values are computed in f64, whatever the dtype: f32 results are more precise than
    MAX's (about 1e-7 relative), and f16 or bf16 results are not rounded or saturated. They agree
    with MAX within the tolerances of the spike's op checks; masks and indices computed from floats
    can differ at near-ties.
  - **Random draws** are deterministic for a seed and shape, but are not MAX's draws: compare
    statistics.

Errors are values: an index out of range, an integer `modBy 0`, a cast of NaN or an out-of-range
value to an integer dtype, or a `whileLoop` running past its guard each stop the run with a message
naming the operation.


# Values

@docs Data, Value


# Tensors

@docs floats, ints, mask


# Graphs

A graph runs as the host runs it: `run` takes each input under its name (a resident input under its
resident name), and returns each output under its name (or its resident name). Keep the resident
buffers in a `Dict` and merge each run's outputs into it, as the host does:

    -- init = Param.initInPlace "init" params: run once with a seed, it writes the parameters;
    -- residentZeros gives the optimizer state and step; step = Train.step ... runs per batch
    -- (each batch a Dict of the step's fed inputs, by name).
    train : Graph -> Graph -> List (Dict String Value) -> Result (List String) (Dict String Value)
    train init step batches =
        let
            seed =
                Dict.singleton "seed" { dtype = "ui64", shape = [ 1 ], data = Ints [ 42 ] }

            runStep batch residents =
                Eval.run step (Dict.union batch residents)
                    |> Result.map (\outs -> Dict.union outs residents)
        in
        Eval.run init seed
            |> Result.map (\params -> Dict.union params (Eval.residentZeros step))
            |> (\start -> List.foldl (\batch acc -> Result.andThen (runStep batch) acc) start batches)

Each run's outputs also hold the loss (under the step's output name, `Train` documents it).

@docs run, runWith, residentZeros

-}

import Array
import Dict exposing (Dict)
import Graph exposing (Graph)
import Tensor exposing (Mask, Tensor)
import Tensor.Internal.Eval as Engine
import Tensor.Internal.Eval.Core as C exposing (T)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Lower as Lower
import Tensor.Internal.Prim as P exposing (DT)
import Tensor.Internal.Types as I
import Tensor.Internal.Values as Values


{-| A tensor's elements, row-major: `Floats` for the floating dtypes, `Ints` for the integer ones
(u64 as the `Int` with the same bits), `Bools` for masks.
-}
type Data
    = Floats (List Float)
    | Ints (List Int)
    | Bools (List Bool)


{-| A graph's input or output: its dtype as `Graph.inputs` spells it (`"f32"`, `"si64"`, `"ui64"`,
`"bool"` …), its shape and its elements.
-}
type alias Value =
    { dtype : String, shape : List Int, data : Data }


{-| The elements of a floating tensor that reads no graph input, row-major.
-}
floats : Tensor Float d s -> Result (List String) (List Float)
floats t =
    evalTensor (I.tensor t)
        |> Result.map (\v -> Array.toList (C.floatsOf v))


{-| The elements of an integer tensor that reads no graph input, row-major (u64 as the `Int` with
the same bits).
-}
ints : Tensor Int d s -> Result (List String) (List Int)
ints t =
    evalTensor (I.tensor t)
        |> Result.map (\v -> Array.toList (C.intsOf v))


{-| The elements of a mask that reads no graph input, row-major.
-}
mask : Mask s -> Result (List String) (List Bool)
mask m =
    evalTensor (I.mask m)
        |> Result.map (\v -> List.map (\n -> n /= 0) (Array.toList (C.intsOf v)))


evalTensor : Expr -> Result (List String) T
evalTensor e =
    case Lower.problems "eval" [] [ ( "value", e ) ] of
        [] ->
            Engine.evalRoots { inputs = Array.empty, maxIterations = defaultIterations } [] { memo = Dict.empty, binds = Dict.empty } [ e ]
                |> Result.mapError List.singleton
                |> Result.andThen
                    (\vs ->
                        case vs of
                            [ Engine.One t ] ->
                                Ok t

                            _ ->
                                Err [ "eval: not a tensor" ]
                    )

        problems ->
            Err problems


defaultIterations : Int
defaultIterations =
    100000


{-| Runs a graph: its inputs by name (a resident input by its resident name), its outputs by name
(a resident output by its resident name). A `whileLoop` may run 100,000 iterations.
-}
run : Graph -> Dict String Value -> Result (List String) (Dict String Value)
run =
    runWith { maxIterations = defaultIterations }


{-| `run` with another guard on `whileLoop` iterations: past it, the run is an error, not a hang.
-}
runWith : { maxIterations : Int } -> Graph -> Dict String Value -> Result (List String) (Dict String Value)
runWith cfg (I.Graph g) given =
    let
        key spec =
            case spec.role of
                I.Resident n ->
                    n

                I.Fed ->
                    spec.name

        inputs =
            List.foldr
                (\spec acc ->
                    case Dict.get (key spec) given of
                        Nothing ->
                            Result.map2 (::) (Err ("missing input " ++ key spec)) acc

                        Just v ->
                            Result.map2 (::) (toT (key spec) spec v) acc
                )
                (Ok [])
                g.inputs
    in
    inputs
        |> Result.mapError List.singleton
        |> Result.andThen
            (\ts ->
                Engine.evalRoots { inputs = Array.fromList ts, maxIterations = cfg.maxIterations } [] { memo = Dict.empty, binds = Dict.empty } g.exprs.outputs
                    |> Result.mapError (\m -> [ g.name ++ ": " ++ m ])
            )
        |> Result.map
            (\vs ->
                List.map2
                    (\spec v ->
                        case v of
                            Engine.One t ->
                                ( key spec, fromT t )

                            Engine.Many _ ->
                                ( key spec, { dtype = spec.dtype, shape = spec.shape, data = Floats [] } )
                    )
                    g.outputs
                    vs
                    |> Dict.fromList
            )


{-| A zero value of the right dtype and shape for every resident input of a graph, under its
resident name: what `Train.initial` gives the host for the optimizer state and `step`.
-}
residentZeros : Graph -> Dict String Value
residentZeros (I.Graph g) =
    List.filterMap
        (\spec ->
            case spec.role of
                I.Resident n ->
                    let
                        count =
                            List.product spec.shape
                    in
                    Just
                        ( n
                        , { dtype = spec.dtype
                          , shape = spec.shape
                          , data =
                                if spec.dtype == "bool" then
                                    Bools (List.repeat count False)

                                else if List.member spec.dtype [ "f16", "bf16", "f32", "f64" ] then
                                    Floats (List.repeat count 0)

                                else
                                    Ints (List.repeat count 0)
                          }
                        )

                I.Fed ->
                    Nothing
        )
        g.inputs
        |> Dict.fromList


dtFromName : String -> Maybe DT
dtFromName name =
    List.filter (\d -> P.dtName d == name) P.allDTs |> List.head


toT : String -> I.Spec -> Value -> Result String T
toT name spec v =
    let
        count =
            List.product spec.shape

        wrong what =
            Err ("input " ++ name ++ ": " ++ what)
    in
    case dtFromName spec.dtype of
        Nothing ->
            wrong ("unknown dtype " ++ spec.dtype)

        Just dt ->
            if v.dtype /= spec.dtype then
                wrong ("dtype " ++ v.dtype ++ ", but the graph takes " ++ spec.dtype)

            else if v.shape /= spec.shape then
                wrong ("shape [" ++ showInts v.shape ++ "], but the graph takes [" ++ showInts spec.shape ++ "]")

            else
                let
                    values =
                        case v.data of
                            Floats l ->
                                if P.isFloat dt then
                                    Ok (Values.FloatValues l)

                                else
                                    Err "Floats for an integer or mask input"

                            Ints l ->
                                if P.isInt dt then
                                    case Values.fitsDtype dt (Values.IntValues l) of
                                        Just msg ->
                                            Err msg

                                        Nothing ->
                                            Ok (Values.IntValues l)

                                else
                                    Err "Ints for a floating or mask input"

                            Bools l ->
                                if dt == P.Bool then
                                    Ok
                                        (Values.IntValues
                                            (List.map
                                                (\b ->
                                                    if b then
                                                        1

                                                    else
                                                        0
                                                )
                                                l
                                            )
                                        )

                                else
                                    Err "Bools for a non-mask input"
                in
                case values of
                    Err msg ->
                        wrong msg

                    Ok vs ->
                        if Values.length vs /= count then
                            wrong (String.fromInt (Values.length vs) ++ " elements, but the shape has " ++ String.fromInt count)

                        else
                            Ok (C.fromValues dt spec.shape vs)


fromT : T -> Value
fromT t =
    { dtype = P.dtName t.dt
    , shape = t.shape
    , data =
        case t.data of
            C.F a ->
                Floats (Array.toList a)

            C.I a ->
                if t.dt == P.Bool then
                    Bools (List.map (\n -> n /= 0) (Array.toList a))

                else
                    Ints (Array.toList a)
    }


showInts : List Int -> String
showInts l =
    String.join ", " (List.map String.fromInt l)
