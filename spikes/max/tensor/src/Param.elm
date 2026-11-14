module Param exposing
    ( Builder, Spec, Field, record
    , heUniform, heNormal, xavierUniform, xavierNormal, normal, zeros, ones
    , data, sub, list, config, frozen, named
    , names, sig, initial, initGraph, initInPlace, importGraph
    , mapElems, count, grad
    )

{-| A model's parameters are a record of tensors, and several things have to be derived from that
record and agree with one another: the graph inputs that carry it, the names of the buffers that
keep it between runs, its first values and its gradient. This module lets a program describe the
record once, in the style of `elm/json` decoders, and derives each of them from that one
description.

    params =
        Param.record Params
            |> Param.sub .l1 (Linear.params T.float32 pixels hidden)
            |> Param.sub .l2 (Linear.params T.float32 hidden classes)

A _description_ (`Spec r`) lists the record's _tensor fields_ in order, each with a dtype, a shape
and a kind. A part (`sub`, `list`) contributes its own tensor fields at the place where it is added.
That order is the order of everything derived from the description: the slots of `sig`, the names
of `names`, the entries of `initial` and the outputs of the graphs built here. A field's _kind_ says
what training does with it and how it is first filled:

  - a _trainable_ field is updated by training, and its first values are given by its
    _initialiser_, one of those that `heUniform` .. `ones` describe;
  - a _frozen_ field (`frozen`) gets its first values in the same way but is not updated by
    training;
  - a _data_ field (`data`) is not updated by training, and `initial`, `initGraph` and
    `initInPlace` fill it with zeros.

A _config_ field (`config`) is not a parameter. It holds a value fixed by the description, such as a
dimension or a constant tensor, and has no slot, no buffer and no initial value.

A field's values can be kept in a _resident buffer_, which whatever runs a graph keeps from one run
to the next (see `Graph.Role`). Each tensor field has a _resident name_, which `names` gives: the
name of the buffer that holds it. `initial`, `initInPlace` and `importGraph` address a field's
buffer by that name, and so must any graph that is to share it. `sig` and `initGraph` do not: their
slots are `Fed`, and `Graph.build` names them from their labels.

First values are made from a seed in one of two ways: `initial` computes them in Elm and gives them
as bytes, while `initGraph` and `initInPlace` build a graph that draws them with random operations.
The two draw differently, so for one seed a drawn field's values from each need not agree.

The He and Xavier initialisers scale their distribution by a field's _fan-in_ and _fan-out_. A
field is read as a weight whose last axis indexes the outputs: the fan-out is the size of that axis,
and the fan-in is the product of the sizes of the other axes, or 1 where that product is less
than 1. A rank-0 field has a fan-in and a fan-out of 1.


# Descriptions

@docs Builder, Spec, Field, record


# Trainable tensors

Each of these adds a trainable field, given the accessor that reads it, its dtype and its shape
(see `Field`).

@docs heUniform, heNormal, xavierUniform, xavierNormal, normal, zeros, ones


# Other fields and parts

@docs data, sub, list, config, frozen, named


# Using a description

@docs names, sig, initial, initGraph, initInPlace, importGraph


# Working with parameters

@docs mapElems, count, grad

-}

import Bytes exposing (Bytes)
import Graph exposing (Graph)
import Signature exposing (Sig)
import Tensor exposing (DType, Elems, F32, R0, Shape, Tensor)
import Tensor.Internal.Encode as Elements
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Names as Names
import Tensor.Internal.Ops as O
import Tensor.Internal.ParamInit as ParamInit
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Types as I
import Tensor.Internal.Values as Values
import Tensor.Random as Random


{-| A parameter description being put together, as an `elm/json` decoder pipeline is: `r` is the
type of the record it reads tensors from and `f` the type of what it has built so far.

`record` starts one from the record's constructor, so that `f` is the constructor's type, and each
field function supplies the constructor's next argument together with the accessor that reads that
field back. Once every argument is supplied, `f` is `r` and the builder is a `Spec r`. Each accessor
must read the field its argument fills, which no type checks. When a signature made with `sig` is a
graph's input, `Graph.build` notices, through the round trip, a wrong accessor of a tensor field or
of a part that holds tensor fields; as a graph's output it can miss one.

This is not a `Signature.Builder`: `sig` makes a signature from a complete description.

-}
type alias Builder r f =
    I.ParamBuilder r f


{-| A complete description of a parameter record of type `r`: its tensor fields in order, each with
a dtype, a shape and a kind, and the values of its config fields.
-}
type alias Spec r =
    Builder r r


