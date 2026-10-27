module Compiler.GlobalOpt.MonoGlobalOptimize exposing (GlobalOptStats, globalOptimize, globalOptimizeWithStats)

{-| Code generation needs to know, at every call, how the function being called
takes its arguments, and this module settles that once for the whole
monomorphized program by running the post-monomorphization passes and writing
the answer into each call's `CallInfo`.

A function value can take its arguments in groups, called _stages_; the list of
group sizes is its _segmentation_, so a closure taking two arguments and
returning a closure that takes one has segmentation `[2, 1]`. A call follows one
of two _call models_. `StageCurried` calls an Elm closure, applied stage by
stage. `FlattenedExternal` calls a kernel function, an extern, a manager leaf, a
constructor or an enum, which take all their arguments at once. The _source
arity_ of a callee is the parameter count of the closure or function that
actually produced the value being called, which can differ from what its type
suggests.

`globalOptimizeWithStats` runs these steps in order:

1.  Every top-level define or port whose type is a function and whose
    expression is not already a closure is wrapped in one, with fresh
    anonymous lambda ids.
2.  `Compiler.GlobalOpt.Staging.regroup` rewrites the types of closures in
    defines and tail functions so that each one's first stage takes exactly its
    parameters.
3.  `Compiler.GlobalOpt.AbiCloning.abiCloningPass` stamps calls whose target it
    can prove. It comes after regrouping so that the stamps see the final
    closure types.
4.  The lambda-set tables are emptied (`Mono.clearLssTables`), keeping
    `lssMemberOrigins` only when borrow inference or the `List.map` template
    is on.
5.  Every `MonoCall` gets a `CallInfo`: its call model, segmentation, source
    arity, the stages left after the first, and how the call is to be made.
6.  Borrow inference runs, when it is enabled.

Most of the file is step 5. Its rule is to trust only what a producer shows:
the remaining stages of a callee are read from the closures that actually
produce it, never guessed from its type, and a call whose source arity is
known only from its type, or that passes more arguments than a known first
stage takes while the later stages are unknown, is marked as such, so that code
generation does not rely on a segmentation nobody established.
Where the branches of a `case` or `if` return closures, a segmentation is
claimed only when every branch is a closure and they all agree.

@docs GlobalOptStats, globalOptimize, globalOptimizeWithStats

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Compiler.GlobalOpt.Borrow as Borrow
import Compiler.GlobalOpt.GenCallCensus as GenCallCensus
import Compiler.GlobalOpt.MonoReturnArity as MonoReturnArity
import Compiler.GlobalOpt.Staging as Staging
import Compiler.Monomorphize.Closure as Closure
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import Set exposing (Set)



-- INTERNAL CONTEXT


{-| The state threaded through the wrapping step: the graph's specialization
registry, read to find each node's home module, and the next unused anonymous
lambda index.
-}
type alias GlobalCtx =
    { registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    }


{-| Returns the wrapping state for a graph, starting the lambda counter at the
graph's `nextLambdaIndex`.
-}
initGlobalCtx : Mono.MonoGraph -> GlobalCtx
initGlobalCtx (Mono.MonoGraph record) =
    { registry = record.registry
    , lambdaCounter = record.nextLambdaIndex
    }


{-| Returns a new anonymous lambda id in `home` and the state with the counter
advanced.
-}
freshLambdaId : ModuleName.Canonical -> GlobalCtx -> ( Mono.LambdaId, GlobalCtx )
freshLambdaId home ctx =
    ( Mono.AnonymousLambda home ctx.lambdaCounter
    , { ctx | lambdaCounter = ctx.lambdaCounter + 1 }
    )



-- CALL STAGING ENVIRONMENT


{-| What the call annotation knows about the local names in scope where it
stands.

`varCallModel`, `varSourceArity` and `varBodyStageArities` hold a name's call
model, source arity and stages after the first, for `let`-bound names whose
bound expression shows them; `varSourceArity` also has tail definitions and
closure captures. No entry is added for a function parameter.

`dynamicParams` holds the function-typed parameters of the enclosing
`MonoTailFunc`. A call through one is `CallGenericApply`, since nothing tells
the compiler how the closure it receives is staged.

`varPolymorphicReturn` holds the names bound to a call whose callee's final
return type is a `CEcoValue` type variable, or to another such name.

-}
type alias CallEnv =
    { varCallModel : Dict Name Mono.CallModel
    , varSourceArity : Dict Name Int
    , varBodyStageArities : Dict Name (List Int)
    , dynamicParams : Set Name
    , varPolymorphicReturn : Set Name
    }


{-| The call environment with nothing in scope.
-}
emptyCallEnv : CallEnv
emptyCallEnv =
    { varCallModel = Dict.empty
    , varSourceArity = Dict.empty
    , varBodyStageArities = Dict.empty
    , dynamicParams = Set.empty
    , varPolymorphicReturn = Set.empty
    }



-- MAIN ENTRY POINT


{-| Returns the graph after every step `globalOptimizeWithStats` runs, using
the default configuration's settings and dropping the statistics.
-}
globalOptimize : Mono.MonoGraph -> Mono.MonoGraph
globalOptimize graph0a =
    Tuple.first (globalOptimizeWithStats Config.default.mono.lss.stamp.census False Config.default.borrow Config.default.list.mapTemplate graph0a)


{-| The counters collected by `globalOptimizeWithStats`.

`genCalls` is empty unless the generic-call census was asked for. `borrow` is
`Borrow.emptyStats` when borrow inference is off.

-}
type alias GlobalOptStats =
    { genCalls : Dict String Int
    , abiCloning : AbiCloning.AbiCloningStats
    , borrow : Borrow.BorrowStats
    }


{-| Returns the graph after the six steps the module docstring lists, with the
counters they collected.

`census` turns on AbiCloning's per-site tallies; it changes no stamping
decision. `stagingCensus` fills in `genCalls` with
`Compiler.GlobalOpt.GenCallCensus.census` of the annotated graph. `borrowCfg`
decides whether borrow inference runs. With `borrowCfg.enabled` or
`listMapTemplate` on, `lssMemberOrigins` is kept through step 4.

-}
globalOptimizeWithStats : Bool -> Bool -> Config.BorrowConfig -> Bool -> Mono.MonoGraph -> ( Mono.MonoGraph, GlobalOptStats )
globalOptimizeWithStats census stagingCensus borrowCfg listMapTemplate graph0a =
    let
        graph1 =
            wrapTopLevelCallables graph0a

        graph2 =
            Staging.regroup graph1

        ( graph4Full, abiStats ) =
            AbiCloning.abiCloningPass census graph2

        graph4 =
            Mono.clearLssTables
                { keepOrigins = borrowCfg.enabled || listMapTemplate }
                graph4Full

        graph5 =
            annotateCallStaging graph4

        ( graph6, borrowStats ) =
            if borrowCfg.enabled then
                Borrow.run borrowCfg graph5

            else
                ( graph5, Borrow.emptyStats )
    in
    ( graph6
    , { genCalls =
            if stagingCensus then
                GenCallCensus.census graph5

            else
                Dict.empty
      , abiCloning = abiStats
      , borrow = borrowStats
      }
    )



-- WRAP TOP-LEVEL CALLABLES


{-| Returns the module a specialization belongs to, used as the home of the
lambda ids minted for it: the global's module, a fixed `eco` accessor module
for an accessor, and a fixed `eco` module when the registry has no entry.
-}
specHome : Mono.SpecializationRegistry -> Int -> ModuleName.Canonical
specHome registry specId =
    case Array.get specId registry.reverseMapping |> Maybe.andThen identity of
        Just ( global, _ ) ->
            case global of
                Mono.Global home _ ->
                    home

                Mono.Accessor _ ->
                    ModuleName.Canonical ( "eco", "accessor" ) "Accessor"

        Nothing ->
            ModuleName.Canonical ( "eco", "global-optimize" ) "GlobalOptimize"


{-| Returns a closure of type `funcType` that takes fresh parameters of
`argTypes` and calls `calleeExpr` with them, with a new lambda id in `home`.

The closure has no source lambda and no lambda-set member, so AbiCloning
indexes it under its type's single lambda-set member, if the type has exactly
one.

-}
makeAliasClosureGO :
    ModuleName.Canonical
    -> Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
makeAliasClosureGO home calleeExpr argTypes retType funcType ctx =
    let
        params =
            Closure.freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        ( lambdaId, ctx1 ) =
            freshLambdaId home ctx

        region =
            Closure.extractRegion calleeExpr

        callExpr =
            Mono.MonoCall region calleeExpr paramExprs retType Mono.defaultCallInfo

        captures =
            Closure.computeClosureCaptures params callExpr

        closureInfo =
            { lambdaId = lambdaId
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = captures
            , params = params
            , closureKind = Nothing
            , captureAbi = Nothing
            }
    in
    ( Mono.MonoClosure closureInfo callExpr funcType, ctx1 )


{-| Returns a closure of type `funcType` that takes fresh parameters of
`argTypes` and calls `expr` with them, with a new lambda id in `home`. It
builds the same closure as `makeAliasClosureGO`.
-}
makeGeneralClosureGO :
    ModuleName.Canonical
    -> Mono.MonoExpr
    -> List Mono.MonoType
    -> Mono.MonoType
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
makeGeneralClosureGO home expr argTypes retType funcType ctx =
    let
        params =
            Closure.freshParams argTypes

        paramExprs =
            List.map (\( name, ty ) -> Mono.MonoVarLocal name ty) params

        ( lambdaId, ctx1 ) =
            freshLambdaId home ctx

        region =
            Closure.extractRegion expr

        callExpr =
            Mono.MonoCall region expr paramExprs retType Mono.defaultCallInfo

        captures =
            Closure.computeClosureCaptures params callExpr

        closureInfo =
            { lambdaId = lambdaId
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = captures
            , params = params
            , closureKind = Nothing
            , captureAbi = Nothing
            }
    in
    ( Mono.MonoClosure closureInfo callExpr funcType, ctx1 )


{-| Returns `expr` as a closure when `monoType` is a function type, and
unchanged otherwise or when it already is a closure.

A global becomes a closure over the first stage of `monoType` that calls it. A
kernel becomes a closure taking all of the kernel's arguments at once, with the
kernel's own flattened type and a ⊤ lambda-set annotation on its arrow. Any
other expression becomes a closure over the first stage of `monoType` that
calls the expression.

-}
ensureCallableForNode :
    ModuleName.Canonical
    -> Mono.MonoExpr
    -> Mono.MonoType
    -> GlobalCtx
    -> ( Mono.MonoExpr, GlobalCtx )
ensureCallableForNode home expr monoType ctx =
    case monoType of
        Mono.MFunction _ _ _ _ ->
            let
                stageArgTypes =
                    Mono.stageParamTypes monoType

                stageRetType =
                    Mono.stageReturnType monoType
            in
            case expr of
                Mono.MonoClosure _ _ _ ->
                    ( expr, ctx )

                Mono.MonoVarGlobal region specId _ ->
                    makeAliasClosureGO home
                        (Mono.MonoVarGlobal region specId monoType)
                        stageArgTypes
                        stageRetType
                        monoType
                        ctx

                Mono.MonoVarKernel region kernelPrefix kernelHome name kernelAbiType ->
                    let
                        ( kernelFlatArgTypes, kernelFlatRetType ) =
                            Closure.flattenFunctionType kernelAbiType

                        flattenedFuncType =
                            Mono.mFunction Mono.topSynth kernelFlatArgTypes kernelFlatRetType
                    in
                    makeAliasClosureGO home
                        (Mono.MonoVarKernel region kernelPrefix kernelHome name kernelAbiType)
                        kernelFlatArgTypes
                        kernelFlatRetType
                        flattenedFuncType
                        ctx

                _ ->
                    makeGeneralClosureGO home expr stageArgTypes stageRetType monoType ctx

        _ ->
            ( expr, ctx )


{-| Returns the graph with every define and port whose type is a function
wrapped in a closure, as `ensureCallableForNode` describes, and the graph's
`nextLambdaIndex` advanced past the lambda ids the wrappers took.
-}
wrapTopLevelCallables : Mono.MonoGraph -> Mono.MonoGraph
wrapTopLevelCallables (Mono.MonoGraph record0) =
    let
        ctx0 =
            initGlobalCtx (Mono.MonoGraph record0)

        ( newNodes, finalCtx ) =
            Array.foldl
                (\maybeNode ( accNodes, specId, accCtx ) ->
                    case maybeNode of
                        Just node ->
                            let
                                home =
                                    specHome accCtx.registry specId

                                ( newNode, accCtx1 ) =
                                    wrapNodeCallables home node accCtx
                            in
                            ( Array.push (Just newNode) accNodes, specId + 1, accCtx1 )

                        Nothing ->
                            ( Array.push Nothing accNodes, specId + 1, accCtx )
                )
                ( Array.empty, 0, ctx0 )
                record0.nodes
                |> (\( n, _, c ) -> ( n, c ))
    in
    Mono.MonoGraph { record0 | nodes = newNodes, nextLambdaIndex = finalCtx.lambdaCounter }


{-| Returns a define or port node with its expression made a closure, as
`ensureCallableForNode` describes, and any other node unchanged.
-}
wrapNodeCallables :
    ModuleName.Canonical
    -> Mono.MonoNode
    -> GlobalCtx
    -> ( Mono.MonoNode, GlobalCtx )
wrapNodeCallables home node ctx =
    case node of
        Mono.MonoDefine expr tipe ->
            let
                ( callableExpr, ctx1 ) =
                    ensureCallableForNode home expr tipe ctx
            in
            ( Mono.MonoDefine callableExpr tipe, ctx1 )

        Mono.MonoPortIncoming expr tipe ->
            let
                ( callableExpr, ctx1 ) =
                    ensureCallableForNode home expr tipe ctx
            in
            ( Mono.MonoPortIncoming callableExpr tipe, ctx1 )

        Mono.MonoPortOutgoing expr tipe ->
            let
                ( callableExpr, ctx1 ) =
                    ensureCallableForNode home expr tipe ctx
            in
            ( Mono.MonoPortOutgoing callableExpr tipe, ctx1 )

        Mono.MonoTailFunc params body tipe ->
            ( Mono.MonoTailFunc params body tipe, ctx )

        Mono.MonoCtor shape tipe ->
            ( Mono.MonoCtor shape tipe, ctx )

        Mono.MonoEnum tag tipe ->
            ( Mono.MonoEnum tag tipe, ctx )

        Mono.MonoExtern tipe ->
            ( Mono.MonoExtern tipe, ctx )

        Mono.MonoManagerLeaf leafHome tipe ->
            ( Mono.MonoManagerLeaf leafHome tipe, ctx )



-- CALL STAGING ANNOTATION


{-| Returns the graph with a `CallInfo` on every `MonoCall` in its defines,
tail functions and ports.

A call whose `CallInfo` already has a non-empty `stageArities` keeps it as it
is. Any other call gets one derived by `computeCallInfo`, into which the fields
AbiCloning stamps (`closureKind`, `captureAbi`, `fastEvaluator`,
`fastEvaluatorSpec` and `fastPapPrefix`) are copied from the call's existing
`CallInfo`, since the derivation knows nothing of them.

-}
annotateCallStaging : Mono.MonoGraph -> Mono.MonoGraph
annotateCallStaging graph =
    let
        (Mono.MonoGraph record) =
            graph

        env =
            emptyCallEnv

        newNodes =
            Array.indexedMap
                (\nodeId -> Maybe.map (annotateNodeCalls graph nodeId env))
                record.nodes
    in
    Mono.MonoGraph { record | nodes = newNodes }


{-| Returns a node with its calls annotated. A tail function's function-typed
parameters are dynamic callees in its body.
-}
annotateNodeCalls : Mono.MonoGraph -> Int -> CallEnv -> Mono.MonoNode -> Mono.MonoNode
annotateNodeCalls graph nodeId env node =
    case node of
        Mono.MonoDefine expr tipe ->
            Mono.MonoDefine (annotateExprCalls graph env expr) tipe

        Mono.MonoTailFunc params body tipe ->
            let
                dynamicParams =
                    params
                        |> List.filterMap
                            (\( name, ty ) ->
                                if Mono.isFunctionType ty then
                                    Just name

                                else
                                    Nothing
                            )
                        |> Set.fromList

                envWithParams =
                    { env | dynamicParams = dynamicParams }
            in
            Mono.MonoTailFunc params (annotateExprCalls graph envWithParams body) tipe

        Mono.MonoPortIncoming expr tipe ->
            Mono.MonoPortIncoming (annotateExprCalls graph env expr) tipe

        Mono.MonoPortOutgoing expr tipe ->
            Mono.MonoPortOutgoing (annotateExprCalls graph env expr) tipe

        _ ->
            node


{-| Returns `expr` with every call in it annotated, given what `env` knows of
the names in scope. A `let` definition extends the environment for its body,
and a closure's captures with a known source arity extend it for the closure
body.
-}
annotateExprCalls : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Mono.MonoExpr
annotateExprCalls graph env expr =
    let
        recurse =
            annotateExprCalls graph env
    in
    case expr of
        Mono.MonoLet def body tipe ->
            let
                ( def1, env1 ) =
                    annotateDefCalls graph env def

                body1 =
                    annotateExprCalls graph env1 body
            in
            Mono.MonoLet def1 body1 tipe

        Mono.MonoCall region func args resultType existingCallInfo ->
            let
                newFunc =
                    recurse func

                newArgs =
                    List.map recurse args

                callInfo =
                    if not (List.isEmpty existingCallInfo.stageArities) then
                        existingCallInfo

                    else
                        let
                            derived =
                                computeCallInfo graph env newFunc newArgs resultType
                        in
                        { derived
                            | closureKind = existingCallInfo.closureKind
                            , captureAbi = existingCallInfo.captureAbi
                            , fastEvaluator = existingCallInfo.fastEvaluator
                            , fastEvaluatorSpec = existingCallInfo.fastEvaluatorSpec
                            , fastPapPrefix = existingCallInfo.fastPapPrefix
                        }
            in
            Mono.MonoCall region newFunc newArgs resultType callInfo

        Mono.MonoCase label scrutinee decider jumps resultType ->
            let
                newDecider =
                    annotateDeciderCalls graph env decider

                newJumps =
                    List.map (\( i, e ) -> ( i, recurse e )) jumps
            in
            Mono.MonoCase label scrutinee newDecider newJumps resultType

        Mono.MonoIf branches final resultType ->
            let
                newBranches =
                    List.map (\( c, t ) -> ( recurse c, recurse t )) branches

                newFinal =
                    recurse final
            in
            Mono.MonoIf newBranches newFinal resultType

        Mono.MonoClosure info body closureType ->
            let
                newCaptures =
                    List.map (\( n, e, t ) -> ( n, annotateExprCalls graph env e, t )) info.captures

                envWithCaptures =
                    List.foldl
                        (\( name, captureExpr, _ ) envAcc ->
                            case sourceArityForExpr graph envAcc captureExpr of
                                Just arity ->
                                    { envAcc
                                        | varSourceArity =
                                            Dict.insert name arity envAcc.varSourceArity
                                    }

                                Nothing ->
                                    envAcc
                        )
                        env
                        newCaptures

                newBody =
                    annotateExprCalls graph envWithCaptures body
            in
            Mono.MonoClosure { info | captures = newCaptures } newBody closureType

        Mono.MonoTailCall name args resultType ->
            let
                newArgs =
                    List.map (\( n, e ) -> ( n, recurse e )) args
            in
            Mono.MonoTailCall name newArgs resultType

        Mono.MonoDestruct path inner resultType ->
            Mono.MonoDestruct path (recurse inner) resultType

        Mono.MonoList region items resultType ->
            Mono.MonoList region (List.map recurse items) resultType

        Mono.MonoRecordCreate fields resultType ->
            let
                newFields =
                    List.map (\( n, e ) -> ( n, recurse e )) fields
            in
            Mono.MonoRecordCreate newFields resultType

        Mono.MonoRecordAccess inner field resultType ->
            Mono.MonoRecordAccess (recurse inner) field resultType

        Mono.MonoRecordUpdate record updates resultType ->
            let
                newRecord =
                    recurse record

                newUpdates =
                    List.map (\( n, e ) -> ( n, recurse e )) updates
            in
            Mono.MonoRecordUpdate newRecord newUpdates resultType

        Mono.MonoTupleCreate region elements resultType ->
            Mono.MonoTupleCreate region (List.map recurse elements) resultType

        Mono.MonoLiteral _ _ ->
            expr

        Mono.MonoVarLocal _ _ ->
            expr

        Mono.MonoVarGlobal _ _ _ ->
            expr

        Mono.MonoVarKernel _ _ _ _ _ ->
            expr

        Mono.MonoUnit ->
            expr

        Mono.MonoAccessorValue _ _ _ ->
            expr


{-| Returns a `let` definition with its calls annotated, and the environment
for the `let` body.

A plain definition is annotated in `env`, then its name is recorded with
whatever its annotated bound expression shows: call model, source arity,
stages after the first, and polymorphic return. A tail definition's name is
recorded with its parameter count as source arity, and its body is annotated
with that entry in scope.

-}
annotateDefCalls :
    Mono.MonoGraph
    -> CallEnv
    -> Mono.MonoDef
    -> ( Mono.MonoDef, CallEnv )
annotateDefCalls graph env def =
    case def of
        Mono.MonoDef name bound ->
            let
                bound1 =
                    annotateExprCalls graph env bound

                maybeModel =
                    callModelForExpr graph env bound1

                maybeSourceArity =
                    sourceArityForExpr graph env bound1

                env1 =
                    case maybeModel of
                        Just model ->
                            { env
                                | varCallModel =
                                    Dict.insert name model env.varCallModel
                            }

                        Nothing ->
                            env

                env2 =
                    case maybeSourceArity of
                        Just arity ->
                            { env1
                                | varSourceArity =
                                    Dict.insert name arity env1.varSourceArity
                            }

                        Nothing ->
                            env1

                maybeBodyStageArities =
                    closureBodyStageArities graph bound1

                env3 =
                    case maybeBodyStageArities of
                        Just arities ->
                            { env2
                                | varBodyStageArities =
                                    Dict.insert name arities env2.varBodyStageArities
                            }

                        Nothing ->
                            env2

                env4 =
                    if exprHasPolymorphicReturn env3 bound1 then
                        { env3
                            | varPolymorphicReturn =
                                Set.insert name env3.varPolymorphicReturn
                        }

                    else
                        env3
            in
            ( Mono.MonoDef name bound1, env4 )

        Mono.MonoTailDef name params bound ->
            let
                tailArity =
                    List.length params

                env1 =
                    { env
                        | varSourceArity =
                            Dict.insert name tailArity env.varSourceArity
                    }
            in
            ( Mono.MonoTailDef name params (annotateExprCalls graph env1 bound), env1 )


{-| Returns a decision tree with the calls in its inline leaves annotated.
-}
annotateDeciderCalls : Mono.MonoGraph -> CallEnv -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
annotateDeciderCalls graph env decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (annotateChoiceCalls graph env choice)

        Mono.Chain edges success failure ->
            Mono.Chain edges
                (annotateDeciderCalls graph env success)
                (annotateDeciderCalls graph env failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, annotateDeciderCalls graph env d )) edges)
                (annotateDeciderCalls graph env fallback)


