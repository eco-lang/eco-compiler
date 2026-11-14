module Tensor.Internal.ParamInit exposing (fans, initValues, kindLabel, residentNames)

{-| This module holds the two rules that give each tensor field of a parameter description its
resident name and, when its first values are computed in Elm, those values, so that each rule has
one implementation.

A _resident buffer_ is a buffer that whatever runs a graph keeps from one run to the next (see
`Graph`), and a field's _resident name_ is the name of the buffer that holds it. `Param.names`
publishes these names. A field's resident name is made from its kind's _label_, `param` for a
trainable field, `frozen` for a frozen one and `data` for a data field, numbered when the label
repeats among the fields of the field's group. A _group_ is the set of fields that carry one
`name`, which `Param.named` sets, wherever they sit in the description; the fields that carry no
name form one group of their own.

When computed in Elm, a trainable or frozen field's first values follow its `Init`: all 0 under
`Zeros`, all 1 under `Ones`, and otherwise drawn with the pseudo-random generator of
`Tensor.Internal.Encode`. A data field's are zeros. The He initialisers scale their distribution
by the field's _fan-in_, and the Xavier ones by its fan-in and _fan-out_. A field is read as a
weight whose last axis indexes the outputs, so the fan-out is the size of that axis and the fan-in
is the product of the sizes of the others, at least 1: how many elements feed one output.

-}

import Tensor.Internal.Encode as Elements
import Tensor.Internal.Names as Names
import Tensor.Internal.Types as I


{-| Returns the label a field of kind `k` contributes to its resident name: `param` for a
trainable field, `frozen` for a frozen one and `data` for a data field.
-}
kindLabel : I.FieldKind -> String
kindLabel k =
    case k of
        I.Trainable _ ->
            "param"

        I.Frozen _ ->
            "frozen"

        I.Data ->
            "data"


{-| Returns the fan-in and fan-out of a field of shape `s`, in that order.

The fan-out is the size of the last axis. The fan-in is the product of the sizes of the other axes,
or 1 where that product is less than 1, as it is when one of those axes has size 0. A rank-0
shape gives `( 1, 1 )`.

-}
fans : List Int -> ( Int, Int )
fans s =
    case List.reverse s of
        out :: rest ->
            ( Basics.max 1 (List.product rest), out )

        [] ->
            ( 1, 1 )


{-| Returns the first values of field `f`, drawn from `seed`, and the generator's state after the
last draw, from which further draws can continue.

There is one value for each element of the field, one for a rank-0 field, and the values are
`Float`s whatever the field's dtype. A trainable or frozen field's values follow its `Init`, with
fan-in and fan-out as `fans` gives them:

  - `HeUniform`: uniform in [−b, b), where b = √(6 / fan-in).
  - `XavierUniform`: uniform in [−b, b), where b = √(6 / (fan-in + fan-out)), when
    fan-in + fan-out is positive.
  - `HeNormal`: normal with mean 0 and standard deviation √(2 / fan-in).
  - `XavierNormal`: normal with mean 0 and standard deviation √(2 / (fan-in + fan-out)), when
    fan-in + fan-out is positive.
  - `Normal std`: standard normal values scaled by `std`.
  - `Zeros` and `Ones`: every value 0 or 1.

A data field's values are all 0. Where nothing is drawn, for `Zeros`, `Ones`, a data field or a
field with no elements, the state returned is `seed` itself. How the values follow from the seed,
including their order and how far they agree across platforms, is as `Tensor.Internal.Encode`
describes for its generator.

A shape whose sizes multiply to a negative number gives no values, except under `HeUniform` and
`XavierUniform`, where the draw never returns.

-}
initValues : I.Field -> Int -> ( List Float, Int )
initValues f seed =
    let
        n =
            List.product f.shape

        ( fanIn, fanOut ) =
            fans f.shape

        init =
            case f.kind of
                I.Trainable i ->
                    Just i

                I.Frozen i ->
                    Just i

                I.Data ->
                    Nothing
    in
    case init of
        Just I.HeUniform ->
            let
                bound =
                    sqrt (6 / toFloat fanIn)
            in
            Elements.draws (\u -> (2 * u - 1) * bound) n seed

        Just I.XavierUniform ->
            let
                bound =
                    sqrt (6 / toFloat (fanIn + fanOut))
            in
            Elements.draws (\u -> (2 * u - 1) * bound) n seed

        Just I.HeNormal ->
            Elements.normalDraws 0 (sqrt (2 / toFloat fanIn)) n seed

        Just I.XavierNormal ->
            Elements.normalDraws 0 (sqrt (2 / toFloat (fanIn + fanOut))) n seed

        Just (I.Normal std) ->
            Elements.normalDraws 0 std n seed

        Just I.Ones ->
            ( List.repeat n 1, seed )

        _ ->
            ( List.repeat n 0, seed )


{-| Returns the resident name of each of `fields`, in the same order.

A field's resident name is its kind's label (`kindLabel`), numbered among the fields of its group
as `Tensor.Internal.Names.names` numbers labels: a label that occurs once in the group is kept, and
a repeated one is numbered from 0 in field order. In a group named `n` every name begins with `n.`.
So three unnamed fields, two trainable and then one frozen, are named `param0`, `param1` and
`frozen`, and the same three in a group named `enc` are `enc.param0`, `enc.param1` and
`enc.frozen`.

The names are distinct. Within a group the labels are only the three kind labels, which numbering
cannot make collide, and a label contains no dot, so the dot after a group's name keeps groups
apart.

A name depends on the kinds and the order of the other fields in its group, so adding, removing or
changing the kind of one field can rename others in its group.

-}
residentNames : List I.Field -> List String
residentNames fields =
    let
        groupNames key =
            let
                members =
                    List.filter (\f -> f.name == key) fields

                labels =
                    Names.names "param" (List.map (.kind >> kindLabel) members)
            in
            case key of
                Just n ->
                    List.map (\l -> n ++ "." ++ l) labels

                Nothing ->
                    labels

        step f ( done, acc ) =
            -- A group's first field computes the whole group's names; later fields take the next.
            case List.filter (\( k, _ ) -> k == f.name) done of
                ( _, next :: rest ) :: _ ->
                    ( List.map
                        (\( k, ns ) ->
                            if k == f.name then
                                ( k, rest )

                            else
                                ( k, ns )
                        )
                        done
                    , next :: acc
                    )

                _ ->
                    case groupNames f.name of
                        first :: rest ->
                            ( ( f.name, rest ) :: done, first :: acc )

                        [] ->
                            ( done, acc )
    in
    List.foldl step ( [], [] ) fields |> Tuple.second |> List.reverse
