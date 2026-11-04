module SourceIR.CovPreMonoCases exposing (expectSuite)

{-| Source programs written to reach the pre-monomorphization passes
(`Compiler.PreMono.*`) on shapes the rest of the catalogue does not give them,
chiefly the definitions that η-expansion rewrites and so hands to
`Compiler.PreMono.Fresh.mintNewNode`.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies, so what is checked, and at
which stage, is decided by that function.

Every program is written as Elm source text and parsed with
`Compiler.Parse.Module.fromByteString`; a text that does not parse fails its
case with the message "fixture failed to parse". Each is a module named `Test`
that defines `testValue`; its imports, including the default ones the parser
adds, are replaced by those of `makeModule`, `Basics` and `List`. Most of them
declare `type alias Fn = Int -> Int`, so that a definition annotated
`Int -> Fn` but written with one parameter has a deficit of one and is
η-expanded.

The cases, by label:

  - "eta-expanded body holding every leaf kind": `mk`, annotated `Int -> Fn`
    and written with one parameter, is a `let` around a local function `h`
    whose body holds a character, a float, an enumeration constructor, a
    single-constructor box, a local tail-recursive function and its tail call.
    η-expansion mints the whole rewritten body, so each of those node kinds
    passes through `mintExpr`.
  - "eta-expanded cycle members": `ping` and `pong`, annotated `Int -> Fn`,
    call each other, so they form a cycle. Each is a `case` whose branches end
    in a partial application of `add` or a call of the other, and both gain a
    parameter.
  - "eta-expanded cycle values": `viaCall`, annotated `Fn`, and `viaLambda`, a
    lambda annotated `Int -> Int -> Int`, are zero-argument members of a cycle
    with the function `step`. Both have a deficit, which is counted but not
    expanded.
  - "constructor alias and saturated call returning a function": `mkBox` and
    `mkPair` are defined as bare constructors, and are left alone as
    constructor aliases. `mk`, annotated `Int -> Fn`, is a saturated call of
    `pick : Int -> a -> a` whose second argument is a partial application,
    so the new argument is applied to the call from outside.
  - "parameterized function alias": a state-monad style program over
    `State a = Int -> ( a, Int )`, with `andThen` and `get` written at the
    alias's arity and a `let`-bound helper annotated with the alias.
  - "cheap let chain before a partial application": `mk` is a `let` chain of
    cheap bindings (an enumeration constructor, a record, an update, a field
    access, a float, a character and a tuple destructuring) around a `case`
    whose branches are partial applications, so it is expanded; `loop` binds
    a local tail-recursive function first, which is not cheap, so it is not.

  - "lambda at a function alias": `pong : Int -> Fn`, with
    `type alias Fn = Int -> Int`, returns one of two lambda literals at the
    alias's type. Before finding F3 was fixed each lambda's node type was
    `TAlias Fn`, breaking POST\_007; it is now the `TLambda` chain
    `Int -> Int`.

  - "recursive lambda at a function alias": `ping : Int -> Fn` returns a
    lambda in one branch and calls itself in the other, the program finding
    F3 was found with. Its call `ping 3 4` passes more arguments than `ping`
    has parameters; before finding F6 was fixed, global optimization claimed
    the stages of `ping`'s result from its type through that join, breaking
    GOPT\_003.

All cases run inside one test through `Compiler.BulkCheck.bulkCheck`, which
stops at the first case that fails and reports its label.

Among what is not tested: the pre-mono inliner
(`Compiler.PreMono.InlineSimplify`), which runs only under `inline.preMono`,
`Fresh.assertMinted`, which runs only under `mono.validate`, and a declared
arity over `HeapLimits.maxStageArity`, whose 2,048-arrow type makes every
suite take minutes.

-}

