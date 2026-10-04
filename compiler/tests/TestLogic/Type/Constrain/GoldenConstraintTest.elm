module TestLogic.Type.Constrain.GoldenConstraintTest exposing (suite)

{-| Pins the exact output of constraint generation for a corpus of modules, so
that a change to the order in which the generator walks a module, allocates
solver variables or builds constraints, if it alters the output for one of
those modules, fails a test even when every program still type-checks.

Constraint generation has two pathways, and both run the one generator in
`Compiler.Type.Constrain.Typed.Module`. The typed pathway,
`constrainWithIdsDetailed`, also records the node-id state: which solver
variable belongs to each expression and pattern id, which ids got a synthetic
placeholder variable, and, for each annotated definition, the variable chosen
for each type variable its annotation introduces. The erased pathway,
`Compiler.Type.Constrain.Erased.Module.constrain`, records none of it.

A fingerprint is a pair of 32-bit FNV-1a hashes of `Debug.toString` output: of
the constraint together with the whole node-id state on the typed pathway, and
of the constraint alone on the erased pathway. Each pathway runs from an empty
variable store and a solver variable prints as its index, so the printed text
records the order in which variables were allocated. Barring a hash collision,
a fingerprint moves when the walk order, the variable allocation order or the
constraint changes.

A fingerprint also moves when the printed form of something the output carries
changes, with the constraint itself unchanged. A `CForeign` constraint carries
the `Can.Annotation` of what it refers to, such as an operator, a foreign value
or a constructor, and in four corpus entries such an annotation contains a
`Can.Type` function type (`TLambda`): `binop-chains`, `pipe-chains`,
`top-level-vars` and `typed-defs`. No other entry's output contains a
`TLambda`, so a change to how `TLambda` prints moves those four alone; a change
meant to do only that, which moves any other entry, has changed more.

The fixture is a corpus of thirteen small modules, one per test.
Twelve are built as source with `Compiler.AST.SourceBuilder` and canonicalized
against `Compiler.Elm.Interface.Basic.testIfaces`; `kernel-var` is built
directly as a canonical module. A `makeModule` entry is a module `Test` whose
one top-level value, `testValue`, is the given expression, so the functions it
defines are `let`-bound. `True` and `False` in an expression are references to
the `Basics` constructors.

Each test asserts that its module's fingerprint equals the recorded pair:

  - `literals-containers`: a list of triples of integer, float and string
    literals, paired with nested pairs of a char, the unit value and `True`.
  - `access-update-accessor`: a `let`-bound record `s`, then a triple of a
    lambda reading the nested field `r.a.b.c`, the update `{ s | f = 2 }`, and
    the accessor `.g`.
  - `binop-chains`: the operator chains `1 + 2 + 3 * 4 - 5`,
    `"a" ++ "b" ++ "c" ++ "d"` and `1 == 2`.
  - `pipe-chains`: with a `let`-bound `f x = x`, the chains `0 |> f |> f` and
    `f <| f <| 1`.
  - `call-shapes`: with a `let`-bound two-argument `f`, a saturated call, a
    parenthesised partial call applied to one more argument, and a call whose
    first argument is a parenthesised call.
  - `if-chain`: an `if` whose `else` branch is another `if`, three deep, built
    as nested one-branch `if`s with no parentheses between them, not as one
    `else if` chain.
  - `case-list-patterns`: a lambda casing its argument on a list pattern
    `[ 1, a ]`, a two-deep cons pattern, a wildcard under an `as` alias and a
    variable.
  - `case-misc-patterns`: a `case` on a pair with the patterns `( a, "x" )`
    and `( _, s2 )`, a `case` on `True` with the patterns `True` and `False`,
    and a `case` on a char with a char pattern and a wildcard.
  - `record-unit-lambdas`: lambdas taking a record pattern `{ a, b }`, the
    unit pattern, and a variable whose body is `-(-x)`.
  - `let-family`: nested `let`s binding a constant, a self-recursive `go`, a
    pair destructured into `x` and `y`, and a function `t` annotated
    `Int -> Int`.
  - `top-level-vars`: top-level values `helper`, the mutually recursive
    `evenish` and `oddish`, and `testValue`, which uses `helper` and calls
    `List.map`.
  - `typed-defs`: annotated top-level functions `f : Int -> Int`,
    `g : a -> a`, a self-recursive `rec : Int -> Int` and
    `m : Maybe b -> Maybe b`, which cases on `Just` and `Nothing`.
  - `kernel-var`: a `testValue` that is the bare kernel reference
    `Elm.Kernel.List.foldr`, which contributes no constraint of its own (on
    the erased pathway its constraint is `CTrue`).

The `if-chain` pair does not match what the generator produces now,
`( 1208837591, 366174875 )`, so that test fails.

When a fingerprint moves, the hashes do not say where. Comparing the two
`Debug.toString` strings that `fingerprints` hashes, from before and after the
change, does.

Among what is not tested: the solver, and anything after constraint
generation; the `Can.Expr_` forms `VarDebug`, `VarOperator` (an operator used
as a value) and `Shader`; ports and effect managers; and declarations of custom
types and type aliases, since no module in the corpus declares any.

-}

