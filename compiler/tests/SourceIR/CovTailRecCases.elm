module SourceIR.CovTailRecCases exposing (expectSuite)

{-| Programs written so that the MLIR back end's tail-loop compilation
(`Compiler.GenerateMlir.TailRec`) meets parameters it can split into slots
and parameters it must not split: tuple parameters rebuilt, passed unchanged,
bound by a `let`, or replaced by an unknown value in the recursive calls, and recursive calls made from `case` fan-outs, shared
branches, closures and local tail functions.

These cases assert nothing themselves. Each one parses a program from source
text and hands it to the expectation function the caller supplies, so what is
checked, and at which stage, is decided by that function.

The programs are parsed as modules of elm/core (`Parse.Package Pkg.core`), so
they get no default imports and may name `Elm.Kernel.*` functions; every
import is written out in `header`. They compile against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`. Each defines `testValue`.

The cases, by label:

  - "Split a triple parameter": a tail-recursive function whose triple
    parameter is rebuilt in the recursive call and read in the base case.
  - "Pair parameter passed unchanged, let-bound and rebuilt": recursive calls
    that pass the pair parameter itself, a `let`-bound fresh pair, and a pair
    literal, from the branches of a `case` over a custom type of three
    constructors and of a `case` with a shared fallback; the parameter is read
    only by destructuring.
  - "Pair parameter replaced by an unknown value": recursive calls that pass a
    pair returned by a function call, so the parameter is not split, and a pair
    built by a closure call, with the pair rebuilt inside a local tail
    function, whose calls are not counted.
  - "Pair parameters swapped, and a loop returning a lambda": recursive calls
    that pass one pair parameter in the other's place, and a loop over a
    destructured pair whose base case returns a lambda.
  - "Tail function of two parameters returning a function": an annotated
    `f : Int -> Int -> Int -> Int` defined with two parameters, whose base
    case returns a lambda and whose tail call is in the `else` of an `if`, so
    its loop has two parameters while its type flattens to three; it is
    applied to all three arguments, `f 3 0 10`.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Elm.Package as Pkg
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Tail loop coverage " followed by `condStr`, that passes
when `expectFn` passes on every case's program and otherwise fails with the
label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Tail loop coverage " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case of `programs`, in order.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, body ) -> { label = label, run = \_ -> runSource expectFn body })
        programs


{-| Runs `expectFn` on the module parsed from `header` followed by `body`, or
fails when that source does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn body =
    case Parse.fromByteString (Parse.Package Pkg.core) (header ++ body) of
        Ok modul ->
            expectFn modul

        Err _ ->
            Expect.fail ("fixture does not parse:\n" ++ body)


{-| The module header shared by the programs: module `Test` and the imports
they use, all written out because an elm/core module gets no default imports.
-}
header : String
header =
    """module Test exposing (..)

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple

"""


{-| The programs, by label, as the source that follows `header`.
-}
programs : List ( String, String )
programs =
    [ ( "Split a triple parameter"
      , """
rot : Int -> ( Int, Int, Float ) -> Float
rot n ( a, b, c ) =
    if n <= 0 then
        toFloat (a + b) + c

    else
        rot (n - 1) ( b, a + 1, c * 2.0 )


testValue k =
    rot k ( 1, 2, 3.0 )
"""
      )
    , ( "Pair parameter passed unchanged, let-bound and rebuilt"
      , """
type T
    = A
    | B Int
    | C


loop : Int -> T -> ( Int, Int ) -> Int
loop n t p =
    let
        ( x, y ) =
            p
    in
    case t of
        A ->
            if n <= 0 then
                x

            else
                loop (n - 1) C p

        B k ->
            let
                q =
                    ( k, y )
            in
            loop (n - 1) A q

        C ->
            loop (n - 1) (B n) ( y, x )


jumpy : Int -> Maybe Int -> ( Int, Int ) -> Int
jumpy n m p =
    let
        ( x, y ) =
            p
    in
    case m of
        Just 1 ->
            jumpy (n - 1) Nothing ( y, x )

        Just 2 ->
            jumpy (n - 1) (Just 1) ( 1, 2 )

        _ ->
            if n <= 0 then
                x + y

            else
                jumpy (n - 1) (Just 2) p


testValue k =
    ( loop k A ( 1, 2 ), jumpy k (Just 3) ( 3, 4 ) )
"""
      )
    , ( "Pair parameter replaced by an unknown value"
      , """
swap : ( Int, Int ) -> ( Int, Int )
swap ( a, b ) =
    ( b, a )


loop : Int -> ( Int, Int ) -> Int
loop n p =
    let
        ( x, y ) =
            p
    in
    if n <= 0 then
        x

    else if n == 5 then
        loop (n - 1) ( y, x )

    else
        loop (n - 1) (swap p)


inner : Int -> ( Int, Int ) -> Int
inner n p =
    let
        ( x, y ) =
            p

        go k q =
            if k <= 0 then
                k

            else
                go (k - 1) ( y, k )

        f =
            \\z -> ( z, z )
    in
    if n <= 0 then
        go 3 ( x, y ) + x

    else if n == 5 then
        inner (n - 1) ( y, x )

    else
        inner (n - 1) (f n)


testValue k =
    ( loop k ( 1, 2 ), inner k ( 3, 4 ) )
"""
      )
    , ( "Pair parameters swapped, and a loop returning a lambda"
      , """
alt : Int -> ( Int, Int ) -> ( Int, Int ) -> Int
alt n p q =
    let
        ( a, b ) =
            p

        ( c, d ) =
            q
    in
    if n <= 0 then
        a + b + c + d

    else if n == 3 then
        alt (n - 1) ( b, a ) q

    else
        alt (n - 1) q p


toFn : Int -> ( Int, Int ) -> (Int -> Int)
toFn n p =
    let
        ( a, b ) =
            p
    in
    if n <= 0 then
        \\z -> z + a + b

    else
        toFn (n - 1) ( b, a + 1 )


testValue k =
    ( alt k ( 1, 2 ) ( 3, 4 ), toFn k ( 5, 6 ) k )
"""
      )
    , ( "Tail function of two parameters returning a function"
      , """
f : Int -> Int -> Int -> Int
f n acc =
    if n == 0 then
        \\x -> x + acc

    else
        f (n - 1) (acc + 1)


testValue : Int
testValue =
    f 3 0 10
"""
      )
    ]