{-| Returns a decision-tree leaf with its calls annotated, if it holds an
expression rather than a jump.
-}
annotateChoiceCalls : Mono.MonoGraph -> CallEnv -> Mono.MonoChoice -> Mono.MonoChoice
annotateChoiceCalls graph env choice =
    case choice of
        Mono.Inline expr ->
            Mono.Inline (annotateExprCalls graph env expr)

        Mono.Jump i ->
            Mono.Jump i


{-| Returns the call model of a callee when it can be read from the
expression: `FlattenedExternal` for a kernel, or for a global whose node is an
extern, manager leaf, constructor or enum; `StageCurried` for a closure or any
other global; the recorded model for a local; `Nothing` otherwise.
-}
callModelForExpr : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Maybe Mono.CallModel
callModelForExpr (Mono.MonoGraph { nodes }) env expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            case Array.get specId nodes |> Maybe.andThen identity of
                Just (Mono.MonoExtern _) ->
                    Just Mono.FlattenedExternal

                Just (Mono.MonoManagerLeaf _ _) ->
                    Just Mono.FlattenedExternal

                Just (Mono.MonoCtor _ _) ->
                    Just Mono.FlattenedExternal

                Just (Mono.MonoEnum _ _) ->
                    Just Mono.FlattenedExternal

                _ ->
                    Just Mono.StageCurried

        Mono.MonoVarKernel _ _ _ _ _ ->
            Just Mono.FlattenedExternal

        Mono.MonoVarLocal name _ ->
            Dict.get name env.varCallModel

        Mono.MonoClosure _ _ _ ->
            Just Mono.StageCurried

        _ ->
            Nothing