import Bitwise
import Compiler.AST.Canonical as Can
import Compiler.AST.CanonicalBuilder as CB
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Result as Result
import Compiler.Type.Constrain.Erased.Module as ErasedConstrain
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)



-- ====== FINGERPRINTING ======


{-| Returns the 32-bit FNV-1a hash of `str`, as an unsigned value.

Each character is folded in by its code point, not by its UTF-8 bytes, so for
text outside ASCII the result differs from byte-oriented FNV-1a.

-}
fnv1a : String -> Int
fnv1a str =
    String.foldl
        (\c h -> mul32 (Bitwise.xor h (Char.toCode c)) 16777619)
        2166136261
        str
        |> Bitwise.shiftRightZfBy 0


{-| Returns `a * b` modulo 2^32, as an unsigned value, for a 32-bit `a` and a
`b` below 2^32.

`a` is split into 16-bit halves so that every partial product stays below 2^53
and is exact in JavaScript's floating-point numbers, which `a * b` itself would
not be.

-}
mul32 : Int -> Int -> Int
mul32 a b =
    let
        aHi16 =
            Bitwise.shiftRightZfBy 16 a

        aLo16 =
            Bitwise.and a 0xFFFF
    in
    Bitwise.shiftRightZfBy 0
        (aLo16 * b + Bitwise.shiftLeftBy 16 (Bitwise.and (aHi16 * b) 0xFFFF))


{-| Returns the fingerprint of `canonical`: the `fnv1a` hash of the printed
typed-pathway output, the constraint with the final node-id state, then the
hash of the printed erased-pathway constraint.

Because the node-id state is hashed, a change to which variable is recorded
for an id moves the first hash even when the constraint is unchanged.

-}
fingerprints : Can.Module -> ( Int, Int )
fingerprints canonical =
    let
        typedStr =
            Debug.toString
                (IO.unsafePerformIO (ConstrainTyped.constrainWithIdsDetailed canonical))

        erasedStr =
            Debug.toString
                (IO.unsafePerformIO (ErasedConstrain.constrain canonical))
    in
    ( fnv1a typedStr, fnv1a erasedStr )



-- ====== CORPUS HELPERS ======


{-| Canonicalizes `srcModule` as a module of the package `eco/example`, against
the test interfaces of `Compiler.Elm.Interface.Basic.testIfaces`. Warnings are
dropped, and any failure gives the one message `"canonicalization failed"`,
without the errors.
-}
canonicalizeModule : Src.Module -> Result String Can.Module
canonicalizeModule srcModule =
    case Result.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule) of
        ( _, Ok modul ) ->
            Ok modul

        ( _, Err _ ) ->
            Err "canonicalization failed"


{-| Creates the test `name`, which canonicalizes `srcModule` and expects its
fingerprint to equal `expected`. It fails if canonicalization fails.
-}
goldenSrc : String -> ( Int, Int ) -> Src.Module -> Test
goldenSrc name expected srcModule =
    Test.test name <|
        \_ ->
            case canonicalizeModule srcModule of
                Err msg ->
                    Expect.fail msg

                Ok canonical ->
                    Expect.equal expected (fingerprints canonical)


{-| Creates the test `name`, which expects the fingerprint of the canonical
module `canonical` to equal `expected`.
-}
goldenCan : String -> ( Int, Int ) -> Can.Module -> Test
goldenCan name expected canonical =
    Test.test name <|
        \_ ->
            Expect.equal expected (fingerprints canonical)