{-| Starts a description of a record from its constructor. Each field added after it supplies the
constructor's next argument, in order.
-}
record : f -> Builder r f
record constructor =
    I.ParamBuilder { fields = [], build = \es -> ( constructor, es ), flatten = \_ -> [], checks = [] }


{-| The type of the trainable-field functions (`heUniform` .. `ones`): a function that takes the
accessor that reads a float tensor field from the record, the field's dtype and its shape, and adds
the field to a builder as its next argument.
-}
type alias Field r d s f =
    (r -> Tensor Float d s) -> DType Float d -> Shape s -> Builder r (Tensor Float d s -> f) -> Builder r f


{-| Returns the field function for fields of kind `kind`. It adds a tensor field, read back by
`getter`, with the given dtype and shape. Built from a list with no tensor left, the field is a
rank-0 zero of its dtype.
-}
tensorField : I.FieldKind -> (r -> Tensor k d s) -> DType k d -> Shape s -> Builder r (Tensor k d s -> f) -> Builder r f
tensorField kind getter (I.DType dt _) (I.Shape s) (I.ParamBuilder b) =
    I.ParamBuilder
        { fields = b.fields ++ [ { dtype = dt, shape = s, kind = kind, name = Nothing } ]
        , build =
            \es ->
                let
                    ( f, rest ) =
                        b.build es
                in
                case rest of
                    e :: more ->
                        ( f (I.Tensor e), more )

                    [] ->
                        ( f (I.Tensor (E.scalar dt 0)), [] )
        , flatten = \r -> b.flatten r ++ [ I.tensor (getter r) ]
        , checks = b.checks
        }


{-| Adds a trainable field whose first values are drawn uniformly between −b and b, where
b = √(6 / fan-in).
-}
heUniform : Field r d s f
heUniform =
    tensorField (I.Trainable I.HeUniform)


{-| Adds a trainable field whose first values are drawn from a normal distribution with mean 0 and
standard deviation √(2 / fan-in).
-}
heNormal : Field r d s f
heNormal =
    tensorField (I.Trainable I.HeNormal)


{-| Adds a trainable field whose first values are drawn uniformly between −b and b, where
b = √(6 / (fan-in + fan-out)).
-}
xavierUniform : Field r d s f
xavierUniform =
    tensorField (I.Trainable I.XavierUniform)


{-| Adds a trainable field whose first values are drawn from a normal distribution with mean 0 and
standard deviation √(2 / (fan-in + fan-out)).
-}
xavierNormal : Field r d s f
xavierNormal =
    tensorField (I.Trainable I.XavierNormal)


{-| Produces the field function for a trainable field whose first values are drawn from a normal
distribution with mean 0 and standard deviation `std`.
-}
normal : Float -> Field r d s f
normal std =
    tensorField (I.Trainable (I.Normal std))


{-| Adds a trainable field whose first values are all 0.
-}
zeros : Field r d s f
zeros =
    tensorField (I.Trainable I.Zeros)


{-| Adds a trainable field whose first values are all 1.
-}
ones : Field r d s f
ones =
    tensorField (I.Trainable I.Ones)


{-| Adds a data field: a tensor of any element type, read back by the accessor, with the given dtype
and shape.

Training does not update it, and `initial`, `initGraph` and `initInPlace` give it zeros. Any other
contents have to come from elsewhere, such as `importGraph`.

-}
data : (r -> Tensor k d s) -> DType k d -> Shape s -> Builder r (Tensor k d s -> f) -> Builder r f
data =
    tensorField I.Data


{-| Adds a field holding a part with its own description, such as a layer's parameters. The part's
tensor fields join this description's at this point, in their own order, and `getter` reads the
part back from the record.
-}
sub : (r -> p) -> Spec p -> Builder r (p -> f) -> Builder r f
sub getter (I.ParamBuilder s) (I.ParamBuilder b) =
    I.ParamBuilder
        { fields = b.fields ++ s.fields
        , build =
            \es ->
                let
                    ( f, r1 ) =
                        b.build es

                    ( p, r2 ) =
                        s.build r1
                in
                ( f p, r2 )
        , flatten = \r -> b.flatten r ++ s.flatten (getter r)
        , checks = b.checks ++ List.map (\c -> getter >> c) s.checks
        }


