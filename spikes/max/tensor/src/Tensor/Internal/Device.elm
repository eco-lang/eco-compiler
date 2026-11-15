module Tensor.Internal.Device exposing (Device(..), axisNotLastMark, hostMark, place)

{-| The MLIR ops of a graph are written once, in their form for the CPU with two marks added, and
this module adapts them to the device the graph is to run on. Adapting them is called _placing_ the
ops, and `place` is the whole of it.

In the form written for a GPU, a tensor type names the device, as in
`!mo.tensor<[2, 3], f32, gpu:0>`. Placing for `Gpu i` therefore adds `gpu:i` to the tensor types
the ops carry: their result types, the argument types of their regions, and their attributes that
are types, such as a graph's function type. An attribute named `device` and written as text becomes
`#M.device_ref<"gpu", i>`.

Some values stay on the CPU even then, such as a shape or an axis that another op reads as an
operand. An op that makes one carries a _host mark_, the attribute named by `hostMark`, and
placing leaves its result types as they are. Every op without the mark has its tensor results
placed on the GPU, constants included.

Some ops are refused on a GPU, and placing for a GPU then returns every refusal and no ops. A top-k
along an axis other than the last carries the _axis-not-last mark_, the attribute named by
`axisNotLastMark`, and is refused, as this module assumes a GPU supports only the last axis. A
branch (`mo.if`) or a loop (`mo.while`) is refused: this module assumes MAX needs its predicate on
the CPU, and the module writes no transfer to put it there.

Placing removes both marks, from the ops inside regions too. For the CPU that is all placing does,
and it never refuses.

-}

import Tensor.Internal.Ir as Ir


{-| The device a graph's ops are placed for.

Placing for `Cpu` leaves every attribute other than the host and axis-not-last marks, and every
type, as it is.

`Gpu i` is the GPU with index `i`, written `gpu:i` in tensor types and `#M.device_ref<"gpu", i>` in
a `device` attribute. The index is written as given: nothing here checks that the GPU exists or
that `i` is not negative. `Max.toBytecodeOn` and `Max.toGenericTextOn` refuse a
negative index before placing.

-}
type Device
    = Cpu
    | Gpu Int


{-| The name of the attribute that keeps an op's results on the CPU when the ops are placed for a
GPU. Only the name is looked for; the attribute's value is ignored.
-}
hostMark : String
hostMark =
    "eco.host"


{-| The name of the attribute that marks a top-k along an axis other than the last, which `place`
refuses for a GPU. Only the name is looked for; the attribute's value is ignored.
-}
axisNotLastMark : String
axisNotLastMark =
    "eco.axisNotLast"


{-| Places `ops` for `device`, or returns why they cannot be placed there.

For `Cpu` the result is always `Ok`: the ops with every mark removed, inside regions too, and
nothing else changed.

For `Gpu i`, every op is checked, at any depth of regions. An op with the axis-not-last mark, and
every `mo.if` and `mo.while`, gives one refusal message naming the op, such as "rmo.mo.bottom\_k: on
a GPU only the last axis is supported", and if there are any the
result is `Err` with all of them, each op's own before those of its regions. Otherwise the result
is `Ok` with the marks removed and the ops placed on GPU `i`: `gpu:i` added to the tensor types of
every result (except those of an op with the host mark), of every region argument and of every
attribute that is a type, and every `device` attribute written as text replaced by
`#M.device_ref<"gpu", i>`.

-}
place : Device -> List Ir.Op -> Result (List String) (List Ir.Op)
place device ops =
    let
        refusals =
            case device of
                Cpu ->
                    []

                Gpu _ ->
                    List.concatMap notOnGpu ops
    in
    if List.isEmpty refusals then
        Ok (List.map (placeOp device) ops)

    else
        Err refusals


{-| Returns the reasons `op`, and the ops in its regions at any depth, cannot be placed on a GPU:
one message for each refused op, `op`'s own first.
-}
notOnGpu : Ir.Op -> List String
notOnGpu op =
    (if List.any (\( n, _ ) -> n == axisNotLastMark) op.attrs then
        [ op.name ++ ": on a GPU only the last axis is supported" ]

     else if op.name == "mo.if" || op.name == "mo.while" then
        [ "cond and whileLoop are not written for a GPU yet: MAX needs their predicate on the CPU (" ++ op.name ++ ")" ]

     else
        []
    )
        ++ List.concatMap (\r -> List.concatMap notOnGpu (regionOps r)) op.regions


{-| Returns the ops of a region, isolated or open.
-}
regionOps : Ir.Region -> List Ir.Op
regionOps r =
    case r of
        Ir.Region _ ops ->
            ops

        Ir.OpenRegion _ ops ->
            ops


