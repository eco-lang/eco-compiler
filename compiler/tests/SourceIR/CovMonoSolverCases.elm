module SourceIR.CovMonoSolverCases exposing (expectSuite)

{-| Source programs written to reach the solver monomorphization engine
(`Compiler.Monomorphize.Solver.*`) on shapes the rest of the catalogue does
not give it: cycles with tail-recursive members, an extensible record inside a
constructor, functions held in data, accessor values (including one passed
through a tail call), an unused local tail-recursive function and literals
typed through aliases.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies, so what is checked, and at
which stage, is decided by that function.

Every program is written as Elm source text and parsed with
`Compiler.Parse.Module.fromByteString`; a text that does not parse fails its
case with the message "fixture failed to parse". Each is a module named
`Test` that defines `testValue`. Its imports, including the default ones the
parser adds, are replaced by those of `makeKernelModule`: `Basics`, `Maybe`,
`List`, `Elm.JsArray as JsArray`, `String`, `Char`, `Bitwise`, `Tuple`,
`Bytes`, `Bytes.Encode` and `Bytes.Decode`, all exposing everything.

The cases, by label:

  - "cycle with a tail-recursive member": Two cycles that each contain a
    tail-recursive member: `countDown` and `finish`, and `loopFn`, annotated
    `Int -> Fn` with `Fn` an alias of `Int -> Int` and written with two
    parameters, and `other`.
  - "extensible record inside a constructor": `W a` wraps the extensible record
    `{ a | x : Int }`, and `getX` reads `x` from it at two record types.
  - "functions stored in data": Functions stored in constructor fields, a list,
    a record, a tuple and a `Maybe`, and applied after being taken out.
  - "accessors of function-typed fields": Accessors of the function-typed
    fields of `Ops`, which specialization leaves as accessor values: bound to
    locals, held in records, joined across `if` branches (the same field, two
    different fields, and records of accessors), applied with more arguments
    than one, and put in a list.
  - "unused local tail-recursive function": A `let` binds a tail-recursive `go`
    that the body never calls, next to a used one, so one local tail-recursive
    function is translated with no recorded instance.
  - "literals typed by aliases": List, record and tuple literals annotated
    through aliases, plain and parameterized (`Ints`, `R`, `P`, `Pair a`, `Box
    a`), nested in each other.
  - "accessor values passed through a tail call": A local tail-recursive `loop`
    takes a field accessor of a function-typed field as an argument and
    tail-calls itself with it, so the accessor value reaches a position the
    accessor rewrite gives no expected type; `(getF ops) 3` applies an accessor
    local to the record alone first.

All cases run inside one test through `Compiler.BulkCheck.bulkCheck`, which
stops at the first case that fails and reports its label.

-}

