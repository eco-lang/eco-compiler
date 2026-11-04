module SourceIR.CovLambdaSetCases exposing (expectSuite)

{-| Programs in which function values flow through the places where the
monomorphizer's lambda-set solver loses track of which functions a value can
be, so that a caller's check can be run on them: functions chosen by an `if`
or a `case`, held in records, tuples, `Maybe`s, custom types and lists,
returned from `let`s, partially applied, composed, passed through mutually
recursive functions, and destructured.

The solver shares its store with the type checker, so these programs reach the
lambda-set cases of `Compiler.Type.Unify` and the shared lambda-set contents
of `Compiler.Type.State.IO`, which no type-checking program reaches.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies.

Every program is the source text of a module named `Test`, parsed as an
application module, that defines `testValue`. Default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks are dropped. The cases, by
label:

  - "Functions chosen by if and case, applied through a polymorphic apply".
  - "Functions in records, tuples and Maybe".
  - "Functions in a custom type and composed".
  - "Closures returned from lets and partial applications".
  - "Higher-order parameters passed through two levels".
  - "Functions destructured from tuples and records".

All the cases run inside one test through `Compiler.BulkCheck.bulkCheck`,
which stops at the first case that fails and reports its label.

Among what is not tested: a recursive function that returns a function, such
as one accumulating a closure through its recursive call. Two such programs
once broke invariant GOPT\_003 (finding F-type-5); they are in
`SourceIR.FunctionAccumulatorCases`.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Function values " followed by `condStr`, that
passes when `expectFn` passes on every case's program and otherwise fails with
the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Function values " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each running `expectFn` on its program, in the order
of the module documentation.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, body ) ->
            { label = label
            , run =
                \_ ->
                    case parse body of
                        Ok modul ->
                            expectFn modul

                        Err message ->
                            Expect.fail message
            }
        )
        programs


{-| Parses `body` after the header `module Test exposing (..)`, keeping only
the imports the mock interfaces can resolve.
-}
parse : String -> Result String Src.Module
parse body =
    case Parse.fromByteString Parse.Application ("module Test exposing (..)\n\n" ++ body) of
        Ok (Src.Module m) ->
            Ok (Src.Module { m | imports = List.filter isMockImport m.imports })

        Err _ ->
            Err "fixture failed to parse"


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The label and the source after the module header of each case.
-}
programs : List ( String, String )
programs =
    [ ( "Functions chosen by if and case, applied through a polymorphic apply"
      , """apply : (a -> b) -> a -> b
apply f x =
    f x


choose : Bool -> (Int -> Int)
choose b =
    if b then
        \\x -> x + 1

    else
        \\x -> x * 2


pickC : Int -> (Int -> Int)
pickC n =
    case n of
        0 ->
            negate

        1 ->
            abs

        _ ->
            identity


testValue : Int
testValue =
    apply (choose True) 1 + apply (pickC 0) 2 + List.foldl (\\f acc -> f acc) 0 [ choose False, pickC 1, \\y -> y ]
"""
      )
    , ( "Functions in records, tuples and Maybe"
      , """type alias Ops =
    { inc : Int -> Int, dbl : Int -> Int }


ops : Ops
ops =
    { inc = \\x -> x + 1, dbl = \\x -> x * 2 }


pairF : ( Int -> Int, Int -> Int )
pairF =
    ( ops.inc, \\x -> x - 1 )


maybeF : Maybe (Int -> Int)
maybeF =
    Just ops.dbl


run : Maybe (Int -> Int) -> Int -> Int
run m x =
    case m of
        Just f ->
            f x

        Nothing ->
            x


testValue : Int
testValue =
    run maybeF 3 + Tuple.first pairF 1 + Tuple.second pairF 2 + run (Just (Tuple.first pairF)) 4
"""
      )
    , ( "Functions in a custom type and composed"
      , """type Step
    = Step (Int -> Int)
    | Done


runStep : Step -> Int -> Int
runStep s x =
    case s of
        Step f ->
            f x

        Done ->
            x


steps : List Step
steps =
    [ Step (\\x -> x + 1), Step ((*) 2), Step (negate >> abs), Done ]


testValue : Int
testValue =
    List.foldl runStep 1 steps
"""
      )
    , ( "Closures returned from lets and partial applications"
      , """adder : Int -> Int -> Int
adder a b =
    a + b


makeAdder : Int -> (Int -> Int)
makeAdder n =
    let
        k =
            n * 2

        f =
            adder k
    in
    f


twice : (a -> a) -> a -> a
twice f =
    f << f


testValue : Int
testValue =
    twice (makeAdder 1) 0 + twice (adder 3) 1 + List.length (List.map (makeAdder 2) [ 1, 2 ])
"""
      )
    , ( "Higher-order parameters passed through two levels"
      , """outer : (Int -> Int) -> Int -> Int
outer f x =
    inner f (x + 1)


inner : (Int -> Int) -> Int -> Int
inner g y =
    if y > 10 then
        g y

    else
        outer g (y * 2)


testValue : Int
testValue =
    outer (\\z -> z - 1) 1 + outer abs 2
"""
      )
    , ( "Functions destructured from tuples and records"
      , """testValue : Int
testValue =
    let
        ( f, g ) =
            ( \\x -> x + 1, \\x -> x * 2 )

        { h } =
            { h = \\x -> x - 3 }

        fs =
            [ f, g, h ]
    in
    List.foldl (\\fn acc -> fn acc) 5 fs
"""
      )
    ]
