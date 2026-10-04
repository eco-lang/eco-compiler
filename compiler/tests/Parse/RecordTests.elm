module Parse.RecordTests exposing (suite)

{-| Without these tests, a change could go unnoticed in the regions the
expression parser records for the empty record `{}` and for a one-field record
update, or in the error it gives when the target of an update starts with an
upper-case letter.

A record update is written `{ target | field = value }`. After the `{` and any
whitespace, the parser accepts either `}` or a lower-case variable name, so a
target that starts with an upper-case letter is rejected at its first
character. That failure is an `E.RecordOpen` error at the target's position,
wrapped in `E.Record`, whose own row and column are where the record began, at
the `{`.

The fixture is six one-line source strings, each parsed as a whole expression
by `record`. The tests establish:

  - `{}` parses to an empty `Src.Record` with no comments, whose region runs
    from row 1, column 1 to row 1, column 3. A region's end is the position
    just after its last character.
  - `{ a | x = 2 }` parses to a `Src.Update` with no comments anywhere. Its
    region runs from column 1 to column 14 of row 1, its target is the
    variable `a` at columns 3 to 4, and its one field is `x` at columns 7 to
    8, set to the integer `2` at columns 11 to 12.
  - `{ A.b | x = 2 }`, `{ A.B.c | x = 2 }`, `{ A | x = 2 }` and
    `{ A.B | x = 2 }` each fail with `E.RecordOpen` at row 1, column 3,
    inside `E.Record` at row 1, column 1. All four fail at the upper-case
    first letter, so these tests do not tell a qualified target apart from
    any other target that starts with an upper-case letter.

Among what is not tested: record literals with fields, updates of more than one
field, a qualified lower-case target such as `{ a.b | x = 2 }`, record field
access, comments inside the braces, and indentation errors.

-}

import Compiler.AST.Source as Src
import Compiler.Parse.Expression exposing (expression)
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E
import Expect
import Test exposing (Test)


{-| The record parser tests, grouped under "Parse.Record".
-}
suite : Test
suite =
    Test.describe "Parse.Record"
        [ (\_ ->
            record "{}"
                |> Expect.equal (Ok (A.at (A.Position 1 1) (A.Position 1 3) (Src.Record ( [], [] ))))
          )
            |> Test.test "Empty record"
        , (\_ ->
            record "{ a | x = 2 }"
                |> Expect.equal
                    (Ok
                        (A.at (A.Position 1 1) (A.Position 1 14) <|
                            Src.Update ( ( [], [] ), A.at (A.Position 1 3) (A.Position 1 4) (Src.Var Src.LowVar "a") )
                                ( []
                                , [ ( ( [], [], Nothing )
                                    , ( ( [], A.at (A.Position 1 7) (A.Position 1 8) "x" )
                                      , ( [], A.at (A.Position 1 11) (A.Position 1 12) (Src.Int 2 "2") )
                                      )
                                    )
                                  ]
                                )
                        )
                    )
          )
            |> Test.test "Extend record by unqualified name"
        , (\_ ->
            record "{ A.b | x = 2 }"
                |> Expect.equal (Err (E.Record (E.RecordOpen 1 3) 1 1))
          )
            |> Test.test "Extend record by qualified name is not allowed"
        , (\_ ->
            record "{ A.B.c | x = 2 }"
                |> Expect.equal (Err (E.Record (E.RecordOpen 1 3) 1 1))
          )
            |> Test.test "Extend record by nested qualified name is not allowed"
        , (\_ ->
            record "{ A | x = 2 }"
                |> Expect.equal (Err (E.Record (E.RecordOpen 1 3) 1 1))
          )
            |> Test.test "Extend record with custom type is not allowed"
        , (\_ ->
            record "{ A.B | x = 2 }"
                |> Expect.equal (Err (E.Record (E.RecordOpen 1 3) 1 1))
          )
            |> Test.test "Extend record with qualified custom type is not allowed"
        ]


{-| Parses `str` as one complete expression and returns the expression alone,
dropping the comments and end position the expression parser returns with it.

On failure it returns the parser's error. If the parse succeeds but stops
before the end of `str`, the error is `E.Start` at the position where it
stopped.

-}
record : String -> Result E.Expr Src.Expr
record str =
    P.fromByteString expression E.Start str
        |> Result.map (\( ( _, expr ), _ ) -> expr)
