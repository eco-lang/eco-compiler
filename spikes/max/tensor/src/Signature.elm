module Signature exposing
    ( Sig, Builder
    , tensor, f32, bf16, i64, u8, mask, anyTensor
    , unit, pair, triple, list
    , record, field
    , map, label
    )

{-| Graphs, transforms and control flow take and give tensors as an ordered list, while a program
keeps them in records, tuples and lists. A _signature_ (`Sig a`) describes how a value of type `a`
corresponds to such a list, in both directions.

    Sig.pair (Sig.u8 (T.r2 batch pixels)) (Sig.u8 (T.r1 batch))

A signature is a list of _slots_, one per tensor in order, together with two functions: _build_
makes a value from tensors taken from the front of a list, one per slot, and _flatten_ lists a
value's tensors in slot order. Each slot carries a _label_, from which `Graph.build` names a graph's
inputs and outputs; a dtype and shape, which it may declare or leave open; and a role. Every slot
made here has the role `Fed` (`Graph.Role`): it is given with every run of a graph.

Everything rests on one contract that no type states, the _round trip_: given one tensor per slot,
_build_ makes a value whose _flatten_ gives those same tensors back, in the same order. It can
break, for example, where a record field's accessor reads a different field of the same type from
the one its constructor argument fills, or where `map` is given a `from` that does not undo `to`.
`Graph.build` checks the round trip of its input and output signatures and refuses a graph that
breaks it. Nothing else checks it.

A different mistake is to give `list n` a list whose length is not `n`: its _flatten_ then gives
failed tensors, one per slot, whose build error names `Signature.list` (see `list`).

Building never fails. A tensor slot made here that finds the list empty builds a failed f32 scalar
instead, whatever type it declares.

The dtype and shape a slot declares are what `Graph.build` gives an input. For an output,
`Graph.build` refuses a result whose dtype or shape differs from what the slot declares.

Records are described as `elm/json` decoder pipelines are: `record` takes the constructor, and each
`field` supplies the next argument together with the accessor that reads it back.


# Signatures

@docs Sig, Builder


# Tensors

@docs tensor, f32, bf16, i64, u8, mask, anyTensor


# Structures

@docs unit, pair, triple, list


# Records

@docs record, field


# Changing a signature

@docs map, label

-}

import Tensor exposing (BF16, DType, F32, I64, Mask, Shape, Tensor, U8)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I


{-| A signature being put together, as an `elm/json` decoder pipeline is: it flattens an `r` and
builds an `f`.

`record` starts one with `f` the record's constructor, and each `field` supplies the constructor's
next argument. When every argument is supplied and the accessors read the record being built, `r`
and `f` are the same type and the builder is a `Sig` of it.

-}
type alias Builder r f =
    I.SigBuilder r f


{-| A signature for values of type `a`: the slots of the tensors one `a` holds, how to build an
`a` from them and how to flatten one back. The round trip, described at the top of this module, is
its contract, and only `Graph.build` checks it.
-}
type alias Sig a =
    Builder a a


{-| Returns a one-slot signature declaring dtype `dt` and shape `s`, labelled `arg` and fed. It
builds by applying `wrap` to the first tensor of the list and flattens with `unwrap`. With no tensor
left it wraps a failed f32 scalar instead, whose build error is "Signature: no tensor left to build
this slot from".
-}
one : Maybe DT -> Maybe (List Int) -> (Expr -> a) -> (a -> Expr) -> Sig a
one dt s wrap unwrap =
    I.SigBuilder
        { slots = [ { label = "arg", dtype = dt, shape = s, role = I.Fed } ]
        , build =
            \es ->
                case es of
                    e :: rest ->
                        ( wrap e, rest )

                    [] ->
                        ( wrap (E.failWith "Signature: no tensor left to build this slot from" (E.scalar F32 0)), [] )
        , flatten = \a -> [ unwrap a ]
        }


{-| Creates a signature for one tensor of the given dtype and shape.
-}
tensor : DType k d -> Shape s -> Sig (Tensor k d s)
tensor (I.DType dt _) (I.Shape s) =
    one (Just dt) (Just s) I.Tensor I.tensor


{-| Creates a signature for one f32 tensor of the given shape.
-}
f32 : Shape s -> Sig (Tensor Float F32 s)
f32 =
    tensor Tensor.float32


{-| Creates a signature for one bf16 tensor of the given shape.
-}
bf16 : Shape s -> Sig (Tensor Float BF16 s)
bf16 =
    tensor Tensor.bfloat16


{-| Creates a signature for one signed 64-bit integer tensor of the given shape. Its dtype name,
as a graph's specs give it, is `si64`.
-}
i64 : Shape s -> Sig (Tensor Int I64 s)
i64 =
    tensor Tensor.int64


{-| Creates a signature for one unsigned 8-bit integer tensor of the given shape. Its dtype name,
as a graph's specs give it, is `ui8`.
-}
u8 : Shape s -> Sig (Tensor Int U8 s)
u8 =
    tensor Tensor.uint8


{-| Creates a signature for one mask, a tensor of dtype `bool`, of the given shape.
-}
mask : Shape s -> Sig (Mask s)
mask (I.Shape s) =
    one (Just Bool) (Just s) I.Mask I.mask