import Compiler.AST.SourceBuilder exposing (makeModule, unitExpr)
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Compiler.Parse.Module as M
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Pre-mono coverage programs " followed by
`condStr`, that passes when `expectFn` passes on every case's program and
otherwise fails with the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Pre-mono coverage programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each running `expectFn` on its parsed program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, source ) -> { label = label, run = \_ -> runSource expectFn source })
        [ ( "eta-expanded body holding every leaf kind", etaLeafKinds )
        , ( "eta-expanded cycle members", etaCycleMembers )
        , ( "eta-expanded cycle values", etaCycleValues )
        , ( "constructor alias and saturated call returning a function", etaCtorAliasAndSaturatedCall )
        , ( "parameterized function alias", etaParameterizedAlias )
        , ( "cheap let chain before a partial application", etaCheapLetChain )
        , ( "lambda at a function alias", lambdaAtFunctionAliasNonRecursive )
        , ( "recursive lambda at a function alias", lambdaAtFunctionAlias )
        ]


{-| Runs `expectFn` on the program `source` parses to, or fails when it does
not parse. The parsed module's imports, including the parser's default ones,
are replaced by those of `makeModule`, `Basics` and `List`.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn source =
    case M.fromByteString M.Application source of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    makeModule "unused" unitExpr
            in
            expectFn (Src.Module { m | imports = template.imports })

        Err _ ->
            Expect.fail "fixture failed to parse"



-- ============================================================================
-- ETA EXPANSION
-- ============================================================================


{-| A definition with a deficit of one whose body holds a character, a float,
an enumeration constructor, a box constructor and a local tail-recursive
function.
-}
etaLeafKinds : String
etaLeafKinds =
    """
module Test exposing (..)


type Color
    = Red
    | Green
    | Blue


type Box
    = Box Int


type alias Fn =
    Int -> Int


mk : Int -> Fn
mk n =
    let
        h z =
            let
                go acc k =
                    if k <= 0 then
                        acc

                    else
                        go (acc + k) (k - 1)

                c =
                    'x'

                f =
                    1.5

                col =
                    Green

                b =
                    Box z
            in
            case ( col, b ) of
                ( Green, Box v ) ->
                    go v n + floor f

                _ ->
                    if c == 'x' then
                        0

                    else
                        1
    in
    h


testValue : Int
testValue =
    mk 3 4
"""


{-| Two mutually recursive definitions, each with a deficit of one, whose
branches end in a partial application of `add`.
-}
etaCycleMembers : String
etaCycleMembers =
    """
module Test exposing (..)


type alias Fn =
    Int -> Int


add : Int -> Int -> Int
add a b =
    a + b


ping : Int -> Fn
ping n =
    case n of
        0 ->
            add 1

        _ ->
            pong 0


pong : Int -> Fn
pong n =
    case n of
        0 ->
            add 2

        _ ->
            ping 0


testValue : Int
testValue =
    ping 3 4
"""


{-| A recursive function returning a lambda literal at the type `Fn`, an alias
of a function type: the program finding F3 was found with, and an instance of
finding F6.
-}
lambdaAtFunctionAlias : String
lambdaAtFunctionAlias =
    """
module Test exposing (..)


type alias Fn =
    Int -> Int


ping : Int -> Fn
ping n =
    if n <= 0 then
        \\x -> x

    else
        ping (n - 1)


testValue : Int
testValue =
    ping 3 4
"""


{-| Two lambda literals returned at the type `Fn`, an alias of a function type.
Each lambda's node type must be the `TLambda` chain `Int -> Int`, not
`TAlias Fn` (POST\_007, finding F3).
-}
lambdaAtFunctionAliasNonRecursive : String
lambdaAtFunctionAliasNonRecursive =
    """
module Test exposing (..)


type alias Fn =
    Int -> Int


pong : Int -> Fn
pong n =
    if n <= 0 then
        \\x -> x

    else
        \\x -> x + n


testValue : Int
testValue =
    pong 3 4
"""


{-| Two cycle values, zero-argument definitions annotated `Fn` that refer to
the cycle function `step`: `viaCall` is a call of `step`, and `viaLambda` is a
lambda of one parameter annotated `Int -> Int -> Int`. Both have a deficit,
which is counted but not expanded.
-}
etaCycleValues : String
etaCycleValues =
    """
module Test exposing (..)


type alias Fn =
    Int -> Int


viaCall : Fn
viaCall =
    step 1


viaLambda : Int -> Int -> Int
viaLambda =
    \\k -> step k


step : Int -> Int -> Int
step k x =
    case k of
        0 ->
            x

        _ ->
            viaCall x + viaLambda 0 x


testValue : Int
testValue =
    step 2 3
"""


{-| `mkBox`, annotated `Int -> Box` and defined as the bare constructor `Box`,
and `mkPair`, defined as the two-field constructor `Pair`, are constructor
aliases and are not expanded. `mk`, annotated `Int -> Fn`, is a
saturated call of `pick`, whose declared arity is two, with a partial
application as its second argument: the new argument cannot be merged into the
call, so the call is applied to it from outside.
-}
etaCtorAliasAndSaturatedCall : String
etaCtorAliasAndSaturatedCall =
    """
module Test exposing (..)


type Box
    = Box Int


type Pair
    = Pair Int Int


type alias Fn =
    Int -> Int


mkBox : Int -> Box
mkBox =
    Box


mkPair : Int -> Int -> Pair
mkPair =
    Pair


add : Int -> Int -> Int
add a b =
    a + b


pick : Int -> a -> a
pick _ x =
    x


mk : Int -> Fn
mk n =
    pick n (add n)


testValue : Int
testValue =
    case ( mkBox 2, mkPair 1 2 ) of
        ( Box v, Pair a _ ) ->
            mk v a
"""


{-| A state-monad style program over the parameterized alias
`State a = Int -> ( a, Int )`. `andThen` and `get` are written at the alias's
arity, and `prog` has a `let`-bound helper annotated with the alias.
-}
etaParameterizedAlias : String
etaParameterizedAlias =
    """
module Test exposing (..)


type alias State a =
    Int -> ( a, Int )


andThen : (a -> State b) -> State a -> State b
andThen k m s =
    case m s of
        ( a, s1 ) ->
            k a s1


get : State Int
get s =
    ( s, s )


put : Int -> State ()
put n _ =
    ( (), n )


prog : State Int
prog =
    let
        bump : Int -> State Int
        bump x =
            andThen (always get) (put (x + 1))
    in
    andThen bump get


testValue : Int
testValue =
    case prog 5 of
        ( v, _ ) ->
            v
"""



{-| `mk`, annotated `Int -> Fn` and written with one parameter, is a `let`
chain whose bound expressions are all cheap to repeat: an enumeration
constructor, a record, a record update, a field access, a float, a character
and a tuple destructuring. Its body is a partial application of `add`, so the
whole definition is expanded. `loop`, annotated `Int -> Fn`, binds a local
tail-recursive function first, which is not cheap, so it is not expanded.
-}
etaCheapLetChain : String
etaCheapLetChain =
    """
module Test exposing (..)


type Color
    = Red
    | Green


type alias Fn =
    Int -> Int


add : Int -> Int -> Int
add a b =
    a + b


mk : Int -> Fn
mk n =
    let
        col =
            Green

        r =
            { a = n, b = 2 }

        r2 =
            { r | a = 3 }

        v =
            r2.b

        fl =
            1.5

        ch =
            'c'

        ( p, q ) =
            ( n, v )
    in
    case col of
        Green ->
            add q

        Red ->
            add p


loop : Int -> Fn
loop n =
    let
        go acc k =
            case k of
                0 ->
                    acc

                _ ->
                    go (acc + k) (k - 1)
    in
    add (go 0 n)


testValue : Int
testValue =
    mk 1 2 + loop 3 4
"""
