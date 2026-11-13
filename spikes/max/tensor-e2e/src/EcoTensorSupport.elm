module EcoTensorSupport exposing (constants, graphText, two64)

{-| Helpers shared by the eco-tensor E2E tests (no `main`: not a test itself).
-}

import Bitwise
import Graph exposing (Graph)
import Graph.Max


{-| The generic MLIR text of a built graph, or its build errors.
-}
graphText : Result (List String) Graph -> String
graphText r =
    case r of
        Ok g ->
            Graph.Max.toGenericText g

        Err es ->
            "errors: " ++ String.join "; " es


{-| Every constant's value attribute in a graph's text, in order: `#M.dense_array<...> : tensor<...>`.
-}
constants : String -> List String
constants text =
    String.split "value = #M.dense_array" text
        |> List.drop 1
        |> List.map (\s -> "#M.dense_array" ++ (String.split "}" s |> List.head |> Maybe.withDefault ""))


{-| 2^k, built at run time: eco's front end refuses integer literals beyond 2^53.
-}
two64 : Int -> Int
two64 k =
    Bitwise.shiftLeftBy k 1
