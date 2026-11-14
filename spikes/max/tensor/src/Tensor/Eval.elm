module Tensor.Eval exposing
    ( Data(..), Value
    , floats, ints, mask
    , run, runWith, residentZeros
    , Prepared, prepare, runPrepared, runPreparedWith
    )

{-| This module computes tensors in plain Elm, with no MAX, so that their values can be had wherever
Elm runs: in tests that check values, in examples, in a page in the browser.

It computes either a single tensor that reads no graph input (`floats`, `ints`, `mask`) or a whole
`Graph`, run on input values given by name (`run`). Graphs that use gradients, `vmap`, branches,
loops and shared functions are computed too. Each element is computed with ordinary Elm arithmetic,
so the module suits small graphs; it is not a fast way to run a large one.

With `three` a `Dim` of size 3:

    x = T.fromList T.float32 (T.r1 three) [ 1, 2, 3 ]

    Eval.floats (x |> T.times x |> T.plus x)    --> Ok [ 2, 6, 12 ]
    Eval.ints (T.argMax Axis.last1 x)           --> Ok [ 2 ]


# What it computes

Every element is held in an Elm `Float` or `Int`, whatever its dtype, and most of how a result
relates to its dtype follows from that.

  - **Floating-point** elements are 64-bit doubles, and nothing rounds them to their dtype, a cast
    included: an `f32` result carries more precision than `f32` arithmetic gives, and an `f16` or
    `bf16` result is neither rounded nor saturated. Results can therefore differ from results
    computed in the dtype's own precision, and a mask or an index computed from floats can then
    differ where two values nearly tie.
  - **Integer** results are wrapped to their dtype's width as two's complement arithmetic wraps
    them, `si64` and `ui64` ones modulo 2⁶⁴. A `ui64` element is the `Int` with the same 64 bits,
    as `Tensor` describes, and is ordered, divided and averaged as an unsigned number. An integer
    mean is the sum, wrapped, divided by the count and rounded toward zero. Natively an `Int` has
    64 bits and holds every result. Under JavaScript an `Int` is a double, which holds every
    integer only up to 2⁵³. There the integer arithmetic is done so that a result that a double
    holds exactly is the native one, and an `si64` or `ui64` sum, difference, product, mean,
    cumulative sum or matrix product that no double holds exactly is refused as an error rather
    than rounded. Salting a seed that is already large, as `Tensor.Random.salt` of a salted seed
    usually does, gives such a product. Other `si64` and `ui64` values past 2⁵³, such as a
    constant, may be rounded there.
  - **NaN** is treated as this package takes MAX on the CPU to treat it. A comparison with NaN on
    either side is false, `notEquals` included. `max`, `min`, `maximum`, `minimum` and
    `Nn.maxPool2d` ignore NaN, giving NaN only where every value they compare is NaN, and `argMax`
    and `argMin` skip it. `topK`, `bottomK` and `sort` rank NaN above every number, `relu` keeps
    it, and a cast to a mask makes it `True`. Sums, means, cumulative sums and softmax let it
    through their arithmetic.
  - **Random draws** do not give the values MAX draws for the same seed, and under JavaScript a
    draw can give different values from the same draw in native code. `Tensor.Random` describes how
    draws on one seed relate to each other.

Some errors are found while computing, and returned as values: an index outside its axis given to
`take`, `rowsAt`, `put` or `putAdd`; an integer `modBy` by zero; a cast to an integer dtype of a
floating-point NaN, ±∞ or value the dtype cannot hold; under JavaScript, an `si64` or `ui64`
result that no `Int` holds exactly, as described above; a random draw of more than 2³¹ elements;
and a `whileLoop` whose test still holds after the number of steps loops are allowed. Computing
stops at the first such error. Its message starts with the name of the operation that failed,
which can differ from the function called (an index error in `rowsAt` gives a message starting
`"take: "`), as in `"modBy: integer division by zero"`. `floats`, `ints` and `mask` put `"eval: "`
before it, and the functions that run a graph put the graph's name and `": "`.


# Values

@docs Data, Value


# Tensors

A tensor that reads no graph input can be computed on its own, with no graph. It is first checked
as `Graph.build` checks the one output of a graph named `eval` with no inputs, so every message
from the check starts `"eval: "`.
A tensor that passes is computed, and the first error met while computing it is returned with the
same prefix, as in `"eval: modBy: integer division by zero"`. The guard on loops is 100,000 steps:
each time a `whileLoop` runs, a test that still holds after that many steps makes the computation
fail.

@docs floats, ints, mask


# Graphs

A graph's inputs and outputs travel as a `Dict` of `Value`s. Each one is keyed by its resident name
if its role is `Resident`, and by its spec's name otherwise (see `Graph.Role`). Whatever runs a
graph keeps its resident buffers, and here that is the caller: hold them in a `Dict`, and merge each
run's outputs into it. For a training loop, with `init` the graph `Param.initInPlace` builds and
`step` the one `Train.step` builds:

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

`init` writes the parameters' first values from the seed. `residentZeros` gives every resident
input of `step` a zero value, and `Dict.union` keeps the parameters `init` wrote over those zeros.
Each batch is a `Dict` of the step's fed inputs. The step's fed outputs, such as its loss, are
merged into the `Dict` as well; a run ignores keys its graph does not take.

@docs run, runWith, residentZeros


# Running a graph many times

`run` compiles the graph each time it is called: it works out the order in which the graph's
expressions are computed and where each one reads its operands. A graph that is run many times,
every animation frame or every iteration of a solver, can be compiled once by `prepare` and run by
`runPrepared`:

    stepper : Eval.Prepared
    stepper =
        Eval.prepare stepGraph

    -- each frame
    Eval.runPrepared stepper inputs

@docs Prepared, prepare, runPrepared, runPreparedWith

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


{-| A tensor's elements, as a flat list in row-major order: the last axis varies fastest.

`Floats` holds the elements of a floating-point dtype: `f16`, `bf16`, `f32` or `f64`.

`Ints` holds those of an integer dtype: `si8`, `si32`, `si64`, `ui8` or `ui64`. A `ui64` element
is the `Int` with the same 64 bits, so 2⁶³ … 2⁶⁴ − 1 are negative `Int`s.

`Bools` holds those of a mask, whose dtype is `bool`.

-}
type Data
    = Floats (List Float)
    | Ints (List Int)
    | Bools (List Bool)


{-| The value of one input or output of a graph: its dtype, its shape and its elements.

`dtype` is the dtype's name as `Graph.Spec` gives it: `"f16"`, `"bf16"`, `"f32"`, `"f64"`, `"si8"`,
`"si32"`, `"si64"`, `"ui8"`, `"ui64"` or `"bool"`, not `"i64"` or `"u8"`. `shape` lists the size of
each axis, and is `[]` for a scalar, which has one element.

-}
type alias Value =
    { dtype : String, shape : List Int, data : Data }


{-| Computes a floating-point tensor that reads no graph input, and returns its elements in
row-major order or what is wrong with it, as described under Tensors above.
-}
floats : Tensor Float d s -> Result (List String) (List Float)
floats t =
    evalTensor (I.tensor t)
        |> Result.map (\v -> Array.toList (C.floatsOf v))


{-| Computes an integer tensor that reads no graph input, and returns its elements in row-major
order or what is wrong with it, as described under Tensors above. A `ui64` element is returned as
the `Int` with the same 64 bits.
-}
ints : Tensor Int d s -> Result (List String) (List Int)
ints t =
    evalTensor (I.tensor t)
        |> Result.map (\v -> Array.toList (C.intsOf v))


{-| Computes a mask that reads no graph input, and returns its elements in row-major order or what
is wrong with it, as described under Tensors above.
-}
mask : Mask s -> Result (List String) (List Bool)
mask m =
    evalTensor (I.mask m)
        |> Result.map (\v -> List.map (\n -> n /= 0) (Array.toList (C.intsOf v)))


{-| Computes `e` and returns its value, or what is wrong with it.

`e` is first checked as the one output, named `value`, of a graph named `eval` with no inputs, so
every message from the check starts `"eval: "`. If the check finds nothing, `e` is compiled and run
with the default loop guard, and a run-time error is returned with `"eval: "` before it.

-}
evalTensor : Expr -> Result (List String) T
evalTensor e =
    case Lower.problems "eval" [] [ ( "value", e ) ] of
        [] ->
            Engine.execute { inputs = Array.empty, maxIterations = defaultIterations } (Engine.compile [ e ])
                |> Result.mapError (\m -> [ "eval: " ++ m ])
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


{-| The default guard on loops: the number of steps a `whileLoop` may take each time it runs. A
loop whose test still holds after that many steps fails the run.
-}
defaultIterations : Int
defaultIterations =
    100000


{-| Runs a graph on the input values in a `Dict`, and returns its output values, or the first error
met.

Each input and output is keyed by its resident name if its role is `Resident`, and by its spec's
name otherwise. Each input's `Value` must have the spec's dtype and exactly its shape, so an input
declared `[1]` is not given as `[]`. Its elements must be `Floats` for a floating-point dtype,
`Ints` for an integer dtype, and `Bools` for `bool`, as many as the shape holds. `Ints` for `si8`,
`ui8` or `si32` must fit the dtype: they are refused, not wrapped. Keys the graph does not take are
ignored.

An error comes back as a list of one message, which starts with the graph's name and `": "`. It is
about the first input, in the order of the graph's inputs, that is missing
(`"<name>: missing input <key>"`) or does not fit (`"<name>: input <key>: ..."`), or it is the first
error met while computing. The guard on loops is 100,000 steps: each time a `whileLoop` runs, a test that
still holds after that many steps makes the run fail. `runWith` sets another guard.

Names need not be unique, as `Graph` describes. Two inputs with one key read the same entry, and of
two outputs with one key only the last is returned.

`run` compiles the graph on every call; `prepare` compiles it once.

-}
run : Graph -> Dict String Value -> Result (List String) (Dict String Value)
run =
    runWith { maxIterations = defaultIterations }


{-| Runs a graph as `run` does, with `maxIterations` as the guard on loops: each time a `whileLoop`
runs, a test that still holds after `maxIterations` steps makes the run fail. The steps of each
execution of a loop are counted separately, not those of the whole run. A negative `maxIterations`
is refused, whether or not the graph has a loop, with a message that names it.
-}
runWith : { maxIterations : Int } -> Graph -> Dict String Value -> Result (List String) (Dict String Value)
runWith cfg g =
    runPreparedWith cfg (prepare g)


{-| A graph compiled once, so that it can be run many times without being compiled again.

The only way to make one is `prepare`. Running it with `runPrepared` or `runPreparedWith` gives
what `run` or `runWith` gives on the graph it was prepared from.

-}
type Prepared
    = Prepared { name : String, inputs : List I.Spec, outputs : List I.Spec, program : Engine.Program }


{-| Compiles a graph once, for `runPrepared` to run many times. Preparing cannot fail: whatever
`run` would report about the graph is reported each time the prepared graph runs.
-}
prepare : Graph -> Prepared
prepare (I.Graph g) =
    Prepared { name = g.name, inputs = g.inputs, outputs = g.outputs, program = Engine.compile g.exprs.outputs }


{-| Runs a prepared graph as `run` runs the graph it was prepared from, with the guard of 100,000
loop steps.
-}
runPrepared : Prepared -> Dict String Value -> Result (List String) (Dict String Value)
runPrepared =
    runPreparedWith { maxIterations = defaultIterations }


{-| Runs a prepared graph as `runWith` runs the graph it was prepared from.
-}
runPreparedWith : { maxIterations : Int } -> Prepared -> Dict String Value -> Result (List String) (Dict String Value)
runPreparedWith cfg (Prepared g) given =
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

        checked =
            if cfg.maxIterations < 0 then
                Err ("maxIterations must be 0 or more, not " ++ String.fromInt cfg.maxIterations)

            else
                inputs
    in
    checked
        |> Result.andThen
            (\ts ->
                Engine.execute { inputs = Array.fromList ts, maxIterations = cfg.maxIterations } g.program
            )
        |> Result.mapError (\m -> [ g.name ++ ": " ++ m ])
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


{-| Returns a zero value for every resident input of a graph, keyed by its resident name, with the
input's dtype and shape: `Bools` of `False` for `bool`, `Floats` of 0 for a floating-point dtype,
and `Ints` of 0 for an integer one.

Every resident input gets one, a model's parameters included. To keep values already known, merge
them over the zeros: `Dict.union params (residentZeros step)` keeps the entries of `params`.

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


{-| Returns the dtype whose name, as `Tensor.Internal.Prim.dtName` spells it, is `name`, or
`Nothing` if no dtype has that name.
-}
dtFromName : String -> Maybe DT
dtFromName name =
    List.filter (\d -> P.dtName d == name) P.allDTs |> List.head


{-| Converts `v`, the value given under the key `name`, to the run-time tensor of the input `spec`
describes, or returns why it does not fit, in a message starting `"input " ++ name ++ ": "`.

It refuses a value whose dtype or shape differs from the spec's, whose `Data` constructor is not
the one for the spec's dtype, or whose element count is not the shape's; `Ints` for an `si8`, `ui8`
or `si32` input that do not fit the dtype; and a spec whose dtype has no name it knows.

-}
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


{-| Converts a run-time tensor to a `Value` with its dtype's name and its shape. Elements held as
floats become `Floats`, and elements held as integers become `Bools` for `bool` and `Ints`
otherwise, a `ui64` element as the `Int` with the same 64 bits.
-}
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


{-| Returns the integers in `l` in decimal, separated by commas, for an error message.
-}
showInts : List Int -> String
showInts l =
    String.join ", " (List.map String.fromInt l)
