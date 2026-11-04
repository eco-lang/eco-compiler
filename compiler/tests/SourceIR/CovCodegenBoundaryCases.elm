module SourceIR.CovCodegenBoundaryCases exposing (expectSuite)

{-| Programs written so that the MLIR back end meets forms the rest of the
catalogue does not give it: kernel functions passed as values at `Int`,
`Float` and `Char`, whose declarations get a type suffix
(`Compiler.GenerateMlir.KernelAbi.kernelInstanceSymbol`); functions whose
2- or 3-tuple results are promoted to `$sret` workers, and the fixpoints that
choose them (`Compiler.GenerateMlir.Backend.buildSretPromoted`).

These cases assert nothing themselves. Each one parses a program from source
text and hands it to the expectation function the caller supplies.

Every program is the source text of a module named `Test`, parsed as an
application module, that defines `testValue`. Default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks are dropped. A kernel function
has no declared type here, so each reference takes the type of its use, and a
kernel result that nothing fixes stays a type variable, a boxed `!eco.value`.
The cases, by label:

  - "Kernels as values at Float", "... at Char" and "... at Int": lists of the
    `Elm.Kernel.Utils` comparisons, equalities and `compare`, applied in turn
    by a recursive function so that each stays a value, and in each program
    some of: `Elm.Kernel.String.fromNumber`, `Elm.Kernel.List.cons`,
    `Elm.Kernel.Json.wrap`, `Elm.Kernel.Basics.add` and `mul` (with a `Float`
    result fixed by an annotated identity, so that the kernel declaration
    returns `f64`), and the `Elm.Kernel.JsArray` functions `singleton`,
    `push`, `unsafeSet`, `unsafeGet` and `slice`, on an `Elm.Kernel.JsArray.empty`.
    An `Int` index is an annotated `zero`, because a bare literal there stays
    a boxed type variable.
  - "Three-slot result promotion": a recursive function and a tail-recursive
    function returning a 3-tuple of `Int`s, each bound by a `let` at a call.
  - "Promoted results through case jumps": a function and a tail-recursive
    function returning pairs from a `case` on a `Maybe Int` whose default
    branch is reached from two places in the decision tree (a jump).
  - "Promoted result passed to a split parameter": a pair-returning function
    called as the argument of a function that destructures its pair parameter.
  - "Result promotion chain of 40": forty pair-returning functions, each of
    which returns a call of the next, the last a kernel call, so that the
    greatest fixpoint of result promotion does not settle in 31 passes and the
    least fixpoint is used; three more functions form a chain the least
    fixpoint grows by.

All the cases run inside one test through `Compiler.BulkCheck.bulkCheck`,
which stops at the first case that fails and reports its label.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Codegen boundary coverage " followed by `condStr`,
that passes when `expectFn` passes on every case's program and otherwise fails
with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Codegen boundary coverage " ++ condStr) <|
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
            Err ("fixture failed to parse:\n" ++ body)


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The label and the source after the module header of each case.
-}
programs : List ( String, String )
programs =
    [ ( "Kernels as values at Float"
      , kernelValuesAt "1.5"
            "2.5"
            [ "applyAll1 [ Elm.Kernel.String.fromNumber ] 2.5"
            , "applyAll2 [ Elm.Kernel.List.cons ] 1.5 [ 2.5 ]"
            , "applyAll1 [ Elm.Kernel.JsArray.singleton ] 1.5"
            , "applyAll2 [ Elm.Kernel.JsArray.push ] 1.5 arr"
            , "asFloats (applyAll2 [ Elm.Kernel.Basics.add, Elm.Kernel.Basics.mul ] 1.5 2.5)"
            ]
      )
    , ( "Kernels as values at Char"
      , kernelValuesAt "'a'"
            "'b'"
            [ "applyAll2 [ Elm.Kernel.List.cons ] 'a' [ 'b' ]"
            , "applyAll1 [ Elm.Kernel.Json.wrap ] 'c'"
            , "applyAll1 [ Elm.Kernel.JsArray.singleton ] 'a'"
            , "applyAll2 [ Elm.Kernel.JsArray.push ] 'a' arr"
            , "applyAll3 [ Elm.Kernel.JsArray.unsafeSet ] 0 'z' arr"
            ]
      )
    , ( "Kernels as values at Int"
      , kernelValuesAt "1"
            "2"
            [ "applyAll1 [ Elm.Kernel.JsArray.singleton ] 1"
            , "applyAll2 [ Elm.Kernel.JsArray.push ] 1 arr"
            , "applyAll3 [ Elm.Kernel.JsArray.unsafeSet ] 0 7 arr"
            , "applyAll2 [ Elm.Kernel.JsArray.unsafeGet ] zero arr"
            , "applyAll3 [ Elm.Kernel.JsArray.slice ] zero (zero + 1) arr"
            ]
      )
    , ( "Three-slot result promotion", threeSlot )
    , ( "Promoted results through case jumps", caseJumps )
    , ( "Promoted result passed to a split parameter", sretIntoSplit )
    , ( "Result promotion chain of 40", promotionChain 40 )
    ]


