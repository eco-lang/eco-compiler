module Tensor.Internal.Device exposing (Device(..), place, hostMark, axisNotLastMark)

{-| Writing lowered ops for a device (plans/tensor-api-round2.md, A3; `work/inventory/g16_gpu.txt`).

On a GPU every tensor type names the device (`!mo.tensor<[2, 3], f32, gpu:0>`) except the operands
MAX keeps on the host: shapes, permutations, paddings, axes, bounds, epsilons. `Mo` marks the ops
that make those (`hostMark`); everything else, data constants included, moves to the device. A
`mo.custom` names its device in an attribute. `Mo` also marks a top-k off the last axis, which
MAX's GPU kernels do not support. Branches and loops are refused on a GPU for now: MAX needs their
predicate on the CPU, which takes a transfer threaded through the chain. For the CPU the marks are only removed, so the ops are exactly
what round 1 wrote.

-}

import Tensor.Internal.MlirBc as Bc


type Device
    = Cpu
    | Gpu Int


hostMark : String
hostMark =
    "eco.host"


axisNotLastMark : String
axisNotLastMark =
    "eco.axisNotLast"


place : Device -> List Bc.Op -> Result (List String) (List Bc.Op)
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


notOnGpu : Bc.Op -> List String
notOnGpu op =
    (if List.any (\( n, _ ) -> n == axisNotLastMark) op.attrs then
        [ "topK: on a GPU only the last axis is supported (" ++ op.name ++ ")" ]

     else if op.name == "mo.if" || op.name == "mo.while" then
        -- MAX needs the predicate on the CPU: a transfer, written with the GPU host (M4)
        [ "cond and whileLoop are not written for a GPU yet: MAX needs their predicate on the CPU (" ++ op.name ++ ")" ]

     else
        []
    )
        ++ List.concatMap (\r -> List.concatMap notOnGpu (regionOps r)) op.regions


regionOps : Bc.Region -> List Bc.Op
regionOps r =
    case r of
        Bc.Region _ ops ->
            ops

        Bc.OpenRegion _ ops ->
            ops


isMark : ( String, Bc.Attr ) -> Bool
isMark ( n, _ ) =
    n == hostMark || n == axisNotLastMark


placeOp : Device -> Bc.Op -> Bc.Op
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


placeRegion : Device -> Bc.Region -> Bc.Region
placeRegion device r =
    case r of
        Bc.Region args ops ->
            Bc.Region (List.map (placeType device) args) (List.map (placeOp device) ops)

        Bc.OpenRegion args ops ->
            Bc.OpenRegion (List.map (placeType device) args) (List.map (placeOp device) ops)


placeAttr : Device -> ( String, Bc.Attr ) -> ( String, Bc.Attr )
placeAttr device ( n, a ) =
    case ( device, a ) of
        ( Cpu, _ ) ->
            ( n, a )

        ( Gpu i, Bc.OpaqueAttr text ) ->
            if n == "device" then
                ( n, Bc.OpaqueAttr ("#M.device_ref<\"gpu\", " ++ String.fromInt i ++ ">") )

            else
                ( n, a )

        ( _, Bc.TypeAttr t ) ->
            ( n, Bc.TypeAttr (placeType device t) )

        _ ->
            ( n, a )


placeType : Device -> Bc.Type -> Bc.Type
placeType device t =
    case ( device, t ) of
        ( Cpu, _ ) ->
            t

        ( Gpu i, Bc.OpaqueType text ) ->
            Bc.OpaqueType (onDevice i text)

        ( _, Bc.FunctionType ins outs ) ->
            Bc.FunctionType (List.map (placeType device) ins) (List.map (placeType device) outs)

        _ ->
            t


{-| Every `!mo.tensor<[dims], dtype ...>` in the text, with `, gpu:i` after its dtype.
-}
onDevice : Int -> String -> String
onDevice i text =
    case String.split "!mo.tensor<[" text of
        first :: rest ->
            first ++ String.concat (List.map (\part -> "!mo.tensor<[" ++ afterDims i part) rest)

        [] ->
            text


afterDims : Int -> String -> String
afterDims i part =
    case String.indexes "]" part of
        close :: _ ->
            let
                -- "], f32>..." or "], f32, {layout = ...}>..."
                dims =
                    String.left (close + 1) part

                tail =
                    String.dropLeft (close + 1) part

                dtypeEnd =
                    [ String.indexes "," (String.dropLeft 2 tail), String.indexes ">" (String.dropLeft 2 tail) ]
                        |> List.filterMap List.head
                        |> List.minimum
                        |> Maybe.withDefault 0
            in
            dims ++ String.left (2 + dtypeEnd) tail ++ ", gpu:" ++ String.fromInt i ++ String.dropLeft (2 + dtypeEnd) tail

        [] ->
            part