{-| Returns the call model of a callee, `StageCurried` when
`callModelForExpr` cannot tell.
-}
callModelForCallee : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Mono.CallModel
callModelForCallee graph env funcExpr =
    case callModelForExpr graph env funcExpr of
        Just model ->
            model

        Nothing ->
            Mono.StageCurried


{-| Returns the source arity of a function value when the expression shows
it, or `Nothing`.

For a global it comes from the node: a define's closure parameter count (a
define that is not a closure gives `Nothing`), a tail function's parameter
count, all the arguments of an extern or manager leaf, a constructor's field
count, 0 for an enum, and a port's closure parameter count or 0. A kernel takes
all its arguments; a closure, its parameters; a local, its recorded entry.

For a call it is the arity left over: the callee's source arity minus the
arguments, while that is positive. A call that uses up the first stage takes
its answer from the callee's later stages as `closureBodyStageArities` reads
them, with any excess arguments consumed stage by stage, and gives `Nothing`
when those stages are unknown, rather than a guess from the type. A `let`
gives its body's source arity.

-}
sourceArityForExpr : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Maybe Int
sourceArityForExpr graph env expr =
    let
        (Mono.MonoGraph { nodes }) =
            graph
    in
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            case Array.get specId nodes |> Maybe.andThen identity of
                Just (Mono.MonoDefine innerExpr _) ->
                    case innerExpr of
                        Mono.MonoClosure closureInfo _ _ ->
                            Just (List.length closureInfo.params)

                        _ ->
                            Nothing

                Just (Mono.MonoTailFunc params _ _) ->
                    Just (List.length params)

                Just (Mono.MonoExtern monoType) ->
                    Just (List.length (Tuple.first (Mono.decomposeFunctionType monoType)))

                Just (Mono.MonoManagerLeaf _ monoType) ->
                    Just (List.length (Tuple.first (Mono.decomposeFunctionType monoType)))

                Just (Mono.MonoCtor shape _) ->
                    Just (List.length shape.fieldTypes)

                Just (Mono.MonoEnum _ _) ->
                    Just 0

                Just (Mono.MonoPortIncoming innerExpr _) ->
                    case innerExpr of
                        Mono.MonoClosure closureInfo _ _ ->
                            Just (List.length closureInfo.params)

                        _ ->
                            Just 0

                Just (Mono.MonoPortOutgoing innerExpr _) ->
                    case innerExpr of
                        Mono.MonoClosure closureInfo _ _ ->
                            Just (List.length closureInfo.params)

                        _ ->
                            Just 0

                Nothing ->
                    Nothing

        Mono.MonoVarKernel _ _ _ _ kernelType ->
            Just (List.length (Tuple.first (Mono.decomposeFunctionType kernelType)))

        Mono.MonoVarLocal name _ ->
            Dict.get name env.varSourceArity

        Mono.MonoClosure closureInfo _ _ ->
            Just (List.length closureInfo.params)

        Mono.MonoCall _ func args _ _ ->
            case sourceArityForExpr graph env func of
                Just sourceArity ->
                    let
                        argCount =
                            List.length args

                        resultArity =
                            sourceArity - argCount
                    in
                    if resultArity > 0 then
                        Just resultArity

                    else
                        let
                            excessArgs =
                                argCount - sourceArity

                            consumeFromStages excess stages =
                                case stages of
                                    [] ->
                                        Nothing

                                    stage :: rest ->
                                        if excess >= stage then
                                            consumeFromStages (excess - stage) rest

                                        else
                                            Just (stage - excess)
                        in
                        case closureBodyStageArities graph func of
                            Just stages ->
                                consumeFromStages excessArgs stages

                            Nothing ->
                                Nothing

                Nothing ->
                    Nothing

        Mono.MonoLet def body _ ->
            sourceArityForExpr graph (extendSourceArityEnv graph env def) body

        _ ->
            Nothing


