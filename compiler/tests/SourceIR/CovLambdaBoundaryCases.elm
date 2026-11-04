module SourceIR.CovLambdaBoundaryCases exposing (expectSuite)

{-| Functions whose body is a `case` or a `let` between two lambdas, built so
that a caller's check can be run on the merging of such lambdas by
`Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries`, and in particular on the
renaming of a branch's parameter into the shared parameter of the merged
lambda in every kind of expression and pattern a branch body can hold.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies.

Every program is the source text of a module named `Test`, parsed as an
application module, that defines `testValue`. Default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks are dropped. The cases, by
label:

  - "Case boundary over every expression kind": `pick n` is a `case` on `n`
    whose two branches are lambdas over a record `p`, typed `{ x : Int, y : Int }`
    in the annotation. The first branch's body
    destructures `p` and its fields in `let`s and uses them in a boolean, a
    character, a float, an enumeration constructor, a single-constructor box
    and its destructuring, a list, a nested lambda, a local tail-recursive
    function, an `if`, a `case` on the enumeration, an accessor, a field
    access, a record update, a record, a unit, a tuple and a kernel call.
    The second branch maps a lambda over a list, builds a record literal and
    calls `helper`, which calls `pick` back, so the two form a recursive
    group.
  - "Case boundary in a recursive value": `pickV` is defined without
    parameters, as a lambda whose body is a `case` between lambdas, and one
    branch calls `pickV` again, so the renamed branch refers to a value of its
    own recursive group.
  - "Case boundary under a function alias": `choose : Int -> F`, with
    `type alias F = Int -> Int`, is a `case` with a lambda in each branch, a
    boundary the merge leaves alone because it does not look through the
    alias. Each lambda's node type is the `TLambda` chain `Int -> Int`, not
    `TAlias F` (POST\_007, finding F3).
  - "Lambda over an aliased record": `f : P -> Int` and `g : P -> P`, with
    `type alias P = { x : Int, y : Int }`, are lambdas whose parameter is used
    as a record. Each lambda's node type is built from its parameter's and
    body's own types, so it agrees with them (POST\_007, finding F3).
  - "Let boundary under a tracked lambda": a top-level function whose body is
    a `let` around a lambda, applied in full.
  - "Case boundary with inline lambdas": a `case` on a `Maybe` whose two
    branches are lambdas with one parameter, each reached from one leaf of the
    decision tree.

All the cases run inside one test through `Compiler.BulkCheck.bulkCheck`,
which stops at the first case that fails and reports its label.

Among what is not tested: a shader in a renamed branch body.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Lambda boundaries " followed by `condStr`, that
passes when `expectFn` passes on every case's program and otherwise fails with
the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Lambda boundaries " ++ condStr) <|
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
    [ ( "Case boundary over every expression kind"
      , """type Color
    = Red
    | Green
    | Blue


type Box
    = Box Int


pick : Int -> { x : Int, y : Int } -> ( Int, { x : Int, y : Int } )
pick n =
    case n of
        0 ->
            \\p ->
                let
                    ( u, v ) =
                        ( p.x, p.y )

                    { x } =
                        p

                    go k acc =
                        if k <= 0 then
                            acc

                        else
                            go (k - 1) (acc + 1)

                    q =
                        { p | x = u }

                    r =
                        { x = v, y = x }

                    flag =
                        p.x > 0 && True

                    c =
                        'c'

                    fl =
                        1.5 + toFloat p.y

                    col =
                        if flag then
                            Red

                        else
                            Blue

                    bx =
                        Box p.x

                    (Box inner) =
                        bx

                    xs =
                        [ p.x, 2 ]

                    getX =
                        .x

                    f =
                        \\z -> z + u

                    w =
                        case col of
                            Red ->
                                1

                            Green ->
                                2

                            Blue ->
                                3

                    unit =
                        ()

                    kn =
                        Elm.Kernel.Basics.add p.x 1
                in
                ( go u 0 + getX q + f v + w + inner + List.length xs + round fl + kn + (if c == 'c' then 1 else 0), r )

        _ ->
            \\p2 -> ( List.length (List.map (\\z -> z + p2.x) [ 1 ]), { x = p2.y, y = Tuple.first (helper p2) } )


helper : { x : Int, y : Int } -> ( Int, { x : Int, y : Int } )
helper p =
    if p.x > 0 then
        pick 0 { p | x = 0 }

    else
        ( 0, p )


testValue : Int
testValue =
    Tuple.first (pick 1 { x = 1, y = 2 })
"""
      )
    , ( "Case boundary in a recursive value"
      , """pickV : Int -> Int -> Int
pickV =
    \\n ->
        case n of
            0 ->
                \\a ->
                    if a > 10 then
                        pickV 1 a

                    else
                        a + 1

            _ ->
                \\b -> b


testValue : Int
testValue =
    pickV 0 3
"""
      )
    , ( "Let boundary under a tracked lambda"
      , """scaled : Int -> Int -> Int
scaled factor =
    let
        twice =
            factor * 2
    in
    \\v -> v * twice


testValue : Int
testValue =
    scaled 2 5
"""
      )
    , ( "Case boundary with inline lambdas"
      , """orZero : Maybe Int -> Int -> Int
orZero m =
    case m of
        Just j ->
            \\d -> j + d

        Nothing ->
            \\e -> e


testValue : Int
testValue =
    orZero (Just 1) 2 + orZero Nothing 3
"""
      )
    , ( "Case boundary under a function alias"
      , """type alias F =
    Int -> Int


choose : Int -> F
choose n =
    case n of
        0 ->
            \\a -> a + 1

        _ ->
            \\b -> b * 2


testValue : Int
testValue =
    choose 0 3
"""
      )
    , ( "Lambda over an aliased record"
      , """type alias P =
    { x : Int, y : Int }


f : P -> Int
f =
    \\p -> p.x + p.y


g : P -> P
g =
    \\p -> { p | x = 1 }


testValue : Int
testValue =
    f (g { x = 2, y = 3 })
"""
      )
    ]
