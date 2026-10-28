module Compiler.Canonicalize.Environment.DupsUnionsOrderTest exposing (suite)

{-| Reproduces a bug in `Compiler.Canonicalize.Environment.Dups.unions`: it folds
with `List.foldl union Dict.empty`, which evaluates `union tracker acc`, so a
later tracker's occurrences come before an earlier one's. `detect` then reports
the later occurrence as the first region of a duplicate error (e.g.
`ExportDuplicate`, `DuplicateCtor`). Upstream Elm (`foldl' union`) and `insert`
/ `union` keep source order.

Fixed 2026-10-28 (plans/review-bug-triage-fixes.md, Part 5); the tests pin
the fix.

-}

import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as R
import Expect
import Test exposing (Test)


region : Int -> A.Region
region row =
    A.Region (A.Position row 1) (A.Position row 2)


suite : Test
suite =
    Test.describe "Dups.unions keeps source order"
        [ Test.test "first region of the duplicate error is the earlier occurrence" <|
            \_ ->
                let
                    tracker =
                        Dups.unions [ Dups.one "x" (region 1) (), Dups.one "x" (region 2) () ]
                in
                case R.run (Dups.detect (\name r1 r2 -> Error.DuplicateDecl name r1 r2) tracker) of
                    ( _, Err errs ) ->
                        case OneOrMore.destruct (::) errs of
                            [ Error.DuplicateDecl _ r1 r2 ] ->
                                Expect.equal ( region 1, region 2 ) ( r1, r2 )

                            _ ->
                                Expect.fail "unexpected errors"

                    ( _, Ok _ ) ->
                        Expect.fail "duplicate not detected"
        ]