{-| Returns `env` with the source arity of a `let` definition recorded, as
`annotateDefCalls` records it, without annotating the definition.

`sourceArityForExpr` reads only `varSourceArity`, so this is all it needs.
Calling `annotateDefCalls` instead would annotate the bound expression again
each time, which is exponential in the depth of `let`s nested in bound
position.

-}
extendSourceArityEnv : Mono.MonoGraph -> CallEnv -> Mono.MonoDef -> CallEnv
extendSourceArityEnv graph env def =
    case def of
        Mono.MonoDef name bound ->
            case sourceArityForExpr graph env bound of
                Just arity ->
                    { env | varSourceArity = Dict.insert name arity env.varSourceArity }

                Nothing ->
                    env

        Mono.MonoTailDef name params _ ->
            { env | varSourceArity = Dict.insert name (List.length params) env.varSourceArity }


{-| Where a callee's source arity came from.

`FromProducer` is an arity read from the closure or function that produces the
value. `FromType` is the first stage of the callee's type, used when no
producer is known, as for a function parameter. A call through a callee whose
arity is `FromType` gets an `initialRemaining` of 0 and is never
`CallDirectKnownSegmentation`.

-}
type SourceArity
    = FromProducer Int
    | FromType Int


{-| Returns the source arity of a callee, falling back to the first stage of
its type when `sourceArityForExpr` cannot tell.
-}
sourceArityForCallee : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> SourceArity
sourceArityForCallee graph env funcExpr =
    case sourceArityForExpr graph env funcExpr of
        Just arity ->
            FromProducer arity

        Nothing ->
            FromType (firstStageArityFromType (Mono.typeOf funcExpr))