{-| Returns a description of a list of `n` values, each described by `s`, such as the layers of a
stack. Its tensor fields are those of `s`, repeated `n` times.

For `n` of 0 or more, building gives `n` records. Flattening lists the tensors of every record in
the list it is given, whatever the list's length. `sig`, `importGraph`, `mapElems` and `grad`
refuse a length other than `n`, with build errors on the tensors they give.

-}
list : Int -> Spec p -> Spec (List p)
list n (I.ParamBuilder s) =
    I.ParamBuilder
        { fields = List.concat (List.repeat n s.fields)
        , build =
            \es ->
                List.foldl
                    (\_ ( acc, rest ) ->
                        let
                            ( x, r ) =
                                s.build rest
                        in
                        ( x :: acc, r )
                    )
                    ( [], es )
                    (List.range 1 n)
                    |> Tuple.mapFirst List.reverse
        , flatten = List.concatMap s.flatten
        , checks =
            [ \ps ->
                if List.length ps /= n then
                    Just ("a list of " ++ String.fromInt n ++ " has " ++ String.fromInt (List.length ps))

                else
                    List.filterMap (\p -> List.filterMap (\c -> c p) s.checks |> List.head) ps |> List.head
            ]
        }


{-| Adds a config field: a value that is part of the description, `value`, rather than a parameter,
such as a dimension or a constant tensor. It has no slot, no resident buffer and no initial value,
and `count` does not count it.

Every record built from the description holds `value` in this field, including the records that
`grad` and `mapElems` return. The field is compared with `value`, by `==`, where `sig` flattens a
record and where `importGraph`, `mapElems` and `grad` read one, and the record is refused, with
build errors on the tensors they give, when they are not equal, so a NaN is refused even when it is
`value`.

-}
config : (r -> c) -> c -> Builder r (c -> f) -> Builder r f
config getter value (I.ParamBuilder b) =
    I.ParamBuilder
        { fields = b.fields
        , build =
            \es ->
                let
                    ( f, rest ) =
                        b.build es
                in
                ( f value, rest )
        , flatten = b.flatten
        , checks =
            b.checks
                ++ [ \r ->
                        if getter r == value then
                            Nothing

                        else
                            Just "a configuration field differs from the parameter description (it is a constant of the description)"
                   ]
        }


{-| Returns the description `s` with every trainable field made frozen: first filled as its
initialiser says, but not updated by training. Data fields are unchanged.

A frozen field's resident name is made from `frozen` instead of `param`, so freezing renames the
fields it changes and can renumber the other fields of their group (see `names`).

-}
frozen : Spec p -> Spec p
frozen (I.ParamBuilder s) =
    I.ParamBuilder
        { s
            | fields =
                List.map
                    (\f ->
                        case f.kind of
                            I.Trainable i ->
                                { f | kind = I.Frozen i }

                            _ ->
                                f
                    )
                    s.fields
        }


{-| Returns the signature of a parameter record: one slot for each tensor field, in field order,
with the field's dtype and shape.

Every slot is `Fed`, so a graph that takes this signature as its input is given the parameters with
every run and keeps no buffer for them. The slots are labelled `param`, `frozen` or `data` by kind,
and `Graph.build` names them as it names any labelled slots, numbering a label that several slots
of the whole signature carry. When no field is in a `named` part, the slots keep these labels and
no other slot of the signature carries one of them, the names are those `names` gives.

When this signature flattens a record that does not match the description, because a config field
holds another value or a `list` has the wrong length, every tensor it lists that has not already
failed carries a build error describing the first mismatch found, prefixed with `Param:`. Built from too few tensors, it makes
each missing field that `heUniform` .. `ones` or `data` added a rank-0 zero of the field's dtype.

-}
sig : Spec r -> Sig r
sig (I.ParamBuilder s) =
    I.SigBuilder
        { slots = List.map (\f -> { label = ParamInit.kindLabel f.kind, dtype = Just f.dtype, shape = Just f.shape, role = I.Fed }) s.fields
        , build = s.build
        , flatten =
            \r ->
                case List.filterMap (\c -> c r) s.checks of
                    [] ->
                        s.flatten r

                    problem :: _ ->
                        List.map (E.failWith ("Param: " ++ problem)) (s.flatten r)
        }


