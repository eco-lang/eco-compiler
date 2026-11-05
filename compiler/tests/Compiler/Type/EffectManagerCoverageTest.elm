module Compiler.Type.EffectManagerCoverageTest exposing (suite)

{-| Type checks and locally optimizes effect modules, so that the parts of
the type checker and of the typed optimizer that only an effect manager
reaches run under test: the constraints on a manager's `init`, `onEffects`,
`onSelfMsg`, `cmdMap` and `subMap`, the `command` and `subscription` values a
manager module gets, and the manager node the typed optimizer adds to the
local graph.

An effect module may only be compiled as part of a kernel package, so each
case is parsed as a kernel application (`Compiler.Parse.Module.KernelApplication`)
of the package `eco/example`, whose author makes it a kernel package. It is
canonicalized against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`, with the default imports of modules
those interfaces lack dropped, type checked along the erased path
(`Compiler.Type.Solve.run`) and along the typed path
(`TestLogic.TestPipeline.runToPostSolve`), and given to the typed optimizer
(`Compiler.LocalOpt.Typed.Module.optimizeTyped`), all of which must succeed.

The mock interfaces have no `Platform` or `Task` module, so the manager
functions build their tasks with the kernel function
`Elm.Kernel.Scheduler.succeed`, which has no declared type. Their types
against `Platform.Task`, `Platform.Router` and `Platform.Cmd.Cmd` come from the
constraints the manager header adds.

The three cases are a manager of commands, one of subscriptions, and one of
both. Among what is not tested: a manager whose functions have the wrong
types, and monomorphizing a manager.

-}

import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.Parse.Module as Parse
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Erased.Module as TypeErased
import Compiler.Type.Solve as Solve
import Compiler.Type.SolverRoots as SolverRoots
import Compiler.Type.State.IO as IO
import Compiler.Type.TypedCanonical as TCanBuild
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| One test per manager, under a label that contains "coverage run" so that
the coverage loop's quick run includes it.
-}
suite : Test
suite =
    Test.describe "Effect managers (coverage run)"
        [ Test.test "command manager" <| \_ -> expectCompiles cmdManager
        , Test.test "subscription manager" <| \_ -> expectCompiles subManager
        , Test.test "command and subscription manager" <| \_ -> expectCompiles fxManager
        ]


{-| Passes when `source` parses, canonicalizes, type checks along both paths
and goes through the typed optimizer; otherwise fails naming the step.
-}
expectCompiles : String -> Expectation
expectCompiles source =
    case Parse.fromByteString (Parse.KernelApplication ( "eco", "example" )) source of
        Err _ ->
            Expect.fail "the module does not parse"

        Ok (Src.Module m) ->
            let
                srcModule =
                    Src.Module { m | imports = List.filter isMockImport m.imports }
            in
            case RResult.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule) of
                Err _ ->
                    Expect.fail "the module does not canonicalize"

                Ok canonical ->
                    case IO.unsafePerformIO (TypeErased.constrain canonical |> IO.andThen Solve.run) of
                        Err _ ->
                            Expect.fail "the erased type check fails"

                        Ok _ ->
                            case Pipeline.runToPostSolve srcModule of
                                Err message ->
                                    Expect.fail ("typed path: " ++ message)

                                Ok a ->
                                    let
                                        nodeVars =
                                            SolverRoots.normalizeNodeVars a.solverState a.nodeVars

                                        result =
                                            TypedOptimize.optimizeTyped
                                                a.annotations
                                                a.nodeTypesPost
                                                nodeVars
                                                a.kernelEnv
                                                (SolverRoots.normalizeAnnotationVars a.solverState a.annotationVars)
                                                (SolverRoots.normalizeAllSchemeRoots a.solverState a.schemeBinderVars)
                                                (TCanBuild.fromCanonical a.canonical a.nodeTypesPost nodeVars)
                                    in
                                    case RResult.run result of
                                        Ok _ ->
                                            Expect.pass

                                        Err _ ->
                                            Expect.fail "the typed optimizer rejects the module"


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The manager functions every case defines, with a `state` of `()`.
-}
managerFunctions : String
managerFunctions =
    """init = Elm.Kernel.Scheduler.succeed ()

onEffects router effects state = Elm.Kernel.Scheduler.succeed state

onSelfMsg router msg state = Elm.Kernel.Scheduler.succeed state
"""


{-| A manager of commands of type `MyCmd`.
-}
cmdManager : String
cmdManager =
    """effect module Test where { command = MyCmd } exposing (..)

type MyCmd msg = Go msg

cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap f (Go m) = Go (f m)

"""
        ++ managerFunctions


{-| A manager of subscriptions of type `MySub`.
-}
subManager : String
subManager =
    """effect module Test where { subscription = MySub } exposing (..)

type MySub msg = Listen msg

subMap : (a -> b) -> MySub a -> MySub b
subMap f (Listen m) = Listen (f m)

"""
        ++ managerFunctions


{-| A manager of both, whose `onEffects` takes the commands and then the
subscriptions.
-}
fxManager : String
fxManager =
    """effect module Test where { command = MyCmd, subscription = MySub } exposing (..)

type MyCmd msg = Go msg

type MySub msg = Listen msg

cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap f (Go m) = Go (f m)

subMap : (a -> b) -> MySub a -> MySub b
subMap f (Listen m) = Listen (f m)

init = Elm.Kernel.Scheduler.succeed ()

onEffects router cmds subs state = Elm.Kernel.Scheduler.succeed state

onSelfMsg router msg state = Elm.Kernel.Scheduler.succeed state
"""