{-| Returns the number of arguments in the first stage of a function type, so
2 for `MFunction [a, b] (MFunction [c] d)`, and 0 for a type that is not a
function.
-}
firstStageArityFromType : Mono.MonoType -> Int
firstStageArityFromType monoType =
    case monoType of
        Mono.MFunction _ _ argTypes _ ->
            List.length argTypes

        _ ->
            0


{-| Returns the segmentation of what a callee returns once its first stage is
applied, read from the code that produces it, or `Nothing` when that code does
not show it.

For a closure it is the stages of its body's type. For a global it depends on
the node: a tail function gives the stages of its body's type; a define or
port whose expression is a closure looks at the closure's body, and answers
only when that body is a `case` or `if` whose branches agree, as below; a
define or port whose expression is itself a `case` or `if` is read the same
way. Anything else gives `Nothing`, rather than a guess from the type.

A `case` or `if` claims a segmentation only when every branch, `case` jumps and
inline leaves alike, is a closure and all of them have the same segmentation
(the closure's parameter count followed by the stages of its body's type).
Staging regroups each closure separately, so branches can disagree.

-}
closureBodyStageArities : Mono.MonoGraph -> Mono.MonoExpr -> Maybe (List Int)
closureBodyStageArities graph expr =
    let
        (Mono.MonoGraph { nodes }) =
            graph

        getNodeBodyArities : Mono.MonoNode -> Maybe (List Int)
        getNodeBodyArities node =
            case node of
                Mono.MonoDefine innerExpr _ ->
                    getExprBodyArities innerExpr

                Mono.MonoTailFunc _ bodyExpr _ ->
                    Just (MonoReturnArity.collectStageArities (Mono.typeOf bodyExpr))

                Mono.MonoPortIncoming innerExpr _ ->
                    getExprBodyArities innerExpr

                Mono.MonoPortOutgoing innerExpr _ ->
                    getExprBodyArities innerExpr

                _ ->
                    Nothing

        -- Branches inlined into the decision tree are in Inline leaves, not in the jumps.
        inlineLeaves : Mono.Decider Mono.MonoChoice -> List Mono.MonoExpr -> List Mono.MonoExpr
        inlineLeaves decider acc =
            case decider of
                Mono.Leaf (Mono.Inline inlineExpr) ->
                    inlineExpr :: acc

                Mono.Leaf (Mono.Jump _) ->
                    acc

                Mono.Chain _ yes no ->
                    inlineLeaves no (inlineLeaves yes acc)

                Mono.FanOut _ tests fallback ->
                    inlineLeaves fallback (List.foldl (\( _, d ) a -> inlineLeaves d a) acc tests)

        agreedArities : List Mono.MonoExpr -> Maybe (List Int)
        agreedArities branchExprs =
            case List.map getClosureArityFromExpr branchExprs of
                (Just first) :: rest ->
                    if List.all (\r -> r == Just first) rest then
                        Just first

                    else
                        Nothing

                _ ->
                    Nothing

        getClosureArityFromCase : Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Maybe (List Int)
        getClosureArityFromCase decider jumps =
            agreedArities (List.map Tuple.second jumps ++ inlineLeaves decider [])

        getClosureArityFromIf : List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> Maybe (List Int)
        getClosureArityFromIf branches final =
            agreedArities (List.map Tuple.second branches ++ [ final ])

        getExprBodyArities : Mono.MonoExpr -> Maybe (List Int)
        getExprBodyArities e =
            case e of
                Mono.MonoClosure _ body _ ->
                    case body of
                        Mono.MonoCase _ _ decider jumps _ ->
                            getClosureArityFromCase decider jumps

                        Mono.MonoIf branches final _ ->
                            getClosureArityFromIf branches final

                        _ ->
                            Nothing

                Mono.MonoCase _ _ decider jumps _ ->
                    getClosureArityFromCase decider jumps

                Mono.MonoIf branches final _ ->
                    getClosureArityFromIf branches final

                _ ->
                    Nothing

        getClosureArityFromExpr : Mono.MonoExpr -> Maybe (List Int)
        getClosureArityFromExpr e =
            case e of
                Mono.MonoClosure closureInfo body _ ->
                    Just (List.length closureInfo.params :: MonoReturnArity.collectStageArities (Mono.typeOf body))

                _ ->
                    Nothing
    in
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            Array.get specId nodes
                |> Maybe.andThen identity
                |> Maybe.andThen getNodeBodyArities

        Mono.MonoClosure _ body _ ->
            Just (MonoReturnArity.collectStageArities (Mono.typeOf body))

        _ ->
            Nothing