{-| Returns every tensor field's first values, computed in Elm from the seed, in field order, each
as bytes under the field's resident name (`names`).

Trainable and frozen fields are drawn as their initialisers say, and data fields are zeros. The
draws come from the package's own pseudo-random generator, whose state passes from each field to
the next, so a field's values depend on the fields drawn before it. They need not be the values
`initGraph` draws for the same seed. Drawn values need not agree to the last bit across platforms:
those of a normal initialiser for any seed, and any of them for a seed of magnitude beyond about
5.4 · 10⁹.

The bytes are in the encoding stated in `Train`'s module documentation.

-}
initial : Spec r -> Int -> List ( String, Bytes )
initial ((I.ParamBuilder s) as spec) seed0 =
    List.foldl
        (\f ( seed, acc ) ->
            let
                ( values, seed1 ) =
                    ParamInit.initValues f seed
            in
            ( seed1, Elements.encodeValues f.dtype (Values.forDtype f.dtype values) :: acc )
        )
        ( seed0, [] )
        s.fields
        |> Tuple.second
        |> List.reverse
        |> List.map2 Tuple.pair (names spec)


{-| Builds the graph `graphName`, which takes a seed and returns every tensor field's first values,
in field order.

The graph has one fed input, `seed`, a `ui64 [1]` tensor. A drawn field `i`, counting every tensor
field from 0, is drawn from the seed salted as `Tensor.Random.salt i` salts it. Trainable and frozen
fields are drawn as their initialisers say, in `f32` and then cast to the field's dtype; fields
initialised by `zeros` or `ones`, and data fields, are constant fills. The drawn values need not
agree with those `initial` computes for the same seed, and depend on what runs the graph, as
`Tensor.Random` describes.

The outputs are fed. They are labelled by kind, as `sig` labels its slots, so their names are those
`names` gives only if no field is in a `named` part.

-}
initGraph : String -> Spec r -> Result (List String) Graph
initGraph =
    initWith False


{-| Builds the graph `graphName`, which draws the same values as `initGraph` but gives each as a
resident output rather than a fed one: every output is `Resident` under the field's resident name
(`names`). The outputs' names are those of `initGraph`; only their resident names follow `named`.
-}
initInPlace : String -> Spec r -> Result (List String) Graph
initInPlace =
    initWith True


{-| Builds the graph of `initGraph` and `initInPlace`: one fed seed input, and one output per tensor
field, `Resident` under the field's resident name when `inPlace` and `Fed` otherwise.

Field `i`'s seed is the seed input salted by `Tensor.Random.salt i`. The distributions are those
`Tensor.Internal.ParamInit.initValues` draws in Elm, written as graph draws, so the two must be
changed together.

-}
initWith : Bool -> String -> Spec r -> Result (List String) Graph
initWith inPlace graphName (I.ParamBuilder s) =
    let
        seedSig =
            I.SigBuilder
                { slots = [ { label = "seed", dtype = Just UI64, shape = Just [ 1 ], role = I.Fed } ]
                , build = \es -> ( List.head es |> Maybe.withDefault (E.scalar UI64 0), List.drop 1 es )
                , flatten = \e -> [ e ]
                }

        outSig =
            I.SigBuilder
                { slots =
                    List.map2
                        (\f n ->
                            { label = ParamInit.kindLabel f.kind
                            , dtype = Just f.dtype
                            , shape = Just f.shape
                            , role =
                                if inPlace then
                                    I.Resident n

                                else
                                    I.Fed
                            }
                        )
                        s.fields
                        (ParamInit.residentNames s.fields)
                , build = \es -> ( es, [] )
                , flatten = identity
                }

        one i f seed =
            let
                ( fanIn, fanOut ) =
                    ParamInit.fans f.shape

                (I.Seed salted) =
                    Random.salt i (I.Seed seed)

                drawIn lo hi =
                    O.cast f.dtype (O.random 0 F32 f.shape lo hi salted)

                drawN std =
                    O.cast f.dtype (O.random 1 F32 f.shape 0 std salted)

                init =
                    case f.kind of
                        I.Trainable x ->
                            Just x

                        I.Frozen x ->
                            Just x

                        I.Data ->
                            Nothing
            in
            case init of
                Just I.HeUniform ->
                    drawIn -(sqrt (6 / toFloat fanIn)) (sqrt (6 / toFloat fanIn))

                Just I.XavierUniform ->
                    drawIn -(sqrt (6 / toFloat (fanIn + fanOut))) (sqrt (6 / toFloat (fanIn + fanOut)))

                Just I.HeNormal ->
                    drawN (sqrt (2 / toFloat fanIn))

                Just I.XavierNormal ->
                    drawN (sqrt (2 / toFloat (fanIn + fanOut)))

                Just (I.Normal std) ->
                    drawN std

                Just I.Ones ->
                    O.broadcastTo f.shape (E.scalar f.dtype 1)

                _ ->
                    O.broadcastTo f.shape (E.scalar f.dtype 0)
    in
    Graph.build graphName seedSig outSig (\seed -> List.indexedMap (\i f -> one i f seed) s.fields)


