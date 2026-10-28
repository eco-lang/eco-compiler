module Compiler.Reporting.ResultTraverseErrorsTest exposing (suite)

{-| Reproduces two bugs in `Compiler.Reporting.Result`:

  - `indexedTraverse` folds with `List.foldr` over `andThen`, so it runs the
    elements last to first and stops at the first failure in that order: with
    two failing elements only the later one's error is reported, and warnings
    come out in reverse list order. `traverse` and upstream Elm's applicative
    `indexedTraverse` report every error in list order.
  - `mapTraverseWithKey` is built on `loop`/`map`, so only the first failing
    entry's errors are reported, not every entry's (upstream
    `Map.traverseWithKey` accumulates).

EXPECTED TO FAIL until the bugs are fixed.

-}

import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Reporting.Result as R
import Data.Map as DataMap
import Expect
import Test exposing (Test)


errors : ( List w, Result (OneOrMore.OneOrMore e) a ) -> List e
errors ( _, result ) =
    case result of
        Err es ->
            OneOrMore.destruct (::) es

        Ok _ ->
            []


suite : Test
suite =
    Test.describe "Result traversals collect every error"
        [ Test.test "indexedTraverse reports both failures in list order" <|
            \_ ->
                R.indexedTraverse (\_ x -> R.throw x) [ "first", "second" ]
                    |> R.run
                    |> errors
                    |> Expect.equal [ "first", "second" ]
        , Test.test "mapTraverseWithKey reports every failing entry" <|
            \_ ->
                DataMap.fromList identity [ ( 1, "first" ), ( 2, "second" ) ]
                    |> R.mapTraverseWithKey identity (\_ x -> R.throw x)
                    |> R.run
                    |> errors
                    |> Expect.equal [ "first", "second" ]
        ]