{-| Returns whether a callee is a function-typed parameter of the enclosing
tail function.
-}
isDynamicCallee : CallEnv -> Mono.MonoExpr -> Bool
isDynamicCallee env funcExpr =
    case funcExpr of
        Mono.MonoVarLocal name monoType ->
            Set.member name env.dynamicParams && Mono.isFunctionType monoType

        _ ->
            False


{-| Returns whether a `let`-bound expression is to be recorded in
`varPolymorphicReturn`: a call, saturated or not, whose callee's type has a
`CEcoValue` type variable as its final return type, or a local already
recorded.

A call through a recorded name is made with `CallGenericApply`, because the
underlying function's result is a `CEcoValue` while the type at the call site
may say otherwise.

-}
exprHasPolymorphicReturn : CallEnv -> Mono.MonoExpr -> Bool
exprHasPolymorphicReturn env expr =
    let
        hasCEcoValueReturn : Mono.MonoType -> Bool
        hasCEcoValueReturn monoType =
            let
                ( _, finalReturn ) =
                    Mono.decomposeFunctionType monoType
            in
            case finalReturn of
                Mono.MVar _ Mono.CEcoValue ->
                    True

                _ ->
                    False
    in
    case expr of
        Mono.MonoCall _ func _ _ _ ->
            hasCEcoValueReturn (Mono.typeOf func)

        Mono.MonoVarLocal name _ ->
            Set.member name env.varPolymorphicReturn

        _ ->
            False


