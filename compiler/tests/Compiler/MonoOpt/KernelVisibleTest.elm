module Compiler.MonoOpt.KernelVisibleTest exposing (suite)

{-| Tests for `Compiler.MonoOpt.KernelVisible` (plans/constructor-representation-levels.md
§4, MONO_032).

The type environment comes from monomorphizing a small program declaring
`type W = W Int` and `type V = V Int`. The graph's nodes are then replaced by
hand-built kernel calls over those types and `Rec = { n : Int }`, so that each
test exercises one rule:

  - `W` passed to a kernel the table does not list (here `Debugger.unsafeCoerce`) is
    kernel-visible: the deny-all closure of the call's argument and result
    types;
  - `V` passed only to `List.cons`, which the table lists `Transparent`, is
    not;
  - a kernel used as a function value (not called) closes deny-all over its own
    type;
  - `Maybe Int` returned by a kernel (`String.toInt`) is a visible
    instantiation while `Maybe Rec`, which no kernel touches, is not, though
    the type constructor `Maybe` is then visible: the set keeps both, so that
    `NullableMaybe`, which decides per instantiation, is not stopped by one
    kernel's `Maybe`;
  - a kernel that never returns (`Crash.crash`) marks nothing;
  - `Bytes.decode` pins the `Maybe` it builds, but not the payload it copies
    out of the decoder's result without looking at it (`W` stays erasable);
  - from the kernel review (`design_docs/elm_kernel_functions.csv`):
    `String.foldl` only moves its accumulator, `Process.sleep` is found under
    its own home, and `HttpServer.createServerWith`, which reads a `Maybe`
    option's tag and field, keeps that instantiation boxed.

  - a kernel reached only through an alias global (`kInfo = Eco.Kernel.Tls.info`,
    whose shared node has type variables where the kernel's types are) is
    applied at each use site's type: `Tls.info`'s declared `Maybe` is visible at
    the instantiation a use returns, and a wrapper passed to an unlisted
    kernel's alias is visible (plans/constructor-representation-followups.md F2,
    found by the `SocketTls*` E2E tests).

An effect manager's command type (the `MonoManagerLeaf` rule) is covered by the
E2E test `ProcessSpawnExternalTest`, whose `Maybe` the C++ manager builds.

-}

import Array
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , callExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , recordExpr
        , tType
        )
import Compiler.Core.TypeIds as TypeIds
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.IR.Source as Src
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.Core.Annotation as A
import Dict
import Expect
import Test exposing (Test, describe, test)
import TestLogic.TestPipeline as Pipeline


tInt : Src.Type
tInt =
    tType "Int" []


program : Src.Module
program =
    let
        unions : List UnionDef
        unions =
            [ { name = "W", args = [], ctors = [ { name = "W", args = [ tInt ] } ] }
            , { name = "V", args = [], ctors = [ { name = "V", args = [ tInt ] } ] }
            ]

        def name ctor =
            { name = name, args = [], tipe = tType ctor [], body = callExpr (ctorExpr ctor) [ intExpr 1 ] }

        testValue : TypedDef
        testValue =
            { name = "testValue", args = [], tipe = tInt, body = intExpr 0 }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod" [ def "w" "W", def "v" "V", testValue ] unions []


rec : Mono.MonoType
rec =
    Mono.mRecord (Dict.fromList [ ( "n", Mono.MInt ) ])


maybeOf : Mono.MonoType -> Mono.MonoType
maybeOf t =
    Mono.mCustom ModuleName.maybe "Maybe" [ t ]


taskOf : Mono.MonoType -> Mono.MonoType -> Mono.MonoType
taskOf x a =
    Mono.mCustom ModuleName.platform "Task" [ x, a ]


fn : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
fn =
    Mono.mFunction Mono.topSynth


var : Mono.MonoType
var =
    Mono.MVar TypeIds.firstMVarId Mono.CEcoValue


region : A.Region
region =
    A.zero


kernelCall : String -> String -> List Mono.MonoExpr -> Mono.MonoType -> Mono.MonoExpr
kernelCall home name args result =
    Mono.MonoCall region
        (Mono.MonoVarKernel region "Elm" home name (fn (List.map Mono.typeOf args) result))
        args
        result
        Mono.defaultCallInfo


local : String -> Mono.MonoType -> Mono.MonoExpr
local =
    Mono.MonoVarLocal


{-| The set computed on the program's graph with its nodes replaced by
`exprs`, each a `MonoDefine` of its own type, and the type constructors `W`
and `V` of the program.
-}
withKv : (KernelVisible.KvSet -> Mono.MonoType -> Mono.MonoType -> Expect.Expectation) -> (Mono.MonoType -> Mono.MonoType -> List Mono.MonoExpr) -> () -> Expect.Expectation
withKv check exprs _ =
    case Pipeline.runToMonoWith (Pipeline.withoutReprPasses Pipeline.productionConfig) program of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { globalTypeEnv, monoGraph } ->
            let
                (Mono.MonoGraph g) =
                    monoGraph

                home =
                    ModuleName.Canonical ( "eco", "example" ) "TestMod"

                w =
                    Mono.mCustom home "W" []

                v =
                    Mono.mCustom home "V" []

                nodes =
                    exprs w v
                        |> List.map (\e -> Just (Mono.MonoDefine e (Mono.typeOf e)))
                        |> Array.fromList
            in
            check (KernelVisible.compute globalTypeEnv (Mono.MonoGraph { g | nodes = nodes, flagsDecoder = Nothing })) w v