{-| Returns the record the description builds from `r`'s tensors, paired with its tensor fields in
order, after `f` is applied to each tensor paired with a trainable field. Such a tensor is converted
to `f32` for `f` and back to that field's dtype afterwards; the others are kept as they are. Config
fields hold the description's values.

When `r` does not match the description, because a config field holds another value or a `list`
has the wrong length, the result holds `r`'s tensors (a zero of the field's shape for each one
missing), and every one of them that has not already failed carries a build error describing the first mismatch found, prefixed with `Param:`, as `sig`
describes.

-}
mapElems : (Tensor Float F32 Elems -> Tensor Float F32 Elems) -> Spec r -> r -> r
mapElems f (I.ParamBuilder s) r =
    let
        apply field e =
            case field.kind of
                I.Trainable _ ->
                    O.cast field.dtype (I.tensor (f (I.Tensor (O.cast F32 e))))

                _ ->
                    e
    in
    case mismatch s r of
        Just problem ->
            Tuple.first (s.build (poisoned ("Param: " ++ problem) s.fields (s.flatten r)))

        Nothing ->
            Tuple.first (s.build (List.map2 apply s.fields (s.flatten r)))


{-| Returns the first way in which the record `r` does not match the description `s`: a failed
check (a config field holding another value, or a `list` of the wrong length), or a number of
tensors other than the number of tensor fields. Returns `Nothing` when it matches.
-}
mismatch : { b | fields : List I.Field, flatten : r -> List Expr, checks : List (r -> Maybe String) } -> r -> Maybe String
mismatch s r =
    case List.filterMap (\c -> c r) s.checks of
        problem :: _ ->
            Just problem

        [] ->
            let
                got =
                    List.length (s.flatten r)

                want =
                    List.length s.fields
            in
            if got /= want then
                Just ("the record has " ++ String.fromInt got ++ " tensors, the description " ++ String.fromInt want)

            else
                Nothing


{-| Returns one tensor per field of `fields`, each failed with `problem`: the tensor of `es` at the
field's position, or, past the end of `es`, a zero of the field's dtype and shape. A tensor of `es`
that has already failed keeps its own error instead (`Tensor.Internal.Expr.failWith`).
-}
poisoned : String -> List I.Field -> List Expr -> List Expr
poisoned problem fields es =
    List.indexedMap
        (\i f ->
            E.failWith problem
                (List.drop i es
                    |> List.head
                    |> Maybe.withDefault (O.broadcastTo f.shape (E.scalar f.dtype 0))
                )
        )
        fields


{-| Returns the number of tensor fields, trainable, frozen and data. Config fields are not counted.
-}
count : Spec r -> Int
count (I.ParamBuilder s) =
    List.length s.fields


{-| Returns the gradient of `loss` at the record the description builds from `r`'s tensors, as a
record of the same type, holding for each tensor field the gradient with respect to that field.

Frozen and float data fields get a gradient too. A non-float data field, and a field the loss does
not depend on, get zeros. Config fields hold the description's values.

When `r` does not match the description, because a config field holds another value or a `list`
has the wrong length, the result holds `r`'s tensors (a zero of the field's shape for each one
missing), and every one of them that has not already failed carries a build error describing the first mismatch found, prefixed with `Param:`, as `sig`
describes.

-}
grad : Spec r -> (r -> Tensor Float d R0) -> r -> r
grad (I.ParamBuilder s) loss r =
    case mismatch s r of
        Just problem ->
            Tuple.first (s.build (poisoned ("Param: " ++ problem) s.fields (s.flatten r)))

        Nothing ->
            Grad.gradStructured (\es -> Tuple.first (s.build es)) s.flatten (loss >> I.tensor) r
                |> Tuple.second


{-| Returns the resident name of each tensor field, in field order: the name of the buffer that
holds the field between runs, which `initial`, `initInPlace` and `importGraph` use.

A field's name is its kind's label, `param` for a trainable field, `frozen` for a frozen one and
`data` for a data field, numbered among the fields of its group when the label occurs there more
than once. A _group_ is either the fields that carry one name from `named`, whose names begin with
that name and a dot, or the fields that no `named` reaches. So three fields outside any `named`
part, two trainable and then one frozen, are `param0`, `param1` and `frozen`, and the same three
under `named "enc"` are `enc.param0`, `enc.param1` and `enc.frozen`. The names are distinct.

A name depends on the kinds and the order of the other fields in its group, so adding, removing or
freezing a field can rename the others in its group.

-}
names : Spec r -> List String
names (I.ParamBuilder s) =
    ParamInit.residentNames s.fields


