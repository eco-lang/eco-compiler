module Parse.RecordTests exposing (suite)

import Compiler.AST.Source as Src
import Compiler.Parse.Expression as E
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E
import Expect
import Test exposing (Test)


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


record : String -> Result E.Expr Src.Expr
record =
    P.fromByteString (E.record (A.Position 1 1)) E.Start
