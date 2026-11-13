module Training exposing (Stepper, stepper, Trainer, start, train)

{-| Training in the browser: a `Train.step` graph, prepared once, run a few times per animation
frame by `Tensor.Eval`. The step's resident buffers (the parameters, the optimizer's state and its
step count) live in a `Trainer`; the parameters are one flat vector, the single field of the
network's `Param.Spec`, so a page's drawing and drag graphs can share them.

@docs Stepper, stepper, Trainer, start, train

-}

import Dict exposing (Dict)
import Graph exposing (Graph)
import Param
import Tensor.Eval as Eval


{-| A prepared training step, with the names of its fed inputs (in order), its loss output and the
resident parameter vector.
-}
type alias Stepper =
    { prepared : Result (List String) Eval.Prepared
    , fed : List Eval.Value -> Dict String Eval.Value
    , loss : String
    , param : String
    , graph : Result (List String) Graph
    }


stepper : Param.Spec p -> Result (List String) Graph -> Stepper
stepper spec graph =
    let
        specs =
            Result.map Graph.inputs graph |> Result.withDefault []
    in
    { prepared = Result.map Eval.prepare graph
    , fed =
        \values ->
            Dict.fromList
                (List.map2 (\s v -> ( s.name, { v | dtype = s.dtype } ))
                    (List.filter (\s -> s.role == Graph.Fed) specs)
                    values
                )
    , loss =
        Result.map Graph.outputs graph
            |> Result.withDefault []
            |> List.filter (\s -> s.role == Graph.Fed)
            |> List.map .name
            |> List.head
            |> Maybe.withDefault ""
    , param = Param.names spec |> List.head |> Maybe.withDefault "param0"
    , graph = graph
    }


{-| The step's resident buffers, the last loss and the number of steps taken.
-}
type alias Trainer =
    { residents : Dict String Eval.Value, loss : Maybe Float, steps : Int }


start : Stepper -> Trainer
start s =
    { residents = Result.map Eval.residentZeros s.graph |> Result.withDefault Dict.empty, loss = Nothing, steps = 0 }


{-| `n` steps on the fed values (in the step's input order; each value's dtype is taken from the
graph), from these parameters: the new parameters and trainer.
-}
train : Stepper -> Int -> List Eval.Value -> List Float -> Trainer -> ( List Float, Trainer )
train s n fedValues params t =
    case s.prepared of
        Err _ ->
            ( params, t )

        Ok prepared ->
            let
                batch =
                    s.fed fedValues

                first =
                    Dict.insert s.param { dtype = "f64", shape = [ List.length params ], data = Eval.Floats params } t.residents

                once _ ( residents, loss ) =
                    case Eval.runPrepared prepared (Dict.union batch residents) of
                        Ok outs ->
                            ( Dict.union (Dict.remove s.loss outs) residents
                            , case Dict.get s.loss outs |> Maybe.map .data of
                                Just (Eval.Floats [ l ]) ->
                                    Just l

                                _ ->
                                    loss
                            )

                        Err _ ->
                            ( residents, loss )

                ( after, lastLoss ) =
                    List.foldl once ( first, t.loss ) (List.range 1 n)

                newParams =
                    case Dict.get s.param after |> Maybe.map .data of
                        Just (Eval.Floats l) ->
                            l

                        _ ->
                            params
            in
            ( newParams, { residents = after, loss = lastLoss, steps = t.steps + n } )
