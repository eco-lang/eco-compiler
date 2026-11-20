module Compiler.MonoOpt.EraseWrappersTest exposing (suite)

{-| Tests for the type rewriting and the meets rule of
`Compiler.MonoOpt.EraseWrappers` (plans/constructor-representation-levels.md
E1a, E1b).

The tests establish:

  - `eraseType` replaces an erasable wrapper by its field, inside a list, a
    record, a function's parameters and result, and a wrapper of a wrapper,
    and keeps a function type's stage shape;
  - a type that mentions no erasable wrapper is returned as it is;
  - on a monomorphized program (`type W = W String`, built and unwrapped),
    `erase` erases `W` and `check` (MONO_031) finds nothing; a node added
    afterwards whose type still mentions `W` is reported;
  - `consistentWith` keeps an erasure no meet contradicts, drops an unboxed
    erasure that meets a type variable inside a list (an interior meet), keeps
    one that meets a type variable at the root (call-boundary boxing repairs
    that), and drops an erased instantiation that meets an instantiation of
    the same wrapper that is not erased;
  - on a program with a wrapper inside a `Maybe` (`Maybe W`, `type W = W
    { n : Int }`), the kernel-visibility set and the meets carried over the
    erasure (`EraseWrappers.translateKv`, `RepresentationMeets.translate`)
    lead `NullableMaybe` to the same nullable types and counts as a second
    collection on the erased graph (plans/constructor-representation-levels.md
    §13 R2).

-}

import Array
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , recordExpr
        , tRecord
        , accessExpr
        , pCtor
        , pVar
        , strExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Core.TypeIds as TypeIds
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.EraseWrappers as EraseWrappers
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.MonoOpt.NullableMaybe as NullableMaybe
import Compiler.Monomorphize.RepresentationMeets as RepresentationMeets
import Compiler.IR.Source as Src
import Dict
import Expect
import Test exposing (Test, describe, test)
import TestLogic.TestPipeline as Pipeline


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "project" ) "Main"


box : Mono.MonoType -> Mono.MonoType
box t =
    Mono.mCustom home "Box" [ t ]


q : Mono.MonoType
q =
    Mono.mCustom home "Q" []


var : Mono.MonoType
var =
    Mono.MVar TypeIds.firstMVarId Mono.CEcoValue


erasable : EraseWrappers.Erasable
erasable =
    EraseWrappers.erasableFromList
        [ ( box Mono.MString, Mono.MString )
        , ( box (box Mono.MString), box Mono.MString )
        , ( q, Mono.MFloat )
        ]


fn : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
fn =
    Mono.mFunction Mono.topSynth


