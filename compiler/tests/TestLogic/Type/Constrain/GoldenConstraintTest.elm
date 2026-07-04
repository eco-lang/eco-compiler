module TestLogic.Type.Constrain.GoldenConstraintTest exposing (suite)

{-| Golden byte-identity gate for the constraint generator.

For a corpus of modules covering the `Can.Expr_` / `Can.Pattern_` constructor
space, this test fingerprints the FULL output of the constraint generator on
both pathways:

  - typed: `constrainWithIdsDetailed` (constraint + full node-id state)
  - erased: `Erased.constrain` (constraint only, recording off)

The fingerprint is an FNV-1a hash over `Debug.toString` of the output, which
embeds every solver variable index in allocation order. Any change to walk
order, variable allocation order, or constraint structure changes the hash.

The golden values were captured from the pre-Design-B reified-DSL generator
(`ProgS` / `PatternProg`). The Design-B direct-recursion generator must
reproduce them byte-for-byte: a mismatch means a spine loop folds in the
wrong order or a variable is allocated at the wrong step.

To debug a drift: temporarily swap `fingerprints` for `debugStrings` in a
failing case and diff the two `Debug.toString` outputs.

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


{-| 32-bit FNV-1a over a string, with a 32-bit-exact multiply.
-}
fnv1a : String -> Int
fnv1a str =
    String.foldl
        (\c h -> mul32 (Bitwise.xor h (Char.toCode c)) 16777619)
        2166136261
        str
        |> Bitwise.shiftRightZfBy 0


{-| (a \* b) mod 2^32 without exceeding JS float integer precision.
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


{-| Hash both constraint-generation pathways for a canonical module.

The typed pathway hashes the constraint AND the final node-id state
(mapping, synthetic ids, scheme binders), so id→var recording drift is
caught too. The erased pathway hashes just the constraint.

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


canonicalizeModule : Src.Module -> Result String Can.Module
canonicalizeModule srcModule =
    case Result.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule) of
        ( _, Ok modul ) ->
            Ok modul

        ( _, Err _ ) ->
            Err "canonicalization failed"


goldenSrc : String -> ( Int, Int ) -> Src.Module -> Test
goldenSrc name expected srcModule =
    Test.test name <|
        \_ ->
            case canonicalizeModule srcModule of
                Err msg ->
                    Expect.fail msg

                Ok canonical ->
                    Expect.equal expected (fingerprints canonical)


goldenCan : String -> ( Int, Int ) -> Can.Module -> Test
goldenCan name expected canonical =
    Test.test name <|
        \_ ->
            Expect.equal expected (fingerprints canonical)


{-| An annotated (typed) let-level definition; SB.define only builds untyped ones.
-}
typedLetDef : String -> List Src.Pattern -> Src.Expr -> Src.Type -> Src.Def
typedLetDef name args body tipe =
    Src.Define
        (A.At A.zero name)
        (List.map (\p -> ( [], p )) args)
        ( [], body )
        (Just ( [], ( ( [], [] ), tipe ) ))



-- ====== CORPUS ======


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


ifChain : Src.Module
ifChain =
    SB.makeModule "testValue" <|
        SB.ifExpr (SB.boolExpr True)
            (SB.intExpr 1)
            (SB.ifExpr (SB.boolExpr False)
                (SB.intExpr 2)
                (SB.ifExpr (SB.boolExpr True) (SB.intExpr 3) (SB.intExpr 4))
            )


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


recordUnitLambdas : Src.Module
recordUnitLambdas =
    SB.makeModule "testValue" <|
        SB.tuple3Expr
            (SB.lambdaExpr [ SB.pRecord [ "a", "b" ] ] (SB.varExpr "a"))
            (SB.lambdaExpr [ SB.pUnit ] (SB.intExpr 0))
            (SB.lambdaExpr [ SB.pVar "x" ] (SB.negateExpr (SB.parensExpr (SB.negateExpr (SB.varExpr "x")))))


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


kernelVar : Can.Module
kernelVar =
    CB.makeModule "testValue" (CB.varKernelExpr 1 "List" "foldr")


suite : Test
suite =
    Test.describe "Golden constraint fingerprints (byte-identity gate)"
        [ goldenSrc "literals-containers" ( 2511266603, 4226193006 ) literalsContainers
        , goldenSrc "access-update-accessor" ( 2324415555, 136880178 ) accessUpdateAccessor
        , goldenSrc "binop-chains" ( 2019543323, 4270514405 ) binopChains
        , goldenSrc "pipe-chains" ( 2155287695, 1915210536 ) pipeChains
        , goldenSrc "call-shapes" ( 132171800, 639265737 ) callShapes
        , goldenSrc "if-chain" ( 2818725526, 50115275 ) ifChain
        , goldenSrc "case-list-patterns" ( 3193721138, 773629378 ) caseListPatterns
        , goldenSrc "case-misc-patterns" ( 2621323093, 2815270446 ) caseMiscPatterns
        , goldenSrc "record-unit-lambdas" ( 2397726897, 3888057001 ) recordUnitLambdas
        , goldenSrc "let-family" ( 3480157346, 776512907 ) letFamily
        , goldenSrc "top-level-vars" ( 4084548975, 3321295038 ) topLevelVars
        , goldenSrc "typed-defs" ( 1830534477, 2321849689 ) typedDefs
        , goldenCan "kernel-var" ( 2702318790, 1175847913 ) kernelVar
        ]