{-| Builds a `let` definition of `name` with arguments `args`, body `body` and
the annotation `tipe`. `SB.define` builds only unannotated ones.
-}
typedLetDef : String -> List Src.Pattern -> Src.Expr -> Src.Type -> Src.Def
typedLetDef name args body tipe =
    Src.Define
        (A.At A.zero name)
        (List.map (\p -> ( [], p )) args)
        ( [], body )
        (Just ( [], ( ( [], [] ), tipe ) ))



-- ====== CORPUS ======


{-| The `literals-containers` module: a list of two triples of integer, float and
string literals, paired with nested pairs of a char, the unit value and `True`.
-}
literalsContainers : Src.Module
literalsContainers =
    SB.makeModule "testValue" <|
        SB.tupleExpr
            (SB.listExpr
                [ SB.tuple3Expr (SB.intExpr 1) (SB.floatExpr 2.5) (SB.strExpr "s")
                , SB.tuple3Expr (SB.intExpr 2) (SB.floatExpr 3.5) (SB.strExpr "t")
                ]
            )
            (SB.tupleExpr (SB.chrExpr "x") (SB.tupleExpr SB.unitExpr (SB.boolExpr True)))


{-| The `access-update-accessor` module: `s = { f = 1, g = "x" }` bound by `let`,
then the triple of `\r -> r.a.b.c`, `{ s | f = 2 }` and `.g`.
-}
accessUpdateAccessor : Src.Module
accessUpdateAccessor =
    SB.makeModule "testValue" <|
        SB.letExpr
            [ SB.define "s" [] (SB.recordExpr [ ( "f", SB.intExpr 1 ), ( "g", SB.strExpr "x" ) ]) ]
            (SB.tuple3Expr
                (SB.lambdaExpr [ SB.pVar "r" ]
                    (SB.accessExpr (SB.accessExpr (SB.accessExpr (SB.varExpr "r") "a") "b") "c")
                )
                (SB.updateExpr (SB.varExpr "s") [ ( "f", SB.intExpr 2 ) ])
                (SB.accessorExpr "g")
            )


{-| The `binop-chains` module: the triple of `1 + 2 + 3 * 4 - 5`,
`"a" ++ "b" ++ "c" ++ "d"` and `1 == 2`.
-}
binopChains : Src.Module
binopChains =
    SB.makeModule "testValue" <|
        SB.tuple3Expr
            (SB.binopsExpr
                [ ( SB.intExpr 1, "+" ), ( SB.intExpr 2, "+" ), ( SB.intExpr 3, "*" ), ( SB.intExpr 4, "-" ) ]
                (SB.intExpr 5)
            )
            (SB.binopsExpr
                [ ( SB.strExpr "a", "++" ), ( SB.strExpr "b", "++" ), ( SB.strExpr "c", "++" ) ]
                (SB.strExpr "d")
            )
            (SB.binopsExpr [ ( SB.intExpr 1, "==" ) ] (SB.intExpr 2))


{-| The `pipe-chains` module: with `f x = x` bound by `let`, the pair of
`0 |> f |> f` and `f <| f <| 1`.
-}
pipeChains : Src.Module
pipeChains =
    SB.makeModule "testValue" <|
        SB.letExpr
            [ SB.define "f" [ SB.pVar "x" ] (SB.varExpr "x") ]
            (SB.tupleExpr
                (SB.binopsExpr
                    [ ( SB.intExpr 0, "|>" ), ( SB.varExpr "f", "|>" ) ]
                    (SB.varExpr "f")
                )
                (SB.binopsExpr
                    [ ( SB.varExpr "f", "<|" ), ( SB.varExpr "f", "<|" ) ]
                    (SB.intExpr 1)
                )
            )


{-| The `call-shapes` module: with `f x y = x` bound by `let`, the triple of
`f 1 2`, `(f 3) 4` and `f (f 5 6) 7`.
-}
callShapes : Src.Module
callShapes =
    SB.makeModule "testValue" <|
        SB.letExpr
            [ SB.define "f" [ SB.pVar "x", SB.pVar "y" ] (SB.varExpr "x") ]
            (SB.tuple3Expr
                (SB.callExpr (SB.varExpr "f") [ SB.intExpr 1, SB.intExpr 2 ])
                (SB.callExpr (SB.parensExpr (SB.callExpr (SB.varExpr "f") [ SB.intExpr 3 ])) [ SB.intExpr 4 ])
                (SB.callExpr (SB.varExpr "f")
                    [ SB.parensExpr (SB.callExpr (SB.varExpr "f") [ SB.intExpr 5, SB.intExpr 6 ])
                    , SB.intExpr 7
                    ]
                )
            )


