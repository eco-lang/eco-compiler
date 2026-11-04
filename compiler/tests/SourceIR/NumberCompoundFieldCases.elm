module SourceIR.NumberCompoundFieldCases exposing (expectSuite)

{-| Programs in which a number value is destructured through a compound
constructor field (finding F2, reported by the coverage loop as F-mono-2,
fixed). A `let`-bound value whose type has a `number` variable, built with a
constructor whose field wraps that variable in a tuple, a record, a `List`, a
`Maybe` or an alias, and destructured with a constructor pattern, kept the
`Int` default for the destructured name even where it was used as a `Float`.
The pattern's compound slot was bound once, at its eager type, because only a
scalar slot was specialized per use; with real packages the MLIR generator
crashed on a kernel signature mismatch (`Elm_Kernel_Basics_add_Float`). The
fix treats a compound slot with a `number` variable as a number root of its
own, so each use refines it, and through it the original root.

They come from the former unit test
`Compiler.Monomorphize.Solver.NumberCompoundFieldTest`, whose three checks
already ran over the catalogue: MONO\_008
(`TestLogic.Generate.MonoNumericResolution.expectNumericTypesResolved`),
MONO\_007 (`TestLogic.Generate.MonoLayoutIntegrity.expectRecordAccessMatchesLayout`)
and CGEN\_040 (`TestLogic.Generate.CodeGen.OperandTypeConsistency.expectOperandTypeConsistency`).

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Every program is written as Elm source text and parsed with
`Compiler.Parse.Module.fromByteString`; its imports, including the default
ones the parser adds, are replaced by those of
`Compiler.AST.SourceBuilder.makeKernelModule`. Each is a module named `Test`
that defines `testValue`. The cases, by label:

  - "F2 tuple field": `T ( 2, 3 ) 0` destructured as `(T ( t, _ ) _)`, then
    `t + 0.5`.
  - "F2 list field": `L [ 1 ] 0` destructured as `(L xs _)`, then
    `List.foldl (+) 0.25 xs`.
  - "F2 record field": `R { v = 4 } 0` destructured as `(R r _)`, then
    `r.v + 0.5`.
  - "F2 Maybe field": `M (Just 5) 0` destructured as `(M m _)`, then a `case`
    adding `0.5` to the payload.
  - "F2 alias and function fields": `Wrap ( 1, 2 ) (\v -> v)`, whose fields
    have the types `Pt a` (an alias of `( a, a )`) and `a -> a`, destructured
    as `(Wrap ( u, _ ) f)`, then `u + f 0.5`.
  - "F2 many fields at two types": `Many [ 1 ] ( 2, 3 ) { v = 4 } (Just 5) ()`
    destructured into all five fields, read at `Float`, and a second
    `(Many ys _ _ _ _)` read at `Int`, so the root has two instances.
  - "F2 nested tuples": `N ( ( 1, 2 ), 3 )` destructured as
    `(N ( ( a, b ), c ))`, with `a` at `Float` and `c` at `Int`.

-}

import Compiler.AST.SourceBuilder exposing (makeKernelModule, unitExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Compiler.Parse.Module as M
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Number through a compound field programs " followed
by `condStr`, that passes `expectFn` each program in order through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Number through a compound field programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, source ) -> { label = label, run = \_ -> runSource expectFn source })
        [ ( "F2 tuple field", tupleField )
        , ( "F2 list field", listField )
        , ( "F2 record field", recordField )
        , ( "F2 Maybe field", maybeField )
        , ( "F2 alias and function fields", aliasAndFunctionFields )
        , ( "F2 many fields at two types", manyFields )
        , ( "F2 nested tuples", nestedTuples )
        ]


{-| Runs `expectFn` on the program `source` parses to, with its imports
replaced by those of `makeKernelModule`, or fails when it does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn source =
    case M.fromByteString M.Application source of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    makeKernelModule "unused" unitExpr
            in
            expectFn (Src.Module { m | imports = template.imports })

        Err _ ->
            Expect.fail ("fixture does not parse:\n" ++ source)


{-| A number value in a tuple field, destructured and used at `Float`.
-}
tupleField : String
tupleField =
    """
module Test exposing (..)


type T a
    = T ( a, Int ) Int


testValue : Float
testValue =
    let
        tt =
            T ( 2, 3 ) 0

        (T ( t, _ ) _) =
            tt
    in
    t + 0.5
"""


{-| A list of numbers in a field, destructured and folded at `Float`.
-}
listField : String
listField =
    """
module Test exposing (..)


type L a
    = L (List a) Int


testValue : Float
testValue =
    let
        ll =
            L [ 1 ] 0

        (L xs _) =
            ll
    in
    List.foldl (+) 0.25 xs
"""


{-| A record holding a number in a field, destructured and read at `Float`.
-}
recordField : String
recordField =
    """
module Test exposing (..)


type R a
    = R { v : a } Int


testValue : Float
testValue =
    let
        rr =
            R { v = 4 } 0

        (R r _) =
            rr
    in
    r.v + 0.5
"""


{-| A `Maybe` of a number in a field, destructured and used at `Float`.
-}
maybeField : String
maybeField =
    """
module Test exposing (..)


type M a
    = M (Maybe a) Int


testValue : Float
testValue =
    let
        mm =
            M (Just 5) 0

        (M m _) =
            mm
    in
    case m of
        Just z ->
            z + 0.5

        Nothing ->
            0.5
"""


{-| A number value in a field typed by an alias of a pair, next to a function
field, destructured and used at `Float`.
-}
aliasAndFunctionFields : String
aliasAndFunctionFields =
    """
module Test exposing (..)


type alias Pt a =
    ( a, a )


type Wrap a
    = Wrap (Pt a) (a -> a)


testValue : Float
testValue =
    let
        w =
            Wrap ( 1, 2 ) (\\v -> v)

        (Wrap ( u, _ ) f) =
            w
    in
    u + f 0.5
"""


{-| A number value spread over five kinds of field, read at `Float`, and the
same root destructured again and read at `Int`.
-}
manyFields : String
manyFields =
    """
module Test exposing (..)


type Many a
    = Many (List a) ( a, Int ) { v : a } (Maybe a) ()


testValue : ( Float, Int )
testValue =
    let
        many =
            Many [ 1 ] ( 2, 3 ) { v = 4 } (Just 5) ()

        (Many xs ( t, _ ) r m _) =
            many

        (Many ys _ _ _ _) =
            many
    in
    ( List.foldl (+) 0.25 xs
        + t
        + r.v
        + (case m of
            Just z ->
                z

            Nothing ->
                0.5
          )
    , List.foldl (+) 1 ys
    )
"""


{-| A number value in a tuple of tuples, destructured two levels deep, with
the variables taking different types in the two levels.
-}
nestedTuples : String
nestedTuples =
    """
module Test exposing (..)


type N a b
    = N ( ( a, a ), b )


testValue : ( Float, Int )
testValue =
    let
        n =
            N ( ( 1, 2 ), 3 )

        (N ( ( a, b ), c )) =
            n
    in
    ( a + b + 0.5, c + 1 )
"""
