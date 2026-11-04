module SourceIR.CovMonoRefineCases exposing (expectSuite)

{-| Source programs written to reach the number refinement of the solver engine
(`Compiler.Monomorphize.Solver.Translate`, `refineRootInstance` and its
helpers), which finding F2's fix made reachable: number values destructured
through nested constructors, single-field boxes, record patterns, and fields
whose parts share a number variable.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies, so what is checked, and at
which stage, is decided by that function.

Every program is written as Elm source text and parsed with
`Compiler.Parse.Module.fromByteString`; a text that does not parse fails its
case with the message "fixture failed to parse". Each is a module named
`Test` that defines `testValue`. Its imports, including the default ones the
parser adds, are replaced by those of `makeKernelModule`: `Basics`, `Maybe`,
`List`, `Elm.JsArray as JsArray`, `String`, `Char`, `Bitwise`, `Tuple`,
`Bytes`, `Bytes.Encode` and `Bytes.Decode`, all exposing everything. A
`port module` gets those of `makePortModule` instead, which add `Array`,
`Json.Encode`, `Json.Decode`, `Platform.Cmd` and `Platform.Sub` to the
standard set.

The cases, by label:

  - "number fields two constructors deep": `Outer (Inner 1 2) 3` destructured
    as `(Outer (Inner x _) _)` with `x` used at `Float`, so the refinement
    navigates through two constructor fields.
  - "number fields inside a single-field box": `Box ( 1, 2 )`, a constructor
    with one field and so unboxed, destructured as `(Box ( v, _ ))` with `v`
    used at `Float`, and the same inside a record field of a box.
  - "a record pattern inside a constructor pattern": `R { v = 4, k = 1 }`
    destructured as `(R { v })`, then `v + 0.5`, so the path ends in a field
    step below a constructor step.
  - "slots sharing a number variable with Maybe, function and unit parts": `T (
    Just 1, \v -> v, 2, () )`: a tuple field whose `Maybe`, function and scalar
    parts share the variable `a`, and a unit part; `n` is used at `Float`, so
    the refinement carries `Float` to the other parts, and the function part is
    applied.
  - "a two-parameter function field and an alias field": `W (\a b -> a + b) (
    1, 2 ) ( 3, () )`, whose fields are `a -> a -> a`, `Pair a` (an alias of `(
    a, a )`) and `( a, () )`; the function is applied at `Float` and the pairs
    are destructured.

All cases run inside one test through `Compiler.BulkCheck.bulkCheck`, which
stops at the first case that fails and reports its label.

-}

import Compiler.AST.SourceBuilder exposing (makeKernelModule, makePortModule, unitExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Compiler.Parse.Module as M
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Mono refine coverage programs " followed by
`condStr`, that passes when `expectFn` passes on every case's program and
otherwise fails with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Mono refine coverage programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each running `expectFn` on its parsed program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, source ) -> { label = label, run = \_ -> runSource expectFn source })
        [ ( "number fields two constructors deep", refineNestedCtors )
        , ( "number fields inside a single-field box", refineUnboxedBox )
        , ( "a record pattern inside a constructor pattern", refineRecordPatternInCtor )
        , ( "slots sharing a number variable with Maybe, function and unit parts", refineSharedVariables )
        , ( "a two-parameter function field and an alias field", refineCurriedField )
        ]


{-| Runs `expectFn` on the program `source` parses to, with its imports
replaced by those of `makeKernelModule`, or of `makePortModule` for a
`port module`, or fails when it does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn source =
    case M.fromByteString M.Application source of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    if String.startsWith "\nport module" source then
                        makePortModule "unused" [] unitExpr

                    else
                        makeKernelModule "unused" unitExpr
            in
            expectFn (Src.Module { m | imports = template.imports })

        Err _ ->
            Expect.fail "fixture failed to parse"



{-| `Outer (Inner 1 2) 3` destructured as `(Outer (Inner x _) _)` with `x` used at
`Float`, so the refinement navigates through two constructor fields.
-}
refineNestedCtors : String
refineNestedCtors =
    """
module Test exposing (..)


type Inner a
    = Inner a Int


type Outer a
    = Outer (Inner a) Int


testValue : Float
testValue =
    let
        o =
            Outer (Inner 1 2) 3

        (Outer (Inner x _) _) =
            o
    in
    x + 0.5
"""


{-| `Box ( 1, 2 )`, a constructor with one field and so unboxed, destructured as
`(Box ( v, _ ))` with `v` used at `Float`, and the same inside a record field
of a box.
-}
refineUnboxedBox : String
refineUnboxedBox =
    """
module Test exposing (..)


type Box a
    = Box ( a, Int )


type RBox a
    = RBox { inner : ( a, Int ) }


testValue : Float
testValue =
    let
        b =
            Box ( 1, 2 )

        (Box ( v, _ )) =
            b

        rb =
            RBox { inner = ( 3, 4 ) }

        (RBox r) =
            rb

        ( w, _ ) =
            r.inner
    in
    v + w + 0.5
"""


{-| `R { v = 4, k = 1 }` destructured as `(R { v })`, then `v + 0.5`, so the path
ends in a field step below a constructor step.
-}
refineRecordPatternInCtor : String
refineRecordPatternInCtor =
    """
module Test exposing (..)


type R a
    = R { v : a, k : Int }


testValue : Float
testValue =
    let
        rr =
            R { v = 4, k = 1 }

        (R { v }) =
            rr
    in
    v + 0.5
"""


{-| `T ( Just 1, \v -> v, 2, () )`: a tuple field whose `Maybe`, function and
scalar parts share the variable `a`, and a unit part; `n` is used at `Float`,
so the refinement carries `Float` to the other parts, and the function part is
applied.
-}
refineSharedVariables : String
refineSharedVariables =
    """
module Test exposing (..)


type T a
    = T ( Maybe a, a -> a, a ) ()


testValue : Float
testValue =
    let
        t =
            T ( Just 1, \\v -> v, 2 ) ()

        (T ( m, f, n ) _) =
            t
    in
    n
        + f 0.5
        + (case m of
            Just z ->
                z

            Nothing ->
                0
          )
"""


{-| `W (\a b -> a + b) ( 1, 2 ) ( 3, () )`, whose fields are `a -> a -> a`, `Pair
a` (an alias of `( a, a )`) and `( a, () )`; the function is applied at `Float`
and the pairs are destructured.
-}
refineCurriedField : String
refineCurriedField =
    """
module Test exposing (..)


type alias Pair a =
    ( a, a )


type W a
    = W (a -> a -> a) (Pair a) ( a, () )


testValue : Float
testValue =
    let
        w =
            W (\\a b -> a + b) ( 1, 2 ) ( 3, () )

        (W f ( p, _ ) ( q, _ )) =
            w
    in
    f 0.5 p + q
"""