{-| The `if-chain` module: three one-branch `if`s, with conditions `True`,
`False` and `True`, each inner one the `else` branch of the one before, and
branches 1 to 4. No `Src.Parens` separates them, and they are not the single
multi-branch `Src.If` the parser builds for an `else if` chain.
-}
ifChain : Src.Module
ifChain =
    SB.makeModule "testValue" <|
        SB.ifExpr (SB.boolExpr True)
            (SB.intExpr 1)
            (SB.ifExpr (SB.boolExpr False)
                (SB.intExpr 2)
                (SB.ifExpr (SB.boolExpr True) (SB.intExpr 3) (SB.intExpr 4))
            )


{-| The `case-list-patterns` module: a lambda that cases its argument `xs` on
`[ 1, a ]`, `h :: h2 :: t`, `_ as w` and `other`.
-}
caseListPatterns : Src.Module
caseListPatterns =
    SB.makeModule "testValue" <|
        SB.lambdaExpr [ SB.pVar "xs" ] <|
            SB.caseExpr (SB.varExpr "xs")
                [ ( SB.pList [ SB.pInt 1, SB.pVar "a" ], SB.intExpr 10 )
                , ( SB.pCons (SB.pVar "h") (SB.pCons (SB.pVar "h2") (SB.pVar "t")), SB.varExpr "h" )
                , ( SB.pAlias SB.pAnything "w", SB.intExpr 30 )
                , ( SB.pVar "other", SB.intExpr 40 )
                ]


{-| The `case-misc-patterns` module: a triple of `case`s, on a pair with tuple
patterns holding a string literal and a wildcard, on `True` with constructor
patterns, and on a char with a char pattern and a wildcard.
-}
caseMiscPatterns : Src.Module
caseMiscPatterns =
    SB.makeModule "testValue" <|
        SB.tuple3Expr
            (SB.caseExpr (SB.tupleExpr (SB.intExpr 1) (SB.strExpr "s"))
                [ ( SB.pTuple (SB.pVar "a") (SB.pStr "x"), SB.varExpr "a" )
                , ( SB.pTuple SB.pAnything (SB.pVar "s2"), SB.intExpr 0 )
                ]
            )
            (SB.caseExpr (SB.boolExpr True)
                [ ( SB.pCtor "True" [], SB.intExpr 1 )
                , ( SB.pCtor "False" [], SB.intExpr 0 )
                ]
            )
            (SB.caseExpr (SB.chrExpr "z")
                [ ( SB.pChr "z", SB.intExpr 1 )
                , ( SB.pAnything, SB.intExpr 0 )
                ]
            )


{-| The `record-unit-lambdas` module: the triple of `\{ a, b } -> a`, `\() -> 0`
and `\x -> -(-x)`.
-}
recordUnitLambdas : Src.Module
recordUnitLambdas =
    SB.makeModule "testValue" <|
        SB.tuple3Expr
            (SB.lambdaExpr [ SB.pRecord [ "a", "b" ] ] (SB.varExpr "a"))
            (SB.lambdaExpr [ SB.pUnit ] (SB.intExpr 0))
            (SB.lambdaExpr [ SB.pVar "x" ] (SB.negateExpr (SB.parensExpr (SB.negateExpr (SB.varExpr "x")))))


{-| The `let-family` module: four nested `let`s binding `a = 1`, the
self-recursive `go n = go n`, the destructured pair `( x, y ) = ( 1, 2 )` and
`t : Int -> Int`, around the triple `( a, x, t 9 )`.
-}
letFamily : Src.Module
letFamily =
    SB.makeModule "testValue" <|
        SB.letExpr [ SB.define "a" [] (SB.intExpr 1) ] <|
            SB.letExpr [ SB.define "go" [ SB.pVar "n" ] (SB.callExpr (SB.varExpr "go") [ SB.varExpr "n" ]) ] <|
                SB.letExpr [ SB.destruct (SB.pTuple (SB.pVar "x") (SB.pVar "y")) (SB.tupleExpr (SB.intExpr 1) (SB.intExpr 2)) ] <|
                    SB.letExpr [ typedLetDef "t" [ SB.pVar "v" ] (SB.varExpr "v") (SB.tLambda (SB.tType "Int" []) (SB.tType "Int" [])) ] <|
                        SB.tuple3Expr
                            (SB.varExpr "a")
                            (SB.varExpr "x")
                            (SB.callExpr (SB.varExpr "t") [ SB.intExpr 9 ])