import Compiler.AST.SourceBuilder exposing (makeKernelModule, unitExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Compiler.Parse.Module as M
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Mono solver coverage programs " followed by
`condStr`, that passes when `expectFn` passes on every case's program and
otherwise fails with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Mono solver coverage programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each running `expectFn` on its parsed program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, source ) -> { label = label, run = \_ -> runSource expectFn source })
        [ ( "cycle with a tail-recursive member", cycleTailMember )
        , ( "extensible record inside a constructor", extensibleRecordCtorField )
        , ( "functions stored in data", functionsInData )
        , ( "accessors of function-typed fields", accessorValuesOfFunctionFields )
        , ( "unused local tail-recursive function", unusedLocalTailDef )
        , ( "literals typed by aliases", aliasTypedLiterals )
        , ( "accessor values passed through a tail call", accessorInTailCall )
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
            Expect.fail "fixture failed to parse"



{-| Two cycles that each contain a tail-recursive member: `countDown` and `finish`,
and `loopFn`, annotated `Int -> Fn` with `Fn` an alias of `Int -> Int` and
written with two parameters, and `other`.
-}
cycleTailMember : String
cycleTailMember =
    """
module Test exposing (..)


type alias Fn =
    Int -> Int


countDown : Int -> Int -> Int
countDown n acc =
    if n <= 0 then
        finish acc

    else
        countDown (n - 1) (acc + n)


finish : Int -> Int
finish acc =
    if acc > 100 then
        countDown 1 (acc - 100)

    else
        acc


loopFn : Int -> Fn
loopFn n x =
    if n <= 0 then
        other x

    else
        loopFn (n - 1) (x + 1)


other : Int -> Int
other x =
    if x > 10 then
        loopFn 0 (x - 10)

    else
        x


testValue : Int
testValue =
    countDown 5 0 + loopFn 2 3
"""


{-| `W a` wraps the extensible record `{ a | x : Int }`, and `getX` reads `x` from
it at two record types.
-}
extensibleRecordCtorField : String
extensibleRecordCtorField =
    """
module Test exposing (..)


type W a
    = W { a | x : Int }


getX : W a -> Int
getX w =
    case w of
        W r ->
            r.x


testValue : Int
testValue =
    getX (W { x = 1, y = 2 }) + getX (W { x = 3, z = "s" })
"""


{-| Functions stored in constructor fields, a list, a record, a tuple and a
`Maybe`, and applied after being taken out.
-}
functionsInData : String
functionsInData =
    """
module Test exposing (..)


type Op
    = Unary (Int -> Int)
    | Binary (Int -> Int -> Int)
    | Const Int


apply : Op -> Int -> Int
apply op x =
    case op of
        Unary f ->
            f x

        Binary g ->
            g x x

        Const c ->
            c


ops : List Op
ops =
    [ Unary (\\a -> a + 1), Binary (\\a b -> a * b), Const 3, Unary negate ]


table : { inc : Int -> Int, dbl : Int -> Int }
table =
    { inc = \\a -> a + 1, dbl = \\a -> a * 2 }


pick : Bool -> ( Int -> Int, Int -> Int ) -> Int -> Int
pick b ( f, g ) =
    if b then
        f

    else
        g


testValue : Int
testValue =
    List.foldl (\\op acc -> acc + apply op 2) 0 ops
        + table.inc 1
        + table.dbl 2
        + pick True ( table.inc, table.dbl ) 5
        + (case Just table.dbl of
            Just h ->
                h 3

            Nothing ->
                0
          )
"""


{-| Accessors of the function-typed fields of `Ops`, which specialization leaves as
accessor values: bound to locals, held in records, joined across `if` branches
(the same field, two different fields, and records of accessors), applied with
more arguments than one, and put in a list.
-}
accessorValuesOfFunctionFields : String
accessorValuesOfFunctionFields =
    """
module Test exposing (..)


type alias Ops =
    { f : Int -> Int, h : Int -> Int, g : Int -> Int -> Int }


ops : Ops
ops =
    { f = \\x -> x + 1, h = \\x -> x * 2, g = \\a b -> a + b }


choose : Bool -> Int
choose c =
    let
        getF =
            .f

        held =
            { inner = .g }

        same =
            if c then
                .f

            else
                .f

        different =
            if c then
                .f

            else
                .h

        records =
            if c then
                { a = .f, b = .h }

            else
                { a = .f, b = .f }

        mixed =
            if c then
                { a = .f }

            else
                { a = .h }
    in
    getF ops 3
        + .g ops 1 2
        + held.inner ops 4 5
        + same ops 6
        + different ops 7
        + records.a ops 8
        + records.b ops 9
        + mixed.a ops 10
        + List.foldl (\\k acc -> k ops acc) 0 [ .f, .h ]


testValue : Int
testValue =
    choose True + choose False
"""


{-| A `let` binds a tail-recursive `go` that the body never calls, next to a used
one, so one local tail-recursive function is translated with no recorded
instance.
-}
unusedLocalTailDef : String
unusedLocalTailDef =
    """
module Test exposing (..)


testValue : Int
testValue =
    let
        unused n acc =
            if n <= 0 then
                acc

            else
                unused (n - 1) (acc + n)

        used n acc =
            if n <= 0 then
                acc

            else
                used (n - 1) (acc * 2)
    in
    used 3 1
"""


{-| List, record and tuple literals annotated through aliases, plain and
parameterized (`Ints`, `R`, `P`, `Pair a`, `Box a`), nested in each other.
-}
aliasTypedLiterals : String
aliasTypedLiterals =
    """
module Test exposing (..)


type alias Ints =
    List Int


type alias R =
    { a : Int, b : Ints }


type alias P =
    ( Int, R )


type alias Pair a =
    ( a, a )


type alias Box a =
    { v : a, more : List a }


ints : Ints
ints =
    [ 1, 2 ]


rec : R
rec =
    { a = 1, b = [ 3 ] }


pr : P
pr =
    ( 2, { a = 3, b = ints } )


pair : Pair (Box Int)
pair =
    ( { v = 1, more = [ 2 ] }, { v = 3, more = [] } )


testValue : Int
testValue =
    case ( pr, pair ) of
        ( ( x, r ), ( b1, _ ) ) ->
            x + r.a + rec.a + b1.v + List.length rec.b
"""


{-| A local tail-recursive `loop` takes a field accessor of a function-typed field
as an argument and tail-calls itself with it, so the accessor value reaches a
position the accessor rewrite gives no expected type; `(getF ops) 3` applies an
accessor local to the record alone first.
-}
accessorInTailCall : String
accessorInTailCall =
    """
module Test exposing (..)


type alias Ops =
    { f : Int -> Int, h : Int -> Int }


ops : Ops
ops =
    { f = \\x -> x + 1, h = \\x -> x * 2 }


testValue : Int
testValue =
    let
        loop n get acc =
            if n <= 0 then
                acc

            else
                loop (n - 1) get (get ops acc)

        getF =
            .f
    in
    loop 3 .f 0 + loop 2 .h 1 + (getF ops) 3
"""