visible : KernelVisible.KvSet -> Mono.MonoType -> Bool
visible =
    KernelVisible.isVisible


suite : Test
suite =
    describe "Compiler.MonoOpt.KernelVisible"
        [ test "a wrapper passed to an unlisted kernel is visible" <|
            withKv (\kv w _ -> visible kv w |> Expect.equal True)
                (\w _ -> [ kernelCall "Debugger" "unsafeCoerce" [ local "x" w ] w ])
        , test "a wrapper passed only to a transparent kernel is not visible" <|
            withKv (\kv _ v -> visible kv v |> Expect.equal False)
                (\_ v -> [ kernelCall "List" "cons" [ local "x" v, local "xs" (Mono.mList v) ] (Mono.mList v) ])
        , test "a kernel used as a value closes over its own type" <|
            withKv (\kv w _ -> visible kv w |> Expect.equal True)
                (\w _ -> [ Mono.MonoVarKernel region "Elm" "Debugger" "unsafeCoerce" (fn [ w ] w) ])
        , test "a kernel's Maybe Int is a visible instantiation; a Maybe Rec no kernel touches is not" <|
            withKv
                (\kv _ _ ->
                    Expect.all
                        [ \_ -> KernelVisible.isVisibleInstance kv (maybeOf Mono.MInt) |> Expect.equal True
                        , \_ -> KernelVisible.isVisibleInstance kv (maybeOf rec) |> Expect.equal False
                        , \_ -> visible kv (maybeOf rec) |> Expect.equal True
                        ]
                        ()
                )
                (\_ _ ->
                    [ kernelCall "String" "toInt" [ local "s" Mono.MString ] (maybeOf Mono.MInt)
                    , local "m" (maybeOf rec)
                    ]
                )
        , test "a kernel that never returns marks nothing" <|
            withKv (\kv w _ -> visible kv w |> Expect.equal False)
                (\w _ -> [ kernelCall "Crash" "crash" [ local "s" Mono.MString ] w ])
        , test "Bytes.decode builds the Maybe but never looks into its payload" <|
            withKv
                (\kv w _ ->
                    Expect.all
                        [ \_ -> visible kv w |> Expect.equal False
                        , \_ -> KernelVisible.isVisibleInstance kv (maybeOf w) |> Expect.equal True
                        ]
                        ()
                )
                (\w _ ->
                    let
                        bytesType =
                            Mono.mCustom ModuleName.bytes "Bytes" []
                    in
                    [ kernelCall "Bytes"
                        "decode"
                        [ local "d" (fn [ bytesType, Mono.MInt ] (Mono.mTuple (Mono.T2 Mono.MInt w)))
                        , local "bs" bytesType
                        ]
                        (maybeOf w)
                    ]
                )
        , test "a declared kernel reached through an alias inspects the use site's type" <|
            withKv (\kv _ _ -> KernelVisible.isVisibleInstance kv (maybeOf rec) |> Expect.equal True)
                (\_ _ ->
                    [ Mono.MonoVarKernel region "Eco" "Tls" "info" (fn [ Mono.MInt ] (taskOf var var))
                    , Mono.MonoCall region
                        (Mono.MonoVarGlobal region 0 (fn [ Mono.MInt ] (taskOf Mono.MString (maybeOf rec))))
                        [ local "i" Mono.MInt ]
                        (taskOf Mono.MString (maybeOf rec))
                        Mono.defaultCallInfo
                    ]
                )
        , test "a wrapper passed to an unlisted kernel's alias is visible" <|
            withKv (\kv w _ -> visible kv w |> Expect.equal True)
                (\w _ ->
                    [ Mono.MonoVarKernel region "Elm" "Debugger" "unsafeCoerce" (fn [ var ] var)
                    , Mono.MonoCall region (Mono.MonoVarGlobal region 0 (fn [ w ] w)) [ local "x" w ] w Mono.defaultCallInfo
                    ]
                )
        , test "String.foldl moves its accumulator without looking at it" <|
            withKv (\kv w _ -> visible kv w |> Expect.equal False)
                (\w _ -> [ kernelCall "String" "foldl" [ local "f" (fn [ Mono.MChar, w ] w), local "z" w, local "s" Mono.MString ] w ])
        , test "Process.sleep is listed under its own home: the task's error type stays erasable" <|
            withKv (\kv w _ -> visible kv w |> Expect.equal False)
                (\w _ -> [ kernelCall "Process" "sleep" [ local "ms" Mono.MFloat ] (taskOf w Mono.MUnit) ])
        , test "HttpServer.createServerWith reads its Maybe option: that instantiation stays boxed" <|
            withKv (\kv _ _ -> KernelVisible.isVisibleInstance kv (maybeOf rec) |> Expect.equal True)
                (\_ _ -> [ kernelCall "HttpServer" "createServerWith" [ local "host" Mono.MString, local "tls" (maybeOf rec) ] Mono.MInt ])
        ]
