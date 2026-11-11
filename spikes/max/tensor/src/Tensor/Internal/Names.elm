module Tensor.Internal.Names exposing (names)

{-| Input and output names from labels: a label used once is the name; a repeated one is numbered
in order. The default label `arg` becomes `default`.
-}

import Dict


names : String -> List String -> List String
names default labels =
    let
        ls =
            List.map
                (\l ->
                    if l == "arg" then
                        default

                    else
                        l
                )
                labels

        count l =
            List.length (List.filter ((==) l) ls)

        step l ( seen, acc ) =
            let
                i =
                    Maybe.withDefault 0 (Dict.get l seen)
            in
            ( Dict.insert l (i + 1) seen
            , (if count l == 1 then
                l

               else
                l ++ String.fromInt i
              )
                :: acc
            )
    in
    List.foldl step ( Dict.empty, [] ) ls |> Tuple.second |> List.reverse
