module Utils.MainTest exposing (suite)

{-| Regression tests for helpers in `Utils.Main`.

  - `dictFromListWith` once folded with `Dict.update k (Maybe.map ...)`, which
    never inserts an absent key, so it always returned `Dict.empty` and its
    callers (`Builder.Build.checkUniqueRoots`, `Builder.Build.checkRoots`,
    `Builder.Elm.Outline.detectDuplicates`) never detected duplicates.

-}

import Dict
import Expect
import Test exposing (Test)
import Utils.Main as Utils


suite : Test
suite =
    Test.describe "Utils.Main"
        [ Test.test "dictFromListWith keeps every key" <|
            \_ ->
                Utils.dictFromListWith (++) [ ( "a", [ 1 ] ), ( "b", [ 2 ] ) ]
                    |> Dict.toList
                    |> Expect.equal [ ( "a", [ 1 ] ), ( "b", [ 2 ] ) ]
        , Test.test "dictFromListWith combines the values of a repeated key" <|
            \_ ->
                Utils.dictFromListWith (++) [ ( "a", [ 1 ] ), ( "a", [ 2 ] ) ]
                    |> Dict.get "a"
                    |> Maybe.map List.length
                    |> Expect.equal (Just 2)
        ]
