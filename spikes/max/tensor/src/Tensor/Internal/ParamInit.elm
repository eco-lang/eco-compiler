module Tensor.Internal.ParamInit exposing (fans, initValues, kindLabel)

{-| Initial values of parameter fields (shared by `Param` and `Train`).
-}

import Tensor.Internal.Host as Host
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