{-| Returns the description `s` with its fields put in the group `n`, so that their resident names
begin with `n.` (see `names`). A group's names depend only on its own fields, so while no field
outside this part is in the group `n`, the names beginning `n.` stay the same wherever the part
sits in a larger description.

Only fields that are in no group yet are moved: the innermost `named` around a field wins, and
names do not nest. `named "a" (named "b" s)` gives `s`'s fields names beginning `b.`; write
`named "a.b"` for that name. Parts given the same name form one group and are numbered together.

-}
named : String -> Spec p -> Spec p
named n (I.ParamBuilder s) =
    I.ParamBuilder
        { s
            | fields =
                List.map
                    (\f ->
                        case f.name of
                            Nothing ->
                                { f | name = Just n }

                            Just _ ->
                                f
                    )
                    s.fields
        }


{-| Builds the graph `graphName`, which reads raw tensors, such as a checkpoint's, from resident
buffers, converts them with `convert` into a parameter record, and writes every tensor field of
that record into its resident buffer (`names`), whatever its kind.

The raw buffers' names come from the labels of `raw`'s slots: a label used once is the name, a
repeated one is numbered (`w0`, `w1` ..), and an unlabelled slot counts as labelled `raw`. The names
are distinct: a number whose name is one of the labels is skipped, so `w`, `w`, `w1` give `w0`,
`w2` and `w1`. Each raw slot must declare a dtype and a shape; otherwise the result is an error for
each slot that does not, beginning with `graphName`, and no graph is built.

The converted record must match the description as `sig` requires: each `list` part of the length
its `n` gives, and each config field holding the description's value. When it does not, every
output that has not already failed carries a build error describing the first mismatch found, so
the graph is refused. Otherwise the tensors `convert` gives are paired with the fields in order.
Each must have exactly its field's dtype and shape; one that does not, and has not already failed,
carries a build error naming the field's resident name, so the graph is refused.

-}
importGraph : String -> Spec r -> Sig raw -> (raw -> r) -> Result (List String) Graph
importGraph graphName (I.ParamBuilder s) (I.SigBuilder raw) convert =
    let
        rawNames =
            Names.names "raw" (List.map .label raw.slots)

        missing =
            List.filterMap identity
                (List.map2
                    (\n sl ->
                        if sl.dtype == Nothing || sl.shape == Nothing then
                            Just (graphName ++ ": importGraph: raw tensor " ++ n ++ " has no dtype or shape")

                        else
                            Nothing
                    )
                    rawNames
                    raw.slots
                )

        paramNames =
            ParamInit.residentNames s.fields

        inSig =
            I.SigBuilder
                { slots = List.map2 (\n sl -> { sl | label = n, role = I.Resident n }) rawNames raw.slots
                , build = raw.build
                , flatten = raw.flatten
                }

        outSig =
            I.SigBuilder
                { slots = List.map (\n -> { label = n, dtype = Nothing, shape = Nothing, role = I.Resident n }) paramNames
                , build = \es -> ( es, [] )
                , flatten = identity
                }

        body r =
            let
                converted =
                    convert r

                outs =
                    s.flatten converted
            in
            case mismatch s converted of
                Just problem ->
                    poisoned ("importGraph: " ++ problem) s.fields outs

                Nothing ->
                    List.map3
                        (\n f e ->
                            if E.dtype e == f.dtype && E.shape e == f.shape then
                                e

                            else
                                E.failWith
                                    ("importGraph: "
                                        ++ n
                                        ++ " is "
                                        ++ describe (E.dtype e) (E.shape e)
                                        ++ ", the parameter is "
                                        ++ describe f.dtype f.shape
                                    )
                                    e
                        )
                        paramNames
                        s.fields
                        outs
    in
    if List.isEmpty missing then
        Graph.build graphName inSig outSig body

    else
        Err missing


{-| Returns a dtype and shape as the error messages here write them, such as `f32[3,4]`.
-}
describe : DT -> List Int -> String
describe dt shape =
    P.dtName dt ++ "[" ++ String.join "," (List.map String.fromInt shape) ++ "]"