{-| Returns whether a callee is a local recorded in `varPolymorphicReturn`.
-}
calleeHasPolymorphicReturn : CallEnv -> Mono.MonoExpr -> Bool
calleeHasPolymorphicReturn env funcExpr =
    case funcExpr of
        Mono.MonoVarLocal name _ ->
            Set.member name env.varPolymorphicReturn

        _ ->
            False


{-| Returns `t` with `n` function layers removed, stopping early at a type that
is not a function.

A layer is one `MFunction`, however many arguments it takes. Its one caller
passes a count of arguments, not of layers, so for a type whose layers take
several arguments this can peel too far and stop at the final result.

-}
peelStages : Int -> Mono.MonoType -> Mono.MonoType
peelStages n t =
    if n <= 0 then
        t

    else
        case t of
            Mono.MFunction _ _ _ body ->
                peelStages (n - 1) body

            _ ->
                t


{-| Returns the return type of the evaluator that the saturating application
of a call invokes, given the call's `resultType`, the arguments the call
consumes over all stages, and the callee's type.

It is `funcType` with `totalArgsConsumed` layers peeled. When that is still a
function but `resultType` is not, it is the final result of the peeled type
instead: a callee's type can be the full curried type of the function rather
than of the partial application being called, and then the peel stops short. A
call whose result is itself a function keeps the peeled type, so that a
function returning a closure is not peeled past its last stage.

-}
saturatingEvaluatorReturnType : Mono.MonoType -> Int -> Mono.MonoType -> Mono.MonoType
saturatingEvaluatorReturnType resultType totalArgsConsumed funcType =
    let
        peeled =
            peelStages totalArgsConsumed funcType
    in
    if Mono.isFunctionType peeled && not (Mono.isFunctionType resultType) then
        Tuple.second (Mono.decomposeFunctionType peeled)

    else
        peeled