{-| Tells whether an attribute is the host mark or the axis-not-last mark, by its name alone.
-}
isMark : ( String, Ir.Attr ) -> Bool
isMark ( n, _ ) =
    n == hostMark || n == axisNotLastMark


{-| Places one op for `device`, and the ops of its regions with it: removes its marks, places its
attributes, its regions and, unless it carries the host mark, its result types.
-}
placeOp : Device -> Ir.Op -> Ir.Op
placeOp device op =
    let
        onHost =
            List.any (\( n, _ ) -> n == hostMark) op.attrs

        attrs =
            List.filter (not << isMark) op.attrs |> List.map (placeAttr device)
    in
    { op
        | attrs = attrs
        , results =
            if onHost then
                op.results

            else
                List.map (placeType device) op.results
        , regions = List.map (placeRegion device) op.regions
    }


{-| Places a region's argument types and its ops for `device`, keeping it isolated or open as it
was.
-}
placeRegion : Device -> Ir.Region -> Ir.Region
placeRegion device r =
    case r of
        Ir.Region args ops ->
            Ir.Region (List.map (placeType device) args) (List.map (placeOp device) ops)

        Ir.OpenRegion args ops ->
            Ir.OpenRegion (List.map (placeType device) args) (List.map (placeOp device) ops)


{-| Places one named attribute for `device`.

On a GPU, an attribute that is a type has its type placed, and one named `device` and written as
text is replaced by `#M.device_ref<"gpu", i>`. Any other attribute, and every attribute for the
CPU, is returned unchanged; in particular, types inside an array or dictionary attribute are not
placed.

-}
placeAttr : Device -> ( String, Ir.Attr ) -> ( String, Ir.Attr )
placeAttr device ( n, a ) =
    case ( device, a ) of
        ( Cpu, _ ) ->
            ( n, a )

        ( Gpu i, Ir.OpaqueAttr _ ) ->
            if n == "device" then
                ( n, Ir.OpaqueAttr ("#M.device_ref<\"gpu\", " ++ String.fromInt i ++ ">") )

            else
                ( n, a )

        ( _, Ir.TypeAttr t ) ->
            ( n, Ir.TypeAttr (placeType device t) )

        _ ->
            ( n, a )


{-| Places one type for `device`.

On a GPU, a type written as text gets `gpu:i` in every tensor type within it (`onDevice`), and a
function type has its argument and result types placed. Any other type, and every type for the
CPU, is returned unchanged.

-}
placeType : Device -> Ir.Type -> Ir.Type
placeType device t =
    case ( device, t ) of
        ( Cpu, _ ) ->
            t

        ( Gpu i, Ir.OpaqueType text ) ->
            Ir.OpaqueType (onDevice i text)

        ( _, Ir.FunctionType ins outs ) ->
            Ir.FunctionType (List.map (placeType device) ins) (List.map (placeType device) outs)

        _ ->
            t


{-| Returns `text` with `, gpu:i` inserted after the dtype of every `!mo.tensor<[dims], dtype ...>`
in it, wherever it occurs, nested inside another type's text included: `!mo.tensor<[2, 3], f32>`
becomes `!mo.tensor<[2, 3], f32, gpu:0>`. An occurrence with no `]` before the next one, or before
the end of `text`, is left as it is.
-}
onDevice : Int -> String -> String
onDevice i text =
    case String.split "!mo.tensor<[" text of
        first :: rest ->
            first ++ String.concat (List.map (\part -> "!mo.tensor<[" ++ afterDims i part) rest)

        [] ->
            text


{-| Returns `part`, the text that follows one `!mo.tensor<[`, with `, gpu:i` inserted after the
dtype that follows the `]` closing the dimensions. The dtype is taken to begin two characters after
the `]` and to end at the next comma or `>` after that; with neither, `, gpu:i` is inserted where
the dtype begins. A `part` with no `]` is returned unchanged.
-}
afterDims : Int -> String -> String
afterDims i part =
    case String.indexes "]" part of
        close :: _ ->
            let
                dims =
                    String.left (close + 1) part

                tail =
                    String.dropLeft (close + 1) part

                -- tail is ", f32>..." or ", f32, {layout = ...}>...",
                -- so the dtype starts after ", "
                dtypeEnd =
                    [ String.indexes "," (String.dropLeft 2 tail), String.indexes ">" (String.dropLeft 2 tail) ]
                        |> List.filterMap List.head
                        |> List.minimum
                        |> Maybe.withDefault 0
            in
            dims ++ String.left (2 + dtypeEnd) tail ++ ", gpu:" ++ String.fromInt i ++ String.dropLeft (2 + dtypeEnd) tail

        [] ->
            part