{-| Helper definitions: `applyAll1`, `applyAll2` and `applyAll3`, recursive
functions that apply each function of a list to the same one, two or three
arguments, so that the functions are values, not callees; `zero`, an `Int`;
and `asFloats`, an identity on `List Float`.
-}
applyAll2 : String
applyAll2 =
    """applyAll2 : List (a -> b -> c) -> a -> b -> List c
applyAll2 fs x y =
    case fs of
        [] ->
            []

        f :: rest ->
            f x y :: applyAll2 rest x y


applyAll1 : List (a -> b) -> a -> List b
applyAll1 fs x =
    case fs of
        [] ->
            []

        f :: rest ->
            f x :: applyAll1 rest x


zero : Int
zero =
    0


asFloats : List Float -> List Float
asFloats xs =
    xs


applyAll3 : List (a -> b -> c -> d) -> a -> b -> c -> List d
applyAll3 fs x y z =
    case fs of
        [] ->
            []

        f :: rest ->
            f x y z :: applyAll3 rest x y z

"""


{-| A program whose `testValue` applies the comparison and equality kernels,
as values, to `x` and `y`, and then holds each expression of `uses`, nested in
pairs, in a `let` that binds `arr` to `Elm.Kernel.JsArray.empty`.
-}
kernelValuesAt : String -> String -> List String -> String
kernelValuesAt x y uses =
    applyAll2
        ++ """
testValue =
    let
        arr =
            Elm.Kernel.JsArray.empty
    in
    ( applyAll2
        [ Elm.Kernel.Utils.equal
        , Elm.Kernel.Utils.notEqual
        , Elm.Kernel.Utils.lt
        , Elm.Kernel.Utils.le
        , Elm.Kernel.Utils.gt
        , Elm.Kernel.Utils.ge
        ]
        """
        ++ x
        ++ " "
        ++ y
        ++ "\n    , applyAll2 [ Elm.Kernel.Utils.compare ] "
        ++ x
        ++ " "
        ++ y
        ++ "\n    , "
        ++ nestPairs uses
        ++ "\n    )\n"


{-| Nests expressions in pairs, `( e1, ( e2, ( ... ) ) )`, so that they can have
different types.
-}
nestPairs : List String -> String
nestPairs exprs =
    case exprs of
        [] ->
            "()"

        [ e ] ->
            e

        e :: rest ->
            "( " ++ e ++ ", " ++ nestPairs rest ++ " )"


{-| A recursive function and a tail-recursive function with 3-tuple results,
each called at a `let`.
-}
threeSlot : String
threeSlot =
    """triple : Int -> ( Int, Int, Int )
triple n =
    if n <= 0 then
        ( 0, 1, 2 )

    else
        let
            ( a, b, c ) =
                triple (n - 1)
        in
        ( a + 1, b * 2, c + n )


loop3 : Int -> Int -> ( Int, Int, Int )
loop3 n acc =
    if n <= 0 then
        ( acc, n, 7 )

    else
        loop3 (n - 1) (acc + n)


testValue =
    let
        ( x, y, z ) =
            triple 5

        ( p, q, r ) =
            loop3 4 0
    in
    x + y + z + p + q + r
"""