{-| Returns the `CallInfo` for a call of `func` with `args`, its AbiCloning
stamp fields empty.

A `FlattenedExternal` callee gets `CallDirectFlat`, no stages, and
`resultType` as its evaluator return type, since a kernel's or extern's
result already matches its declared signature.

A `StageCurried` callee gets the segmentation of its type as `stageArities`.
`initialRemaining` is its source arity when a producer shows it and 0
otherwise, and the call is single-stage saturated when the arguments exactly
fill a positive `initialRemaining`. `remainingStageArities` comes from
`closureBodyStageArities`, or for a local from its recorded entry, and is
empty when neither knows. The call kind is `CallGenericApply` for a dynamic
callee or one recorded in `varPolymorphicReturn`. Otherwise it is
`CallSegmentationUnknown` when the source arity came from the type, or when
the call passes more arguments than a known positive source arity with no
later stages known, and `CallDirectKnownSegmentation` in the remaining cases.

-}
computeCallInfo :
    Mono.MonoGraph
    -> CallEnv
    -> Mono.MonoExpr
    -> List Mono.MonoExpr
    -> Mono.MonoType
    -> Mono.CallInfo
computeCallInfo graph env func args resultType =
    let
        callModel =
            callModelForCallee graph env func
    in
    case callModel of
        Mono.FlattenedExternal ->
            { callModel = Mono.FlattenedExternal
            , stageArities = []
            , isSingleStageSaturated = False
            , initialRemaining = 0
            , remainingStageArities = []
            , closureKind = Nothing
            , captureAbi = Nothing
            , fastEvaluator = Nothing
            , fastEvaluatorSpec = Nothing
            , fastPapPrefix = Nothing
            , callKind = Mono.CallDirectFlat
            , evaluatorReturnType = resultType
            }

        Mono.StageCurried ->
            let
                funcType : Mono.MonoType
                funcType =
                    Mono.typeOf func

                stageAritiesFull : List Int
                stageAritiesFull =
                    MonoReturnArity.collectStageArities funcType

                sourceArityInfo : SourceArity
                sourceArityInfo =
                    sourceArityForCallee graph env func

                sourceArity : Int
                sourceArity =
                    case sourceArityInfo of
                        FromProducer a ->
                            a

                        FromType _ ->
                            0

                argCount : Int
                argCount =
                    List.length args

                isSingleStageSaturated : Bool
                isSingleStageSaturated =
                    argCount == sourceArity && sourceArity > 0

                -- Must equal the remaining arity of the PAP being extended.
                initialRemaining : Int
                initialRemaining =
                    sourceArity

                remainingStageArities : List Int
                remainingStageArities =
                    case closureBodyStageArities graph func of
                        Just arities ->
                            arities

                        Nothing ->
                            case func of
                                Mono.MonoVarLocal name _ ->
                                    Dict.get name env.varBodyStageArities
                                        |> Maybe.withDefault []

                                _ ->
                                    []

                hasUnknownExcessArgs : Bool
                hasUnknownExcessArgs =
                    argCount > sourceArity && List.isEmpty remainingStageArities && sourceArity > 0

                callKind : Mono.CallKind
                callKind =
                    case sourceArityInfo of
                        FromProducer _ ->
                            if isDynamicCallee env func then
                                Mono.CallGenericApply

                            else if calleeHasPolymorphicReturn env func then
                                Mono.CallGenericApply

                            else if hasUnknownExcessArgs then
                                Mono.CallSegmentationUnknown

                            else
                                Mono.CallDirectKnownSegmentation

                        FromType _ ->
                            if isDynamicCallee env func || calleeHasPolymorphicReturn env func then
                                Mono.CallGenericApply

                            else
                                Mono.CallSegmentationUnknown

                -- Arguments, not stages: a curried type such as
                -- MFunction [Int] (MFunction [Int] Int) can belong to a closure staged [2].
                totalArgsConsumed : Int
                totalArgsConsumed =
                    initialRemaining + List.sum remainingStageArities

                evaluatorReturnType : Mono.MonoType
                evaluatorReturnType =
                    saturatingEvaluatorReturnType resultType totalArgsConsumed funcType
            in
            { callModel = Mono.StageCurried
            , stageArities = stageAritiesFull
            , isSingleStageSaturated = isSingleStageSaturated
            , initialRemaining = initialRemaining
            , remainingStageArities = remainingStageArities
            , closureKind = Nothing
            , captureAbi = Nothing
            , fastEvaluator = Nothing
            , fastEvaluatorSpec = Nothing
            , fastPapPrefix = Nothing
            , callKind = callKind
            , evaluatorReturnType = evaluatorReturnType
            }