{-| The `top-level-vars` module: the top-level values `helper = 1`, the mutually
recursive `evenish` and `oddish`, and
`testValue = ( helper, List.map (\x -> x) [ 1 ] )`.
-}
topLevelVars : Src.Module
topLevelVars =
    SB.makeModuleWithDefs "Test"
        [ ( "helper", [], SB.intExpr 1 )
        , ( "evenish", [ SB.pVar "n" ], SB.callExpr (SB.varExpr "oddish") [ SB.varExpr "n" ] )
        , ( "oddish", [ SB.pVar "n" ], SB.callExpr (SB.varExpr "evenish") [ SB.varExpr "n" ] )
        , ( "testValue"
          , []
          , SB.tupleExpr (SB.varExpr "helper")
                (SB.callExpr (SB.qualVarExpr "List" "map")
                    [ SB.lambdaExpr [ SB.pVar "x" ] (SB.varExpr "x")
                    , SB.listExpr [ SB.intExpr 1 ]
                    ]
                )
          )
        ]


{-| The `typed-defs` module: the annotated top-level functions `f : Int -> Int`,
`g : a -> a`, the self-recursive `rec : Int -> Int` and
`m : Maybe b -> Maybe b`, which maps `Just v` to `Just v` and `Nothing` to
`Nothing`.
-}
typedDefs : Src.Module
typedDefs =
    SB.makeModuleWithTypedDefs "Test"
        [ { name = "f"
          , args = [ SB.pVar "x" ]
          , tipe = SB.tLambda (SB.tType "Int" []) (SB.tType "Int" [])
          , body = SB.varExpr "x"
          }
        , { name = "g"
          , args = [ SB.pVar "y" ]
          , tipe = SB.tLambda (SB.tVar "a") (SB.tVar "a")
          , body = SB.varExpr "y"
          }
        , { name = "rec"
          , args = [ SB.pVar "n" ]
          , tipe = SB.tLambda (SB.tType "Int" []) (SB.tType "Int" [])
          , body = SB.callExpr (SB.varExpr "rec") [ SB.varExpr "n" ]
          }
        , { name = "m"
          , args = [ SB.pVar "mx" ]
          , tipe = SB.tLambda (SB.tType "Maybe" [ SB.tVar "b" ]) (SB.tType "Maybe" [ SB.tVar "b" ])
          , body =
                SB.caseExpr (SB.varExpr "mx")
                    [ ( SB.pCtor "Just" [ SB.pVar "v" ], SB.callExpr (SB.ctorExpr "Just") [ SB.varExpr "v" ] )
                    , ( SB.pCtor "Nothing" [], SB.ctorExpr "Nothing" )
                    ]
          }
        ]


{-| The `kernel-var` module, built as a canonical module: `testValue` is the bare
kernel reference `Elm.Kernel.List.foldr`, with expression id 1.
-}
kernelVar : Can.Module
kernelVar =
    CB.makeModule "testValue" (CB.varKernelExpr 1 "List" "foldr")


{-| The thirteen golden fingerprint tests, one for each corpus module.
-}
suite : Test
suite =
    Test.describe "Golden constraint fingerprints (byte-identity gate)"
        [ goldenSrc "literals-containers" ( 2511266603, 4226193006 ) literalsContainers
        , goldenSrc "access-update-accessor" ( 2324415555, 136880178 ) accessUpdateAccessor
        , goldenSrc "binop-chains" ( 430831143, 3366310689 ) binopChains
        , goldenSrc "pipe-chains" ( 1069070543, 2887143088 ) pipeChains
        , goldenSrc "call-shapes" ( 132171800, 639265737 ) callShapes
        , goldenSrc "if-chain" ( 2818725526, 50115275 ) ifChain
        , goldenSrc "case-list-patterns" ( 3193721138, 773629378 ) caseListPatterns
        , goldenSrc "case-misc-patterns" ( 2621323093, 2815270446 ) caseMiscPatterns
        , goldenSrc "record-unit-lambdas" ( 2397726897, 3888057001 ) recordUnitLambdas
        , goldenSrc "let-family" ( 3480157346, 776512907 ) letFamily
        , goldenSrc "top-level-vars" ( 2604201531, 227965378 ) topLevelVars
        , goldenSrc "typed-defs" ( 3380026013, 2639813465 ) typedDefs
        , goldenCan "kernel-var" ( 2702318790, 1175847913 ) kernelVar
        ]