{-| Pair results from a `case` whose decision tree reaches the default branch
from two places, in a function and in a tail-recursive function.
-}
caseJumps : String
caseJumps =
    """classify : Maybe Int -> Int -> ( Int, Int )
classify m b =
    case m of
        Just 1 ->
            ( 1, 1 )

        Just 2 ->
            ( 2, b )

        _ ->
            ( b * 3, b * 5 )


classifyRec : Maybe Int -> Int -> ( Int, Int )
classifyRec m b =
    if b > 100 then
        let
            ( u, v ) =
                classifyRec m (b - 7)
        in
        ( u + 1, v )

    else
        classify m b


walk : Maybe Int -> Int -> ( Int, Int )
walk m b =
    case m of
        Just 1 ->
            ( 1, 1 )

        Just 2 ->
            walk Nothing (b - 1)

        _ ->
            ( b * 3, b * 5 )


testValue =
    let
        ( s, t ) =
            classifyRec (Just 2) 1

        ( u, v ) =
            walk (Just 3) 2

        ( w, x ) =
            classify Nothing 4

        ( y, z ) =
            walk Nothing 7
    in
    s + t + u + v + w + x + y + z
"""


{-| A pair-returning recursive function called, at a `let` and as the argument
of a function that destructures its pair parameter.
-}
sretIntoSplit : String
sretIntoSplit =
    """mk : Int -> ( Int, Int )
mk x =
    if x > 10 then
        ( x, 1 )

    else
        let
            ( a, b ) =
                mk (x + 1)
        in
        ( a, b + 1 )


weigh : ( Int, Int ) -> Int
weigh ( a, b ) =
    if a <= 0 then
        b

    else
        1 + weigh ( a - 1, b )


testValue =
    let
        ( p, q ) =
            mk 3
    in
    weigh (mk 4) + p + q
"""


{-| `n` pair-returning functions `f1` to `fn`. Each binds a call of itself at a
`let`, so that each has a let-bound call site, and returns a call of the next;
the last returns a kernel call. Three more, `g1` to `g3`, form a chain whose
last returns only tuple literals.
-}
promotionChain : Int -> String
promotionChain n =
    let
        name i =
            "f" ++ String.fromInt i

        link i =
            let
                tailLeaf =
                    if i == n then
                        "Elm.Kernel.Tuple.pair x x"

                    else
                        name (i + 1) ++ " (x + 2)"
            in
            name i
                ++ " : Int -> ( Int, Int )\n"
                ++ name i
                ++ " x =\n    if x > 1000 then\n        let\n            ( a, b ) =\n                "
                ++ name i
                ++ " (x - 1)\n        in\n        ( a + "
                ++ String.fromInt i
                ++ ", b )\n\n    else\n        "
                ++ tailLeaf
                ++ "\n\n\n"
    in
    String.concat (List.map link (List.range 1 n))
        ++ """g1 : Int -> ( Int, Int )
g1 x =
    if x > 1000 then
        let
            ( a, b ) =
                g1 (x - 1)
        in
        ( a + 1, b )

    else
        g2 (x + 1)


g2 : Int -> ( Int, Int )
g2 x =
    if x > 1000 then
        let
            ( a, b ) =
                g2 (x - 1)
        in
        ( a + 2, b )

    else
        g3 (x + 1)


g3 : Int -> ( Int, Int )
g3 x =
    if x > 1000 then
        let
            ( a, b ) =
                g3 (x - 1)
        in
        ( a + 3, b )

    else
        ( x, x * 2 )


scale : Int -> Int
scale x =
    if x > 1000 then
        let
            y =
                scale (x - 1)
        in
        y + 1

    else
        x * 3


testValue =
    let
        ( a, b ) =
            f1 0

        ( c, d ) =
            g1 0

        e =
            scale 2
    in
    a + b + c + d + e
"""
