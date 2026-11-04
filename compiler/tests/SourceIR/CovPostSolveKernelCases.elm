module SourceIR.CovPostSolveKernelCases exposing (expectSuite)

{-| Programs that use a kernel function as a value rather than calling it: as
an argument of a constructor, as an operand of a pipe operator, as a `case`
branch, and as an argument of another kernel call, so that a caller's check
can be run on the places where `Compiler.Type.PostSolve` gives a bare kernel
reference the type its surroundings expect.

A kernel function is one the runtime implements, written as a qualified
reference such as `Elm.Kernel.Basics.add`. None of the kernels used here has a
declared type for the type checker, so PostSolve records the type of each
from its first use. A bare reference passed to a constructor is given the
constructor's argument type, with the constructor's type variables replaced by
the types the call's own type gives them. Every kernel used is one the
catalogue already uses with the same type: `add` and `sub` of
`Elm.Kernel.Basics` at `Int -> Int -> Int`,
`Elm.Kernel.List.map2`, `Elm.Kernel.List.reverse` and `Elm.Kernel.Tuple.pair`.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies.

Every program is the source text of a module named `Test`, parsed as an
application module, that defines `testValue`. Default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks are dropped. The cases, by
label:

  - "Kernel as a constructor argument": `type Box a = Box a`, and
    `testValue : Box (Int -> Int -> Int)` is `Box Elm.Kernel.Basics.add`.
  - "Kernels as arguments of an aliased constructor": `type Fns a = Fns (Op a)
    ((a -> a -> a) -> List a -> List a -> List a) (a -> a -> ( a, a ))`, with
    `type alias Op a = a -> a -> a` and `type alias IntFns = Fns Int`;
    `testValue : IntFns` passes `add`, `map2` and `pair` to `Fns`.
  - "Repeated kernel and a call among constructor arguments": `type Two =
    Two (Int -> Int -> Int) (Int -> Int -> Int) Int`, and `testValue` is
    `Two add add (add 1 2)`.
  - "Kernel in a partially applied constructor": `type Two2 = Two2 (Int -> Int
    -> Int) Int`, and `testValue : Int -> Two2` is `Two2 add`.
  - "Kernels piped into lambdas": after a `let` that calls `sub`, `testValue`
    adds `sub |> (\f -> f a 1)`, whose kernel by then has a recorded type, to
    `add |> (\f -> f a 2)`, whose kernel has none.
  - "Kernel piped before a called kernel is piped": the same pipes in the
    other order, `add |> (\f -> f a 2)` first. PostSolve used to record the
    type of `|>`'s first parameter in its annotation, the bare variable `a`,
    as `add`'s type, and monomorphization then overflowed the stack (finding
    F1); `add` now gets its node type, `Int -> Int -> Int`.
  - "Kernels as case branches": a local `pick n`, a `case` on `n` whose two
    branches are `add` and `sub`, then `add` again, called as `pick 0 1 2`.
  - "Kernel as a kernel argument": `testValue` is
    `Elm.Kernel.List.map2 add [ 1 ] [ 2 ]`, after a `let` that calls `add` so
    that its type is already recorded, and `List.reverse` of a `map2` with
    `sub`, whose type is not.

All the cases run inside one test through `Compiler.BulkCheck.bulkCheck`,
which stops at the first case that fails and reports its label.

Among what is not tested: a bare kernel reference as a `case` branch without
a call around the `case`, and a kernel called with more arguments than the
type recorded for it.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "PostSolve kernel values " followed by `condStr`,
that passes when `expectFn` passes on every case's program and otherwise fails
with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("PostSolve kernel values " ++ condStr) <|
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
    [ ( "Kernel as a constructor argument"
      , """type Box a = Box a

testValue : Box (Int -> Int -> Int)
testValue = Box Elm.Kernel.Basics.add
"""
      )
    , ( "Kernels as arguments of an aliased constructor"
      , """type alias Op a = a -> a -> a

type Fns a = Fns (Op a) ((a -> a -> a) -> List a -> List a -> List a) (a -> a -> ( a, a ))

type alias IntFns = Fns Int

testValue : IntFns
testValue = Fns Elm.Kernel.Basics.add Elm.Kernel.List.map2 Elm.Kernel.Tuple.pair
"""
      )
    , ( "Repeated kernel and a call among constructor arguments"
      , """type Two = Two (Int -> Int -> Int) (Int -> Int -> Int) Int

testValue : Two
testValue = Two Elm.Kernel.Basics.add Elm.Kernel.Basics.add (Elm.Kernel.Basics.add 1 2)
"""
      )
    , ( "Kernel in a partially applied constructor"
      , """type Two2 = Two2 (Int -> Int -> Int) Int

testValue : Int -> Two2
testValue = Two2 Elm.Kernel.Basics.add
"""
      )
    , ( "Kernels piped into lambdas"
      , """testValue : Int
testValue =
    let
        a = Elm.Kernel.Basics.sub 5 3
    in
    (Elm.Kernel.Basics.sub |> (\\f -> f a 1)) + (Elm.Kernel.Basics.add |> (\\f -> f a 2))
"""
      )
    , ( "Kernel piped before a called kernel is piped"
      , """testValue : Int
testValue =
    let
        a = Elm.Kernel.Basics.sub 5 3
    in
    (Elm.Kernel.Basics.add |> (\\f -> f a 2)) + (Elm.Kernel.Basics.sub |> (\\f -> f 1 1))
"""
      )
    , ( "Kernels as case branches"
      , """testValue : Int
testValue =
    let
        pick : Int -> Int -> Int -> Int
        pick n =
            case n of
                0 ->
                    Elm.Kernel.Basics.add

                1 ->
                    Elm.Kernel.Basics.sub

                _ ->
                    Elm.Kernel.Basics.add
    in
    pick 0 1 2
"""
      )
    , ( "Kernel as a kernel argument"
      , """testValue : List Int
testValue =
    let
        a = Elm.Kernel.Basics.add 1 2
    in
    Elm.Kernel.List.map2 Elm.Kernel.Basics.add [ a ] (Elm.Kernel.List.reverse (Elm.Kernel.List.map2 Elm.Kernel.Basics.sub [ 1 ] [ 2 ]))
"""
      )
    ]
