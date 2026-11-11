module Tensor.Internal.ParamInit exposing (fans, initValues, kindLabel, residentNames)

{-| Initial values of parameter fields (shared by `Param` and `Train`).
-}

import Tensor.Internal.Host as Host
import Tensor.Internal.Names as Names
import Tensor.Internal.Types as I


kindLabel : I.FieldKind -> String
kindLabel k =
    case k of
        I.Trainable _ ->
            "param"

        I.Frozen _ ->
            "frozen"

        I.Data ->
            "data"


fans : List Int -> ( Int, Int )
fans s =
    case List.reverse s of
        out :: rest ->
            ( Basics.max 1 (List.product rest), out )

        [] ->
            ( 1, 1 )


{-| The values of one field, drawn from `seed`, and the seed after them.
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
            Host.draws (\u -> (2 * u - 1) * bound) n seed

        Just I.XavierUniform ->
            let
                bound =
                    sqrt (6 / toFloat (fanIn + fanOut))
            in
            Host.draws (\u -> (2 * u - 1) * bound) n seed

        Just I.HeNormal ->
            Host.normalDraws 0 (sqrt (2 / toFloat fanIn)) n seed

        Just I.XavierNormal ->
            Host.normalDraws 0 (sqrt (2 / toFloat (fanIn + fanOut))) n seed

        Just (I.Normal std) ->
            Host.normalDraws 0 std n seed

        Just I.Ones ->
            ( List.repeat n 1, seed )

        _ ->
            ( List.repeat n 0, seed )




{-| The resident names of a spec's fields, in field order: what `Train`, `Infer` and
`Param.importGraph` call the host's buffers. Unnamed fields are numbered among themselves by kind
(`param0`, `frozen`, `data1`: a label used once stays unnumbered); fields named by `Param.named n`
are numbered among the fields with the same name, as `n.param0`.
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
            -- each group's names, handed out in field order
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