suite : Test
suite =
    describe "Compiler.MonoOpt.EraseWrappers"
        [ test "eraseType rewrites nested wrappers" <|
            \_ ->
                [ EraseWrappers.eraseType erasable (box Mono.MString)
                , EraseWrappers.eraseType erasable (box (box Mono.MString))
                , EraseWrappers.eraseType erasable (Mono.mList q)
                , EraseWrappers.eraseType erasable (Mono.mRecord (Dict.fromList [ ( "a", q ) ]))
                , EraseWrappers.eraseType erasable (fn [ q ] (fn [ box Mono.MString ] q))
                ]
                    |> Expect.equal
                        [ Mono.MString
                        , Mono.MString
                        , Mono.mList Mono.MFloat
                        , Mono.mRecord (Dict.fromList [ ( "a", Mono.MFloat ) ])
                        , fn [ Mono.MFloat ] (fn [ Mono.MString ] Mono.MFloat)
                        ]
        , test "a type with no wrapper is unchanged" <|
            \_ ->
                EraseWrappers.eraseType erasable (Mono.mList Mono.MInt)
                    |> Expect.equal (Mono.mList Mono.MInt)
        , test "consistentWith keeps an uncontradicted erasure" <|
            \_ ->
                EraseWrappers.consistentWith [] erasable
                    |> EraseWrappers.erasableSize
                    |> Expect.equal 3
        , test "an unboxed erasure meeting a type variable inside a list is dropped" <|
            \_ ->
                EraseWrappers.consistentWith [ { a = q, b = var, root = False, spec = 0, site = "t" } ] erasable
                    |> (\e -> EraseWrappers.isErasable e q)
                    |> Expect.equal False
        , test "an unboxed erasure meeting a type variable at the root is kept" <|
            \_ ->
                EraseWrappers.consistentWith [ { a = q, b = var, root = True, spec = 0, site = "t" } ] erasable
                    |> (\e -> EraseWrappers.isErasable e q)
                    |> Expect.equal True
        , test "an erased instantiation meeting a kept one of the same wrapper is dropped" <|
            \_ ->
                let
                    tentative =
                        EraseWrappers.erasableFromList
                            [ ( box Mono.MString, Mono.MString )
                            , ( box Mono.MInt, Mono.MInt )
                            ]

                    meets =
                        -- `Box Int` meets a type variable inside a list, so it stays a heap value; then
                        -- `Box String`, which some value is viewed as along with `Box Int`, must too.
                        [ { a = box Mono.MInt, b = var, root = False, spec = 0, site = "t" }
                        , { a = box Mono.MString, b = box Mono.MInt, root = True, spec = 0, site = "t" }
                        ]
                in
                EraseWrappers.consistentWith meets tentative
                    |> EraseWrappers.erasableSize
                    |> Expect.equal 0
            , test "kernel visibility and meets carried over the erasure lead to the nullable decision a recollection does" <|
        \_ ->
            case Pipeline.runToMonoWith (Pipeline.withoutReprPasses Pipeline.productionConfig) carryProgram of
                Err msg ->
                    Expect.fail ("Compilation failed: " ++ msg)

                Ok { globalTypeEnv, monoGraph } ->
                    let
                        kv =
                            KernelVisible.compute globalTypeEnv monoGraph

                        meets =
                            RepresentationMeets.collect monoGraph

                        ( erased, stats, e ) =
                            EraseWrappers.eraseKeeping { allowUnboxed = False, meetsOk = identity, meets = meets } kv monoGraph

                        decide k m =
                            NullableMaybe.run { userTypes = False } k m erased
                                |> (\( Mono.MonoGraph g, nstats ) ->
                                        ( Mono.layoutMapFoldl (\t _ acc -> Mono.toComparableLayoutType t :: acc) [] g.repr.nullable |> List.sort
                                        , nstats
                                        )
                                   )

                        carried =
                            decide (EraseWrappers.translateKv e kv)
                                (RepresentationMeets.translate (EraseWrappers.eraseType e) meets)

                        recollected =
                            decide (KernelVisible.compute globalTypeEnv erased) (RepresentationMeets.collect erased)
                    in
                    Expect.all
                        [ \_ -> Expect.equal stats.erasedCtors 1
                        , \_ -> Expect.equal (List.length (Tuple.first carried)) 1
                        , \_ -> Expect.equal carried recollected
                        ]
                        ()
    , test "erase leaves no erased type behind, and check reports one put back (MONO_031)" <|
        \_ ->
            case Pipeline.runToMonoWith (Pipeline.withoutReprPasses Pipeline.productionConfig) checkProgram of
                Err msg ->
                    Expect.fail ("Compilation failed: " ++ msg)

                Ok { globalTypeEnv, monoGraph } ->
                    let
                        ( erased, stats ) =
                            EraseWrappers.erase { allowUnboxed = False, meetsOk = identity, meets = [] }
                                (KernelVisible.compute globalTypeEnv monoGraph)
                                monoGraph

                        (Mono.MonoGraph g) =
                            erased

                        erasedType =
                            Mono.layoutMapFoldl (\key _ _ -> Just key) Nothing g.repr.erasedKeys

                        withViolation =
                            case erasedType of
                                Just t ->
                                    Mono.MonoGraph { g | nodes = Array.push (Just (Mono.MonoDefine (Mono.MonoVarLocal "x" t) t)) g.nodes }

                                Nothing ->
                                    erased
                    in
                    Expect.all
                        [ \_ -> Expect.equal stats.erasedCtors 1
                        , \_ -> Expect.equal (EraseWrappers.check erased) []
                        , \_ -> Expect.notEqual erasedType Nothing
                        , \_ -> Expect.equal (List.length (EraseWrappers.check withViolation)) 1
                        ]
                        ()
    ]


{-| `type W = W String`, `unW (W s) = s`, `testValue = unW (W "ab")`: the
wrapper is built and unwrapped.
-}
checkProgram : Src.Module
checkProgram =
    let
        unW : TypedDef
        unW =
            { name = "unW", args = [ pCtor "W" [ pVar "s" ] ], tipe = tLambda (tType "W" []) (tType "String" []), body = varExpr "s" }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ unW
        , { name = "testValue", args = [], tipe = tType "String" [], body = callExpr (varExpr "unW") [ callExpr (ctorExpr "W") [ strExpr "ab" ] ] }
        ]
        [ { name = "W", args = [], ctors = [ { name = "W", args = [ tType "String" [] ] } ] } ]
        []


{-| `type W = W { n : Int }`, `get : Maybe W -> Int` (a case on `Just (W r)`),
`testValue = get (Just (W { n = 1 })) + get Nothing`: once `W` is erased, the
`Maybe` holds the record and is made nullable.
-}
carryProgram : Src.Module
carryProgram =
    let
        tW =
            tType "W" []

        get : TypedDef
        get =
            { name = "get"
            , args = [ pVar "m" ]
            , tipe = tLambda (tType "Maybe" [ tW ]) (tType "Int" [])
            , body =
                caseExpr (varExpr "m")
                    [ ( pCtor "Just" [ pCtor "W" [ pVar "r" ] ], accessExpr (varExpr "r") "n" )
                    , ( pAnything, intExpr 0 )
                    ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ get
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr (varExpr "get")
                    [ callExpr (ctorExpr "Just") [ callExpr (ctorExpr "W") [ recordExpr [ ( "n", intExpr 1 ) ] ] ] ]
          }
        ]
        [ { name = "W", args = [], ctors = [ { name = "W", args = [ tRecord [ ( "n", tType "Int" [] ) ] ] } ] } ]
        []