{-| A signature for one tensor that declares no dtype and no shape.

`Graph.build` refuses it as a graph input, since an input needs both. As a graph output it is
accepted, and the output's dtype and shape are the result's. Its type admits any kind, dtype and
shape, and nothing checks the tensor it builds against them.

-}
anyTensor : Sig (Tensor k d s)
anyTensor =
    one Nothing Nothing I.Tensor I.tensor


{-| A signature with no slots: it builds `()` and flattens nothing.
-}
unit : Sig ()
unit =
    I.SigBuilder { slots = [], build = \es -> ( (), es ), flatten = \_ -> [] }


{-| Creates a signature for a pair, whose slots are the first signature's followed by the
second's.
-}
pair : Sig a -> Sig b -> Sig ( a, b )
pair (I.SigBuilder a) (I.SigBuilder b) =
    I.SigBuilder
        { slots = a.slots ++ b.slots
        , build =
            \es ->
                let
                    ( x, r1 ) =
                        a.build es

                    ( y, r2 ) =
                        b.build r1
                in
                ( ( x, y ), r2 )
        , flatten = \( x, y ) -> a.flatten x ++ b.flatten y
        }


{-| Creates a signature for a triple, whose slots are the three signatures' in order.
-}
triple : Sig a -> Sig b -> Sig c -> Sig ( a, b, c )
triple sa sb sc =
    map (\( a, ( b, c ) ) -> ( a, b, c )) (\( a, b, c ) -> ( a, ( b, c ) )) (pair sa (pair sb sc))


{-| Creates a signature for a list of `n` values of one signature, their slots one after another.

It builds exactly `n` values, none when `n` is 0 or less. Flattening a list of `n` values gives
their tensors in order. Flattening a list of any other length gives as many tensors as the
signature has slots all the same, every one failed with a build error such as "Signature.list:
expected 2 values, got 3": the list's tensors, cut short or followed by failed f32 scalars.

-}
list : Int -> Sig a -> Sig (List a)
list n (I.SigBuilder s) =
    let
        slots =
            List.concat (List.repeat n s.slots)
    in
    I.SigBuilder
        { slots = slots
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
        , flatten =
            \xs ->
                let
                    m =
                        List.length xs

                    tensors =
                        List.concatMap s.flatten xs
                in
                if m == max 0 n then
                    tensors

                else
                    let
                        msg =
                            "Signature.list: expected " ++ values (max 0 n) ++ ", got " ++ String.fromInt m

                        count =
                            List.length slots
                    in
                    (List.take count tensors ++ List.repeat (count - List.length tensors) (E.scalar F32 0))
                        |> List.map (E.failWith msg)
        }


{-| Returns `n` followed by "value" or "values", as `n` asks.
-}
values : Int -> String
values n =
    if n == 1 then
        "1 value"

    else
        String.fromInt n ++ " values"


{-| Starts a record signature from the record's constructor. It has no slots until `field` adds
them, one field per constructor argument, in argument order.

    Sig.record Batch
        |> Sig.field .images (Sig.u8 (T.r2 batch pixels))
        |> Sig.field .labels (Sig.u8 (T.r1 batch))

-}
record : f -> Builder r f
record constructor =
    I.SigBuilder { slots = [], build = \es -> ( constructor, es ), flatten = \_ -> [] }


{-| Adds the next field to a record signature, given the accessor that reads it and its
signature. Its slots follow those of the fields before it, and its built value is passed to the
constructor as the next argument.

Among other conditions, each accessor must read the field that its argument fills. The types
refuse a field of the wrong type but not one of the same type read from the wrong place, which can
break the round trip.

-}
field : (r -> a) -> Sig a -> Builder r (a -> f) -> Builder r f
field getter (I.SigBuilder s) (I.SigBuilder b) =
    I.SigBuilder
        { slots = b.slots ++ s.slots
        , build =
            \es ->
                let
                    ( f, r1 ) =
                        b.build es

                    ( x, r2 ) =
                        s.build r1
                in
                ( f x, r2 )
        , flatten = \r -> b.flatten r ++ s.flatten (getter r)
        }


{-| Creates a signature for `b` from one for `a`, with the same slots. Building applies `to` to the
value the signature for `a` builds, and flattening applies `from` first.

`from` must undo `to`. Where it does not, the round trip can break.

-}
map : (a -> b) -> (b -> a) -> Sig a -> Sig b
map to from (I.SigBuilder s) =
    I.SigBuilder
        { slots = s.slots
        , build = \es -> Tuple.mapFirst to (s.build es)
        , flatten = from >> s.flatten
        }


{-| Returns the signature with every slot labelled `l`, replacing any label set inside it, so the
outermost `label` wins. A slot made by this module that no `label` reaches carries `arg`.

`Graph.build` makes the names of a graph's inputs and outputs from these labels, after replacing
`arg` with a default: `arg` for inputs, `result` for outputs. A label that one slot of the input (or
output) signature carries is then that slot's name. One that several carry is numbered, `l0`, `l1`
.., across the whole signature, not only within the part `label` was applied to.

-}
label : String -> Sig a -> Sig a
label l (I.SigBuilder s) =
    I.SigBuilder { s | slots = List.map (\sl -> { sl | label = l }) s.slots }
