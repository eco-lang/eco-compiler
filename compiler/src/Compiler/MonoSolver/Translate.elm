module Compiler.MonoSolver.Translate exposing
    ( translate
    , demandUnifyRoot, enumNode, specializeCtorViaScheme, specializeCycle, specializePort, stampSelfSpine
    )

{-| The solver engine monomorphizes a program one specialization at a time, and
this module turns one definition, demanded at one MonoType, into its
monomorphized node.

A _demand_ is the MonoType a specialization of a global is requested at. The
engine gives each work item a union-find store of its own (see
`Compiler.MonoSolver.Store` for loads, unification and read-back), and every
type here is decided in that store. The definition's annotation is unified
with the demand first (`demandUnifyRoot`), so the annotation's type variables,
which the body shares through the item's memo, take on the demanded types.
Each expression is then translated (`translate`), and every global it refers
to is enqueued as a spec of its own at the type this use needs.

A node's type normally comes from classifying its canonical type, which reads
the store for the type variables the item has bound. Before a child is
translated, its type is _connected_ to the type its context gives it: the two
are unified, best effort, so the child sees what the context already knows.
List elements, tuple slots, record fields, branches of an `if` or `case`, the
bodies of `let` and destructuring, and tail-call arguments are connected this
way. A call unifies the callee's freshly instantiated type with its arguments
and with the call's type before translating the arguments, which is how a
demand reaches a local's uses. Unsupported expressions and broken invariants
abort the build (`Engine.crashFailure`).

A `let` that binds a function, or a value with functions inside it and a free
type variable, is specialized once per type it is used at (or translated once
under its own name when it is never used): the
`let` body is translated first, each use recording its type, and each recorded
type gets its own copy of the definition (`f`, `f$1`, ...), translated again at
that type in a scratch store. A `let` that binds a value of unresolved `number`
type is treated the same way, with copies `n$v1`, ... . A local tail-recursive
function is also translated after the body: once under its own name when it is
used at one type or none, and once per type otherwise.

Under lambda-set specialization (LSS, `env.lss.enabled`) every arrow in the
store also carries a _lambda set_: the _members_ that can reach it, each member
an id for one function value. This module writes the members it can see. A
lambda gets its own member on the first arrows of its type, one per parameter.
A reference to a global or constructor gets a `g|` or `c|` member on its head
arrow, and a reference to a kernel or accessor a `k|` or `a|` member there. A
partial application of a global gets a
`p|` member of its own, never the global's, since it is the global with some
arguments already bound. A kernel's sets are poisoned (made ⊤, meaning
anything may reach them) unless `KernelSetFacts` says otherwise. Where a
container or branch has several children, the sets of the result are joined
over all of them, because one child's set is a claim the others can falsify.

Lambda sets make _devirtualization_ possible: an indirect call through a local
variable whose set has exactly one member, standing for a constructor, a global
function or a kernel registered for it, is rewritten into a direct call when
the call supplies exactly that target's parameters. A set may be
provisional; when a spec's demand widens later, the engine translates the node
again and the decision is made again.

Much of the file is census code, gated on `lss.report`, that counts how
members were written and read without changing what is generated.

@docs translate
@docs demandUnifyRoot, enumNode, specializeCtorViaScheme, specializeCycle, specializePort, stampSelfSpine

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), Step)
import Compiler.MonoSolver.KernelSetFacts as KernelSetFacts
import Compiler.MonoSolver.LssInfer as LssInfer
import Compiler.MonoSolver.Store as Store
import Compiler.MonoSolver.Zonk as Zonk
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.State as State
import Compiler.Reporting.Annotation as A
import Compiler.Type.UnionFind as UF
import Data.HashMap as HashMap
import Data.Map as DMap
import Data.Set as EverySet
import Dict
import Set


{-| Returns the MonoType of `canType` as `Store.classifyDirect` reads it,
with every arrow ⊤ labelled `topKind`.

The label is one of the `Mono.tkClass*` provenance codes and says which kind of
expression was being classified. It is diagnostic only: nothing that decides
code reads a ⊤'s label.

-}
classifyAs : Int -> Can.Type TypeIds.MVarId -> Engine.S -> ( Mono.MonoType, Engine.S )
classifyAs topKind canType s =
    Store.classifyDirect topKind canType s


{-| Unifies a definition's annotation, loaded through the item memo, with a
demanded MonoType, so that the annotation's type variables, which the body
shares, become the demand's types. A mismatch aborts the build
(`Store.unifyStrictS`).
-}
demandUnify : Can.Type TypeIds.MVarId -> Mono.MonoType -> Engine.S -> Engine.S
demandUnify annCanType demand s0 =
    Tuple.second (demandUnifyVar annCanType demand s0)


{-| Does what `demandUnify` does and also returns the variable the annotation
was loaded as.

The variable is returned because a load mints new arrow structure each time;
only type variables are shared through the memo. Loading a ground annotation
again would therefore not see the lambda sets the demand put on its arrows.

-}
demandUnifyVar : Can.Type TypeIds.MVarId -> Mono.MonoType -> Engine.S -> ( Vars.Variable, Engine.S )
demandUnifyVar annCanType demand s0 =
    case Store.loadTypeS annCanType s0 of
        ( annVar, s1 ) ->
            case Store.monoTypeToVarS demand s1 of
                ( demandVar, s2 ) ->
                    ( annVar
                    , Store.unifyStrictS
                        (\() -> "demandUnify " ++ canKind annCanType ++ " vs " ++ monoKind demand)
                        annVar
                        demandVar
                        s2
                    )


{-| Seeds a definition's annotation with its demand before the body is
translated, as `demandUnify` does.

With lambda-set specialization (LSS) on and a body that is syntactically a
lambda, the seeded annotation variable is also kept in the item state
(`lssRootAnn`) so that the body's own lambda takes its type from it rather than
from a fresh load. With LSS and the `lss.qCensus` setting on, the variable is
also kept for that census (`qSigRoot`), whatever the body.

-}
demandUnifyRoot : Can.Type TypeIds.MVarId -> Mono.MonoType -> TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
demandUnifyRoot annCanType demand expr s0 =
    case demandUnifyVar annCanType demand s0 of
        ( annVar, s1 ) ->
            let
                -- Not limited to lambdas: a value such as `fns = [ incr, decr ]` has arrows too.
                sQ =
                    if s1.env.lss.enabled && s1.env.lss.qCensus then
                        let
                            auxQ =
                                s1.itemAux
                        in
                        { s1 | itemAux = { auxQ | qSigRoot = Just annVar } }

                    else
                        s1
            in
            if sQ.env.lss.enabled && exprIsLambda expr then
                let
                    aux1 =
                        sQ.itemAux
                in
                { sQ | itemAux = { aux1 | lssRootAnn = Just ( annCanType, annVar ) } }

            else
                sQ


{-| Tells whether an expression is a lambda literal.
-}
exprIsLambda : TOpt.Expr TypeIds.MVarId -> Bool
exprIsLambda expr =
    case expr of
        TOpt.Function _ _ _ _ ->
            True

        TOpt.TrackedFunction _ _ _ _ ->
            True

        _ ->
            False


{-| Connects a child expression's canonical type to the type its context
gives it: both are loaded through the item memo and unified, so the child's
type variables take on what the context already knows before the child is
translated.

The unification is best effort and never fails the build; a mismatch leaves
the variables as they were. When both types are ground and contain no arrow the
step is skipped, because the loads would touch no memo and mint no set slot.

-}
connectTypes : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
connectTypes childCan parentCan s0 =
    if Store.groundNoArrowWith s0.monoMemo.aliasMemo childCan && Store.groundNoArrowWith s0.monoMemo.aliasMemo parentCan then
        s0

    else
        let
            ( parentVar, s1 ) =
                Store.loadTypeS parentCan s0

            ( childVar, s2 ) =
                Store.loadTypeS childCan s1
        in
        unifyBestEffortS childVar parentVar s2


{-| Connects each argument of a tail call to `funcName` with the parameter of
the same name, as `connectTypes` does. The parameters come from the innermost
loop frame for `funcName` (`withLoopFrame`); with no frame nothing is connected.
-}
connectTailCallArgs : Name -> List ( Name, TOpt.Expr TypeIds.MVarId ) -> Engine.S -> Engine.S
connectTailCallArgs funcName args s0 =
    case lookupLoopFrame funcName s0.itemAux.loopParams of
        Nothing ->
            s0

        Just params ->
            connectTailArgsGo params args s0


{-| Connects each named argument to the parameter of the same name in
`params`, skipping an argument with no such parameter.
-}
connectTailArgsGo : List ( String, Can.Type TypeIds.MVarId ) -> List ( Name, TOpt.Expr TypeIds.MVarId ) -> Engine.S -> Engine.S
connectTailArgsGo params args s0 =
    case args of
        [] ->
            s0

        ( argName, argExpr ) :: rest ->
            case List.filter (\( pn, _ ) -> pn == argName) params of
                ( _, pCan ) :: _ ->
                    connectTailArgsGo params rest (connectTypes (TOpt.typeOf argExpr) pCan s0)

                [] ->
                    connectTailArgsGo params rest s0


{-| Returns the parameters of the innermost loop frame named `funcName`.
-}
lookupLoopFrame : Name -> List ( String, List ( String, Can.Type TypeIds.MVarId ) ) -> Maybe (List ( String, Can.Type TypeIds.MVarId ))
lookupLoopFrame funcName frames =
    case frames of
        [] ->
            Nothing

        ( n, ps ) :: rest ->
            if n == funcName then
                Just ps

            else
                lookupLoopFrame funcName rest


{-| Runs a step with a loop frame for the tail-recursive function `name` and
its parameters pushed, so that tail calls inside it can be connected to those
parameters (`connectTailCallArgs`). The frame stack is restored afterwards.
-}
withLoopFrame : Name -> List ( A.Located Name, Can.Type TypeIds.MVarId ) -> Step a -> Step a
withLoopFrame name typedArgs step s0 =
    let
        frame =
            ( name, List.map (\( ln, t ) -> ( A.toValue ln, t )) typedArgs )
    in
    let
        aux0 =
            s0.itemAux
    in
    case step { s0 | itemAux = { aux0 | loopParams = frame :: aux0.loopParams } } of
        ( a, s1 ) ->
            let
                aux1 =
                    s1.itemAux
            in
            ( a, { s1 | itemAux = { aux1 | loopParams = s0.itemAux.loopParams } } )


{-| Returns the element type of a canonical `List a`, looking through filled
aliases.
-}
listElemCanType : Can.Type TypeIds.MVarId -> Maybe (Can.Type TypeIds.MVarId)
listElemCanType t =
    case t of
        Can.TType _ "List" [ elem ] ->
            Just elem

        Can.TAlias _ _ _ (Can.Filled inner) ->
            listElemCanType inner

        _ ->
            Nothing


{-| Returns the slot types of a canonical tuple, looking through filled aliases.
-}
tupleSlotCanTypes : Can.Type TypeIds.MVarId -> Maybe (List (Can.Type TypeIds.MVarId))
tupleSlotCanTypes t =
    case t of
        Can.TTuple a b rest ->
            Just (a :: b :: rest)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            tupleSlotCanTypes inner

        _ ->
            Nothing


{-| Connects each field expression of a record literal to the record type's
field of the same name (looking through filled aliases), as `connectTypes`
does. Fields the type does not name are skipped.
-}
connectRecordFields : List ( Name, TOpt.Expr TypeIds.MVarId ) -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
connectRecordFields fieldExprs recordCanType s0 =
    case recordFieldCanTypes recordCanType of
        Just fieldCans ->
            List.foldl
                (\( name, fieldExpr ) sa ->
                    case Dict.get name fieldCans of
                        Just fieldCan ->
                            connectTypes (TOpt.typeOf fieldExpr) fieldCan sa

                        Nothing ->
                            sa
                )
                s0
                fieldExprs

        Nothing ->
            s0


{-| Returns the field types of a canonical record type, looking through
filled aliases.
-}
recordFieldCanTypes : Can.Type TypeIds.MVarId -> Maybe (Dict.Dict Name (Can.Type TypeIds.MVarId))
recordFieldCanTypes t =
    case t of
        Can.TRecord fields _ ->
            Just (Dict.map (\_ (Can.FieldType _ ft) -> ft) fields)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            recordFieldCanTypes inner

        _ ->
            Nothing


{-| Returns the type of one field of a canonical record type, looking through
filled aliases, without building the whole field map.
-}
recordFieldCanType : Name -> Can.Type TypeIds.MVarId -> Maybe (Can.Type TypeIds.MVarId)
recordFieldCanType f t =
    case t of
        Can.TRecord fields _ ->
            Dict.get f fields |> Maybe.map (\(Can.FieldType _ ft) -> ft)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            recordFieldCanType f inner

        _ ->
            Nothing


{-| Translates one TypedOptimized expression into a monomorphized expression,
taking every type from the current work item's store.
-}
translate : TOpt.Expr TypeIds.MVarId -> Step Mono.MonoExpr
translate expr s0 =
    case translateDispatch expr s0 of
        ( monoExpr, s1 ) ->
            ( monoExpr, censusProducer expr s1 )


{-| Counts `expr` in the census under `inj|` and its producer form
(`producerKey`), when `lss.report` and LSS are on and the expression's type is
a function (its head is an arrow). Otherwise returns the state unchanged.

It reads signature triviality only from the memo, never computing a signature,
because computing one here would change the order in which member ids are
minted.

-}
censusProducer : TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
censusProducer expr s =
    if not (s.env.lss.report && s.env.lss.enabled && headIsArrow (TOpt.typeOf expr)) then
        s

    else
        Engine.bumpArgFlowCensus ("inj|" ++ producerKey expr s) s


{-| Tells whether a canonical type is a function type at its head, looking
through aliases. Unlike `canTypeHasArrow`, an arrow nested inside the type
does not count.
-}
headIsArrow : Can.Type TypeIds.MVarId -> Bool
headIsArrow t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled real) ->
            headIsArrow real

        Can.TAlias _ _ _ (Can.Holey real) ->
            headIsArrow real

        _ ->
            False


{-| Returns the census label for the form of expression that produces a
function value: a lambda, a reference, a kernel, a local, a call (labelled by
`censusCallKey`), a branch, a let, an accessor, a field read, or other.
-}
producerKey : TOpt.Expr TypeIds.MVarId -> Engine.S -> String
producerKey expr s =
    case expr of
        TOpt.Function _ _ _ _ ->
            "lambda"

        TOpt.TrackedFunction _ _ _ _ ->
            "lambda"

        TOpt.VarGlobal _ _ _ ->
            "ref"

        TOpt.VarEnum _ _ _ _ ->
            "ref"

        TOpt.VarBox _ _ _ ->
            "ref"

        TOpt.VarCycle _ _ _ _ ->
            "ref"

        TOpt.VarKernel _ _ _ _ _ ->
            "kernel"

        TOpt.VarLocal _ _ ->
            "local"

        TOpt.TrackedVarLocal _ _ _ ->
            "local"

        TOpt.Call _ func args _ ->
            censusCallKey func (List.length args) s

        TOpt.If _ _ _ ->
            "branch"

        TOpt.Case _ _ _ _ _ ->
            "branch"

        TOpt.Let _ _ _ ->
            "let"

        TOpt.Destruct _ _ _ ->
            "let"

        TOpt.Accessor _ _ _ ->
            "accessor"

        TOpt.Access _ _ _ _ ->
            "read"

        _ ->
            "other"


{-| Returns the census label for a call that supplies `supplied` arguments.

For a known global callee it is `papKnown|d<k>` when the call leaves `k` of its
declared parameters unsupplied, and otherwise names whether the callee's
memoized signature is trivial, non-trivial or not yet computed. A kernel callee
and any other callee get one label each.

-}
censusCallKey : TOpt.Expr TypeIds.MVarId -> Int -> Engine.S -> String
censusCallKey func supplied s =
    case censusCallGlobal func of
        Just g ->
            let
                declared =
                    LssInfer.declaredArityOf g 8 s
            in
            if declared > supplied then
                "papKnown|d" ++ String.fromInt (declared - supplied)

            else
                case Engine.memoizedSignatureTrivial g s of
                    Just True ->
                        "callResult|trivial"

                    Just False ->
                        "callResult|nontrivial"

                    Nothing ->
                        "callResult|unmemoized"

        Nothing ->
            case func of
                TOpt.VarKernel _ _ _ _ _ ->
                    "callKernel"

                _ ->
                    "callUnknownCallee"


{-| Returns the global a callee expression names, for a global, enum, box or
cycle reference.
-}
censusCallGlobal : TOpt.Expr TypeIds.MVarId -> Maybe TOpt.Global
censusCallGlobal func =
    case func of
        TOpt.VarGlobal _ g _ ->
            Just g

        TOpt.VarEnum _ g _ _ ->
            Just g

        TOpt.VarBox _ g _ ->
            Just g

        TOpt.VarCycle _ home name _ ->
            Just (TOpt.Global home name)

        _ ->
            Nothing


{-| Translates one expression by its form; `translate` adds the census on top.

A node's type is normally classified from its canonical type. Where that
leaves type variables, a container or branch takes its structure from its
translated children instead, with lambda sets joined over all of them
(`joinBranchTypes`), because one child's set is a claim that the others can
falsify. A `TOpt.Shader` aborts the build as unsupported.

-}
translateDispatch : TOpt.Expr TypeIds.MVarId -> Step Mono.MonoExpr
translateDispatch expr s0 =
    case expr of
        TOpt.Bool _ v _ ->
            ( Mono.MonoLiteral (Mono.LBool v) Mono.MBool, s0 )

        TOpt.Chr _ v _ ->
            ( Mono.MonoLiteral (Mono.LChar v) Mono.MChar, s0 )

        TOpt.Str _ v _ ->
            ( Mono.MonoLiteral (Mono.LStr v) Mono.MString, s0 )

        TOpt.Int _ v meta ->
            case classifyAs Mono.tkClassLit meta.tipe s0 of
                ( monoType, s1 ) ->
                    ( case monoType of
                        Mono.MFloat ->
                            Mono.MonoLiteral (Mono.LFloat (toFloat v)) monoType

                        _ ->
                            Mono.MonoLiteral (Mono.LInt v) monoType
                    , s1
                    )

        TOpt.Float _ v meta ->
            case classifyAs Mono.tkClassLit meta.tipe s0 of
                ( monoType, s1 ) ->
                    ( Mono.MonoLiteral (Mono.LFloat v) monoType, s1 )

        TOpt.VarLocal name meta ->
            case Engine.localVarInfo name s0 of
                ( ( isLM, isNM, maybeBound ), s1 ) ->
                    if isLM then
                        -- A let-bound function: record this use's type and name its binding (f, f$1, ...).
                        case classifyAs Mono.tkClassLocal meta.tipe s1 of
                            ( resolvedType, s2 ) ->
                                case Engine.recordLocalInstance name resolvedType s2 of
                                    ( ( freshName, instType, _ ), s3 ) ->
                                        ( Mono.MonoVarLocal freshName instType, s3 )

                    else if isNM then
                        -- A let-bound number: record this use's type and name its binding (n, n$v1, ...).
                        case classifyAs Mono.tkClassLocal meta.tipe s1 of
                            ( resolvedType, s2 ) ->
                                case Engine.recordNumberInstance name resolvedType s2 of
                                    ( ( freshName, instType ), s3 ) ->
                                        ( Mono.MonoVarLocal freshName instType, s3 )

                    else
                        -- The type bound by the enclosing let, lambda or destructor can be more concrete than the meta.
                        case maybeBound of
                            Just boundType ->
                                ( Mono.MonoVarLocal name boundType, s1 )

                            Nothing ->
                                case classifyAs Mono.tkClassLocal meta.tipe s1 of
                                    ( monoType, s2 ) ->
                                        ( Mono.MonoVarLocal name monoType, s2 )

        TOpt.TrackedVarLocal _ name meta ->
            translate (TOpt.VarLocal name meta) s0

        TOpt.VarGlobal region global meta ->
            translateVarRef expr region global meta.tipe s0

        TOpt.VarEnum region global _ meta ->
            translateVarRef expr region global meta.tipe s0

        TOpt.VarBox region global meta ->
            translateVarRef expr region global meta.tipe s0

        TOpt.VarCycle region canonical name meta ->
            translateVarRef expr region (TOpt.Global canonical name) meta.tipe s0

        TOpt.VarKernel region kernelPrefix home name meta ->
            case deriveKernelAbiTypeRef ( kernelPrefix, home, name ) meta.tipe s0 of
                ( funcMonoType, s1 ) ->
                    ( Mono.MonoVarKernel region kernelPrefix home name funcMonoType, s1 )

        TOpt.VarDebug region name _ _ meta ->
            case deriveKernelAbiTypeRef ( "Elm", "Debug", name ) meta.tipe s0 of
                ( funcMonoType, s1 ) ->
                    ( Mono.MonoVarKernel region "Elm" "Debug" name funcMonoType, s1 )

        TOpt.List region exprs meta ->
            let
                connectElems sa =
                    case listElemCanType meta.tipe of
                        Just elemCan ->
                            List.foldl (\e sb -> connectTypes (TOpt.typeOf e) elemCan sb) sa exprs

                        Nothing ->
                            case exprs of
                                first :: restExprs ->
                                    List.foldl (\e sb -> connectTypes (TOpt.typeOf e) (TOpt.typeOf first) sb) sa restExprs

                                [] ->
                                    sa
            in
            case connectElems s0 of
                s1 ->
                    case classifyAs Mono.tkClassMisc meta.tipe s1 of
                        ( monoType0, s2 ) ->
                            case Engine.traverse translate exprs s2 of
                                ( monoExprs, s3 ) ->
                                    let
                                        joinElems =
                                            s3.env.lss.enabled

                                        -- The first element's lambda sets alone could be falsified by the others.
                                        joinedElem first rest =
                                            if joinElems then
                                                List.foldl (\e acc -> joinBranchTypes acc (Mono.typeOf e)) (Mono.typeOf first) rest

                                            else
                                                Mono.typeOf first

                                        ( monoType, s3b ) =
                                            if Mono.containsAnyMVar monoType0 then
                                                case monoExprs of
                                                    first :: rest ->
                                                        Engine.consS (Mono.mList (joinedElem first rest)) s3

                                                    [] ->
                                                        ( monoType0, s3 )

                                            else
                                                case monoExprs of
                                                    first :: rest ->
                                                        if joinElems then
                                                            Engine.consS (Mono.overlayAnnotations monoType0 (Mono.mList (joinedElem first rest))) s3

                                                        else
                                                            ( monoType0, s3 )

                                                    [] ->
                                                        ( monoType0, s3 )
                                    in
                                    ( Mono.MonoList region monoExprs monoType, s3b )

        TOpt.Call region func args meta ->
            translateCall region func args meta.tipe s0

        TOpt.If branches final meta ->
            -- Each condition is translated before its branch value is connected to the If's type,
            -- so a shared number variable used in the condition keeps its earlier type there.
            case classifyAs Mono.tkClassIf meta.tipe s0 of
                ( monoType0, s1 ) ->
                    case Engine.traverse (translateIfBranch meta.tipe) branches s1 of
                        ( monoBranches, s2 ) ->
                            case connectTypes (TOpt.typeOf final) meta.tipe s2 of
                                s3 ->
                                    case translate final s3 of
                                        ( monoFinal, s4 ) ->
                                            let
                                                monoType =
                                                    if Mono.containsAnyMVar monoType0 then
                                                        List.foldl (\( _, b ) acc -> joinBranchTypes acc (Mono.typeOf b))
                                                            (Mono.typeOf monoFinal)
                                                            monoBranches

                                                    else
                                                        monoType0
                                            in
                                            ( Mono.MonoIf monoBranches monoFinal monoType, s4 )

        TOpt.TailCall name args meta ->
            -- The arguments' types are otherwise unconnected to the loop parameters' types.
            case connectTailCallArgs name args s0 of
                s0c ->
                    case classifyAs Mono.tkClassMisc meta.tipe s0c of
                        ( monoType, s1 ) ->
                            case
                                Engine.traverse
                                    (\( argName, argExpr ) sx ->
                                        case translate argExpr sx of
                                            ( me, sx1 ) ->
                                                ( ( argName, me ), sx1 )
                                    )
                                    args
                                    s1
                            of
                                ( monoArgs, s2 ) ->
                                    ( Mono.MonoTailCall name monoArgs monoType, s2 )

        TOpt.Unit _ ->
            ( Mono.MonoUnit, s0 )

        TOpt.Tuple region a b rest meta ->
            let
                connectSlots sa =
                    case tupleSlotCanTypes meta.tipe of
                        Just slotCans ->
                            List.foldl (\( e, slotCan ) sb -> connectTypes (TOpt.typeOf e) slotCan sb)
                                sa
                                (List.map2 Tuple.pair (a :: b :: rest) slotCans)

                        Nothing ->
                            sa
            in
            case connectSlots s0 of
                s1 ->
                    case translate a s1 of
                        ( monoA, s2 ) ->
                            case translate b s2 of
                                ( monoB, s3 ) ->
                                    case Engine.traverse translate rest s3 of
                                        ( monoRest, s4 ) ->
                                            let
                                                allExprs =
                                                    monoA :: monoB :: monoRest
                                            in
                                            let
                                                ( tupleType, s5 ) =
                                                    Engine.consS (Mono.mTuple (List.map Mono.typeOf allExprs)) s4
                                            in
                                            ( Mono.MonoTupleCreate region allExprs tupleType, s5 )

        TOpt.Record fields meta ->
            case connectRecordFields (Dict.toList fields) meta.tipe s0 of
                s1 ->
                    case
                        Engine.foldlS
                            (\( name, fieldExpr ) acc sx ->
                                case translate fieldExpr sx of
                                    ( me, sx1 ) ->
                                        ( ( name, me ) :: acc, sx1 )
                            )
                            []
                            (Dict.toList fields)
                            s1
                    of
                        ( monoFieldsRev, s2 ) ->
                            let
                                ( recType, s3 ) =
                                    Engine.consS (recordTypeFromFields monoFieldsRev) s2
                            in
                            ( Mono.MonoRecordCreate monoFieldsRev recType, s3 )

        TOpt.TrackedRecord _ fields meta ->
            case
                connectRecordFields
                    (List.map (\( locName, e ) -> ( A.toValue locName, e )) (DMap.toList fields))
                    meta.tipe
                    s0
            of
                s1 ->
                    case
                        Engine.foldlS
                            (\( locName, fieldExpr ) acc sx ->
                                case translate fieldExpr sx of
                                    ( me, sx1 ) ->
                                        ( ( A.toValue locName, me ) :: acc, sx1 )
                            )
                            []
                            (DMap.toList fields)
                            s1
                    of
                        ( monoFieldsRev, s2 ) ->
                            let
                                ( recType, s3 ) =
                                    Engine.consS (recordTypeFromFields monoFieldsRev) s2
                            in
                            ( Mono.MonoRecordCreate monoFieldsRev recType, s3 )

        TOpt.Access record _ fieldName meta ->
            translateAccess record fieldName meta s0

        TOpt.Update _ record updates meta ->
            -- An update has exactly its record's type; unconnected, a let-polymorphic record's variables stay open.
            translateUpdate record updates meta.tipe (connectTypes (TOpt.typeOf record) meta.tipe s0)

        TOpt.Let def body meta ->
            -- Same type to the type checker, but separate arrow set slots per occurrence; see the Destruct arm.
            translateLet def body meta.tipe (connectTypes (TOpt.typeOf body) meta.tipe s0)

        TOpt.Case label root decider jumps meta ->
            case classifyAs Mono.tkClassCase meta.tipe s0 of
                ( monoTypeFromCan, s1 ) ->
                    case specializeDecider meta.tipe root decider s1 of
                        ( monoDecider, s2 ) ->
                            case specializeJumps meta.tipe jumps s2 of
                                ( monoJumps, s3 ) ->
                                    ( Mono.MonoCase label
                                        root
                                        monoDecider
                                        monoJumps
                                        (if Mono.containsAnyMVar monoTypeFromCan then
                                            inferCaseType monoJumps monoDecider monoTypeFromCan

                                         else
                                            monoTypeFromCan
                                        )
                                    , caseAnnoCensus monoTypeFromCan monoDecider monoJumps s3
                                    )

        TOpt.Destruct destructor body meta ->
            let
                (TOpt.Destructor dname path dmeta) =
                    destructor
            in
            -- The body is connected to the node's type first, as `specializeChoice` does for an inline leaf.
            -- In a branch such as `Just x -> f x`, which is a Destruct around the value, the call's result
            -- set would otherwise never reach the case's set, and a sibling branch's set would read back
            -- as the case's complete set.
            --
            -- A scalar number slot projected from a let-bound number root is translated body first by
            -- `specializeNumberDestruct`, so its uses decide the root's instances.
            case connectTypes (TOpt.typeOf body) meta.tipe s0 of
                s0d ->
                    case Engine.numberMultiRootType (pathRootName path) s0d of
                        ( maybeRootType, s1 ) ->
                            case maybeRootType of
                                Just eagerRootType ->
                                    case classifyAs Mono.tkClassDestr dmeta.tipe s1 of
                                        ( eagerLeaf, s2 ) ->
                                            if isScalarNumber eagerLeaf && refineRootInstance s1.env.globalTypeEnv eagerRootType path eagerLeaf /= Nothing then
                                                specializeNumberDestruct dname path dmeta (pathRootName path) eagerRootType body s2

                                            else
                                                generalDestruct destructor body meta s2

                                Nothing ->
                                    generalDestruct destructor body meta s1

        TOpt.Accessor region fieldName meta ->
            case classifyAs Mono.tkClassMisc meta.tipe s0 of
                ( monoType, s1 ) ->
                    if ResolveAccessorValues.accessorTypeNeedsDefer monoType then
                        ( Mono.MonoAccessorValue region fieldName monoType, s1 )

                    else
                        case Engine.enqueueSpec (Mono.Accessor fieldName) monoType s1 of
                            ( specId, s2 ) ->
                                ( Mono.MonoVarGlobal region specId monoType, s2 )

        TOpt.Function srcLam params body meta ->
            specializeLambda srcLam params body meta.tipe s0

        TOpt.TrackedFunction srcLam trackedParams body meta ->
            specializeLambda srcLam (List.map (\( locName, pt ) -> ( A.toValue locName, pt )) trackedParams) body meta.tipe s0

        _ ->
            ( Engine.crashFailure (Unsupported (nodeKind expr)), s0 )


{-| Translates one condition and branch value of an `if`, connecting the
branch value's type to the `if`'s type after the condition is translated and
before the value is.
-}
translateIfBranch : Can.Type TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, TOpt.Expr TypeIds.MVarId ) -> Step ( Mono.MonoExpr, Mono.MonoExpr )
translateIfBranch ifCanType ( cond, bodyExpr ) s0 =
    case translate cond s0 of
        ( monoCond, s1 ) ->
            case translate bodyExpr (connectTypes (TOpt.typeOf bodyExpr) ifCanType s1) of
                ( monoBody, s2 ) ->
                    ( ( monoCond, monoBody ), s2 )



-- ====== RECURSIVE CYCLES ======


{-| Specializes the member `name` of a group of mutually recursive definitions
at `demand`, producing that member's node only.

References from it to itself or to other members enqueue those members as
specs of their own, so a group of any size becomes one node per member, each
made in its own work item. When `name` matches no member and the group has
exactly one definition, that definition is used; otherwise the build aborts.

-}
specializeCycle : Name -> List ( Name, TOpt.Expr TypeIds.MVarId ) -> List (TOpt.Def TypeIds.MVarId) -> Mono.MonoType -> Step Mono.MonoNode
specializeCycle name valueDefs funcDefs demand =
    case listFind (\d -> cycleDefName d == name) funcDefs of
        Just def ->
            specializeCycleFuncDef def demand

        Nothing ->
            case listFind (\( n, _ ) -> n == name) valueDefs of
                Just ( _, vexpr ) ->
                    specializeCycleValue vexpr demand

                Nothing ->
                    case ( valueDefs, funcDefs ) of
                        ( [], [ singleDef ] ) ->
                            specializeCycleFuncDef singleDef demand

                        ( [ ( _, vexpr ) ], [] ) ->
                            specializeCycleValue vexpr demand

                        _ ->
                            Engine.crashFailure (EngineBug ("cycle member not found: " ++ name))


{-| Returns the name a definition binds.
-}
cycleDefName : TOpt.Def TypeIds.MVarId -> Name
cycleDefName def =
    case def of
        TOpt.Def _ n _ _ ->
            n

        TOpt.TailDef _ n _ _ _ _ ->
            n


{-| Returns the first element that satisfies `pred`.
-}
listFind : (a -> Bool) -> List a -> Maybe a
listFind pred xs =
    List.head (List.filter pred xs)


{-| Specializes a value (non-function) member of a recursive group at `demand`
as a `MonoDefine`.
-}
specializeCycleValue : TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializeCycleValue vexpr demand s0 =
    case translate vexpr (demandUnifyRoot (TOpt.typeOf vexpr) demand vexpr s0) of
        ( monoExpr, s1 ) ->
            ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), s1 )



-- ====== PORTS ======


{-| Specializes a port at `requestedMonoType` as a one-parameter closure that
calls the kernel `Elm.Platform.leaf` with the port's name and a value.

For an incoming port the value is the closure's argument, and the port's own
decoder (`expr`) is enqueued as a spec of the port global at the decoder's
type; its id is recorded with the port. For an outgoing port the value is the
argument passed through the encoder, which is translated inline. With LSS on,
every lambda set in the port's type is made ⊤ first, since the port's functions
are handed to the runtime. When the requested type is not a function type, the
port's own classified type is used instead. The build aborts when the type
used is not a one-parameter function.

-}
specializePort : Bool -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializePort incoming expr canType requestedMonoType s0 =
    case poisonPortArrowsIfOn canType s0 of
        s1 ->
            specializePortBody incoming expr canType requestedMonoType s1


{-| Makes every lambda set in `canType` ⊤ in the store when LSS is on.
-}
poisonPortArrowsIfOn : Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
poisonPortArrowsIfOn canType s =
    if s.env.lss.enabled then
        case Store.loadTypeS canType s of
            ( v, s1 ) ->
                case Store.poisonArrowSets v s1 of
                    s2 ->
                        Engine.bumpWidenedByKernel s2

    else
        s


{-| Builds the port closure that `specializePort` describes.
-}
specializePortBody : Bool -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializePortBody incoming expr canType requestedMonoType s0 =
    case classifyAs Mono.tkClassMisc canType (demandUnify canType requestedMonoType s0) of
        ( classifiedCan, s1 ) ->
            case portGlobalContext s1 of
                ( ( portGlobal, portName ), s2 ) ->
                    -- A demand that is not a function type is replaced by the port's own classified type.
                    let
                        effectiveType =
                            case requestedMonoType of
                                Mono.MFunction _ _ _ _ ->
                                    requestedMonoType

                                _ ->
                                    classifiedCan
                    in
                    case effectiveType of
                        Mono.MFunction _ _ [ paramType ] resultType ->
                            case allocLambdaId s2 of
                                ( lambdaId, s3 ) ->
                                    let
                                        region =
                                            A.zero

                                        paramName =
                                            "_eco_port_arg"

                                        paramVar =
                                            Mono.MonoVarLocal paramName paramType

                                        nameLit =
                                            Mono.MonoLiteral (Mono.LStr portName) Mono.MString

                                        leafKernel valueType =
                                            Mono.MonoVarKernel region "Elm" "Platform" "leaf" (Mono.mFunction Mono.topSynth [ Mono.MString, valueType ] resultType)

                                        closureInfo =
                                            { lambdaId = lambdaId
                                            , srcLambda = Nothing
                                            , lssMember = Nothing
                                            , captures = []
                                            , params = [ ( paramName, paramType ) ]
                                            , closureKind = Nothing
                                            , captureAbi = Nothing
                                            }
                                    in
                                    if incoming then
                                        let
                                            body =
                                                Mono.MonoCall region (leafKernel paramType) [ nameLit, paramVar ] resultType Mono.defaultCallInfo

                                            wrapper =
                                                Mono.MonoClosure closureInfo body effectiveType
                                        in
                                        case classifyAs Mono.tkClassMisc (TOpt.typeOf expr) s3 of
                                            ( decoderMonoType, s4 ) ->
                                                case Engine.enqueueSpec portGlobal decoderMonoType s4 of
                                                    ( decoderSpecId, s5 ) ->
                                                        ( Mono.MonoPortIncoming wrapper effectiveType
                                                        , recordPort { name = portName, key = Mono.toComparableGlobal portGlobal, incoming = True, decoderSpecId = Just decoderSpecId } s5
                                                        )

                                    else
                                        case translate expr (connectEncoderType expr canType s3) of
                                            ( encoderMono, s4 ) ->
                                                let
                                                    encodedType =
                                                        case Mono.typeOf encoderMono of
                                                            Mono.MFunction _ _ _ r ->
                                                                r

                                                            t ->
                                                                t

                                                    encodedExpr =
                                                        Mono.MonoCall region encoderMono [ paramVar ] encodedType Mono.defaultCallInfo

                                                    body =
                                                        Mono.MonoCall region (leafKernel encodedType) [ nameLit, encodedExpr ] resultType Mono.defaultCallInfo

                                                    wrapper =
                                                        Mono.MonoClosure closureInfo body effectiveType
                                                in
                                                ( Mono.MonoPortOutgoing wrapper effectiveType
                                                , recordPort { name = portName, key = Mono.toComparableGlobal portGlobal, incoming = False, decoderSpecId = Nothing } s4
                                                )

                        _ ->
                            ( Engine.crashFailure (EngineBug ("port '" ++ portName ++ "' must have a single-parameter function type; got " ++ monoKind effectiveType)), s2 )


{-| Connects an outgoing port's encoder expression to the function type
`payload -> r`, where `payload` is the port's parameter type and `r` is a fresh
variable, so that the encoder's type is a function at the payload type rather
than a bare variable. Best effort; a port type that is not a function changes
nothing.
-}
connectEncoderType : TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
connectEncoderType expr portCanType s0 =
    case portCanType of
        Can.TLambda _ payloadCan _ ->
            case Store.loadType (TOpt.typeOf expr) s0 of
                ( encVar, s1 ) ->
                    case Store.loadTypeS payloadCan s1 of
                        ( payloadVar, s2 ) ->
                            case Engine.freshVar (Vars.FlexVar Nothing) s2 of
                                ( resVar, s3 ) ->
                                    case Engine.freshVar (Vars.Structure (Vars.Fun1 payloadVar resVar)) s3 of
                                        ( funVar, s4 ) ->
                                            unifyStepBestEffort encVar funVar s4

        _ ->
            s0


{-| Returns the global being specialized and its name as a string. Aborts the
build when the current global is not a plain `Mono.Global`.
-}
portGlobalContext : Step ( Mono.Global, String )
portGlobalContext s =
    case s.currentGlobal of
        Just ((Mono.Global _ nm) as g) ->
            ( ( g, Name.toElmString nm ), s )

        _ ->
            ( Engine.crashFailure (EngineBug "specializePort: currentGlobal must be a Global"), s )


{-| Returns a short text rendering of a MonoType, used in crash messages.
-}
monoKind : Mono.MonoType -> String
monoKind mt =
    case mt of
        Mono.MFunction _ _ ps r ->
            "(" ++ String.join "," (List.map monoKind ps) ++ "->" ++ monoKind r ++ ")"

        Mono.MCustom _ _ n args ->
            n
                ++ (if List.isEmpty args then
                        ""

                    else
                        "<" ++ String.join "," (List.map monoKind args) ++ ">"
                   )

        Mono.MVar _ Mono.CNumber ->
            "num"

        Mono.MVar _ Mono.CEcoValue ->
            "eco"

        Mono.MInt ->
            "I"

        Mono.MFloat ->
            "F"

        Mono.MList _ e ->
            "[" ++ monoKind e ++ "]"

        Mono.MTuple _ es ->
            "T(" ++ String.join "," (List.map monoKind es) ++ ")"

        Mono.MRecord _ fields ->
            "R{" ++ String.join "," (List.map (\( k, v ) -> k ++ ":" ++ monoKind v) (Dict.toList fields)) ++ "}"

        Mono.MString ->
            "S"

        Mono.MBool ->
            "B"

        _ ->
            "other"


{-| Adds a port registration to the state unless one with the same key is
already there.
-}
recordPort : Mono.PortRegistration -> Engine.S -> Engine.S
recordPort reg s =
    if List.any (\p -> p.key == reg.key) s.ports then
        s

    else
        { s | ports = reg :: s.ports }


{-| Specializes a function member of a recursive group at `demand`.

A plain definition is translated after `demandUnifyRoot` seeds its annotation.
A tail-recursive definition becomes a `MonoTailFunc`. With LSS on, its type
takes its structure from classifying the annotation and its lambda sets from
the seeded annotation in the store, and each parameter is classified and given
the sets peeled from that type. With LSS off, the parameters and type are
classified only.

-}
specializeCycleFuncDef : TOpt.Def TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializeCycleFuncDef def demand =
    case def of
        TOpt.Def _ _ body defType ->
            \sIn ->
                case translate body (demandUnifyRoot defType demand body sIn) of
                    ( monoExpr, s1 ) ->
                        ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), s1 )

        TOpt.TailDef _ tailName typedArgs body defType _ ->
            \sIn ->
                if sIn.env.lss.enabled then
                    -- A classify or a fresh load could not see the lambda sets the demand put on the seeded variable.
                    case demandUnifyVar defType demand sIn of
                        ( annVar, s1 ) ->
                            case Store.zonkToMono annVar s1 of
                                ( zonkedType, s1b ) ->
                                    case classifyAs Mono.tkClassLet defType s1b of
                                        ( classifiedType, s2 ) ->
                                            let
                                                -- Structure from classify, lambda sets from the zonk (see `Mono.overlayAnnotations`).
                                                funcType =
                                                    Mono.overlayAnnotations classifiedType zonkedType

                                                peeled =
                                                    extractFieldTypes (List.length typedArgs) funcType
                                            in
                                            case
                                                if List.length peeled == List.length typedArgs then
                                                    Engine.traverse
                                                        (\( ( locName, argType ), peeledType ) sx ->
                                                            case classifyAs Mono.tkClassParam argType sx of
                                                                ( mt, sx1 ) ->
                                                                    ( ( A.toValue locName, Mono.overlayAnnotations mt peeledType ), sx1 )
                                                        )
                                                        (List.map2 Tuple.pair typedArgs peeled)
                                                        s2

                                                else
                                                    Engine.traverse
                                                        (\( locName, argType ) sx ->
                                                            case classifyAs Mono.tkClassParam argType sx of
                                                                ( mt, sx1 ) ->
                                                                    ( ( A.toValue locName, mt ), sx1 )
                                                        )
                                                        typedArgs
                                                        s2
                                            of
                                                ( monoParams, s3 ) ->
                                                    case withLoopFrame tailName typedArgs (Engine.scoped (\sx -> translate body (insertVars monoParams sx))) s3 of
                                                        ( monoBody, s4 ) ->
                                                            ( Mono.MonoTailFunc monoParams monoBody funcType, s4 )

                else
                    case
                        Engine.traverse
                            (\( locName, argType ) sx ->
                                case classifyAs Mono.tkClassParam argType sx of
                                    ( mt, sx1 ) ->
                                        ( ( A.toValue locName, mt ), sx1 )
                            )
                            typedArgs
                            (demandUnify defType demand sIn)
                    of
                        ( monoParams, s1 ) ->
                            case classifyAs Mono.tkClassLet defType s1 of
                                ( funcType, s2 ) ->
                                    case withLoopFrame tailName typedArgs (Engine.scoped (\sx -> translate body (insertVars monoParams sx))) s2 of
                                        ( monoBody, s3 ) ->
                                            ( Mono.MonoTailFunc monoParams monoBody funcType, s3 )



-- ====== CONSTRUCTOR / ENUM NODES ======


{-| Specializes a constructor at `demand` as a `MonoCtor`.

The constructor's type is unified with the demand and read back; its first
`arity` parameter types are the field types. The node's result type is what is
left of the demand itself after `arity` arrows. A mismatch with the demand
aborts the build.

-}
specializeCtorViaScheme : Name -> Int -> Int -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializeCtorViaScheme name tag arity canType demand s0 =
    case Store.loadTypeS canType s0 of
        ( annVar, s1 ) ->
            case Store.monoTypeToVarS demand s1 of
                ( demandVar, s2 ) ->
                    case Store.unifyStrict annVar demandVar s2 of
                        ( _, s3 ) ->
                            case Store.zonkToMono annVar s3 of
                                ( ctorMonoType, s4 ) ->
                                    ( Mono.MonoCtor
                                        { name = name, tag = tag, fieldTypes = extractFieldTypes arity ctorMonoType }
                                        (extractCtorResultType arity demand)
                                    , s4
                                    )


{-| Specializes a constructor with no fields at `demand` as a `MonoEnum`,
whose type is the constructor's type unified with the demand and read back.
-}
enumNode : Int -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
enumNode tag canType demand s0 =
    case Store.loadTypeS canType s0 of
        ( annVar, s1 ) ->
            case Store.monoTypeToVarS demand s1 of
                ( demandVar, s2 ) ->
                    case Store.unifyStrict annVar demandVar s2 of
                        ( _, s3 ) ->
                            case Store.zonkToMono annVar s3 of
                                ( monoType, s4 ) ->
                                    ( Mono.MonoEnum tag monoType, s4 )


{-| Returns the parameter types of a function type, taking whole stages until at
least `n` parameters are collected, so it can return more than `n`. Returns
fewer when the type runs out of arrows.
-}
extractFieldTypes : Int -> Mono.MonoType -> List Mono.MonoType
extractFieldTypes n monoType =
    if n <= 0 then
        []

    else
        case monoType of
            Mono.MFunction _ _ args result ->
                args ++ extractFieldTypes (n - List.length args) result

            _ ->
                []


{-| Returns what is left of a function type after removing `n` stages, or the
type itself where it runs out of arrows. Each stage counts as one, whatever its
number of parameters.
-}
extractCtorResultType : Int -> Mono.MonoType -> Mono.MonoType
extractCtorResultType n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ _ _ result ->
                extractCtorResultType (n - 1) result

            _ ->
                monoType



-- ====== CLOSURES ======


{-| Specializes a lambda as a `MonoClosure`.

Its type comes from `classifyLambdaHead`, which under LSS also gives the
lambda's own member id. The parameter types are peeled from that type, or
classified one by one when the type has too few arrows. The body is translated
with the parameters in scope, and the captures are computed from the body.
`closureKind` and `captureAbi` are left `Nothing`.

-}
specializeLambda : Maybe TypeIds.SrcLambdaId -> List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
specializeLambda srcLam params body canType s0 =
    case classifyLambdaHead (List.length params) srcLam canType (m2ShapeCensus params body s0) of
        ( ( monoType0, maybeMember ), s1 ) ->
            let
                -- The peel stays concrete where only the function type's variables were unified.
                peeled =
                    extractFieldTypes (List.length params) monoType0

                ( monoParams, s2 ) =
                    if List.length peeled == List.length params then
                        ( List.map2 (\( nm, _ ) pt -> ( nm, pt )) params peeled, s1 )

                    else
                        Engine.traverse
                            (\( name, paramCanType ) sx ->
                                case classifyAs Mono.tkClassParam paramCanType sx of
                                    ( mt, sx1 ) ->
                                        ( ( name, mt ), sx1 )
                            )
                            params
                            s1
            in
            case allocLambdaId s2 of
                ( lambdaId, s3 ) ->
                    case Engine.scoped (\sx -> translate body (insertVars monoParams sx)) s3 of
                        ( monoBody, s4 ) ->
                            -- `monoType0` was read before the body was translated.
                            ( Mono.MonoClosure
                                { lambdaId = lambdaId
                                , srcLambda = srcLam

                                -- The same id the lambda's type carries in its sets.
                                , lssMember = maybeMember
                                , captures = Closure.computeClosureCaptures monoParams monoBody
                                , params = monoParams
                                , closureKind = Nothing
                                , captureAbi = Nothing
                                }
                                monoBody
                                monoType0
                            , s4
                            )


{-| Returns a lambda's type and, under LSS, the member id minted for it.

With LSS off this is the classified type and no member.

With LSS on, the lambda's type is loaded into the store, the lambda's own
member is written into the sets of the first `arity` arrows of its result
spine, and the type is read back, so those arrows carry the lambda together
with whatever the demand put there. `arity` is the lambda's parameter count,
so the arrows of a function the body returns are not marked. The structure of
the result still comes from classifying `canType`; only the lambda sets come
from the store.

A definition's own lambda uses the annotation variable `demandUnifyRoot` kept,
when its type matches ignoring arrow ids, instead of a fresh load, so the
demand's sets reach its parameters. The kept variable is then cleared. Such a
lambda's member is also recorded as the root lambda of the current global, so
that it is minted under the global's key, except when a let-bound function's
instance is being re-translated (the id would name the enclosing global
instead) or the global is a kernel alias.

-}
classifyLambdaHead : Int -> Maybe TypeIds.SrcLambdaId -> Can.Type TypeIds.MVarId -> Step ( Mono.MonoType, Maybe Int )
classifyLambdaHead arity srcLam canType s0 =
    if s0.env.lss.enabled then
        let
            ( maybeRootVar, s0b ) =
                case s0.itemAux.lssRootAnn of
                    Just ( annCanType, annVar ) ->
                        -- Arrow ids differ per occurrence, so the match must ignore them.
                        if sameCanTypeIgnoringArrows annCanType canType then
                            let
                                aux0 =
                                    s0.itemAux
                            in
                            -- `hitExact` also counts the matches that are equal including arrow ids.
                            ( Just annVar
                            , Engine.bumpArgFlowCensus "rootAnn|hit"
                                (if annCanType == canType then
                                    Engine.bumpArgFlowCensus "rootAnn|hitExact" { s0 | itemAux = { aux0 | lssRootAnn = Nothing } }

                                 else
                                    { s0 | itemAux = { aux0 | lssRootAnn = Nothing } }
                                )
                            )

                        else
                            ( Nothing, Engine.bumpArgFlowCensus "rootAnn|missType" s0 )

                    Nothing ->
                        ( Nothing, Engine.bumpArgFlowCensus "rootAnn|absent" s0 )

            -- Record the definition's root lambda so its member is minted under the global's key.
            -- A kernel alias is skipped here because Engine cannot see `kernelAliasOf`; folding one
            -- would give the alias a `g|` member besides its `k|` one.
            s0c =
                case ( maybeRootVar, ( srcLam, s0b.currentGlobal ) ) of
                    ( Just _, ( Just lamId, Just (Mono.Global home name) ) ) ->
                        let
                            g =
                                TOpt.Global home name
                        in
                        if s0b.itemAux.retranslating /= Nothing then
                            -- A let-bound function's instance: folding would name the enclosing global
                            -- and give every instance one id. It keeps its own instance-qualified `l|` id.
                            Engine.bumpArgFlowCensus "rootFold|localSkip" s0b

                        else
                            case LssInfer.kernelAliasOf g s0b of
                                Just _ ->
                                    Engine.bumpArgFlowCensus "rootFold|kernelSkip" s0b

                                Nothing ->
                                    let
                                        tbl =
                                            s0b.lssMemberTable
                                    in
                                    { s0b | lssMemberTable = { tbl | rootLamOf = Dict.insert (Engine.srcLambdaKey lamId) g tbl.rootLamOf } }

                    _ ->
                        s0b
        in
        case
            case maybeRootVar of
                Just annVar ->
                    ( annVar, s0c )

                Nothing ->
                    Store.loadType canType s0c
        of
            ( funcVar, s1 ) ->
                case LssInfer.injectLambdaMemberQualifiedId arity srcLam funcVar s1 of
                    ( maybeMid, s2 ) ->
                        case Store.zonkToMono funcVar s2 of
                            ( zonked, s3 ) ->
                                case classifyAs Mono.tkClassLambda canType s3 of
                                    ( classified, s4 ) ->
                                        ( ( Mono.overlayAnnotations classified zonked, maybeMid ), s4 )

    else
        case classifyAs Mono.tkClassLambda canType s0 of
            ( classified, s1 ) ->
                ( ( classified, Nothing ), s1 )


{-| Returns a new anonymous lambda id in the current module, from the state's
lambda counter.
-}
allocLambdaId : Step Mono.LambdaId
allocLambdaId =
    \s -> ( Mono.AnonymousLambda s.env.currentModule s.lambdaCounter, { s | lambdaCounter = s.lambdaCounter + 1 } )



-- ====== VAR REFERENCES ======


{-| Translates a reference to a global that is not being called as a
`MonoVarGlobal`. The reference's type comes from `classifyRef`, and a spec of
the global at that type is enqueued (`enqueueSpecStamped`).
-}
translateVarRef : TOpt.Expr TypeIds.MVarId -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateVarRef refExpr region global canType s0 =
    case classifyRef refExpr canType s0 of
        ( monoType, s1 ) ->
            case enqueueSpecStamped global monoType s1 of
                ( specId, s2 ) ->
                    ( Mono.MonoVarGlobal region specId monoType, s2 )


{-| Returns the type of a reference to a global.

With LSS on and an arrow in `canType`, the type is loaded into the store, the
referenced value's own member is written into its head set
(`injectArgLambdaMember`, the same as for a call argument), and the type is
read back. Classifying alone would put ⊤ on every arrow, so a bare reference
such as the elements of `[ incr, decr ]` would carry no set. Otherwise the type
is classified.

-}
classifyRef : TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Engine.S -> ( Mono.MonoType, Engine.S )
classifyRef refExpr canType s0 =
    if not (s0.env.lss.enabled && LssInfer.canTypeMentionsArrow canType) then
        classifyAs Mono.tkClassMisc canType s0

    else
        case Store.loadTypeS canType s0 of
            ( canVar, s1 ) ->
                Store.zonkToMono canVar (injectArgLambdaMember refExpr canVar s1)


{-| Tells whether a MonoType contains a `CEcoValue` type variable anywhere.
-}
monoTypeMentionsEco : Mono.MonoType -> Bool
monoTypeMentionsEco mt =
    case mt of
        Mono.MVar _ Mono.CEcoValue ->
            True

        Mono.MFunction _ _ args r ->
            List.any monoTypeMentionsEco args || monoTypeMentionsEco r

        Mono.MList _ t ->
            monoTypeMentionsEco t

        Mono.MTuple _ ts ->
            List.any monoTypeMentionsEco ts

        Mono.MCustom _ _ _ args ->
            List.any monoTypeMentionsEco args

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || monoTypeMentionsEco t) False fields

        _ ->
            False



-- ====== CALLS ======


{-| Translates a call by the form of its callee: a global (whose annotation
is preferred to the reference's type), a kernel or `Debug` function, a local
(which may be a let-bound function), or any other expression, which is an
indirect call.
-}
translateCall : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateCall region func args callCanType =
    case func of
        TOpt.VarGlobal funcRegion global funcMeta ->
            \s0 ->
                case lookupAnnotation global s0 of
                    ( maybeAnn, s1 ) ->
                        let
                            funcCanType =
                                case maybeAnn of
                                    Just (Can.Forall _ annType) ->
                                        annType

                                    Nothing ->
                                        funcMeta.tipe
                        in
                        translateGlobalCall region funcRegion global funcCanType args callCanType s1

        TOpt.VarKernel funcRegion kernelPrefix home name funcMeta ->
            translateKernelCall region funcRegion kernelPrefix home name ( kernelPrefix, home, name ) funcMeta.tipe args callCanType

        TOpt.VarDebug funcRegion name _ _ funcMeta ->
            translateKernelCall region funcRegion "Elm" "Debug" name ( "Elm", "Debug", name ) funcMeta.tipe args callCanType

        TOpt.VarLocal name funcMeta ->
            localCalleeCall region func name funcMeta args callCanType

        TOpt.TrackedVarLocal _ name funcMeta ->
            localCalleeCall region func name funcMeta args callCanType

        _ ->
            translateIndirectCall region func args callCanType


{-| Translates a call whose callee is a local variable. A let-bound function
goes through `translateLocalMultiCall`, so that its instance is recorded at
the type this call gives it; any other local is called indirectly.
-}
localCalleeCall : A.Region -> TOpt.Expr TypeIds.MVarId -> Name -> TOpt.Meta TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
localCalleeCall region func name funcMeta args callCanType s0 =
    case Engine.isLocalMultiTarget name s0 of
        ( isLM, s1 ) ->
            if isLM then
                translateLocalMultiCall region name funcMeta.tipe args callCanType s1

            else
                translateIndirectCall region func args callCanType s1


{-| Translates a call to a let-bound function.

The function's type is instantiated afresh, its parameters are unified with the
arguments' types and its result with the call's type, and the arguments are
translated. The function's instance is then recorded at the read-back type, and
the callee becomes a reference to that instance's binding (`f`, `f$1`, ...).
So `applyTwo (\x y -> x) 1 2` gives `applyTwo` an instance at `Int`.

-}
translateLocalMultiCall : A.Region -> Name -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLocalMultiCall region name funcCanType args callCanType s0 =
    let
        argCount =
            List.length args
    in
    case instantiate funcCanType s0 of
        ( funcVar, s1 ) ->
            case unifyParamsCollect funcVar args s1 of
                ( argStash, s2 ) ->
                    case unifyResultWithExpected funcVar argCount callCanType s2 of
                        s3 ->
                            case translateArgsWith argStash args s3 of
                                ( monoArgs, s3b ) ->
                                    case censusArgs (TOpt.Global (ModuleName.Canonical ( "local", "local" ) "local") name) args s3b of
                                        s4 ->
                                            case Store.zonkToMono funcVar s4 of
                                                ( funcMonoType, s5 ) ->
                                                    case callResultType argCount funcMonoType callCanType s5 of
                                                        ( resultMonoType, s6 ) ->
                                                            case Engine.recordLocalInstance name funcMonoType s6 of
                                                                ( ( freshName, instType, _ ), s7 ) ->
                                                                    ( Mono.MonoCall region
                                                                        (Mono.MonoVarLocal freshName instType)
                                                                        monoArgs
                                                                        resultMonoType
                                                                        Mono.defaultCallInfo
                                                                    , s7
                                                                    )


{-| Translates a call whose callee is an arbitrary expression rather than a
global or kernel reference: a local holding a function, a field access, the
result of another call.

The callee's type is first connected to the shape `arg1 -> ... -> result`
(`appShapeConnect`), since for a function taken out of a pattern this call is
the only place its type meets concrete arguments. The arguments and the callee
are then translated, and the call is devirtualized when `devirtDirectTarget`
names a single target; otherwise it stays indirect (`indirectCallFallback`).
Under `lss.report` the call is counted as saturating or partial.

-}
translateIndirectCall : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateIndirectCall region func args callCanType s0 =
    case appShapeConnect func args callCanType s0 of
        s1 ->
            let
                s1b =
                    if not s1.env.lss.report then
                        s1

                    else if List.length args < LssInfer.canTypeArrowDepth (TOpt.typeOf func) then
                        Engine.bumpArgFlowCensus "m2|lamPartialApp" s1

                    else
                        Engine.bumpArgFlowCensus "m2|indirectSat" s1
            in
            translateIndirectCallBody region func args callCanType s1b


{-| Unifies, best effort, the callee's type with `arg1 -> ... -> result`
built from the arguments' and the call's types.

The callee's type is first unified with the type bound to it in the variable
environment (`enrichFromEnv`), which links it to its declaration's types; a
rebuilt tail call's types are otherwise consistent only among themselves. When
the callee is a local bound by a destructuring pattern, the shape is also
unified with the destructor's type, which carries it back to the value the
function was taken from.

-}
appShapeConnect : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
appShapeConnect func args callCanType s0 =
    case Store.loadType (TOpt.typeOf func) s0 of
        ( funcUseVar, s1 ) ->
            case buildAppVar args callCanType (enrichFromEnv func funcUseVar s1) of
                ( appVar, s2 ) ->
                    let
                        s3 =
                            unifyStepBestEffort funcUseVar appVar s2
                    in
                    case accessedLocalName func of
                        Just localName ->
                            case Dict.get localName s3.derivedDestructors of
                                Just dCan ->
                                    case Store.loadTypeS dCan s3 of
                                        ( dVar, s4 ) ->
                                            unifyStepBestEffort dVar appVar s4

                                Nothing ->
                                    s3

                        Nothing ->
                            s3


{-| Returns a store variable for `arg1 -> ... -> result`, one arrow per
argument, loading each argument's type and the call's type.
-}
buildAppVar : List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Vars.Variable
buildAppVar args callCanType s0 =
    case args of
        [] ->
            Store.loadType callCanType s0

        arg :: rest ->
            case Store.loadType (TOpt.typeOf arg) s0 of
                ( argVar, s1 ) ->
                    case buildAppVar rest callCanType s1 of
                        ( restVar, s2 ) ->
                            Engine.freshVar (Vars.Structure (Vars.Fun1 argVar restVar)) s2


{-| Translates the arguments and the callee of an indirect call, then builds
the call.

When `devirtDirectTarget` names a global, the callee becomes a reference to
that global at the callee's type, so the call is direct. When it names a
kernel, the kernel's ABI type is derived from the call, and the call is direct
only when both kernel guards accept it (`kernelDevirtShapeOk`,
`kernelDevirtEmissionOk`); each refusal is counted. The arguments are
translated once whichever way the call goes.

-}
translateIndirectCallBody : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateIndirectCallBody region func args callCanType s0 =
    case Engine.traverse translate args s0 of
        ( monoArgs, s1 ) ->
            case translate func s1 of
                ( monoFunc, s2 ) ->
                    case devirtDirectTarget func args monoFunc s2 of
                        ( Just (DevirtGlobal ctorGlobal), s3 ) ->
                            case translateVarRef func region ctorGlobal (TOpt.typeOf func) (bumpDevirtDirect s3) of
                                ( ctorRef, s4 ) ->
                                    case classifyAs Mono.tkClassCall callCanType s4 of
                                        ( classifiedResult, s5 ) ->
                                            case indirectResultAnno (Mono.typeOf monoFunc) (List.length args) classifiedResult s5 of
                                                ( resultMonoType, s6 ) ->
                                                    ( Mono.MonoCall region ctorRef monoArgs resultMonoType Mono.defaultCallInfo, s6 )

                        ( Just (DevirtKernel kernelPrefix home name), s3 ) ->
                            -- Not `translateKernelCall`: that would translate the arguments a second time.
                            case deriveKernelAbiTypeCall ( kernelPrefix, home, name ) (TOpt.typeOf func) args s3 of
                                ( funcMonoType, s4 ) ->
                                    case callResultType (List.length args) funcMonoType callCanType s4 of
                                        ( resultMonoType, s5 ) ->
                                            if not (kernelDevirtShapeOk kernelPrefix home name funcMonoType) then
                                                indirectCallFallback region monoFunc monoArgs (List.length args) callCanType (bumpKernelDeclineShape () s5)

                                            else if not (kernelDevirtEmissionOk kernelPrefix home name monoArgs resultMonoType) then
                                                indirectCallFallback region monoFunc monoArgs (List.length args) callCanType (bumpKernelDeclineEmission home name monoArgs resultMonoType s5)

                                            else
                                                ( Mono.MonoCall region
                                                    (Mono.MonoVarKernel region kernelPrefix home name funcMonoType)
                                                    monoArgs
                                                    resultMonoType
                                                    Mono.defaultCallInfo
                                                , bumpDevirtKernel s5
                                                )

                        ( Nothing, s3 ) ->
                            indirectCallFallback region monoFunc monoArgs (List.length args) callCanType s3


{-| The single target an indirect call is rewritten to call directly.

`DevirtGlobal` is a constructor or a global function with a body.
`DevirtKernel` is a kernel function, named by prefix, home and name, that
`KernelFacts` registers for this rewrite.

-}
type DevirtTarget
    = DevirtGlobal TOpt.Global
    | DevirtKernel Name Name Name


{-| Returns the number of arguments a call must supply for a kernel to be
called directly in place of an indirect call, or `Nothing` when `KernelFacts`
does not register the kernel for that rewrite.
-}
kernelDevirtArity : Name -> Name -> Name -> Maybe Int
kernelDevirtArity prefix home name =
    case KernelFacts.devirtOf ( prefix, home, name ) of
        KernelFacts.DevirtAt arity _ ->
            Just arity

        KernelFacts.DevirtNo ->
            Nothing


{-| Tells whether a kernel's derived ABI type passes the kernel's shape guard
in `KernelFacts`.

A guard that lists positions requires that none of those positions, peeled
from the derived type, is an unboxed scalar (`unboxedScalar`). For
`List.cons` the positions are the tail and the result, which are lists and so
are always boxed; a derived type with a scalar there means the call's types
are not reliable. An unregistered kernel, or a type with too few parameters,
fails.

-}
kernelDevirtShapeOk : Name -> Name -> Name -> Mono.MonoType -> Bool
kernelDevirtShapeOk prefix home name funcMonoType =
    case KernelFacts.devirtOf ( prefix, home, name ) of
        KernelFacts.DevirtNo ->
            False

        KernelFacts.DevirtAt arity guard ->
            case guard of
                KernelFacts.ShapeAny ->
                    True

                KernelFacts.ShapeNoUnboxedScalarAt positions ->
                    case peelArrow arity funcMonoType of
                        Just ( argTypes, resultType ) ->
                            List.all (\pos -> not (unboxedScalar (atPosition pos argTypes resultType))) positions

                        Nothing ->
                            False


{-| Returns the type at a guard position: a negative position is the result,
otherwise it is the 0-based argument. A position past the last argument also
gives the result.
-}
atPosition : Int -> List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
atPosition pos argTypes resultType =
    if pos < 0 then
        resultType

    else
        case List.drop pos argTypes of
            t :: _ ->
                t

            [] ->
                resultType


{-| Returns the first `n` parameter types of a function type and what
remains, whether the type is curried, flat or a mixture. Returns `Nothing`
when the type has fewer than `n` parameters or when the `n`th falls inside a
stage of several.
-}
peelArrow : Int -> Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelArrow n tipe =
    peelArrowGo n tipe []


{-| Does the work of `peelArrow`, with the parameters taken so far in
reverse.
-}
peelArrowGo : Int -> Mono.MonoType -> List Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelArrowGo remaining tipe acc =
    if remaining == 0 then
        Just ( List.reverse acc, tipe )

    else
        case tipe of
            Mono.MFunction _ _ argTypes result ->
                let
                    taken =
                        List.length argTypes
                in
                if taken <= remaining then
                    peelArrowGo (remaining - taken) result (List.reverse argTypes ++ acc)

                else
                    Nothing

            _ ->
                Nothing


{-| Tells whether a direct kernel call may be emitted with these translated
arguments and result type.

Code generation declares the kernel from the argument and result types of the
call, not from the callee's type, so the guard is checked on them as well: the
call must supply exactly the registered number of arguments, the guarded
positions must not be unboxed scalars, and no argument or result type may
contain a `number` variable anywhere. Such a variable means the types are not
settled yet; it may later be closed to `Int` (see `unboxedScalar`), which can
make the declaration disagree with another of the same kernel. An unregistered
kernel fails.

-}
kernelDevirtEmissionOk : Name -> Name -> Name -> List Mono.MonoExpr -> Mono.MonoType -> Bool
kernelDevirtEmissionOk prefix home name monoArgs resultMonoType =
    case KernelFacts.devirtOf ( prefix, home, name ) of
        KernelFacts.DevirtNo ->
            False

        KernelFacts.DevirtAt arity guard ->
            let
                argTypes =
                    List.map Mono.typeOf monoArgs

                shapeOk =
                    case guard of
                        KernelFacts.ShapeAny ->
                            True

                        KernelFacts.ShapeNoUnboxedScalarAt positions ->
                            List.all (\pos -> not (unboxedScalar (atPosition pos argTypes resultMonoType))) positions
            in
            (List.length monoArgs == arity)
                && shapeOk
                && not (List.any containsCNumber argTypes)
                && not (containsCNumber resultMonoType)


{-| Tells whether a MonoType contains a `number` type variable anywhere.
-}
containsCNumber : Mono.MonoType -> Bool
containsCNumber t =
    case t of
        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MFunction _ _ argTypes result ->
            List.any containsCNumber argTypes || containsCNumber result

        Mono.MList _ elem ->
            containsCNumber elem

        Mono.MTuple _ elems ->
            List.any containsCNumber elems

        Mono.MCustom _ _ _ typeArgs ->
            List.any containsCNumber typeArgs

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft acc -> acc || containsCNumber ft) False fields

        _ ->
            False


{-| Tells whether a MonoType is, or will become, an unboxed scalar: `Int`,
`Float`, `Char`, or a `number` variable, which is later closed to `Int`.
-}
unboxedScalar : Mono.MonoType -> Bool
unboxedScalar t =
    case t of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MChar ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        _ ->
            False


{-| Builds an indirect call of `monoFunc`, whose result type is classified
from the call's type and given the lambda sets of the callee's own type
(`indirectResultAnno`).
-}
indirectCallFallback : A.Region -> Mono.MonoExpr -> List Mono.MonoExpr -> Int -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
indirectCallFallback region monoFunc monoArgs argCount callCanType s0 =
    case classifyAs Mono.tkClassCall callCanType s0 of
        ( classifiedResult, s1 ) ->
            case indirectResultAnno (Mono.typeOf monoFunc) argCount classifiedResult s1 of
                ( resultMonoType, s2 ) ->
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, s2 )


{-| Returns the single target an indirect call can be rewritten to call
directly, if there is one.

There is one only when LSS is on, the callee is a local variable (so dropping
the callee expression drops no computation), and the head lambda set of the
callee's translated type has exactly one member. A member that stands for a
global (`Engine.standaloneMemberGlobal`) is decided by `devirtGlobalTarget`,
unless the global is an alias of a kernel, which is decided like a kernel. A
member that stands for a kernel is decided by `devirtKernelTarget`. A
partial-application member stands for neither, so it is never a target. A
kernel target also needs the call to supply exactly its registered number of
arguments.

The set may be provisional. If the spec's demand widens later, the node is
translated again and the decision is made again with the wider set.

-}
devirtDirectTarget : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Mono.MonoExpr -> Step (Maybe DevirtTarget)
devirtDirectTarget func args monoFunc s0 =
    if not s0.env.lss.enabled then
        ( Nothing, s0 )

    else if not (calleeIsPlainVar func) then
        ( Nothing, s0 )

    else
        case Mono.headAnno (Mono.typeOf monoFunc) of
            Mono.LSet [ m ] ->
                case Engine.standaloneMemberGlobal m s0 of
                    ( Nothing, s1 ) ->
                        devirtKernelTarget m (List.length args) s1

                    ( Just ctorGlobal, s1 ) ->
                        case LssInfer.kernelAliasOf ctorGlobal s1 of
                            Just ( kernelPrefix, home, name ) ->
                                -- A kernel alias such as `cons = Elm.Kernel.List.cons` goes through the kernel guards;
                                -- as a global, inlining would place the raw kernel call here unguarded.
                                case kernelDevirtArity kernelPrefix home name of
                                    Just arity ->
                                        if arity == List.length args then
                                            ( Just (DevirtKernel kernelPrefix home name), s1 )

                                        else
                                            ( Nothing, recordKernelArityMiss s1 )

                                    Nothing ->
                                        ( Nothing, recordKernelMiss home name s1 )

                            Nothing ->
                                devirtGlobalTarget ctorGlobal (List.length args) s1

            _ ->
                ( Nothing, s0 )


{-| Returns the global as a direct-call target when it is a constructor or a
global with a body, has an annotation, and its annotation has as many arrows
as the call has arguments (at least one). Otherwise returns `Nothing`.
-}
devirtGlobalTarget : TOpt.Global -> Int -> Step (Maybe DevirtTarget)
devirtGlobalTarget ctorGlobal argCount s1 =
    if not (isCtorNode ctorGlobal s1 || isBodyNode ctorGlobal s1) then
        ( Nothing, s1 )

    else
        case lookupAnnotation ctorGlobal s1 of
            ( Just (Can.Forall _ annType), s2 ) ->
                let
                    arity =
                        arrowSpineLength annType
                in
                if arity >= 1 && arity == argCount then
                    ( Just (DevirtGlobal ctorGlobal), s2 )

                else
                    ( Nothing, s2 )

            ( Nothing, s2 ) ->
                ( Nothing, s2 )


{-| Returns the kernel member `m` stands for as a direct-call target, when
`KernelFacts` registers it and the call supplies exactly its registered number
of arguments. An unregistered kernel and an arity mismatch are each counted.
-}
devirtKernelTarget : Int -> Int -> Step (Maybe DevirtTarget)
devirtKernelTarget m argCount s0 =
    case Engine.standaloneMemberKernel m s0 of
        ( Nothing, s1 ) ->
            ( Nothing, s1 )

        ( Just ( kernelPrefix, home, name ), s1 ) ->
            case kernelDevirtArity kernelPrefix home name of
                Just arity ->
                    if arity == argCount then
                        ( Just (DevirtKernel kernelPrefix home name), s1 )

                    else
                        ( Nothing, recordKernelArityMiss s1 )

                Nothing ->
                    ( Nothing, recordKernelMiss home name s1 )


{-| Counts, per kernel, a call whose single callee member is a kernel that
`KernelFacts` does not register for direct calls.
-}
recordKernelMiss : Name -> Name -> Engine.S -> Engine.S
recordKernelMiss home name s =
    let
        stats =
            s.lssStats

        key =
            home ++ "." ++ name
    in
    { s
        | lssStats =
            { stats
                | kernelMissHist =
                    Dict.update key (\v -> Just (Maybe.withDefault 0 v + 1)) stats.kernelMissHist
            }
    }


{-| Counts, per kernel, a use of a kernel whose `KernelSetFacts` license does
not apply to the type it is used at. Other kernels leave the state unchanged.
-}
recordRefusedLicense : ( String, String, String ) -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
recordRefusedLicense ( kPrefix, kHome, kName ) canFuncType s =
    case KernelSetFacts.factFor kPrefix kHome kName of
        Just (KernelSetFacts.TypeFaithful license) ->
            if KernelSetFacts.licenseApplies (Engine.isScalarVar s) license canFuncType then
                s

            else
                let
                    stats =
                        s.lssStats
                in
                { s
                    | lssStats =
                        { stats
                            | kernelUnsolvedHist =
                                Dict.update (kPrefix ++ "." ++ kHome ++ "." ++ kName)
                                    (\v -> Just (Maybe.withDefault 0 v + 1))
                                    stats.kernelUnsolvedHist
                        }
                }

        _ ->
            s


{-| Counts a call that names a registered kernel as its single callee but
supplies a different number of arguments than the kernel is registered for.
-}
recordKernelArityMiss : Engine.S -> Engine.S
recordKernelArityMiss s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | declinedKernelArity = stats.declinedKernelArity + 1 } }


{-| Tells whether a global's node, following links, is a constructor with
fields (`Ctor` or `Box`). An enum is not.
-}
isCtorNode : TOpt.Global -> Engine.S -> Bool
isCtorNode g s =
    case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
        Just (TOpt.Ctor _ _ _) ->
            True

        Just (TOpt.Box _) ->
            True

        Just (TOpt.Link target) ->
            isCtorNode target s

        _ ->
            False


{-| Tells whether a global's node, following links, has a body: a plain or
tracked definition, or a recursive group.
-}
isBodyNode : TOpt.Global -> Engine.S -> Bool
isBodyNode g s =
    case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
        Just (TOpt.Define _ _ _) ->
            True

        Just (TOpt.TrackedDefine _ _ _ _) ->
            True

        Just (TOpt.Cycle _ _ _ _) ->
            True

        Just (TOpt.Link target) ->
            isBodyNode target s

        _ ->
            False


{-| Tells whether an expression is a reference to a local variable.
-}
calleeIsPlainVar : TOpt.Expr TypeIds.MVarId -> Bool
calleeIsPlainVar func =
    case func of
        TOpt.VarLocal _ _ ->
            True

        TOpt.TrackedVarLocal _ _ _ ->
            True

        _ ->
            False


{-| Returns the number of arrows along a canonical type's result spine,
without looking through aliases.
-}
arrowSpineLength : Can.Type TypeIds.MVarId -> Int
arrowSpineLength t =
    case t of
        Can.TLambda _ _ rest ->
            1 + arrowSpineLength rest

        _ ->
            0


{-| Counts an indirect call rewritten to call a global directly.
-}
bumpDevirtDirect : Engine.S -> Engine.S
bumpDevirtDirect s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | devirtDirect = stats.devirtDirect + 1 } }


{-| Counts an indirect call rewritten to call a kernel directly.
-}
bumpDevirtKernel : Engine.S -> Engine.S
bumpDevirtKernel s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | devirtKernel = stats.devirtKernel + 1 } }


{-| Counts a kernel call kept indirect by the shape guard
(`kernelDevirtShapeOk`).
-}
bumpKernelDeclineShape : () -> Engine.S -> Engine.S
bumpKernelDeclineShape () s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | declinedKernelShape = stats.declinedKernelShape + 1 } }


{-| Counts a kernel call kept indirect by the emission guard
(`kernelDevirtEmissionOk`), in one of two counters.

For `List.cons` with two arguments whose tail and result are not unboxed
scalars, the decline is counted as caused by a `number` variable. Every other
decline, including every decline for any other kernel, is counted in the
other counter, whatever its cause.

-}
bumpKernelDeclineEmission : Name -> Name -> List Mono.MonoExpr -> Mono.MonoType -> Engine.S -> Engine.S
bumpKernelDeclineEmission home name monoArgs resultMonoType s =
    let
        stats =
            s.lssStats

        isCNumber =
            if home == "List" && name == "cons" then
                case monoArgs of
                    [ _, tailArg ] ->
                        not (unboxedScalar (Mono.typeOf tailArg))
                            && not (unboxedScalar resultMonoType)

                    _ ->
                        False

            else
                False
    in
    if isCNumber then
        { s | lssStats = { stats | declinedKernelCNumber = stats.declinedKernelCNumber + 1 } }

    else
        { s | lssStats = { stats | declinedKernelEmission = stats.declinedKernelEmission + 1 } }


{-| Returns the classified result type of an indirect call, with LSS on given
the lambda sets of what remains of the callee's type after `argCount`
parameters. This is how a member on `f`'s inner arrow reaches the type of
`f 10`. With LSS off the classified type is returned unchanged.
-}
indirectResultAnno : Mono.MonoType -> Int -> Mono.MonoType -> Step Mono.MonoType
indirectResultAnno funcMono argCount classifiedResult s0 =
    if s0.env.lss.enabled then
        ( Mono.overlayAnnotations classifiedResult (peelResultAnno argCount funcMono), s0 )

    else
        ( classifiedResult, s0 )


{-| Returns what remains of a function type after `n` parameters. When `n`
ends inside a stage of several parameters, the rest of that stage keeps the
stage's own lambda set.
-}
peelResultAnno : Int -> Mono.MonoType -> Mono.MonoType
peelResultAnno n t =
    if n <= 0 then
        t

    else
        case t of
            Mono.MFunction _ anno params ret ->
                let
                    np =
                        List.length params
                in
                if n >= np then
                    peelResultAnno (n - np) ret

                else
                    Mono.mFunction anno (List.drop n params) ret

            _ ->
                t


{-| Translates a call to a global function.

The type the callee is demanded at is found by instantiating its type afresh,
unifying its parameters with the arguments' types and its result with the
call's type, and reading the result back; `translateGlobalCallSlow` does this
in full. Two faster paths give the same result where they can:
`translateGlobalCallFast` for a callee whose type has no variables, and
`translateGlobalCallGroundMemo` for a call whose argument and result types have
none. Neither is taken while a let-bound function or number is having its uses
recorded, because the full path records them. With LSS on, neither is taken
unless the callee's signature is trivial, no argument's type has an arrow, and
the call is not a partial application with a function-typed result
(`lssFastOk`, `needsPapSlow`), because the fast paths would put ⊤ on every
arrow.

-}
translateGlobalCall : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCall region funcRegion global funcCanType args callCanType s =
    if List.isEmpty s.numberMulti && List.isEmpty s.localMulti then
        case lssFastOk global args s of
            ( fastOk, s0 ) ->
                if not fastOk || needsPapSlow global args callCanType s0 then
                    translateGlobalCallSlow region funcRegion global funcCanType args callCanType s0

                else if groundCanType funcCanType then
                    translateGlobalCallFast region funcRegion global funcCanType args callCanType s0

                else if groundCanType callCanType && List.all (groundCanType << TOpt.typeOf) args then
                    translateGlobalCallGroundMemo region funcRegion global funcCanType args callCanType s0

                else
                    translateGlobalCallSlow region funcRegion global funcCanType args callCanType s0

    else
        translateGlobalCallSlow region funcRegion global funcCanType args callCanType s


{-| Tells whether a call must take the full path because, with LSS on, it
supplies fewer arguments than the global's declared arity and its result type
has an arrow. Such a partial application needs store structure for its
result's arrows to carry the partial-application member, and the fast paths
build none. `lssFastOk` never looks at the call's result type, so `(::) x`
would otherwise take a fast path.
-}
needsPapSlow : TOpt.Global -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Engine.S -> Bool
needsPapSlow global args callCanType s =
    s.env.lss.enabled
        && canTypeHasArrow callCanType
        && LssInfer.declaredArityOf global 8 s
        > List.length args


{-| Tells whether a call may take a fast path as far as LSS is concerned:
always with LSS off, and with LSS on only when no argument's type has an arrow
and the callee's signature (`LssInfer.signatureFor`, computed on first use) is
trivial.
-}
lssFastOk : TOpt.Global -> List (TOpt.Expr TypeIds.MVarId) -> Step Bool
lssFastOk global args s =
    if not s.env.lss.enabled then
        ( True, s )

    else if List.any (canTypeHasArrow << TOpt.typeOf) args then
        ( False, s )

    else
        case LssInfer.signatureFor global s of
            ( sig, s1 ) ->
                ( sig.trivial, s1 )


{-| Tells whether a canonical type contains an arrow anywhere, including in
an alias's arguments and its expansion.
-}
canTypeHasArrow : Can.Type TypeIds.MVarId -> Bool
canTypeHasArrow t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TVar _ ->
            False

        Can.TType _ _ typeArgs ->
            List.any canTypeHasArrow typeArgs

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ ft) acc -> acc || canTypeHasArrow ft) False fields

        Can.TUnit ->
            False

        Can.TTuple a b rest ->
            canTypeHasArrow a || canTypeHasArrow b || List.any canTypeHasArrow rest

        Can.TAlias _ _ aliasArgs (Can.Filled real) ->
            canTypeHasArrow real || List.any (\( _, at ) -> canTypeHasArrow at) aliasArgs

        Can.TAlias _ _ aliasArgs (Can.Holey real) ->
            canTypeHasArrow real || List.any (\( _, at ) -> canTypeHasArrow at) aliasArgs


{-| Tells whether two canonical types are equal once every arrow id is
ignored. A definition's annotation and its body's type give the same arrow
different ids, so plain `==` would not match them. Types that are already
equal are not copied.
-}
sameCanTypeIgnoringArrows : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Bool
sameCanTypeIgnoringArrows a b =
    (a == b) || (stripArrowIds a == stripArrowIds b)


{-| Returns a canonical type with every arrow, at any depth, rebuilt by
`Can.tLambda` without its id, and everything else unchanged.
-}
stripArrowIds : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
stripArrowIds t =
    case t of
        Can.TLambda _ from to ->
            Can.tLambda (stripArrowIds from) (stripArrowIds to)

        Can.TVar _ ->
            t

        Can.TType home name args ->
            Can.TType home name (List.map stripArrowIds args)

        Can.TRecord fields ext ->
            Can.TRecord (Dict.map (\_ (Can.FieldType i ft) -> Can.FieldType i (stripArrowIds ft)) fields) ext

        Can.TUnit ->
            t

        Can.TTuple x y rest ->
            Can.TTuple (stripArrowIds x) (stripArrowIds y) (List.map stripArrowIds rest)

        Can.TAlias home name args (Can.Filled inner) ->
            Can.TAlias home name (List.map (Tuple.mapSecond stripArrowIds) args) (Can.Filled (stripArrowIds inner))

        Can.TAlias home name args (Can.Holey inner) ->
            Can.TAlias home name (List.map (Tuple.mapSecond stripArrowIds) args) (Can.Holey (stripArrowIds inner))


{-| Tells whether a canonical type has no type variable, counting an
extensible record's extension as one. A holey alias is ground when its
arguments are.
-}
groundCanType : Can.Type TypeIds.MVarId -> Bool
groundCanType canType =
    case canType of
        Can.TVar _ ->
            False

        Can.TLambda _ a b ->
            groundCanType a && groundCanType b

        Can.TType _ _ args ->
            List.all groundCanType args

        Can.TRecord fields maybeExt ->
            case maybeExt of
                Just _ ->
                    False

                Nothing ->
                    List.all (\( _, Can.FieldType _ t ) -> groundCanType t) (Dict.toList fields)

        Can.TUnit ->
            True

        Can.TTuple a b rest ->
            groundCanType a && groundCanType b && List.all groundCanType rest

        Can.TAlias _ _ _ (Can.Filled inner) ->
            groundCanType inner

        Can.TAlias _ _ aliasArgs (Can.Holey _) ->
            List.all (\( _, t ) -> groundCanType t) aliasArgs


{-| Returns the first parameter type of each of the first `n` stages of a
function type, stopping early where the type runs out of stages. A stage with
several parameters contributes only its first.
-}
mFunctionParams : Int -> Mono.MonoType -> List Mono.MonoType
mFunctionParams n mt =
    if n <= 0 then
        []

    else
        case mt of
            Mono.MFunction _ _ (p :: _) result ->
                p :: mFunctionParams (n - 1) result

            _ ->
                []


{-| Returns the MonoType of a callee type with no variables, from the
engine's cache under `key` or else computed without the store and cached.
-}
cachedSchemeMono : String -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
cachedSchemeMono key funcCanType s0 =
    case Engine.lookupSchemeMono key s0 of
        ( Just mt, s1 ) ->
            ( mt, s1 )

        ( Nothing, s1 ) ->
            computeSchemeMono key funcCanType s1


{-| Computes the MonoType for `cachedSchemeMono` and caches it under `key`.
The type is built through the state's intern table, so every call site that
reuses it shares one value.
-}
computeSchemeMono : String -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
computeSchemeMono key funcCanType s0 =
    let
        ( mt, intern1 ) =
            Zonk.canTypeToMonoI s0.env.superStatic funcCanType s0.intern
    in
    case Engine.putSchemeMono key mt { s0 | intern = intern1 } of
        s1 ->
            ( mt, s1 )


{-| Unifies each argument's canonical type that has variables with the
ground parameter type it is paired with (`demandUnify`). Arguments whose types
are already ground are skipped.
-}
flowArgDemands : List ( Mono.MonoType, Can.Type TypeIds.MVarId ) -> Engine.S -> Engine.S
flowArgDemands pairs s0 =
    List.foldl
        (\( paramMono, argCanType ) sAcc ->
            if groundCanType argCanType then
                sAcc

            else
                demandUnify argCanType paramMono sAcc
        )
        s0
        pairs


{-| Translates a call to a global whose type has no variables. The callee's
MonoType is the cached one (`cachedSchemeMono`); the arguments' and the
call's types are unified with its parameters and result where they have
variables, and a spec is enqueued at the callee's type. A call with more
arguments than the type has stages goes to `translateGlobalCallSlow`.
-}
translateGlobalCallFast : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCallFast region funcRegion global funcCanType args callCanType s0 =
    let
        argCount =
            List.length args
    in
    case cachedSchemeMono (TOpt.toComparableGlobal global) funcCanType s0 of
        ( funcMonoType, s1 ) ->
            let
                paramMonos =
                    mFunctionParams argCount funcMonoType
            in
            if List.length paramMonos < argCount then
                translateGlobalCallSlow region funcRegion global funcCanType args callCanType s1

            else
                let
                    resultMonoType =
                        peelResult argCount funcMonoType

                    s2 =
                        flowArgDemands (List.map2 Tuple.pair paramMonos (List.map TOpt.typeOf args)) s1

                    s3 =
                        if groundCanType callCanType then
                            s2

                        else
                            demandUnify callCanType resultMonoType s2
                in
                case Engine.traverse translate args s3 of
                    ( monoArgs, s4 ) ->
                        case enqueueSpecStamped global funcMonoType s4 of
                            ( specId, s5 ) ->
                                ( Mono.MonoCall region
                                    (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                    monoArgs
                                    resultMonoType
                                    Mono.defaultCallInfo
                                , s5
                                )


{-| Translates a call to a global whose argument and result types have no
variables, memoising the outcome.

The memo key is the global together with the function type built from the
argument types and the call's type. On a miss the callee's type is
instantiated, unified with them and read back, the spec is enqueued, and the
callee's type, the result type and the spec id are stored. On a hit those are
reused and only the arguments are translated. Ground types touch no type
variable of the item, so a hit leaves the store as a miss would have, apart
from the instantiation itself. The key's arrows all carry ⊤, which is enough
because `lssFastOk` keeps calls whose types could carry lambda sets off this
path.

-}
translateGlobalCallGroundMemo : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCallGroundMemo region funcRegion global funcCanType args callCanType s0 =
    let
        key =
            Mono.SpecKey (toptToMonoGlobal global)
                (Mono.mFunction Mono.topDeclOther
                    (List.map (Zonk.canTypeToMono s0.env.superStatic << TOpt.typeOf) args)
                    (Zonk.canTypeToMono s0.env.superStatic callCanType)
                )
    in
    case Engine.lookupCallMemo key s0 of
        ( Just ( funcMonoType, resultMonoType, specId ), s1 ) ->
            -- The spec was enqueued on the miss, so it is not enqueued again.
            case Engine.traverse translate args s1 of
                ( monoArgs, s2 ) ->
                    ( Mono.MonoCall region
                        (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                        monoArgs
                        resultMonoType
                        Mono.defaultCallInfo
                    , s2
                    )

        ( Nothing, s1 ) ->
            case instantiate funcCanType s1 of
                ( funcVar, s2 ) ->
                    let
                        s3 =
                            unifyResultWithExpected funcVar
                                (List.length args)
                                callCanType
                                (unifyParamsWithArgExprs funcVar args s2)
                    in
                    case Store.zonkToMono funcVar s3 of
                        ( funcMonoType, s4 ) ->
                            case callResultType (List.length args) funcMonoType callCanType s4 of
                                ( resultMonoType, s5 ) ->
                                    case Engine.traverse translate args s5 of
                                        ( monoArgs, s6 ) ->
                                            case enqueueSpecStamped global funcMonoType s6 of
                                                ( specId, s7 ) ->
                                                    ( Mono.MonoCall region
                                                        (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                                        monoArgs
                                                        resultMonoType
                                                        Mono.defaultCallInfo
                                                    , Engine.putCallMemo key ( funcMonoType, resultMonoType, specId ) s7
                                                    )


{-| Translates a call to a global in full.

The callee's type is instantiated afresh with its signature facts applied
(`instantiateLss`), its parameters are unified with the arguments' types
(`unifyParamsCollect`) and its result with the call's type, and a partial
application gets its member (`unifyResultThenInjectPap`). Only then are the
arguments translated, so that a use of a local inside an argument sees the
type the call demands of it. The callee's type is read back, a spec is
enqueued at it, and the call is built. With LSS on, a constructor applied to
an argument whose type has a set variable or a non-legacy ⊤
(`Mono.hasVarAnno`) marks the spec (`Engine.markFlexCtorSpec`).

-}
translateGlobalCallSlow : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCallSlow region funcRegion global funcCanType args callCanType s0 =
    let
        argCount =
            List.length args
    in
    case instantiateLss global funcCanType s0 of
        ( funcVar, s1 ) ->
            case unifyParamsCollect funcVar args s1 of
                ( argStash, s2 ) ->
                    case unifyResultThenInjectPap funcVar argCount callCanType global s2 of
                        s3 ->
                            case translateArgsWith argStash args s3 of
                                ( monoArgs, s3b ) ->
                                    -- After the arguments, so their callees' signatures are already memoized.
                                    case censusArgs global args s3b of
                                        s4 ->
                                            case Store.zonkToMono funcVar s4 of
                                                ( funcMonoType, s5 ) ->
                                                    case callResultType argCount funcMonoType callCanType s5 of
                                                        ( resultMonoType, s6 ) ->
                                                            case enqueueSpecStamped global funcMonoType s6 of
                                                                ( specId, s7pre ) ->
                                                                    let
                                                                        s7 =
                                                                            if
                                                                                s7pre.env.lss.enabled
                                                                                    && not (List.isEmpty monoArgs)
                                                                                    && List.any (Mono.hasVarAnno << Mono.typeOf) monoArgs
                                                                                    && isCtorNode global s7pre
                                                                            then
                                                                                Engine.markFlexCtorSpec specId s7pre

                                                                            else
                                                                                s7pre
                                                                    in
                                                                    ( Mono.MonoCall region
                                                                        (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                                                        monoArgs
                                                                        resultMonoType
                                                                        Mono.defaultCallInfo
                                                                    , s7
                                                                    )


{-| Counts, under `lss.report`, the arguments of a call to `global` whose
types contain an arrow. Otherwise returns the state unchanged.

An argument that is itself a call is counted under `pop|` by the called
global, by the class of its callee (`argCalleeKey`) and by whether that
callee's memoized signature is trivial, together with how many of the
callee's declared parameters it supplies (`sat|`, `arity|`), the enclosing
global (`encl|`), and a `fan|` key per called global, callee and argument
type. Any other argument is counted under `shape|` by its form
(`argShapeName`). Signatures are read only from the memo, never computed.

-}
censusArgs : TOpt.Global -> List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
censusArgs global args s0 =
    if not s0.env.lss.report then
        s0

    else
        censusArgsGo (TOpt.toComparableGlobal global) args s0


{-| Counts each argument whose type contains an arrow, for `censusArgs`.
-}
censusArgsGo : String -> List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
censusArgsGo hofKey args s0 =
    case args of
        [] ->
            s0

        arg :: rest ->
            if not (canTypeHasArrow (TOpt.typeOf arg)) then
                censusArgsGo hofKey rest s0

            else
                censusArgsGo hofKey rest (censusOneArg hofKey arg s0)


{-| Counts one argument for `censusArgs`.
-}
censusOneArg : String -> TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
censusOneArg hofKey arg s0 =
    case arg of
        TOpt.Call _ func innerArgs _ ->
            let
                calleeKey =
                    argCalleeKey func

                trivialTag =
                    case func of
                        TOpt.VarGlobal _ g _ ->
                            case Engine.memoizedSignatureTrivial g s0 of
                                Just True ->
                                    "1"

                                Just False ->
                                    "0"

                                Nothing ->
                                    "?"

                        _ ->
                            "n/a"

                supplied =
                    List.length innerArgs

                maybeDeclared =
                    case func of
                        TOpt.VarGlobal _ g _ ->
                            Just (LssInfer.declaredArityOf g 8 s0)

                        _ ->
                            Nothing

                satTag =
                    case maybeDeclared of
                        Nothing ->
                            "unknown"

                        Just d ->
                            if d <= 0 then
                                "unknown"

                            else if supplied < d then
                                "partial"

                            else if supplied == d then
                                "saturated"

                            else
                                "over"

                enclKey =
                    case s0.currentGlobal of
                        Just g ->
                            Mono.toComparableGlobal g

                        Nothing ->
                            "(none)"

                base =
                    s0
                        |> Engine.bumpArgFlowCensus "pop|all"
                        |> Engine.bumpArgFlowCensus ("pop|hof=" ++ hofKey)
                        |> Engine.bumpArgFlowCensus ("pop|callee=" ++ calleeKey)
                        |> Engine.bumpArgFlowCensus ("pop|calleeTrivial=" ++ trivialTag)
                        |> Engine.bumpArgFlowCensus ("sat|" ++ satTag)
                        |> Engine.bumpArgFlowCensus ("sat|" ++ calleeKey ++ "|" ++ satTag)
                        |> Engine.bumpArgFlowCensus ("arity|" ++ calleeKey ++ "|d=" ++ Maybe.withDefault "?" (Maybe.map String.fromInt maybeDeclared) ++ "|s=" ++ String.fromInt supplied)
                        |> Engine.bumpArgFlowCensus ("encl|" ++ enclKey)
                        |> Engine.bumpArgFlowCensus ("popt|" ++ hofKey ++ "|triv=" ++ trivialTag)
                        |> Engine.bumpArgFlowCensus ("calleeTriv|" ++ calleeKey ++ "|triv=" ++ trivialTag)
                        |> Engine.bumpArgFlowCensus ("fan|" ++ hofKey ++ "|" ++ calleeKey ++ "|" ++ canKind (TOpt.typeOf arg))
            in
            case ( satTag, maybeDeclared ) of
                ( "partial", Just d ) ->
                    Engine.bumpArgFlowCensus ("sat|partialDepth=" ++ String.fromInt (d - supplied)) base

                _ ->
                    base

        _ ->
            Engine.bumpArgFlowCensus ("shape|" ++ argShapeName arg) s0


{-| Returns the census label for the callee of an argument that is a call:
the global or kernel by name, or one label each for `Debug`, a local and any
other expression.
-}
argCalleeKey : TOpt.Expr TypeIds.MVarId -> String
argCalleeKey func =
    case func of
        TOpt.VarGlobal _ g _ ->
            "g:" ++ TOpt.toComparableGlobal g

        TOpt.VarCycle _ home name _ ->
            "cycle:" ++ TOpt.toComparableGlobal (TOpt.Global home name)

        TOpt.VarKernel _ _ home name _ ->
            "kernel:" ++ home ++ "." ++ name

        TOpt.VarDebug _ _ _ _ _ ->
            "debug"

        TOpt.VarLocal _ _ ->
            "local"

        TOpt.TrackedVarLocal _ _ _ ->
            "local"

        _ ->
            "indirect"


{-| Returns the census label for the form of an argument that is not a call:
a lambda, a global reference (`standalone`), a kernel, an accessor, a local,
a `let` (`letWrapped`), an `if` or `case` (`branchWrapped`), or anything else
(`blind`).
-}
argShapeName : TOpt.Expr TypeIds.MVarId -> String
argShapeName arg =
    case arg of
        TOpt.Function _ _ _ _ ->
            "lambda"

        TOpt.TrackedFunction _ _ _ _ ->
            "lambda"

        TOpt.VarGlobal _ _ _ ->
            "standalone"

        TOpt.VarEnum _ _ _ _ ->
            "standalone"

        TOpt.VarBox _ _ _ ->
            "standalone"

        TOpt.VarCycle _ _ _ _ ->
            "standalone"

        TOpt.VarKernel _ _ _ _ _ ->
            "kernel"

        TOpt.Accessor _ _ _ ->
            "accessor"

        TOpt.VarLocal _ _ ->
            "local"

        TOpt.TrackedVarLocal _ _ _ ->
            "local"

        TOpt.Let _ _ _ ->
            "letWrapped"

        TOpt.If _ _ _ ->
            "branchWrapped"

        TOpt.Case _ _ _ _ _ ->
            "branchWrapped"

        _ ->
            "blind"


{-| Translates a call to a kernel function.

The kernel's type is derived from the call first (`deriveKernelAbiTypeCall`),
which unifies its parameters with the arguments' types, so the arguments are
translated after their variables are concrete: in `1.4 * n`, `n`'s number
variable is already `Float` when `n` is translated.

-}
translateKernelCall : A.Region -> A.Region -> Name -> Name -> Name -> ( String, String, String ) -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateKernelCall region funcRegion kernelPrefix home name kernelId funcCanType args callCanType s0 =
    case deriveKernelAbiTypeCall kernelId funcCanType args s0 of
        ( funcMonoType, s1 ) ->
            case Engine.traverse translate args s1 of
                ( monoArgs, s2 ) ->
                    case callResultType (List.length args) funcMonoType callCanType s2 of
                        ( resultMonoType, s3 ) ->
                            ( Mono.MonoCall region
                                (Mono.MonoVarKernel funcRegion kernelPrefix home name funcMonoType)
                                monoArgs
                                resultMonoType
                                Mono.defaultCallInfo
                            , s3
                            )


{-| Returns a call's result type: what remains of the callee's type after
`argCount` stages, or, when that still has a type variable, the call's own
type classified.
-}
callResultType : Int -> Mono.MonoType -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
callResultType argCount funcMonoType callCanType s0 =
    let
        abiResultType =
            peelResult argCount funcMonoType
    in
    if Mono.containsAnyMVar abiResultType then
        classifyAs Mono.tkClassCall callCanType s0

    else
        ( abiResultType, s0 )


{-| Returns what remains of a function type after `n` stages, each counting
as one whatever its number of parameters, or the type itself where it runs out
of arrows.
-}
peelResult : Int -> Mono.MonoType -> Mono.MonoType
peelResult n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ _ _ result ->
                peelResult (n - 1) result

            _ ->
                monoType



-- ====== KERNEL ABI ======


{-| Returns a kernel's type at a call: its type is instantiated afresh, its
parameters are unified with the arguments (`unifyParamsWithArgExprs`), and the
result is read back under the kernel's ABI mode (`deriveKernelAbiTypeWith`).
-}
deriveKernelAbiTypeCall : ( String, String, String ) -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Step Mono.MonoType
deriveKernelAbiTypeCall kernelId canFuncType args =
    deriveKernelAbiTypeWith kernelId canFuncType <|
        \s0 ->
            case instantiate canFuncType s0 of
                ( funcVar, s1 ) ->
                    ( funcVar, unifyParamsWithArgExprs funcVar args s1 )


{-| Unifies each parameter of a function variable with the corresponding
argument, as `unifyParamsCollect` does, discarding what it records.
-}
unifyParamsWithArgExprs : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
unifyParamsWithArgExprs funcVar args s0 =
    Tuple.second (unifyParamsCollect funcVar args s0)


{-| What unifying a callee's parameter with one argument left for that
argument's translation.

`StashLocalMulti` is for an argument that is a reference to a let-bound
function. Its type is instantiated afresh for this call rather than loaded
through the item memo, because a type with variable ids shared with the
function's own type would otherwise change that type. The variable is the
fresh instantiation; the argument's translation reads it back to record the
function's instance at the type this call demands.

`StashNone` is for every other argument, which is translated normally.

-}
type ArgStash
    = StashNone
    | StashLocalMulti Vars.Variable


{-| Unifies, best effort, each parameter of a function variable with the
corresponding argument, and returns one `ArgStash` per argument.

An argument that refers to a let-bound function is unified as a fresh
instantiation of its type. Any other argument is unified as `argUnifyVar`
loads it, which also brings in the type bound to a local in the variable
environment and writes the argument's own member into its lambda sets. When
the function variable runs out of arrows, the remaining arguments are left
ununified.

-}
unifyParamsCollect : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Step (List ArgStash)
unifyParamsCollect funcVar args s0 =
    case args of
        [] ->
            ( [], s0 )

        arg :: rest ->
            case Engine.liftIO (UF.get funcVar) s0 of
                ( desc, s1 ) ->
                    case Store.arrowParts desc.content of
                        Just ( pParam, pRest ) ->
                            case localMultiArgName arg (noteAppliedS desc.content s1) of
                                ( maybeLM, s2 ) ->
                                    case maybeLM of
                                        Just _ ->
                                            -- No `injectArgLambdaMember` here: `translateArgsWith` writes the instance's member.
                                            case instantiate (TOpt.typeOf arg) s2 of
                                                ( freshVar0, s3 ) ->
                                                    case unifyStepBestEffort pParam freshVar0 s3 of
                                                        s4 ->
                                                            case unifyParamsCollect pRest rest s4 of
                                                                ( restStash, s5 ) ->
                                                                    ( StashLocalMulti freshVar0 :: restStash, s5 )

                                        Nothing ->
                                            case argUnifyVar arg s2 of
                                                ( argVar, s3 ) ->
                                                    case unifyStepBestEffort pParam argVar s3 of
                                                        s4 ->
                                                            case unifyParamsCollect pRest rest s4 of
                                                                ( restStash, s5 ) ->
                                                                    ( StashNone :: restStash, s5 )

                        Nothing ->
                            ( List.map (\_ -> StashNone) args, censusStashMiss args s1 )


{-| Counts, under `lss.report`, the arguments left ununified because the
callee's type ran out of arrows: how many there were, and each one that is a
call with an arrow in its type, by the class of its callee.
-}
censusStashMiss : List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
censusStashMiss args s0 =
    if not s0.env.lss.report then
        s0

    else
        let
            qualifying =
                List.filter (\a -> isDirectCallShape a && canTypeHasArrow (TOpt.typeOf a)) args
        in
        if List.isEmpty qualifying then
            s0

        else
            List.foldl
                (\a acc ->
                    acc
                        |> Engine.bumpArgFlowCensus "stashmiss|all"
                        |> Engine.bumpArgFlowCensus
                            ("stashmiss|callee="
                                ++ (case a of
                                        TOpt.Call _ f _ _ ->
                                            argCalleeKey f

                                        _ ->
                                            "?"
                                   )
                            )
                )
                (Engine.bumpArgFlowCensus ("stashmiss|remaining=" ++ String.fromInt (List.length args)) s0)
                qualifying


{-| Tells whether an expression is a call.
-}
isDirectCallShape : TOpt.Expr TypeIds.MVarId -> Bool
isDirectCallShape arg =
    case arg of
        TOpt.Call _ _ _ _ ->
            True

        _ ->
            False


{-| Translates a call's arguments, given what `unifyParamsCollect` stashed
for each.

An argument that refers to a let-bound function becomes a reference to the
function's instance at the read-back fresh instantiation. Under LSS that
instance's member is then written into the instantiation
(`injectLocalMultiUseMember`); it is written after the instance is recorded so
that the instance is keyed by the demanded type alone. Every other argument is
translated normally. The stash has one entry per argument.

-}
translateArgsWith : List ArgStash -> List (TOpt.Expr TypeIds.MVarId) -> Step (List Mono.MonoExpr)
translateArgsWith stash args s0 =
    Engine.traverse
        (\( entry, arg ) ->
            case ( entry, accessedLocalName arg ) of
                ( StashLocalMulti v, Just localName ) ->
                    \sa ->
                        case Store.zonkToMono v sa of
                            ( instType0, s1 ) ->
                                case Engine.recordLocalInstance localName instType0 s1 of
                                    ( ( freshName, instType, ord ), s2 ) ->
                                        -- The callee is read back after all arguments, so its demand carries this member.
                                        case injectLocalMultiUseMember localName ord v s2 of
                                            s3 ->
                                                ( Mono.MonoVarLocal freshName instType, s3 )

                _ ->
                    translate arg
        )
        (List.map2 Tuple.pair stash args)
        s0


{-| Returns the source lambda id and parameter count of a let-bound
function's right-hand side when it is a lambda literal with an id.
-}
rhsLamOf : TOpt.Expr TypeIds.MVarId -> Maybe ( TypeIds.SrcLambdaId, Int )
rhsLamOf defBody =
    case defBody of
        TOpt.Function (Just lam) params _ _ ->
            Just ( lam, List.length params )

        TOpt.TrackedFunction (Just lam) params _ _ ->
            Just ( lam, List.length params )

        _ ->
            Nothing


{-| Returns the global and the number of arguments supplied when a let-bound
right-hand side is a call of a global with at least one argument and fewer
than the global's declared arity: a partial application.
-}
rhsPapOf : TOpt.Expr TypeIds.MVarId -> Engine.S -> Maybe ( TOpt.Global, Int )
rhsPapOf defBody s =
    case defBody of
        TOpt.Call _ (TOpt.VarGlobal _ g _) args _ ->
            if not (List.isEmpty args) && List.length args < LssInfer.declaredArityOf g 8 s then
                Just ( g, List.length args )

            else
                Nothing

        _ ->
            Nothing


{-| Writes, with LSS on, the member of instance `ord` of the let-bound
function `localName` into the first `arity` arrows of `v`'s result spine,
where `arity` is the right-hand side lambda's parameter count.

The member is minted under the instance's own tag, the same tag its
right-hand side is translated under, so the id written here is the one that
translation mints for the lambda. A right-hand side that is not a lambda goes
to `injectLocalMultiUsePap`.

-}
injectLocalMultiUseMember : Name -> Int -> Vars.Variable -> Engine.S -> Engine.S
injectLocalMultiUseMember localName ord v s0 =
    if not s0.env.lss.enabled then
        s0

    else
        case List.head (List.filter (\e -> e.defName == localName) s0.localMulti) |> Maybe.andThen .rhsLam of
            Nothing ->
                injectLocalMultiUsePap localName v s0

            Just ( lam, arity ) ->
                case Engine.localInstanceTagFor ord s0 of
                    ( instTag, s1 ) ->
                        let
                            aux1 =
                                s1.itemAux

                            outerTag =
                                aux1.currentLocalInstance
                        in
                        case LssInfer.injectLambdaMemberQualified arity (Just lam) v { s1 | itemAux = { aux1 | currentLocalInstance = instTag } } of
                            s2 ->
                                let
                                    aux2 =
                                        s2.itemAux
                                in
                                Engine.bumpArgFlowCensus "lmInject|use" { s2 | itemAux = { aux2 | currentLocalInstance = outerTag } }


{-| Writes, when the let-bound function `localName`'s right-hand side is a
partial application of a global (`rhsPapOf`), that partial application's
member into the head set of `v` only; otherwise only counts the use. The
member does not depend on the instance.
-}
injectLocalMultiUsePap : Name -> Vars.Variable -> Engine.S -> Engine.S
injectLocalMultiUsePap localName v s0 =
    case List.head (List.filter (\e -> e.defName == localName) s0.localMulti) |> Maybe.andThen .rhsPap of
        Nothing ->
            Engine.bumpArgFlowCensus "lmInject|noLam" s0

        Just ( g, k ) ->
            case Engine.papMemberIdFor g k s0 of
                ( mid, s1 ) ->
                    Engine.bumpArgFlowCensus "lmInject|pap"
                        (LssInfer.injectSpineMemberId 1 mid v s1)


{-| Tells whether an expression is a lambda literal.
-}
isLambdaLiteral : TOpt.Expr TypeIds.MVarId -> Bool
isLambdaLiteral arg =
    case arg of
        TOpt.Function _ _ _ _ ->
            True

        TOpt.TrackedFunction _ _ _ _ ->
            True

        _ ->
            False


{-| Counts, under `lss.report`, a lambda by whether it has two or more
parameters and whether its body is itself a lambda.
-}
m2ShapeCensus : List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
m2ShapeCensus params body s =
    if not s.env.lss.report then
        s

    else
        let
            nested =
                isLambdaLiteral body

            key =
                if List.length params >= 2 then
                    if nested then
                        "m2|stagedNested"

                    else
                        "m2|stagedLam"

                else if nested then
                    "m2|nestedLam"

                else
                    "m2|plainLam"
        in
        Engine.bumpArgFlowCensus key s


{-| Returns the name of the local an argument refers to when that local is a
let-bound function.
-}
localMultiArgName : TOpt.Expr TypeIds.MVarId -> Step (Maybe Name)
localMultiArgName arg s0 =
    case accessedLocalName arg of
        Just localName ->
            case Engine.isLocalMultiTarget localName s0 of
                ( isLM, s1 ) ->
                    ( if isLM then
                        Just localName

                      else
                        Nothing
                    , s1
                    )

        Nothing ->
            ( Nothing, s0 )


{-| Returns the store variable a call argument is unified with: its type
loaded through the item memo, unified with what the variable environment binds
to locals in it (`enrichFromEnv`), and with the argument's own member written
into its lambda sets (`injectArgLambdaMember`).

The binding matters because the type at a local's use can be more general than
the type bound to it, for example a narrower extensible record.

-}
argUnifyVar : TOpt.Expr TypeIds.MVarId -> Step Vars.Variable
argUnifyVar arg s0 =
    case Store.loadTypeS (TOpt.typeOf arg) s0 of
        ( canVar, s1 ) ->
            case enrichFromEnv arg canVar s1 of
                s2 ->
                    case injectArgLambdaMember arg canVar s2 of
                        s3 ->
                            ( canVar, s3 )


{-| Counts, under `lss.report`, an argument whose type has arrows, by its
form and by whether its type has more arrows than the depth its form's member
injection is taken to cover (`argdeep|<form>|deep` or `|flat`).
-}
argDeepCensus : TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
argDeepCensus arg s =
    if not s.env.lss.report then
        s

    else
        let
            depth =
                LssInfer.canTypeArrowDepth (TOpt.typeOf arg)

            ( form, covered ) =
                case arg of
                    TOpt.Function _ params _ _ ->
                        ( "fn", List.length params )

                    TOpt.TrackedFunction _ params _ _ ->
                        ( "fn", List.length params )

                    TOpt.VarGlobal _ g _ ->
                        ( "ref", LssInfer.declaredArityOf g 8 s )

                    TOpt.VarBox _ g _ ->
                        ( "ref", LssInfer.declaredArityOf g 8 s )

                    TOpt.VarCycle _ home name _ ->
                        ( "ref", LssInfer.declaredArityOf (TOpt.Global home name) 8 s )

                    TOpt.VarKernel _ _ _ _ _ ->
                        ( "kernel", 1 )

                    TOpt.Accessor _ _ _ ->
                        ( "accessor", 1 )

                    TOpt.VarLocal _ _ ->
                        ( "local", 0 )

                    TOpt.TrackedVarLocal _ _ _ ->
                        ( "local", 0 )

                    TOpt.Call _ _ _ _ ->
                        ( "call", 0 )

                    _ ->
                        ( "other", 0 )
        in
        if depth == 0 then
            s

        else if depth > covered then
            Engine.bumpArgFlowCensus ("argdeep|" ++ form ++ "|deep") s

        else
            Engine.bumpArgFlowCensus ("argdeep|" ++ form ++ "|flat") s


{-| Writes, with LSS on, the member of the let-bound function instance being
translated into `canVar`'s sets, when `name` is that function referring to
itself from inside its own right-hand side, as `helper` passing `helper` on.
Nothing else in scope gives that reference a member. Any other local is left
alone.
-}
injectRetranslatingSelf : Name -> Vars.Variable -> Engine.S -> Engine.S
injectRetranslatingSelf name canVar s0 =
    if not s0.env.lss.enabled then
        s0

    else
        case s0.itemAux.retranslating of
            Just ( selfName, lam, arity ) ->
                if selfName == name then
                    Engine.bumpArgFlowCensus "lmInject|self"
                        (LssInfer.injectLambdaMemberQualified arity (Just lam) canVar s0)

                else
                    s0

            Nothing ->
                s0


{-| Writes into `canVar`'s lambda sets the member of the function value an
argument or reference is, as `injectArgLambdaMemberGo` describes, after
counting it in the `argDeepCensus`.
-}
injectArgLambdaMember : TOpt.Expr TypeIds.MVarId -> Vars.Variable -> Engine.S -> Engine.S
injectArgLambdaMember arg canVar s0 =
    injectArgLambdaMemberGo arg canVar (argDeepCensus arg s0)


{-| Writes into `canVar`'s lambda sets the member of the function value
`arg` is, by its form.

This is needed because each load makes new arrow structure: the sets the
lambda's own translation writes into are not the ones `canVar` has, and
`canVar` is what the callee's parameter is unified with.

A lambda literal gets its member on the first arrows of the result spine, one
per parameter. A global, cycle member, enum or box gets its `g|` or `c|`
member on the head arrow and partial-application members (`p|`) on the deeper
arrows of its spine; a global that is an alias of a kernel gets the kernel's
`k|` member at the head instead, with the `p|` members keyed by the alias. A
kernel reference gets its `k|` member at the head only, and an accessor its
`a|` member at the head only. A local is handled by
`injectRetranslatingSelf`. Anything else gets nothing here.

-}
injectArgLambdaMemberGo : TOpt.Expr TypeIds.MVarId -> Vars.Variable -> Engine.S -> Engine.S
injectArgLambdaMemberGo arg canVar s =
    case arg of
        TOpt.Function srcLam params _ _ ->
            LssInfer.injectLambdaMemberQualified (List.length params) srcLam canVar s

        TOpt.TrackedFunction srcLam params _ _ ->
            LssInfer.injectLambdaMemberQualified (List.length params) srcLam canVar s

        TOpt.VarGlobal _ g _ ->
            -- A kernel alias gets the kernel's member: a `g|` and a `k|` member for one value would make a set of two.
            case
                case LssInfer.kernelAliasOf g s of
                    Just ( kernelPrefix, home, name ) ->
                        standaloneArgKernelMember ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name ) canVar s

                    Nothing ->
                        standaloneArgMember ("g|" ++ TOpt.toComparableGlobal g) g canVar s
            of
                s1 ->
                    LssInfer.injectPapSuccessors g canVar s1

        TOpt.VarEnum _ g _ _ ->
            LssInfer.injectPapSuccessors g
                canVar
                (standaloneArgMember ("c|" ++ TOpt.toComparableGlobal g) g canVar s)

        TOpt.VarBox _ g _ ->
            LssInfer.injectPapSuccessors g
                canVar
                (standaloneArgMember ("c|" ++ TOpt.toComparableGlobal g) g canVar s)

        TOpt.VarCycle _ home name _ ->
            LssInfer.injectPapSuccessors (TOpt.Global home name)
                canVar
                (standaloneArgMember ("g|" ++ TOpt.toComparableGlobal (TOpt.Global home name)) (TOpt.Global home name) canVar s)

        TOpt.Accessor _ field _ ->
            case Engine.memberIdFor ("a|" ++ field) (Engine.bumpArgFlowCensus "argArm|accessor" s) of
                ( mid, s1 ) ->
                    LssInfer.injectSpineMemberId 1 mid canVar s1

        TOpt.VarLocal name _ ->
            injectRetranslatingSelf name canVar s

        TOpt.TrackedVarLocal _ name _ ->
            injectRetranslatingSelf name canVar s

        TOpt.VarKernel _ kernelPrefix home name _ ->
            standaloneArgKernelMember ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name ) canVar (Engine.bumpArgFlowCensus "argArm|kernel" s)

        _ ->
            s


{-| Writes the standalone member under `key` for global `g` into `canVar`'s
head set only. Signature inference in `LssInfer` writes the same member at the
same depth; at different depths the two would name different sets for one
value.
-}
standaloneArgMember : String -> TOpt.Global -> Vars.Variable -> Engine.S -> Engine.S
standaloneArgMember key g canVar s =
    case Engine.standaloneMemberIdFor key g s of
        ( mid, s1 ) ->
            LssInfer.injectSpineMemberId 1 mid canVar s1


{-| Writes the kernel member under `key` for kernel `k` into `canVar`'s head
set only. A kernel member is never put on inner arrows, as in `LssInfer`.
-}
standaloneArgKernelMember : String -> ( Name, Name, Name ) -> Vars.Variable -> Engine.S -> Engine.S
standaloneArgKernelMember key k canVar s =
    case Engine.kernelMemberIdFor key k s of
        ( mid, s1 ) ->
            LssInfer.injectSpineMemberId 1 mid canVar s1


{-| Unifies a call's result with the call's type (`unifyResultWithExpected`)
and then writes the partial-application member, if any (`injectPapMember`).
The order matters: the member must go into the result variables the call's
type has been unified with.
-}
unifyResultThenInjectPap : Vars.Variable -> Int -> Can.Type TypeIds.MVarId -> TOpt.Global -> Engine.S -> Engine.S
unifyResultThenInjectPap funcVar argCount callCanType global s0 =
    case unifyResultWithExpected funcVar argCount callCanType s0 of
        s1 ->
            injectPapMember global funcVar argCount s1


{-| Writes, with LSS on, the member of a partial application into the result
of a call that supplies `argCount` arguments to `global`, fewer than its
declared arity.

A partial application is not the global itself: it is the global with
`argCount` arguments already bound. It therefore gets a member of its own,
`p|<global>|<argCount>`, registered as a partial application, and never the
global's `g|` or `k|` member. Were it to get the global's member, a call
through a set holding only that member would be rewritten into a direct call
of the global with the bound arguments missing. No direct-call rewrite acts on
a `p|` member, but it still counts as a member, so a branch join that meets a
partial application has a set of two rather than a wrong set of one.

The member goes on the head arrow of the call's result. Each arrow deeper is a
partial application with one more argument bound, so it gets
`p|<global>|<argCount + i>` (`LssInfer.injectPapSuccessorsFrom`). Nothing is
written, and the case is counted, when the result variable is not an arrow
spine at that depth. A saturated or over-applied call is left alone.

-}
injectPapMember : TOpt.Global -> Vars.Variable -> Int -> Engine.S -> Engine.S
injectPapMember global funcVar argCount s0 =
    if not s0.env.lss.enabled then
        s0

    else
        let
            declared =
                LssInfer.declaredArityOf global 8 s0
        in
        if declared <= argCount then
            s0

        else
            case resultVarAfter funcVar argCount s0 of
                ( Nothing, s1 ) ->
                    Engine.bumpArgFlowCensus "papInject|opaque" s1

                ( Just residualVar, s1 ) ->
                    let
                        residualDepth =
                            declared - argCount

                        s2 =
                            Engine.bumpArgFlowCensus "papInject|pap" s1

                        s3 =
                            if residualDepth > 1 && s2.env.lss.report then
                                Engine.bumpArgFlowCensus
                                    ("papInject|deep|d" ++ String.fromInt residualDepth)
                                    s2

                            else
                                s2
                    in
                    case Engine.papMemberIdFor global argCount s3 of
                        ( mid, s3a ) ->
                            LssInfer.injectPapSuccessorsFrom global
                                (argCount + 1)
                                residualVar
                                (LssInfer.injectSpineMemberId 1 mid residualVar s3a)


{-| Returns the member id for arrow depth `d` of global `g`'s own type, the
same id a reference to `g` gets elsewhere.

At depth 0 it is the kernel's `k|` member for an alias of a kernel, the `c|`
member for a constructor, enum or box, and otherwise the global's member:
the ground id from `groundKey` when one is given, else `g|`. At depth `d`
greater than 0 it is the partial-application member `p|<g>|<d>`. A kernel,
effect manager or port node, or a global with no node, has no member at depth
0 (`Nothing`).

-}
memberIdForDepth : TOpt.Global -> Int -> Maybe (() -> String) -> Step (Maybe Int)
memberIdForDepth g d groundKey s0 =
    if d > 0 then
        case Engine.papMemberIdFor g d s0 of
            ( mid, s1 ) ->
                ( Just mid, s1 )

    else
        case LssInfer.kernelAliasOf g s0 of
            Just ( kernelPrefix, home, name ) ->
                case Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name ) s0 of
                    ( mid, s1 ) ->
                        ( Just mid, s1 )

            Nothing ->
                case HashMap.get TOpt.globalHash (==) g s0.env.toptNodes of
                    Just (TOpt.Ctor _ _ _) ->
                        case Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g s0 of
                            ( mid, s1 ) ->
                                ( Just mid, s1 )

                    Just (TOpt.Enum _ _) ->
                        case Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g s0 of
                            ( mid, s1 ) ->
                                ( Just mid, s1 )

                    Just (TOpt.Box _) ->
                        case Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g s0 of
                            ( mid, s1 ) ->
                                ( Just mid, s1 )

                    Just (TOpt.Kernel _ _) ->
                        ( Nothing, s0 )

                    Just (TOpt.Manager _) ->
                        ( Nothing, s0 )

                    Just (TOpt.PortIncoming _ _ _) ->
                        ( Nothing, s0 )

                    Just (TOpt.PortOutgoing _ _ _) ->
                        ( Nothing, s0 )

                    Just _ ->
                        case groundKey of
                            Just groundKeyOf ->
                                -- The same key the definition's root lambda is minted under, so both give one id.
                                let
                                    ( mid, table1, next1 ) =
                                        Engine.groundStandaloneMemberIdFor g (groundKeyOf ()) s0.lssMemberTable s0.nextMemberId
                                in
                                ( Just mid, { s0 | lssMemberTable = table1, nextMemberId = next1 } )

                            Nothing ->
                                case Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal g) g s0 of
                                    ( mid, s1 ) ->
                                        ( Just mid, s1 )

                    Nothing ->
                        ( Nothing, s0 )


{-| Returns a demanded type for global `g` with, under LSS, `g`'s own members
written on the leading arrows of its result spine. With LSS off the type is
returned unchanged.

A value of `g`'s type demanded for `g` is `g` itself, so its head arrow can
only hold `g`, and each arrow below it, up to `g`'s declared arity, can only
hold `g` partially applied. The head arrow gets the kernel's `k|` member when
`g` is an alias of a kernel, the `c|` member when `g` is a constructor, enum or
box, and otherwise `g`'s own member, minted under the key of the demand with
its sets widened. The arrow at depth `d` below it gets the partial-application
member `p|<g>|<d>`. Arrows past the declared arity belong to whatever the body
returns and are not touched.

The declared arity is `LssInfer.declaredArityOf`, which is at least 1, so even
a global with no parameters gets its head arrow stamped. An arrow whose set is
already an `LSet` keeps it; any other annotation, including an `LPartial`, is
replaced by the one-member set. A kernel, effect manager or port has no
member, and its type is returned unstamped.

-}
stampSelfSpine : TOpt.Global -> Mono.MonoType -> Step Mono.MonoType
stampSelfSpine g monoType s0 =
    if not s0.env.lss.enabled then
        ( monoType, s0 )

    else
        let
            -- Deferred: rendering the key is costly and only the head arrow of a plain global reads it.
            groundKey =
                Just (\() -> Mono.toComparableMonoType (Mono.widenSets monoType))
        in
        stampSpineGo g groundKey (LssInfer.declaredArityOf g 8 s0) 0 monoType s0


{-| Stamps the arrows of `monoType`'s result spine from depth `d` up to
`arity`, for `stampSelfSpine`. Where a depth has no member, that arrow and the
ones below it are left as they are; only depth 0 can lack one.
-}
stampSpineGo : TOpt.Global -> Maybe (() -> String) -> Int -> Int -> Mono.MonoType -> Step Mono.MonoType
stampSpineGo g groundKey arity d monoType s0 =
    if d >= arity then
        ( monoType, s0 )

    else
        case monoType of
            Mono.MFunction _ anno args ret ->
                case
                    memberIdForDepth g
                        d
                        (if d == 0 then
                            groundKey

                         else
                            Nothing
                        )
                        s0
                of
                    ( Nothing, s1 ) ->
                        ( monoType, Engine.bumpArgFlowCensus "regid|noId" s1 )

                    ( Just mid, s1 ) ->
                        let
                            ( anno2, s2 ) =
                                case anno of
                                    Mono.LSet _ ->
                                        ( anno, Engine.bumpArgFlowCensus "regid|alreadySet" s1 )

                                    _ ->
                                        ( Mono.LSet [ mid ], Engine.bumpArgFlowCensus "regid|stamped" s1 )
                        in
                        case stampSpineGo g groundKey arity (d + 1) ret s2 of
                            ( ret2, s3 ) ->
                                ( Mono.mFunction anno2 args ret2, s3 )

            _ ->
                ( monoType, s0 )


{-| Enqueues a spec of `global` at `monoType` after stamping the global's own
members on it (`stampSelfSpine`), so the spec is keyed and stored at the
stamped type.
-}
enqueueSpecStamped : TOpt.Global -> Mono.MonoType -> Engine.S -> ( Mono.SpecId, Engine.S )
enqueueSpecStamped global monoType s0 =
    case stampSelfSpine global monoType s0 of
        ( stamped, s1 ) ->
            case Engine.enqueueSpec (toptToMonoGlobal global) stamped s1 of
                ( specId, s2 ) ->
                    ( specId, s2 )


{-| Counts, under `lss.report`, a type taken from the variable environment by
`enrichFromEnv`, by whether it has any lambda-set members (`enrich|withSets`)
or none (`enrich|bare`).
-}
enrichCensusRow : Mono.MonoType -> Engine.S -> Engine.S
enrichCensusRow boundType s =
    if not s.env.lss.report then
        s

    else if List.isEmpty (Mono.collectAnnoMembers boundType) then
        Engine.bumpArgFlowCensus "enrich|bare" s

    else
        Engine.bumpArgFlowCensus "enrich|withSets" s


{-| Unifies, best effort, `canVar` (the loaded type of `arg`) with types the
variable environment gives the locals `arg` is made of.

A reference to a local is unified with the type bound to it. A tuple literal
is followed into its elements. With LSS on, a field access on a local record is
unified with that field's type in the record's bound type. A let-bound
function is never used, because its binding holds only its declared type,
which could block the more specific type the call gives it. Where the use's
type is ground and has no arrow, nothing is unified, since it could receive
nothing.

-}
enrichFromEnv : TOpt.Expr TypeIds.MVarId -> Vars.Variable -> Engine.S -> Engine.S
enrichFromEnv arg canVar s0 =
    case accessedLocalName arg of
        Just localName ->
            case Engine.isLocalMultiTarget localName s0 of
                ( isLM, s1 ) ->
                    if isLM then
                        Engine.bumpArgFlowCensus "enrich|localMulti" s1

                    else
                        case Engine.lookupVar localName s1 of
                            ( maybeBound, s2 ) ->
                                case maybeBound of
                                    Just boundType ->
                                        if Store.groundNoArrowWith s2.monoMemo.aliasMemo (TOpt.typeOf arg) then
                                            enrichCensusRow boundType s2

                                        else
                                            case Store.monoTypeToVarS boundType s2 of
                                                ( boundVar, s3 ) ->
                                                    unifyStepBestEffort canVar boundVar (enrichCensusRow boundType s3)

                                    Nothing ->
                                        Engine.bumpArgFlowCensus "enrich|unbound" s2

        Nothing ->
            case arg of
                TOpt.Tuple _ a b rest _ ->
                    if Store.groundNoArrowWith s0.monoMemo.aliasMemo (TOpt.typeOf arg) then
                        s0

                    else
                        case Engine.liftIO (UF.get canVar) s0 of
                            ( desc, s1 ) ->
                                case desc.content of
                                    Vars.Structure (Vars.Tuple1 pa pb pRest) ->
                                        case enrichFromEnv a pa s1 of
                                            s2 ->
                                                case enrichFromEnv b pb s2 of
                                                    s3 ->
                                                        List.foldl
                                                            (\( e, pt ) sAcc -> enrichFromEnv e pt sAcc)
                                                            s3
                                                            (List.map2 Tuple.pair rest pRest)

                                    _ ->
                                        s1

                TOpt.Access record _ fieldName _ ->
                    case accessedLocalName record of
                        Just rname ->
                            if not s0.env.lss.enabled then
                                s0

                            else
                                case Engine.isLocalMultiTarget rname s0 of
                                    ( isLM, s1 ) ->
                                        if isLM then
                                            Engine.bumpArgFlowCensus "enrich|access|localMulti" s1

                                        else
                                            case Engine.lookupVar rname s1 of
                                                ( Just (Mono.MRecord _ fields), s2 ) ->
                                                    case Dict.get fieldName fields of
                                                        Just fieldType ->
                                                            if Store.groundNoArrowWith s2.monoMemo.aliasMemo (TOpt.typeOf arg) then
                                                                Engine.bumpArgFlowCensus "enrich|access|ofLocal" s2

                                                            else
                                                                case Store.monoTypeToVarS fieldType s2 of
                                                                    ( fieldVar, s3 ) ->
                                                                        unifyStepBestEffort canVar fieldVar (Engine.bumpArgFlowCensus "enrich|access|ofLocal" s3)

                                                        Nothing ->
                                                            Engine.bumpArgFlowCensus "enrich|access|noField" s2

                                                ( _, s2 ) ->
                                                    Engine.bumpArgFlowCensus "enrich|access|noRecord" s2

                        Nothing ->
                            s0

                _ ->
                    s0


{-| Returns the type of a kernel referred to without being called, as in
`eq = Utils.equal`. The type is loaded through the item memo, not
instantiated afresh, so it sees what the enclosing definition's demand made of
its variables; it is then read back as `deriveKernelAbiTypeWith` describes.
-}
deriveKernelAbiTypeRef : ( String, String, String ) -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
deriveKernelAbiTypeRef kernelId canFuncType =
    deriveKernelAbiTypeWith kernelId canFuncType (Store.loadTypeS canFuncType)


{-| Returns a kernel's type as code generation needs it, from the store
variable `funcVarStep` produces.

The kernel's lambda sets are poisoned or kept by its facts
(`poisonKernelArrowsThen`), and the variable is read back. What happens next
depends on the kernel's ABI mode (`KernelAbi.deriveKernelAbiMode`). In
substitution mode the read-back type is the answer. In preserved-variables
mode, a kernel that selects its implementation by the types it is called at
keeps the read-back type when it has no type variable, and otherwise keeps it
with its `CEcoValue` variables renamed to new ids. Any other kernel takes its
type from its canonical type with the variables preserved, again with
`CEcoValue` variables renamed.

The renaming is needed because a variable id can be shared with other work
items, and a `number` constraint recorded against it elsewhere would make
pruning close the variable to `Int`, giving an unboxed parameter to a kernel
that expects a boxed value. A new id keeps the position boxed. `number`
variables are not renamed.

-}
deriveKernelAbiTypeWith : ( String, String, String ) -> Can.Type TypeIds.MVarId -> Step Vars.Variable -> Step Mono.MonoType
deriveKernelAbiTypeWith kernelId canFuncType funcVarStep s0 =
    let
        abiKey =
            case kernelId of
                ( _, home, name ) ->
                    ( home, name )
    in
    case funcVarStep s0 of
        ( funcVar0, sA ) ->
            case poisonKernelArrowsThen kernelId canFuncType funcVar0 sA of
                ( funcVar, sB ) ->
                    case Store.zonkToMono funcVar sB of
                        ( monoAfterSubst, sC ) ->
                            case currentMVarEnv sC of
                                ( mvarEnv, sD ) ->
                                    case KernelAbi.deriveKernelAbiMode abiKey canFuncType of
                                        KernelAbi.UseSubstitution ->
                                            ( monoAfterSubst, sD )

                                        KernelAbi.PreserveVars ->
                                            if
                                                EverySet.member KernelAbi.comparePair abiKey KernelAbi.suffixSelectingKernels
                                                    && not (Mono.containsAnyMVar monoAfterSubst)
                                            then
                                                ( monoAfterSubst, sD )

                                            else if EverySet.member KernelAbi.comparePair abiKey KernelAbi.suffixSelectingKernels then
                                                -- The read-back type keeps the shape the suffix is selected by.
                                                let
                                                    ( abi2, nextId2 ) =
                                                        KernelAbi.remapEcoVarsFresh sD.nextMVarId monoAfterSubst
                                                in
                                                ( abi2, { sD | nextMVarId = nextId2 } )

                                            else
                                                let
                                                    ( abiType, env1 ) =
                                                        KernelAbi.canTypeToMonoType_preserveVars mvarEnv canFuncType

                                                    ( finalAbi, nextId2 ) =
                                                        KernelAbi.remapEcoVarsFresh env1.nextId abiType
                                                in
                                                ( finalAbi, { sD | nextMVarId = nextId2 } )


{-| Applies, with LSS on, a kernel's lambda-set policy from `KernelSetFacts`
to the kernel's loaded type `funcVar`, and returns `funcVar`.

A kernel with no fact has every set in its type poisoned (made ⊤). A
`TypeFaithful` license that applies to `canFuncType` leaves every set as it is;
one that does not apply poisons everything. A `Positional` row poisons the
parameters marked `PSFOpaque` and the result when it is so marked, and leaves
the `PSFApplies` parameters alone; when the type has fewer arrows than the row
has parameters, everything is poisoned.

At a call this runs after the parameters were unified with the arguments, so a
poison reaches the argument's own sets, and a set left alone carries what the
caller put there into the read-back type. Under `lss.report`, a license that
does not apply is also counted (`recordRefusedLicense`).

-}
poisonKernelArrowsThen : ( String, String, String ) -> Can.Type TypeIds.MVarId -> Vars.Variable -> Step Vars.Variable
poisonKernelArrowsThen ( kPrefix, kHome, kName ) canFuncType funcVar s0 =
    let
        s =
            if s0.env.lss.report then
                recordRefusedLicense ( kPrefix, kHome, kName ) canFuncType s0

            else
                s0
    in
    if s.env.lss.enabled then
        case KernelSetFacts.factFor kPrefix kHome kName of
            Nothing ->
                case Store.poisonArrowSets funcVar s of
                    s1 ->
                        ( funcVar, Engine.bumpWidenedByKernel s1 )

            Just (KernelSetFacts.TypeFaithful license) ->
                if not (KernelSetFacts.licenseApplies (Engine.isScalarVar s) license canFuncType) then
                    -- Left alone, the caller's members would stand in a set the kernel may not honour.
                    case Store.poisonArrowSets funcVar s of
                        s1 ->
                            ( funcVar, Engine.bumpWidenedByKernel s1 )

                else
                    ( funcVar, Engine.bumpKernelLicensed s )

            Just (KernelSetFacts.Positional plan) ->
                case poisonKernelPerParam plan.params [] funcVar False s of
                    ( maybeOutcome, s1 ) ->
                        case maybeOutcome of
                            Nothing ->
                                case Store.poisonArrowSets funcVar s1 of
                                    s2 ->
                                        ( funcVar, Engine.bumpWidenedByKernel s2 )

                            Just ( resVar, tunnelVars, argPoisoned ) ->
                                let
                                    resultStep =
                                        case plan.result of
                                            KernelSetFacts.PSFOpaque ->
                                                case Store.poisonArrowSets resVar s1 of
                                                    s2 ->
                                                        ( True, s2 )

                                            _ ->
                                                ( False, s1 )
                                in
                                case resultStep of
                                    ( resPoisoned, s2 ) ->
                                        case joinKernelTunnels resVar tunnelVars s2 of
                                            s3 ->
                                                ( funcVar
                                                , Engine.bumpKernelFactHit
                                                    (if argPoisoned || resPoisoned then
                                                        Engine.bumpWidenedByKernel s3

                                                     else
                                                        s3
                                                    )
                                                )

    else
        ( funcVar, s )


{-| Walks a kernel type's arrows one per entry of `flows`, poisoning the sets
of each `PSFOpaque` parameter. Returns the remaining result variable, the
collected tunnel variables (always none, since no flow adds one), and whether
anything was poisoned; or `Nothing` when the type runs out of arrows first.
-}
poisonKernelPerParam : List KernelSetFacts.ParamSetFlow -> List Vars.Variable -> Vars.Variable -> Bool -> Step (Maybe ( Vars.Variable, List Vars.Variable, Bool ))
poisonKernelPerParam flows tunnelsRev v poisoned s0 =
    case flows of
        [] ->
            ( Just ( v, List.reverse tunnelsRev, poisoned ), s0 )

        flow :: rest ->
            case Engine.liftIO (UF.get v) s0 of
                ( desc, s1 ) ->
                    case Store.arrowParts desc.content of
                        Nothing ->
                            ( Nothing, s1 )

                        Just ( pParam, pRest ) ->
                            case flow of
                                KernelSetFacts.PSFOpaque ->
                                    case Store.poisonArrowSets pParam s1 of
                                        s2 ->
                                            poisonKernelPerParam rest tunnelsRev pRest True s2

                                KernelSetFacts.PSFApplies ->
                                    poisonKernelPerParam rest tunnelsRev pRest poisoned s1


{-| Lets the lambda sets of each variable in `vars` flow into the matching
sets of `resVar` (`LssInfer.flowArrowSetsPlain`).
-}
joinKernelTunnels : Vars.Variable -> List Vars.Variable -> Engine.S -> Engine.S
joinKernelTunnels resVar vars s0 =
    case vars of
        [] ->
            s0

        v :: rest ->
            case LssInfer.flowArrowSetsPlain v resVar s0 of
                s1 ->
                    joinKernelTunnels resVar rest s1


{-| Loads a type as a fresh instantiation whose type variables share nothing
with the rest of the item (`Store.loadTypeIsolated`). The new variables stay
in the item's store.
-}
instantiate : Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
instantiate canType =
    Store.loadTypeIsolated canType


{-| Instantiates a global's type afresh, as `instantiate` does, and with LSS
on applies the global's signature facts to the new arrows
(`LssInfer.instantiateWithSignature`).
-}
instantiateLss : TOpt.Global -> Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
instantiateLss global funcCanType s =
    if s.env.lss.enabled then
        LssInfer.instantiateWithSignature global funcCanType s

    else
        instantiate funcCanType s


{-| Unifies two variables without ever failing the build. When the
unification fails, the store is put back as it was; the rest of the state is
kept, as in `Store.unifyBestEffortStoreS`.
-}
unifyBestEffortS : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
unifyBestEffortS v1 v2 s =
    case Store.unifyStep v1 v2 s of
        ( True, s1 ) ->
            s1

        ( False, s1 ) ->
            { s1 | store = s.store }


{-| The same as `unifyBestEffortS`.
-}
unifyStepBestEffort : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
unifyStepBestEffort v1 v2 s =
    unifyBestEffortS v1 v2 s


{-| Returns a short text rendering of a canonical type, used in crash
messages and census keys.
-}
canKind : Can.Type TypeIds.MVarId -> String
canKind canType =
    case canType of
        Can.TVar _ ->
            "var"

        Can.TLambda _ a b ->
            "(" ++ canKind a ++ "->" ++ canKind b ++ ")"

        Can.TType _ name args ->
            name
                ++ (if List.isEmpty args then
                        ""

                    else
                        "<" ++ String.join "," (List.map canKind args) ++ ">"
                   )

        Can.TRecord _ _ ->
            "record"

        Can.TUnit ->
            "unit"

        Can.TTuple _ _ _ ->
            "tuple"

        Can.TAlias _ name _ _ ->
            "alias:" ++ name


{-| Unifies, best effort, what remains of a callee's type after `argCount`
arrows with the call's type, so that a callee whose result type is
polymorphic learns it from the call. Does nothing when the callee's type runs
out of arrows.
-}
unifyResultWithExpected : Vars.Variable -> Int -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
unifyResultWithExpected funcVar argCount callCanType s0 =
    case resultVarAfter funcVar argCount s0 of
        ( Just resultVar, s1 ) ->
            case Store.loadTypeS callCanType s1 of
                ( expectedVar, s2 ) ->
                    unifyStepBestEffort resultVar expectedVar s2

        ( Nothing, s1 ) ->
            s1


{-| Returns the store variable left after `n` arrows of `funcVar`, or
`Nothing` when it has fewer arrows. Each arrow passed is counted as applied
(`noteAppliedS`).
-}
resultVarAfter : Vars.Variable -> Int -> Engine.S -> ( Maybe Vars.Variable, Engine.S )
resultVarAfter funcVar n s0 =
    if n <= 0 then
        ( Just funcVar, s0 )

    else
        case Engine.liftIO (UF.get funcVar) s0 of
            ( desc, s1 ) ->
                case Store.arrowParts desc.content of
                    Just ( _, pRest ) ->
                        resultVarAfter pRest (n - 1) (noteAppliedS desc.content s1)

                    Nothing ->
                        ( Nothing, s1 )


{-| Records in the census that an arrow was applied; the same as
`LssInfer.noteApplied`.
-}
noteAppliedS : Vars.Content -> Engine.S -> Engine.S
noteAppliedS =
    LssInfer.noteApplied


{-| Returns a type-variable environment for the `KernelAbi` helpers, starting
at the engine's next variable id and holding only the static super-class
table. `number` constraints recorded during specialization are left out, so
another item's constraint cannot make a kernel's variable a `number`.
-}
currentMVarEnv : Step State.MVarEnv
currentMVarEnv =
    \s -> ( State.initMVarEnv s.nextMVarId s.env.superStatic, s )



-- ====== RECORDS ======


{-| Returns the record type whose fields have the types of the given
translated expressions.
-}
recordTypeFromFields : List ( Name, Mono.MonoExpr ) -> Mono.MonoType
recordTypeFromFields fields =
    Mono.mRecord (List.foldl (\( name, me ) acc -> Dict.insert name (Mono.typeOf me) acc) Dict.empty fields)


{-| Returns the type of a field access, choosing between the access's
classified type and the field's type in the translated record's type.

The field's type is used when the classified type still has a type variable,
or when both are records and the classified one has a strict subset of the
field's fields (a narrower extensible-record view; the record's own type
decides the layout). When `overlay` is set and the two have the same layout,
the classified type is given the field type's lambda sets. Otherwise, or when
the record type has no such field, the classified type is kept.

-}
refineAccessType : Bool -> Mono.MonoType -> Mono.MonoType -> Name -> Mono.MonoType
refineAccessType overlay classified recordType fieldName =
    case recordType of
        Mono.MRecord _ fields ->
            case Dict.get fieldName fields of
                Just fieldType ->
                    if Mono.containsAnyMVar classified then
                        fieldType

                    else if recordKeySubset classified fieldType then
                        fieldType

                    else if overlay && Mono.eqLayout classified fieldType then
                        Mono.overlayAnnotations classified fieldType

                    else
                        classified

                Nothing ->
                    classified

        _ ->
            classified


{-| Tells whether two types differ, but only where one has `Int` or `Float`
and the other has the other or a `number` variable. That is what a classified
type looks like when a shared `number` variable was made `Float` by another
use. Types equal up to their ⊤ labels (`Mono.eqModuloTopLabel`) do not differ.
-}
numericLeafOnlyDiff : Mono.MonoType -> Mono.MonoType -> Bool
numericLeafOnlyDiff a b =
    if Mono.eqModuloTopLabel a b then
        False

    else
        sameShapeModuloNumeric a b


{-| Tells whether two types have the same structure, treating `Int`, `Float`
and a `number` variable as interchangeable (though `Int` against `Int` is
compared with `==` like any other leaf). Lambda sets are ignored.
-}
sameShapeModuloNumeric : Mono.MonoType -> Mono.MonoType -> Bool
sameShapeModuloNumeric a b =
    case ( a, b ) of
        ( Mono.MInt, Mono.MFloat ) ->
            True

        ( Mono.MFloat, Mono.MInt ) ->
            True

        ( Mono.MVar _ Mono.CNumber, Mono.MInt ) ->
            True

        ( Mono.MVar _ Mono.CNumber, Mono.MFloat ) ->
            True

        ( Mono.MInt, Mono.MVar _ Mono.CNumber ) ->
            True

        ( Mono.MFloat, Mono.MVar _ Mono.CNumber ) ->
            True

        ( Mono.MFunction _ _ args1 r1, Mono.MFunction _ _ args2 r2 ) ->
            allPairs sameShapeModuloNumeric args1 args2 && sameShapeModuloNumeric r1 r2

        ( Mono.MList _ e1, Mono.MList _ e2 ) ->
            sameShapeModuloNumeric e1 e2

        ( Mono.MTuple _ es1, Mono.MTuple _ es2 ) ->
            allPairs sameShapeModuloNumeric es1 es2

        ( Mono.MCustom _ h1 n1 args1, Mono.MCustom _ h2 n2 args2 ) ->
            h1 == h2 && n1 == n2 && allPairs sameShapeModuloNumeric args1 args2

        ( Mono.MRecord _ f1, Mono.MRecord _ f2 ) ->
            (Dict.size f1 == Dict.size f2)
                && Dict.foldl
                    (\name t1 ok ->
                        ok
                            && (case Dict.get name f2 of
                                    Just t2 ->
                                        sameShapeModuloNumeric t1 t2

                                    Nothing ->
                                        False
                               )
                    )
                    True
                    f1

        _ ->
            a == b


{-| Tells whether `f` holds for every pair of elements at the same position;
`False` when the lists differ in length. Stops at the first pair that fails.
-}
allPairs : (a -> b -> Bool) -> List a -> List b -> Bool
allPairs f xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: restX, y :: restY ) ->
            f x y && allPairs f restX restY

        _ ->
            False


{-| Tells whether both types are records and `narrow`'s fields are a strict
subset of `full`'s.
-}
recordKeySubset : Mono.MonoType -> Mono.MonoType -> Bool
recordKeySubset narrow full =
    case ( narrow, full ) of
        ( Mono.MRecord _ nf, Mono.MRecord _ ff ) ->
            Dict.size nf < Dict.size ff && List.all (\k -> Dict.member k ff) (Dict.keys nf)

        _ ->
            False


{-| Translates a record update. Its type is the classified type with the
translated record's fields added where the classified type lacks them
(`unionRecordTypes`).
-}
translateUpdate : TOpt.Expr TypeIds.MVarId -> DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateUpdate record updates canType s0 =
    case classifyAs Mono.tkClassLet canType s0 of
        ( monoType, s1 ) ->
            case translate record s1 of
                ( monoRecord, s2 ) ->
                    case
                        Engine.foldlS
                            (\( locName, updateExpr ) acc sx ->
                                case translate updateExpr sx of
                                    ( me, sx1 ) ->
                                        ( ( A.toValue locName, me ) :: acc, sx1 )
                            )
                            []
                            (DMap.toList updates)
                            s2
                    of
                        ( monoUpdatesRev, s3 ) ->
                            let
                                recordMonoType =
                                    Mono.typeOf monoRecord

                                resultMonoType =
                                    unionRecordTypes monoType recordMonoType
                            in
                            ( Mono.MonoRecordUpdate monoRecord monoUpdatesRev resultMonoType, s3 )


{-| Returns the record type with the fields of `classified`, plus those of
`recordType` it lacks; a field in both keeps `classified`'s type. When either
is not a record, returns `classified`.
-}
unionRecordTypes : Mono.MonoType -> Mono.MonoType -> Mono.MonoType
unionRecordTypes classified recordType =
    case ( classified, recordType ) of
        ( Mono.MRecord _ resultFields, Mono.MRecord _ recordFields ) ->
            Mono.mRecord (Dict.union resultFields recordFields)

        ( Mono.MRecord _ _, _ ) ->
            classified

        _ ->
            classified



-- ====== LET ======


{-| Translates a `let` with one definition.

A definition of function type, or of a type that contains a function and has
a free type variable, is translated once per type it is used at
(`translateLocalMultiLet`). A definition of an unresolved `number` type is
handled by `translateNumberMultiLet`. Any other value is translated once and
bound at its classified type, or at the right-hand side's own type where the
classified type has a type variable, is a narrower record, or differs only by
`number` pollution (`numericLeafOnlyDiff`, for types without a `CEcoValue`
variable). With LSS on, a classified type that is kept is given the right-hand
side's lambda sets.

A tail-recursive definition is translated after the `let` body, so that the
body's uses record the types it is used at. Used at one type or none, it is
translated once under its own name (`translateTailDefSingle`); used at two or
more, once per type (`translateTailDefInstances`).

-}
translateLet : TOpt.Def TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLet def body letCanType sTop =
    case def of
        TOpt.Def _ name defBody defCanType ->
            if isFunctionType defCanType || (typeContainsCanLambda defCanType && KernelAbi.hasAnyFreeVar defCanType) then
                translateLocalMultiLet name defBody body letCanType sTop

            else
                case isNumberMultiEligible defCanType sTop of
                    ( eligible, s1 ) ->
                        if eligible then
                            translateNumberMultiLet name defBody body letCanType s1

                        else
                            case translate defBody s1 of
                                ( monoDefBody, s2 ) ->
                                    case classifyAs Mono.tkClassLet defCanType s2 of
                                        ( defMonoType0, s3 ) ->
                                            let
                                                bodyType =
                                                    Mono.typeOf monoDefBody

                                                useBodyType =
                                                    Mono.containsAnyMVar defMonoType0
                                                        || recordKeySubset defMonoType0 bodyType
                                                        || (not (monoTypeMentionsEco bodyType) && numericLeafOnlyDiff defMonoType0 bodyType)

                                                letOverlay =
                                                    s3.env.lss.enabled

                                                defType =
                                                    if useBodyType then
                                                        bodyType

                                                    else if letOverlay then
                                                        Mono.overlayAnnotations defMonoType0 bodyType

                                                    else
                                                        defMonoType0

                                                -- Counts a binding whose right-hand side's lambda sets are dropped.
                                                s3b =
                                                    if not s3.env.lss.report || useBodyType || letOverlay || not (canTypeHasArrow defCanType) then
                                                        s3

                                                    else
                                                        Engine.bumpArgFlowCensus "leak|letAnno" s3
                                            in
                                            Engine.scoped
                                                (\sx -> finishLet (Mono.MonoDef name monoDefBody) body letCanType (Engine.insertVar name defType sx))
                                                s3b

        TOpt.TailDef _ name typedArgs tailBody defCanType _ ->
            case classifyAs Mono.tkClassLet defCanType (Engine.pushLocalMulti Nothing Nothing name sTop) of
                ( declType, s1 ) ->
                    case Engine.scoped (\sx -> translate body (Engine.insertVar name declType sx)) s1 of
                        ( monoBody0, s2 ) ->
                            -- Takes part in handing nested let-functions' use-site overlays up (see `flushLocalMultiEnrich`).
                            case Engine.popLocalMulti s2 of
                                ( maybeEntry, s3 ) ->
                                    case flushLocalMultiEnrich name maybeEntry [] monoBody0 s3 of
                                        ( monoBody, s4 ) ->
                                            case multiInstances maybeEntry of
                                                Just instances ->
                                                    translateTailDefInstances name typedArgs tailBody defCanType instances monoBody letCanType s4

                                                Nothing ->
                                                    translateTailDefSingle name typedArgs tailBody defCanType maybeEntry monoBody letCanType s4


{-| Returns the recorded instances of a let-bound function when there are two
or more, else `Nothing`.
-}
multiInstances : Maybe Engine.NumberMultiEntry -> Maybe (List Engine.NumberInstance)
multiInstances maybeEntry =
    case maybeEntry of
        Just entry ->
            case Mono.specMapValues entry.instances of
                ((_ :: _ :: _) as instances) ->
                    Just instances

                _ ->
                    Nothing

        Nothing ->
            Nothing


{-| Translates a local tail-recursive function used at one type or none, once,
under its own name, and builds the `let` around the already translated body.

With one recorded instance, the definition's type is unified, best effort, with
that instance's type in the item store, and the parameter and definition types
come from it (`tailDefBindingTypes`); with none, they are classified. The
`let`'s type is the body's type where the classified one has a type variable
or differs only by `number` pollution.

-}
translateTailDefSingle : Name -> List ( A.Located Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Maybe Engine.NumberMultiEntry -> Mono.MonoExpr -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateTailDefSingle name typedArgs tailBody defCanType maybeEntry monoBody letCanType s4 =
                                            let
                                                singleInstance =
                                                    case maybeEntry of
                                                        Just entry ->
                                                            case Mono.specMapValues entry.instances of
                                                                [ inst ] ->
                                                                    Just inst.monoType

                                                                _ ->
                                                                    Nothing

                                                        Nothing ->
                                                            Nothing

                                                ( maybeAnnVar, s5 ) =
                                                    case singleInstance of
                                                        Just instType ->
                                                            case Store.loadTypeS defCanType s4 of
                                                                ( annVar, sL1 ) ->
                                                                    case Store.monoTypeToVarS instType sL1 of
                                                                        ( demandVar, sL2 ) ->
                                                                            ( Just annVar, unifyStepBestEffort annVar demandVar sL2 )

                                                        Nothing ->
                                                            ( Nothing, s4 )
                                            in
                                            case tailDefBindingTypes maybeAnnVar typedArgs defCanType s5 of
                                                ( ( monoParams, defType ), s6 ) ->
                                                    case
                                                        withLoopFrame name
                                                            typedArgs
                                                            (Engine.scoped
                                                                (\sx -> translate tailBody (insertVars monoParams (Engine.insertVar name defType sx)))
                                                            )
                                                            s6
                                                    of
                                                        ( monoTailBody, s7 ) ->
                                                            case classifyAs Mono.tkClassLet letCanType s7 of
                                                                ( letType0, s8 ) ->
                                                                    let
                                                                        letType =
                                                                            if
                                                                                Mono.containsAnyMVar letType0
                                                                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                                                                            then
                                                                                Mono.typeOf monoBody

                                                                            else
                                                                                letType0
                                                                    in
                                                                    ( Mono.MonoLet (Mono.MonoTailDef name monoParams monoTailBody) monoBody letType, s8 )


{-| Translates a local tail-recursive function used at two or more types,
once per type, and nests the `let`s around the already translated body.

The body's uses already name the instances' bindings (`f`, `f$1`, ...). Each
instance's definition is translated at its type in a scratch store
(`retranslateTailAtInstance`), and its references to itself, tail calls
included, are renamed to the instance's name (`MonoTraverse.renameLocal`).

-}
translateTailDefInstances : Name -> List ( A.Located Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> List Engine.NumberInstance -> Mono.MonoExpr -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateTailDefInstances name typedArgs tailBody defCanType instances monoBody letCanType s0 =
    case
        Engine.traverse
            (\( ord, inst ) sx ->
                case retranslateTailAtInstance name ord typedArgs tailBody defCanType inst.monoType sx of
                    ( ( monoParams, monoTailBody ), sx1 ) ->
                        ( Mono.MonoTailDef inst.freshName monoParams (MonoTraverse.renameLocal name inst.freshName monoTailBody), sx1 )
            )
            (List.indexedMap Tuple.pair instances)
            s0
    of
        ( instanceDefs, s1 ) ->
            case classifyAs Mono.tkClassLet letCanType s1 of
                ( letType0, s2 ) ->
                    let
                        letType =
                            if
                                Mono.containsAnyMVar letType0
                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                            then
                                Mono.typeOf monoBody

                            else
                                letType0
                    in
                    ( List.foldl (\d acc -> Mono.MonoLet d acc (Mono.typeOf acc)) monoBody (List.reverse instanceDefs)
                        |> retypeLet letType
                    , s2
                    )


{-| Translates one instance of a local tail-recursive function, returning its
parameters and body.

The work happens in a scratch store, under the instance's own tag; the item's
store, memos and state are put back afterwards. The definition's type is
unified, best effort, with the instance's type, the parameter and definition
types are taken from it (`tailDefBindingTypes`), and the body is translated
under the function's bare name.

-}
retranslateTailAtInstance : Name -> Int -> List ( A.Located Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step ( List ( Name, Mono.MonoType ), Mono.MonoExpr )
retranslateTailAtInstance name ord typedArgs tailBody defCanType instType s0 =
    case Engine.localInstanceTagFor ord s0 of
        ( instTag, sT ) ->
            let
                clearedA =
                    Engine.clearedAux sT.itemAux

                sFresh =
                    { sT | store = Engine.freshStore, memo = Dict.empty, revMemo = Array.empty, itemAux = { clearedA | currentLocalInstance = instTag, retranslating = Nothing } }

                step sx0 =
                    case Store.loadTypeS defCanType sx0 of
                        ( annVar, sx1 ) ->
                            case Store.monoTypeToVarS instType sx1 of
                                ( demandVar, sx2 ) ->
                                    case tailDefBindingTypes (Just annVar) typedArgs defCanType (unifyStepBestEffort annVar demandVar sx2) of
                                        ( ( monoParams, defType ), sx3 ) ->
                                            case
                                                withLoopFrame name
                                                    typedArgs
                                                    (Engine.scoped
                                                        (\sy -> translate tailBody (insertVars monoParams (Engine.insertVar name defType sy)))
                                                    )
                                                    sx3
                                            of
                                                ( monoTailBody, sx4 ) ->
                                                    ( ( monoParams, monoTailBody ), sx4 )
            in
            case step sFresh of
                ( result, s1 ) ->
                    ( result, { s1 | store = sT.store, memo = sT.memo, revMemo = sT.revMemo, itemAux = Engine.restoredAux sT.itemAux s1.itemAux } )


{-| Returns a local tail-recursive function's parameter types and its own
type.

Each parameter is classified as a parameter and the function's type as a
`let`. With LSS on and a seeded annotation variable, the function's type is
given the lambda sets of that variable read back, and each parameter is given
the sets of the matching parameter peeled from it when the counts agree.

-}
tailDefBindingTypes : Maybe Vars.Variable -> List ( A.Located Name, Can.Type TypeIds.MVarId ) -> Can.Type TypeIds.MVarId -> Step ( List ( Name, Mono.MonoType ), Mono.MonoType )
tailDefBindingTypes maybeAnnVar typedArgs defCanType s0 =
    case
        Engine.traverse
            (\( locName, argType ) sx ->
                case classifyAs Mono.tkClassParam argType sx of
                    ( mt, sx1 ) ->
                        ( ( A.toValue locName, mt ), sx1 )
            )
            typedArgs
            s0
    of
        ( classifiedParams, s1 ) ->
            case classifyAs Mono.tkClassLet defCanType s1 of
                ( classifiedType, s2 ) ->
                    case ( s2.env.lss.enabled, maybeAnnVar ) of
                        ( True, Just annVar ) ->
                            case Store.zonkToMono annVar s2 of
                                ( zonkedType, s3 ) ->
                                    let
                                        funcType =
                                            Mono.overlayAnnotations classifiedType zonkedType

                                        peeled =
                                            extractFieldTypes (List.length typedArgs) funcType

                                        monoParams =
                                            if List.length peeled == List.length classifiedParams then
                                                List.map2 (\( nm, mt ) pt -> ( nm, Mono.overlayAnnotations mt pt )) classifiedParams peeled

                                            else
                                                classifiedParams
                                    in
                                    ( ( monoParams, funcType ), Engine.bumpArgFlowCensus "letOverlay|tailFn" s3 )

                        _ ->
                            ( ( classifiedParams, classifiedType ), s2 )


{-| Translates a `let` body and builds the `let` around `monoDef`. The
`let`'s type is the body's type where the classified one has a type variable
or differs only by `number` pollution.
-}
finishLet : Mono.MonoDef -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
finishLet monoDef body letCanType s0 =
    case translate body s0 of
        ( monoBody, s1 ) ->
            case classifyAs Mono.tkClassLet letCanType s1 of
                ( letType0, s2 ) ->
                    let
                        letType =
                            if
                                Mono.containsAnyMVar letType0
                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                            then
                                Mono.typeOf monoBody

                            else
                                letType0
                    in
                    ( Mono.MonoLet monoDef monoBody letType, s2 )


{-| Binds each name to its type in the variable environment.
-}
insertVars : List ( Name, Mono.MonoType ) -> Engine.S -> Engine.S
insertVars pairs s0 =
    List.foldl (\( name, t ) sAcc -> Engine.insertVar name t sAcc) s0 pairs



-- ====== LET-BOUND NUMBERS ======


{-| Translates a `let` that binds a value of unresolved `number` type, once
per type it is used at.

The right-hand side is translated first at the type it has now (the eager
instance), and recorded as the first instance, which keeps the bare name. The
`let` body is then translated, each use recording the type it needs. Each
other recorded type gets a copy named `n$v<k>`, translated again at that type
(`buildFloatDefs`). The eager definition is outermost and the copies are
nested inside it.

-}
translateNumberMultiLet : Name -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateNumberMultiLet name defBody body letCanType s0 =
    case translate defBody s0 of
        ( eagerBody, s1 ) ->
            case Engine.recordNumberInstance name (Mono.typeOf eagerBody) (Engine.pushNumberMulti name s1) of
                ( _, s2 ) ->
                    -- Bound for readers other than a variable use, such as a destructor's root.
                    case Engine.scoped (\sx -> translate body (Engine.insertVar name (Mono.typeOf eagerBody) sx)) s2 of
                        ( monoBody, s3 ) ->
                            case Engine.popNumberMulti s3 of
                                ( maybeEntry, s4 ) ->
                                    case buildFloatDefs name defBody maybeEntry s4 of
                                        ( floatDefs, s5 ) ->
                                            case classifyAs Mono.tkClassLet letCanType s5 of
                                                ( letType0, s6 ) ->
                                                    let
                                                        letType =
                                                            if
                                                                Mono.containsAnyMVar letType0
                                                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                                                            then
                                                                Mono.typeOf monoBody

                                                            else
                                                                letType0

                                                        bodyWithFloats =
                                                            List.foldl (\d acc -> Mono.MonoLet d acc (Mono.typeOf acc)) monoBody (List.reverse floatDefs)
                                                    in
                                                    ( Mono.MonoLet (Mono.MonoDef name eagerBody) bodyWithFloats letType, s6 )


{-| Returns a definition for each recorded instance of a let-bound number
other than the one that keeps the bare name, each translated again at its
instance's type (`retranslateAt`), so that `10 + 20` becomes a `Float`
addition in a `Float` copy.
-}
buildFloatDefs : Name -> TOpt.Expr TypeIds.MVarId -> Maybe Engine.NumberMultiEntry -> Step (List Mono.MonoDef)
buildFloatDefs name defBody maybeEntry s0 =
    case maybeEntry of
        Just entry ->
            Engine.traverse
                (\inst sx ->
                    case retranslateAt defBody inst.monoType sx of
                        ( e, sx1 ) ->
                            ( Mono.MonoDef inst.freshName e, sx1 )
                )
                (Mono.specMapValues entry.instances |> List.filter (\inst -> inst.freshName /= name))
                s0

        Nothing ->
            ( [], s0 )


{-| Translates an expression again at `instType`, as `retranslateWithTag`
does, keeping the enclosing instance tag. Copies of a let-bound number are not
given tags of their own: copies at different types already differ in layout.
-}
retranslateAt : TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoExpr
retranslateAt defBody instType s0 =
    retranslateWithTag s0.itemAux.currentLocalInstance s0.itemAux.retranslating defBody instType s0


{-| Translates instance `ord` of the let-bound function `name` again at
`instType`, as `retranslateWithTag` does, under the instance's own tag
(`Engine.localInstanceTagFor`), so lambdas minted inside it get member ids
apart from the same lambdas in other instances. When the right-hand side is a
lambda, a reference to `name` inside it is given this instance's member
(`injectRetranslatingSelf`).
-}
retranslateAtInstance : Name -> Int -> TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoExpr
retranslateAtInstance name ord defBody instType s0 =
    case Engine.localInstanceTagFor ord s0 of
        ( instTag, s1 ) ->
            retranslateWithTag instTag (Maybe.map (\( lam, arity ) -> ( name, lam, arity )) (rhsLamOf defBody)) defBody instType s1


{-| Translates `defBody` at `instType` in a scratch store, with the given
instance tag and self-reference record, and puts the item's store, memos and
store-scoped state back afterwards. The variable environment and the engine's
global state are kept, so the expression can refer to outer locals and
enqueue specs.

The scratch store is seeded through `demandUnifyRoot`, so a lambda right-hand
side takes its type from the demand. State that names store variables is
cleared on entry (`Engine.clearedAux`), because those indices mean nothing in
the item's store.

-}
retranslateWithTag : Int -> Maybe ( Name, TypeIds.SrcLambdaId, Int ) -> TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoExpr
retranslateWithTag instTag retranslating defBody instType s0 =
    let
        clearedA =
            Engine.clearedAux s0.itemAux

        sFresh =
            { s0 | store = Engine.freshStore, memo = Dict.empty, revMemo = Array.empty, itemAux = { clearedA | currentLocalInstance = instTag, retranslating = retranslating } }

        step =
            \sx -> translate defBody (demandUnifyRoot (TOpt.typeOf defBody) instType defBody sx)
    in
    case step sFresh of
        ( monoExpr, s1 ) ->
            ( monoExpr, { s1 | store = s0.store, memo = s0.memo, revMemo = s0.revMemo, itemAux = Engine.restoredAux s0.itemAux s1.itemAux } )


{-| Tells whether a `let` definition of type `defCanType` should be
specialized per use type as a number: its type has a free variable constrained
to `number` in the item's super table, and its classified type is a numeric
shape (`isNumericFixableShape`).
-}
isNumberMultiEligible : Can.Type TypeIds.MVarId -> Step Bool
isNumberMultiEligible defCanType s0 =
    case hasNumberVar defCanType s0 of
        ( True, s1 ) ->
            case classifyAs Mono.tkClassLet defCanType s1 of
                ( t, s2 ) ->
                    ( isNumericFixableShape t, s2 )

        ( False, s1 ) ->
            ( False, s1 )


{-| Tells whether any free type variable of a canonical type is constrained
to `number` in the item's super table.
-}
hasNumberVar : Can.Type TypeIds.MVarId -> Step Bool
hasNumberVar defCanType s =
    ( List.any (\id -> Dict.get (Id.toComparable id) s.superTable == Just Vars.Number) (KernelAbi.freeVarIds defCanType [])
    , s
    )


{-| Tells whether a type is one a let-bound number can be specialized at per
use: `Int`, `Float`, a `number` variable, a non-empty tuple or record made only
of such types, a list of one, or a custom type with at least one such argument
and no other argument that mentions a number.
-}
isNumericFixableShape : Mono.MonoType -> Bool
isNumericFixableShape monoType =
    case monoType of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MTuple _ elems ->
            not (List.isEmpty elems) && List.all isNumericFixableShape elems

        Mono.MRecord _ fields ->
            not (Dict.isEmpty fields) && List.all isNumericFixableShape (Dict.values fields)

        Mono.MList _ elem ->
            isNumericFixableShape elem

        Mono.MCustom _ _ _ args ->
            List.any isNumericFixableShape args
                && List.all (\a -> isNumericFixableShape a || not (monoTypeMentionsNumeric a)) args

        _ ->
            False


{-| Tells whether a type contains `Int`, `Float` or a `number` variable
anywhere.
-}
monoTypeMentionsNumeric : Mono.MonoType -> Bool
monoTypeMentionsNumeric mt =
    case mt of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MList _ t ->
            monoTypeMentionsNumeric t

        Mono.MTuple _ ts ->
            List.any monoTypeMentionsNumeric ts

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || monoTypeMentionsNumeric t) False fields

        Mono.MCustom _ _ _ args ->
            List.any monoTypeMentionsNumeric args

        Mono.MFunction _ _ args r ->
            List.any monoTypeMentionsNumeric args || monoTypeMentionsNumeric r

        _ ->
            False



-- ====== RECORD ACCESS ======


{-| Translates a field access.

When the record is a let-bound number value being specialized per use and the
access's classified type is `Int` or `Float`, the record's eager type with
only this field set to that type is recorded as an instance of the record, and
the access reads from that instance (`r$v<k>`). Each access thus picks its own
instance; flowing the type through the store instead would reach the other
uses, which share type variables. Otherwise the access is translated by
`genericAccess`.

-}
translateAccess : TOpt.Expr TypeIds.MVarId -> Name -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
translateAccess record fieldName meta s0 =
    case accessedLocalName record of
        Just rname ->
            case Engine.numberMultiRootType rname s0 of
                ( Just eagerRootType, s1 ) ->
                    case classifyAs Mono.tkClassMisc meta.tipe s1 of
                        ( demand, s2 ) ->
                            if demand == Mono.MFloat || demand == Mono.MInt then
                                case refineRootInstance s2.env.globalTypeEnv eagerRootType (TOpt.Field fieldName (TOpt.Root rname)) demand of
                                    Just refinedRootType ->
                                        case Engine.recordNumberInstance rname refinedRootType s2 of
                                            ( ( freshName, instType ), s3 ) ->
                                                ( Mono.MonoRecordAccess (Mono.MonoVarLocal freshName instType) fieldName demand, s3 )

                                    Nothing ->
                                        genericAccess record fieldName meta s2

                            else
                                genericAccess record fieldName meta s2

                ( Nothing, s1 ) ->
                    genericAccess record fieldName meta s1

        Nothing ->
            genericAccess record fieldName meta s0


{-| Returns the name of the local an expression refers to, when it is a
reference to a local.
-}
accessedLocalName : TOpt.Expr TypeIds.MVarId -> Maybe Name
accessedLocalName record =
    case record of
        TOpt.VarLocal rname _ ->
            Just rname

        TOpt.TrackedVarLocal _ rname _ ->
            Just rname

        _ ->
            Nothing


{-| Translates a field access by connecting its type to the field's type in
the record's canonical type, translating the record, and choosing the type with
`refineAccessType`.
-}
genericAccess : TOpt.Expr TypeIds.MVarId -> Name -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
genericAccess record fieldName meta s0 =
    let
        sConn =
            case recordFieldCanType fieldName (TOpt.typeOf record) of
                Just fieldCan ->
                    connectTypes meta.tipe fieldCan s0

                Nothing ->
                    s0
    in
    case classifyAs Mono.tkClassMisc meta.tipe sConn of
        ( monoType, s1 ) ->
            case translate record s1 of
                ( monoRecord, s2 ) ->
                    ( Mono.MonoRecordAccess monoRecord
                        fieldName
                        (refineAccessType s2.env.lss.enabled monoType (Mono.typeOf monoRecord) fieldName)
                    , s2
                    )



-- ====== DESTRUCTURING ======


{-| Translates a destructuring that binds one name.

The destructor's canonical type is remembered under the bound name, and
connected to the type of the slot it reads in the root's canonical type. A
later call of a function bound this way (`appShapeConnect`) can then carry
its argument types back to the value it was taken from.

-}
generalDestruct : TOpt.Destructor TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
generalDestruct ((TOpt.Destructor dname0 _ dmeta0) as destructor) body meta s0 =
    let
        (TOpt.Destructor _ dpath0 _) =
            destructor

        s1 =
            { s0 | derivedDestructors = Dict.insert dname0 dmeta0.tipe s0.derivedDestructors }

        s2 =
            case Dict.get (pathRootName dpath0) s1.localCanTypes |> Maybe.andThen (\rootCan -> canSlotForPath rootCan dpath0) of
                Just slotCan ->
                    connectTypes dmeta0.tipe slotCan s1

                Nothing ->
                    s1
    in
    generalDestructBody destructor body meta s2


{-| Translates the destructor (`specializeDestructor`), binds its name at
the destructor's type, and translates the body. The node's type is the
classified one, or the body's type where that has a type variable.
-}
generalDestructBody : TOpt.Destructor TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
generalDestructBody destructor body meta s0 =
    case classifyAs Mono.tkClassDestr meta.tipe s0 of
        ( monoType0, s1 ) ->
            case specializeDestructor destructor s1 of
                ( monoDestructor, s2 ) ->
                    let
                        (Mono.MonoDestructor destructorName _ destructorType) =
                            monoDestructor
                    in
                    Engine.scoped
                        (\sx ->
                            case translate body (Engine.insertVar destructorName destructorType sx) of
                                ( monoBody, sx1 ) ->
                                    ( Mono.MonoDestruct monoDestructor
                                        monoBody
                                        (if Mono.containsAnyMVar monoType0 then
                                            Mono.typeOf monoBody

                                         else
                                            monoType0
                                        )
                                    , sx1
                                    )
                        )
                        s2


{-| Translates a destructuring of a scalar number out of a let-bound number
value that is being specialized per use.

The bound name is itself treated as a number specialized per use, and the body
is translated first, each use recording its type. For each recorded type, an
instance of the root with only this slot set to that type is recorded on the
root (the root's own `let` emits it), and a destructor reading from that root
instance is emitted under the instance's name. The destructor for the bare
name is emitted only when the body still refers to it.

-}
specializeNumberDestruct : Name -> TOpt.Path -> TOpt.Meta TypeIds.MVarId -> Name -> Mono.MonoType -> TOpt.Expr TypeIds.MVarId -> Step Mono.MonoExpr
specializeNumberDestruct dname path dmeta rootName eagerRootType body s0 =
    case classifyAs Mono.tkClassDestr dmeta.tipe s0 of
        ( eagerLeaf, s1 ) ->
            case Engine.recordNumberInstance dname eagerLeaf (Engine.pushNumberMulti dname s1) of
                ( _, s2 ) ->
                    case Engine.scoped (\sx -> translate body (Engine.insertVar dname eagerLeaf sx)) s2 of
                        ( monoBody, s3 ) ->
                            case Engine.popNumberMulti s3 of
                                ( maybeEntry, s4 ) ->
                                    let
                                        dnameUsed =
                                            exprReferencesLocal dname monoBody

                                        instances =
                                            case maybeEntry of
                                                Just e ->
                                                    List.filter (\i -> i.freshName /= dname || dnameUsed) (Mono.specMapValues e.instances)

                                                Nothing ->
                                                    []
                                    in
                                    case Engine.traverse (buildRefinedDestructor rootName eagerRootType path) instances s4 of
                                        ( maybeDestructors, s5 ) ->
                                            let
                                                destructors =
                                                    List.filterMap identity maybeDestructors
                                            in
                                            ( List.foldl (\md acc -> Mono.MonoDestruct md acc (Mono.typeOf acc)) monoBody (List.reverse destructors)
                                            , s5
                                            )


{-| Builds, for one recorded instance of a destructured name, the root
instance with only this slot set to the instance's type, records it on the
root, and returns a destructor under the instance's name that reads from it.
Returns `Nothing` when the slot cannot be set (`refineRootInstance`).
-}
buildRefinedDestructor : Name -> Mono.MonoType -> TOpt.Path -> Engine.NumberInstance -> Step (Maybe Mono.MonoDestructor)
buildRefinedDestructor rootName eagerRootType path inst s0 =
    buildRefinedDestructorWith s0.env.globalTypeEnv rootName eagerRootType path inst s0


{-| Does the work of `buildRefinedDestructor` with the global type
environment given.
-}
buildRefinedDestructorWith : TypeEnv.GlobalTypeEnv -> Name -> Mono.MonoType -> TOpt.Path -> Engine.NumberInstance -> Step (Maybe Mono.MonoDestructor)
buildRefinedDestructorWith gte rootName eagerRootType path inst s0 =
    case refineRootInstance gte eagerRootType path inst.monoType of
        Just refinedRootType ->
            case Engine.recordNumberInstance rootName refinedRootType s0 of
                ( ( freshRootName, _ ), s1 ) ->
                    case specializePath (rewriteRootInPath rootName freshRootName path) (Engine.insertVar freshRootName refinedRootType s1) of
                        ( monoPath, s2 ) ->
                            let
                                dtype =
                                    Mono.getMonoPathType monoPath
                            in
                            ( Just (Mono.MonoDestructor inst.freshName monoPath dtype)
                            , Engine.insertVar inst.freshName dtype s2
                            )

        Nothing ->
            ( Nothing, s0 )


{-| Returns `container` with the slot `path` selects (a tuple element, record
field, constructor field or unboxed value) replaced by `leaf`, other slots
unchanged. A constructor field may have any declared type: the type arguments
it mentions are rebound to the parts of `leaf` at the same positions
(`rebindTypeArgs`). Returns `Nothing` for a list path, a path it cannot follow,
or a `leaf` whose shape does not match the field's declared type.
-}
refineRootInstance : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> TOpt.Path -> Mono.MonoType -> Maybe Mono.MonoType
refineRootInstance gte container path leaf =
    case path of
        TOpt.Root _ ->
            Just leaf

        TOpt.Index idx hint subPath ->
            navigateType gte container subPath
                |> Maybe.andThen
                    (\subC ->
                        case hint of
                            TOpt.HintCustom ctorName ->
                                replaceCustomSlot gte ctorName (Index.toMachine idx) subC leaf

                            TOpt.HintList ->
                                Nothing

                            _ ->
                                replaceIndexSlot subC (Index.toMachine idx) leaf
                    )
                |> Maybe.andThen (\newSub -> refineRootInstance gte container subPath newSub)

        TOpt.Field fieldName subPath ->
            navigateType gte container subPath
                |> Maybe.andThen (\subC -> replaceRecordSlot subC fieldName leaf)
                |> Maybe.andThen (\newSub -> refineRootInstance gte container subPath newSub)

        TOpt.Unbox subPath ->
            navigateType gte container subPath
                |> Maybe.andThen (\subC -> replaceUnboxSlot gte subC leaf)
                |> Maybe.andThen (\newSub -> refineRootInstance gte container subPath newSub)

        _ ->
            Nothing


{-| Returns the custom type `container` with the type arguments that
constructor `ctorName`'s field `idx` mentions rebound so that the field's type
becomes `leaf` (`rebindTypeArgs`); `Nothing` when the field is missing or
`leaf` does not match the field's declared shape.
-}
replaceCustomSlot : TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Mono.MonoType -> Maybe Mono.MonoType
replaceCustomSlot gte ctorName idx container leaf =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    findCtorArg ctorName idx unionData.alts
                        |> Maybe.andThen (\fieldCanType -> rebindTypeArgs home typeName unionData.vars typeArgs fieldCanType leaf)

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns `MCustom home typeName` with each parameter that the declared field
type `fieldCanType` mentions set to the type `leaf` gives it there, other
arguments unchanged. `Nothing` when `leaf` does not match the field's shape or
gives one parameter two different types.
-}
rebindTypeArgs : ModuleName.Canonical -> Name -> List Name -> List Mono.MonoType -> Can.Type Name -> Mono.MonoType -> Maybe Mono.MonoType
rebindTypeArgs home typeName vars typeArgs fieldCanType leaf =
    matchParams fieldCanType leaf Dict.empty
        |> Maybe.map
            (\bound ->
                Mono.mCustom home
                    typeName
                    (List.map2 (\v t -> Dict.get v bound |> Maybe.withDefault t) vars typeArgs)
            )


{-| Binds the type variables of a declared type to the parts of `mono` at the
same positions. A function type binds nothing (its parameters keep their
current arguments). `Nothing` on a shape mismatch or a conflicting binding.
-}
matchParams : Can.Type Name -> Mono.MonoType -> Dict.Dict Name Mono.MonoType -> Maybe (Dict.Dict Name Mono.MonoType)
matchParams canType mono acc =
    let
        matchList cs ms a =
            if List.length cs == List.length ms then
                List.foldl (\( c, m ) -> Maybe.andThen (matchParams c m)) (Just a) (List.map2 Tuple.pair cs ms)

            else
                Nothing
    in
    case ( canType, mono ) of
        ( Can.TVar n, _ ) ->
            case Dict.get n acc of
                Nothing ->
                    Just (Dict.insert n mono acc)

                Just prev ->
                    if prev == mono then
                        Just acc

                    else
                        Nothing

        ( Can.TType _ _ args, Mono.MCustom _ _ _ margs ) ->
            matchList args margs acc

        ( Can.TType _ _ [ a ], Mono.MList _ m ) ->
            matchParams a m acc

        ( Can.TType _ _ [], _ ) ->
            Just acc

        ( Can.TTuple a b rest, Mono.MTuple _ ms ) ->
            matchList (a :: b :: rest) ms acc

        ( Can.TUnit, _ ) ->
            Just acc

        ( Can.TRecord fields _, Mono.MRecord _ mfields ) ->
            Dict.foldl
                (\fname (Can.FieldType _ ft) ma ->
                    case Dict.get fname mfields of
                        Just mf ->
                            Maybe.andThen (matchParams ft mf) ma

                        Nothing ->
                            Nothing
                )
                (Just acc)
                fields

        ( Can.TLambda _ _ _, Mono.MFunction _ _ _ _ ) ->
            Just acc

        ( Can.TAlias _ _ _ (Can.Filled inner), _ ) ->
            matchParams inner mono acc

        ( Can.TAlias _ _ args (Can.Holey inner), _ ) ->
            -- Match the body with the formals, then each argument with its formal's binding.
            matchParams inner mono Dict.empty
                |> Maybe.andThen
                    (\formals ->
                        List.foldl
                            (\( formal, argT ) ma ->
                                case Dict.get formal formals of
                                    Just m ->
                                        Maybe.andThen (matchParams argT m) ma

                                    Nothing ->
                                        ma
                            )
                            (Just acc)
                            args
                    )

        _ ->
            Nothing


{-| Returns the custom type `container` with the type arguments its single
constructor's single field mentions rebound so that the field's type becomes
`leaf` (`rebindTypeArgs`); `Nothing` when the type is not such a wrapper or
`leaf` does not match the field's declared shape.
-}
replaceUnboxSlot : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Mono.MonoType -> Maybe Mono.MonoType
replaceUnboxSlot gte container leaf =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor c ] ->
                            case c.args of
                                [ fieldCanType ] ->
                                    rebindTypeArgs home typeName unionData.vars typeArgs fieldCanType leaf

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns the type of the slot `path` selects in `container`, or `Nothing`
for a list path or a path it cannot follow. A constructor field's type is its
declared type instantiated at `container`'s type arguments.
-}
navigateType : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> TOpt.Path -> Maybe Mono.MonoType
navigateType gte container path =
    case path of
        TOpt.Root _ ->
            Just container

        TOpt.Index idx hint subPath ->
            navigateType gte container subPath
                |> Maybe.andThen
                    (\c ->
                        case hint of
                            TOpt.HintCustom ctorName ->
                                customSlot gte ctorName (Index.toMachine idx) c

                            TOpt.HintList ->
                                Nothing

                            _ ->
                                tupleSlot c (Index.toMachine idx)
                    )

        TOpt.Field fieldName subPath ->
            navigateType gte container subPath |> Maybe.andThen (recordSlot fieldName)

        TOpt.Unbox subPath ->
            navigateType gte container subPath |> Maybe.andThen (unboxSlot gte)

        _ ->
            Nothing


{-| Returns the type of constructor `ctorName`'s field `idx` in the custom
type `container`: its declared type instantiated at `container`'s type
arguments (`Analysis.instantiateCtorField`).
-}
customSlot : TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Maybe Mono.MonoType
customSlot gte ctorName idx container =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    findCtorArg ctorName idx unionData.alts
                        |> Maybe.map (Analysis.instantiateCtorField unionData.vars typeArgs)

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns the type of the single field of a custom type with one
constructor of one field: its declared type instantiated at the type's
arguments (`Analysis.instantiateCtorField`).
-}
unboxSlot : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Maybe Mono.MonoType
unboxSlot gte container =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor c ] ->
                            case c.args of
                                [ fieldCanType ] ->
                                    Just (Analysis.instantiateCtorField unionData.vars typeArgs fieldCanType)

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns the type of tuple element `i`.
-}
tupleSlot : Mono.MonoType -> Int -> Maybe Mono.MonoType
tupleSlot t i =
    case t of
        Mono.MTuple _ elems ->
            List.head (List.drop i elems)

        _ ->
            Nothing


{-| Returns the type of record field `f`.
-}
recordSlot : String -> Mono.MonoType -> Maybe Mono.MonoType
recordSlot f t =
    case t of
        Mono.MRecord _ fields ->
            Dict.get f fields

        _ ->
            Nothing


{-| Returns the tuple type with element `i` replaced by `leaf`, or `Nothing`
when `i` is out of range or the type is not a tuple.
-}
replaceIndexSlot : Mono.MonoType -> Int -> Mono.MonoType -> Maybe Mono.MonoType
replaceIndexSlot t i leaf =
    case t of
        Mono.MTuple _ elems ->
            if i >= 0 && i < List.length elems then
                Just
                    (Mono.mTuple
                        (List.indexedMap
                            (\j x ->
                                if j == i then
                                    leaf

                                else
                                    x
                            )
                            elems
                        )
                    )

            else
                Nothing

        _ ->
            Nothing


{-| Returns the record type with field `f` set to `leaf`, adding it if it is
missing.
-}
replaceRecordSlot : Mono.MonoType -> String -> Mono.MonoType -> Maybe Mono.MonoType
replaceRecordSlot t f leaf =
    case t of
        Mono.MRecord _ fields ->
            Just (Mono.mRecord (Dict.insert f leaf fields))

        _ ->
            Nothing


{-| Returns the canonical type of the slot a destructor path selects, for
paths made of tuple elements and record fields; `Nothing` for any other step.
-}
canSlotForPath : Can.Type TypeIds.MVarId -> TOpt.Path -> Maybe (Can.Type TypeIds.MVarId)
canSlotForPath rootCan path =
    case path of
        TOpt.Root _ ->
            Just rootCan

        TOpt.Index idx _ sub ->
            canSlotForPath rootCan sub
                |> Maybe.andThen tupleSlotCanTypes
                |> Maybe.andThen (\slots -> List.head (List.drop (Index.toMachine idx) slots))

        TOpt.Field f sub ->
            canSlotForPath rootCan sub
                |> Maybe.andThen (recordFieldCanType f)

        _ ->
            Nothing


{-| Returns the name of the variable a destructor path starts from.
-}
pathRootName : TOpt.Path -> Name
pathRootName path =
    case path of
        TOpt.Root name ->
            name

        TOpt.Index _ _ sub ->
            pathRootName sub

        TOpt.ArrayIndex _ sub ->
            pathRootName sub

        TOpt.Field _ sub ->
            pathRootName sub

        TOpt.Unbox sub ->
            pathRootName sub


{-| Returns the path with its root variable renamed from `oldName` to
`newName`.
-}
rewriteRootInPath : Name -> Name -> TOpt.Path -> TOpt.Path
rewriteRootInPath oldName newName path =
    case path of
        TOpt.Root name ->
            TOpt.Root
                (if name == oldName then
                    newName

                 else
                    name
                )

        TOpt.Index i h sub ->
            TOpt.Index i h (rewriteRootInPath oldName newName sub)

        TOpt.ArrayIndex i sub ->
            TOpt.ArrayIndex i (rewriteRootInPath oldName newName sub)

        TOpt.Field f sub ->
            TOpt.Field f (rewriteRootInPath oldName newName sub)

        TOpt.Unbox sub ->
            TOpt.Unbox (rewriteRootInPath oldName newName sub)


{-| Tells whether a type is `Int`, `Float` or a `number` variable.
-}
isScalarNumber : Mono.MonoType -> Bool
isScalarNumber t =
    case t of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        _ ->
            False


{-| Tells whether an expression refers to the local `name` without binding
it.
-}
exprReferencesLocal : Name -> Mono.MonoExpr -> Bool
exprReferencesLocal name expr =
    List.member name (Closure.findFreeLocals Set.empty expr)



-- ====== LET-BOUND FUNCTIONS ======


{-| Tells whether a canonical type contains an arrow anywhere, including in
an alias's arguments and its expansion.
-}
typeContainsCanLambda : Can.Type TypeIds.MVarId -> Bool
typeContainsCanLambda t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TType _ _ args ->
            List.any typeContainsCanLambda args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ ft) acc -> acc || typeContainsCanLambda ft) False fields

        Can.TTuple a b rest ->
            List.any typeContainsCanLambda (a :: b :: rest)

        Can.TAlias _ _ args (Can.Filled inner) ->
            typeContainsCanLambda inner || List.any (\( _, at ) -> typeContainsCanLambda at) args

        Can.TAlias _ _ args (Can.Holey inner) ->
            typeContainsCanLambda inner || List.any (\( _, at ) -> typeContainsCanLambda at) args

        _ ->
            False


{-| Tells whether a canonical type is a function type, looking through
aliases.
-}
isFunctionType : Can.Type TypeIds.MVarId -> Bool
isFunctionType t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled inner) ->
            isFunctionType inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            isFunctionType inner

        _ ->
            False


{-| Translates a `let` that binds a function (or a value containing functions
with a free type variable), once per type the binding is used at.

The `let` body is translated first, each use recording the type it needs. Each
recorded type gets a definition (`f`, `f$1`, ...) whose right-hand side is
translated again at that type in a scratch store (`buildLocalDefs`); a binding
the body never uses gets one definition at its classified type. With LSS on,
the uses are then given the lambda sets of their instance's definition
(`flushLocalMultiEnrich`). The `let`'s type is computed from the body before
that overlay.

-}
translateLocalMultiLet : Name -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLocalMultiLet name defBody body letCanType s0 =
    let
        sA =
            { s0 | localCanTypes = Dict.insert name (TOpt.typeOf defBody) s0.localCanTypes }

        sB =
            Engine.pushLocalMulti (rhsLamOf defBody) (rhsPapOf defBody sA) name sA
    in
    case classifyAs Mono.tkClassLet (TOpt.typeOf defBody) sB of
        ( declType, s1 ) ->
            -- Bound for readers other than a variable use, such as a destructor's root.
            case Engine.scoped (\sx -> translate body (Engine.insertVar name declType sx)) s1 of
                ( monoBody, s2 ) ->
                    case Engine.popLocalMulti s2 of
                        ( maybeEntry, s3 ) ->
                            case buildLocalDefs name defBody maybeEntry s3 of
                                ( instanceDefs, s4 ) ->
                                    case flushLocalMultiEnrich name maybeEntry instanceDefs monoBody s4 of
                                        ( monoBody1, s5 ) ->
                                            case classifyAs Mono.tkClassLet letCanType s5 of
                                                ( letType0, s6 ) ->
                                                    let
                                                        letType =
                                                            if
                                                                Mono.containsAnyMVar letType0
                                                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                                                            then
                                                                Mono.typeOf monoBody

                                                            else
                                                                letType0
                                                    in
                                                    ( List.foldl (\d acc -> Mono.MonoLet d acc (Mono.typeOf acc)) monoBody1 (List.reverse instanceDefs)
                                                        |> retypeLet letType
                                                    , s6
                                                    )


{-| Returns the expression with the type of its outermost `MonoLet` replaced
by `letType`; any other expression is returned unchanged.
-}
retypeLet : Mono.MonoType -> Mono.MonoExpr -> Mono.MonoExpr
retypeLet letType expr =
    case expr of
        Mono.MonoLet d inner _ ->
            Mono.MonoLet d inner letType

        _ ->
            expr


{-| Returns, with LSS on, the `let` body with each use of a let-bound
function's instance given the lambda sets of that instance's right-hand side.
With LSS off the body is returned unchanged.

A use was translated before its instance's definition, so its type carries no
sets of its own, while the definition, translated at the use's type, does. The
values reaching the use are the values that definition produces, so its sets
are overlaid onto the use (`Mono.overlayAnnotations`, which keeps the use's
structure). Elm forbids shadowing, so matching uses by name is exact.

To walk each body once, the work is done only by the outermost let-bound
function of the work item. A nested one, finding an enclosing entry on the
let-function stack, adds its own instances, and those it inherited, to that
entry's pending set and returns the body unchanged. The outermost one walks
its body once (`overlayLocalMultiUses`). A group's uses inside its own
right-hand sides are not overlaid; uses of enclosing groups' instances are.

-}
flushLocalMultiEnrich : Name -> Maybe Engine.NumberMultiEntry -> List Mono.MonoDef -> Mono.MonoExpr -> Step Mono.MonoExpr
flushLocalMultiEnrich defName maybeEntry instanceDefs monoBody s0 =
    if not s0.env.lss.enabled then
        ( monoBody, s0 )

    else
        let
            inherited =
                case maybeEntry of
                    Just entry ->
                        entry.pendingEnrich

                    Nothing ->
                        Dict.empty

            -- Not yet wrapped around `monoBody`, so a walk here binds them at the root.
            own =
                List.foldl
                    (\d acc ->
                        case d of
                            Mono.MonoDef n rhs ->
                                Dict.insert n ( defName, Mono.typeOf rhs ) acc

                            Mono.MonoTailDef _ _ _ ->
                                acc
                    )
                    Dict.empty
                    instanceDefs

            pending =
                Dict.union own inherited
        in
        if Dict.isEmpty pending then
            ( monoBody, s0 )

        else
            case s0.localMulti of
                top :: rest ->
                    ( monoBody, { s0 | localMulti = { top | pendingEnrich = Dict.union pending top.pendingEnrich } :: rest } )

                [] ->
                    let
                        rootEnv =
                            Dict.map (\_ ( _, t ) -> t) own
                    in
                    ( overlayLocalMultiUses pending rootEnv monoBody, enrichCensus pending rootEnv monoBody s0 )


{-| Returns `root` with the instance uses overlaid, as `flushLocalMultiEnrich`
describes. `groups` maps each recorded instance name to its function's name
and the type its right-hand side had when recorded; `env` holds the instance
bindings in scope at the root, with their types.
-}
overlayLocalMultiUses : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.MonoExpr -> Mono.MonoExpr
overlayLocalMultiUses groups env root =
    Maybe.withDefault root (olmExpr groups env root)


{-| Returns the expression with instance uses overlaid, or `Nothing` when
nothing in it changes, so that unchanged subtrees are not rebuilt. A chain of
one group's instance definitions brings that group's bindings into scope for
the body below it (`olmChain`, `olmGroup`).
-}
olmExpr : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.MonoExpr -> Maybe Mono.MonoExpr
olmExpr groups env expr =
    case expr of
        Mono.MonoVarLocal n t ->
            case Dict.get n env of
                Just src ->
                    Just (Mono.MonoVarLocal n (Mono.overlayAnnotations t src))

                Nothing ->
                    Nothing

        Mono.MonoLet def body t ->
            case olmChain groups expr of
                Just ( members, innerBody ) ->
                    Just (olmGroup groups env members innerBody)

                Nothing ->
                    case ( olmDef groups env def, olmExpr groups env body ) of
                        ( Nothing, Nothing ) ->
                            Nothing

                        ( md, mb ) ->
                            Just (Mono.MonoLet (Maybe.withDefault def md) (Maybe.withDefault body mb) t)

        Mono.MonoClosure info body t ->
            case ( olmCaptures groups env info.captures, olmExpr groups env body ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mc, mb ) ->
                    Just (Mono.MonoClosure { info | captures = Maybe.withDefault info.captures mc } (Maybe.withDefault body mb) t)

        Mono.MonoCall region func args t info ->
            case ( olmExpr groups env func, olmList groups env args ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mf, ma ) ->
                    Just (Mono.MonoCall region (Maybe.withDefault func mf) (Maybe.withDefault args ma) t info)

        Mono.MonoTailCall name args t ->
            Maybe.map (\a -> Mono.MonoTailCall name a t) (olmNamed groups env args)

        Mono.MonoIf branches final t ->
            case ( olmBranches groups env branches, olmExpr groups env final ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mb, mf ) ->
                    Just (Mono.MonoIf (Maybe.withDefault branches mb) (Maybe.withDefault final mf) t)

        Mono.MonoDestruct path inner t ->
            Maybe.map (\i -> Mono.MonoDestruct path i t) (olmExpr groups env inner)

        Mono.MonoCase label scrutinee decider jumps t ->
            case ( olmDecider groups env decider, olmNamed groups env jumps ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( md, mj ) ->
                    Just (Mono.MonoCase label scrutinee (Maybe.withDefault decider md) (Maybe.withDefault jumps mj) t)

        Mono.MonoList region items t ->
            Maybe.map (\i -> Mono.MonoList region i t) (olmList groups env items)

        Mono.MonoRecordCreate fields t ->
            Maybe.map (\f -> Mono.MonoRecordCreate f t) (olmNamed groups env fields)

        Mono.MonoRecordAccess inner field t ->
            Maybe.map (\i -> Mono.MonoRecordAccess i field t) (olmExpr groups env inner)

        Mono.MonoRecordUpdate record updates t ->
            case ( olmExpr groups env record, olmNamed groups env updates ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mr, mu ) ->
                    Just (Mono.MonoRecordUpdate (Maybe.withDefault record mr) (Maybe.withDefault updates mu) t)

        Mono.MonoTupleCreate region elements t ->
            Maybe.map (\e -> Mono.MonoTupleCreate region e t) (olmList groups env elements)

        Mono.MonoLiteral _ _ ->
            Nothing

        Mono.MonoVarGlobal _ _ _ ->
            Nothing

        Mono.MonoVarKernel _ _ _ _ _ ->
            Nothing

        Mono.MonoUnit ->
            Nothing

        Mono.MonoAccessorValue _ _ _ ->
            Nothing


{-| Returns the longest chain of nested `let`s starting here whose
definitions are recorded instances of one group, top first, together with the
body below the chain. A definition belongs only when its right-hand side still
has the recorded type, since the same name in a sibling scope is a different
value. Returns `Nothing` when no chain starts here.
-}
olmChain : Dict.Dict String ( String, Mono.MonoType ) -> Mono.MonoExpr -> Maybe ( List ( Name, Mono.MonoExpr, Mono.MonoType ), Mono.MonoExpr )
olmChain groups expr =
    case expr of
        Mono.MonoLet (Mono.MonoDef n rhs) body t ->
            case Dict.get n groups of
                Just ( group, recordedType ) ->
                    if Mono.typeOf rhs == recordedType then
                        Just (olmChainGo groups group body [ ( n, rhs, t ) ])

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Extends a chain for `olmChain` while the next `let` belongs to `group`.
-}
olmChainGo : Dict.Dict String ( String, Mono.MonoType ) -> String -> Mono.MonoExpr -> List ( Name, Mono.MonoExpr, Mono.MonoType ) -> ( List ( Name, Mono.MonoExpr, Mono.MonoType ), Mono.MonoExpr )
olmChainGo groups group expr acc =
    case expr of
        Mono.MonoLet (Mono.MonoDef n rhs) body t ->
            case Dict.get n groups of
                Just ( g, recordedType ) ->
                    if g == group && Mono.typeOf rhs == recordedType then
                        olmChainGo groups group body (( n, rhs, t ) :: acc)

                    else
                        ( List.reverse acc, expr )

                Nothing ->
                    ( List.reverse acc, expr )

        _ ->
            ( List.reverse acc, expr )


{-| Rebuilds one group's chain of definitions over its body. The right-hand
sides are overlaid with the outer bindings only, the body with the group's own
bindings as well. The top `let` keeps its type; each lower one gets the type of
the body as overlaid with the group's bindings.
-}
olmGroup : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( Name, Mono.MonoExpr, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoExpr
olmGroup groups env members innerBody =
    let
        own =
            List.foldl (\( n, rhs, _ ) acc -> Dict.insert n (Mono.typeOf rhs) acc) Dict.empty members

        newBody =
            Maybe.withDefault innerBody (olmExpr groups (Dict.union own env) innerBody)

        memberType =
            case innerBody of
                Mono.MonoVarLocal n t ->
                    case Dict.get n own of
                        Just src ->
                            Mono.overlayAnnotations t src

                        Nothing ->
                            t

                other ->
                    Mono.typeOf other
    in
    olmRebuild groups env members newBody memberType True


{-| Wraps `body` in the group's `let`s for `olmGroup`, overlaying each
right-hand side with `env`.
-}
olmRebuild : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( Name, Mono.MonoExpr, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> Bool -> Mono.MonoExpr
olmRebuild groups env members body memberType isTop =
    case members of
        [] ->
            body

        ( n, rhs, tOrig ) :: rest ->
            Mono.MonoLet
                (Mono.MonoDef n (Maybe.withDefault rhs (olmExpr groups env rhs)))
                (olmRebuild groups env rest body memberType False)
                (if isTop then
                    tOrig

                 else
                    memberType
                )


{-| Overlays a definition's right-hand side, or returns `Nothing` when it
does not change.
-}
olmDef : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.MonoDef -> Maybe Mono.MonoDef
olmDef groups env def =
    case def of
        Mono.MonoDef n rhs ->
            Maybe.map (Mono.MonoDef n) (olmExpr groups env rhs)

        Mono.MonoTailDef n params rhs ->
            Maybe.map (Mono.MonoTailDef n params) (olmExpr groups env rhs)


{-| Overlays each expression in a list, or returns `Nothing` when none
changes.
-}
olmList : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List Mono.MonoExpr -> Maybe (List Mono.MonoExpr)
olmList groups env items =
    case items of
        [] ->
            Nothing

        x :: xs ->
            case ( olmExpr groups env x, olmList groups env xs ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mx, mxs ) ->
                    Just (Maybe.withDefault x mx :: Maybe.withDefault xs mxs)


{-| Overlays the expression of each keyed pair, or returns `Nothing` when
none changes.
-}
olmNamed : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( k, Mono.MonoExpr ) -> Maybe (List ( k, Mono.MonoExpr ))
olmNamed groups env items =
    case items of
        [] ->
            Nothing

        ( k, x ) :: xs ->
            case ( olmExpr groups env x, olmNamed groups env xs ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mx, mxs ) ->
                    Just (( k, Maybe.withDefault x mx ) :: Maybe.withDefault xs mxs)


{-| Overlays the expression of each closure capture, or returns `Nothing`
when none changes.
-}
olmCaptures : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( Name, Mono.MonoExpr, a ) -> Maybe (List ( Name, Mono.MonoExpr, a ))
olmCaptures groups env items =
    case items of
        [] ->
            Nothing

        ( n, x, t ) :: xs ->
            case ( olmExpr groups env x, olmCaptures groups env xs ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mx, mxs ) ->
                    Just (( n, Maybe.withDefault x mx, t ) :: Maybe.withDefault xs mxs)


{-| Overlays the condition and value of each `if` branch, or returns
`Nothing` when none changes.
-}
olmBranches : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Maybe (List ( Mono.MonoExpr, Mono.MonoExpr ))
olmBranches groups env items =
    case items of
        [] ->
            Nothing

        ( c, x ) :: xs ->
            case ( olmExpr groups env c, olmExpr groups env x, olmBranches groups env xs ) of
                ( Nothing, Nothing, Nothing ) ->
                    Nothing

                ( mc, mx, mxs ) ->
                    Just (( Maybe.withDefault c mc, Maybe.withDefault x mx ) :: Maybe.withDefault xs mxs)


{-| Overlays the inline leaves of a decision tree, or returns `Nothing` when
none changes. Jump leaves are reached through the case's jump list instead.
-}
olmDecider : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.Decider Mono.MonoChoice -> Maybe (Mono.Decider Mono.MonoChoice)
olmDecider groups env decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Maybe.map (\e1 -> Mono.Leaf (Mono.Inline e1)) (olmExpr groups env e)

        Mono.Leaf (Mono.Jump _) ->
            Nothing

        Mono.Chain test success failure ->
            case ( olmDecider groups env success, olmDecider groups env failure ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( ms, mf ) ->
                    Just (Mono.Chain test (Maybe.withDefault success ms) (Maybe.withDefault failure mf))

        Mono.FanOut path edges fallback ->
            case ( olmEdges groups env edges, olmDecider groups env fallback ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( me, mf ) ->
                    Just (Mono.FanOut path (Maybe.withDefault edges me) (Maybe.withDefault fallback mf))


{-| Overlays the decision trees of a fan-out's edges, or returns `Nothing`
when none changes.
-}
olmEdges : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( a, Mono.Decider Mono.MonoChoice ) -> Maybe (List ( a, Mono.Decider Mono.MonoChoice ))
olmEdges groups env edges =
    case edges of
        [] ->
            Nothing

        ( test, d ) :: rest ->
            case ( olmDecider groups env d, olmEdges groups env rest ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( md, mr ) ->
                    Just (( test, Maybe.withDefault d md ) :: Maybe.withDefault rest mr)


{-| Counts, under `lss.report`, the cost of one walk of
`flushLocalMultiEnrich`:

    e4a|walks       walks made
    e4a|nodes       nodes the walk visited
    e4a|oldVisits   nodes walking each group's body separately would visit
    e4a|groups      chains of instance definitions covered
    e4a|depth|<d>   walks whose deepest chain nesting is d
    e4a|item|<g>    oldVisits for a global, when at least 1,000,000

-}
enrichCensus : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.MonoExpr -> Engine.S -> Engine.S
enrichCensus groups rootEnv body s =
    if not s.env.lss.report then
        s

    else
        let
            ownGroup =
                if Dict.isEmpty rootEnv then
                    0

                else
                    1

            ( size, st ) =
                enrichCensusGo groups (1 + ownGroup) body { old = 0, groups = 0, maxDepth = 0 }

            old =
                st.old + ownGroup * size

            depth =
                max st.maxDepth ownGroup

            itemKey =
                case s.currentGlobal of
                    Just g ->
                        Mono.toComparableGlobal g

                    Nothing ->
                        "?"
        in
        s
            |> Engine.bumpArgFlowCensusBy "e4a|walks" 1
            |> Engine.bumpArgFlowCensusBy "e4a|nodes" size
            |> Engine.bumpArgFlowCensusBy "e4a|oldVisits" old
            |> Engine.bumpArgFlowCensusBy "e4a|groups" (st.groups + ownGroup)
            |> Engine.bumpArgFlowCensusBy ("e4a|depth|" ++ String.fromInt depth) 1
            |> (if old >= 1000000 then
                    Engine.bumpArgFlowCensusBy ("e4a|item|" ++ itemKey) old

                else
                    identity
               )


{-| What `enrichCensusGo` accumulates: the visits a separate walk per group
would make, the number of chains, and the deepest chain nesting.
-}
type alias EnrichCensus =
    { old : Int, groups : Int, maxDepth : Int }


{-| Returns the number of expression nodes in a subtree, and adds to the
census each chain inside it. `depth` is one more than the number of chains
enclosing the node.
-}
enrichCensusGo : Dict.Dict String ( String, Mono.MonoType ) -> Int -> Mono.MonoExpr -> EnrichCensus -> ( Int, EnrichCensus )
enrichCensusGo groups depth expr st =
    case olmChain groups expr of
        Just ( members, innerBody ) ->
            let
                ( rhsSize, st1 ) =
                    List.foldl
                        (\( _, rhs, _ ) ( n, a ) ->
                            let
                                ( m, a1 ) =
                                    enrichCensusGo groups depth rhs a
                            in
                            ( n + m, a1 )
                        )
                        ( 0, st )
                        members

                ( bodySize, st2 ) =
                    enrichCensusGo groups (depth + 1) innerBody st1
            in
            ( List.length members + rhsSize + bodySize
            , { st2 | old = st2.old + bodySize, groups = st2.groups + 1, maxDepth = max st2.maxDepth depth }
            )

        Nothing ->
            let
                ( childSum, st1 ) =
                    List.foldl
                        (\c ( n, a ) ->
                            let
                                ( m, a1 ) =
                                    enrichCensusGo groups depth c a
                            in
                            ( n + m, a1 )
                        )
                        ( 0, st )
                        (MonoTraverse.childrenOf expr)
            in
            ( 1 + childSum, st1 )


{-| Returns the definitions of a let-bound function's instances, each
translated again at its type under the instance's position in recording order
(`retranslateAtInstance`). An unused function gets one definition under its
own name, translated once in the item's store.
-}
buildLocalDefs : Name -> TOpt.Expr TypeIds.MVarId -> Maybe Engine.NumberMultiEntry -> Step (List Mono.MonoDef)
buildLocalDefs name defBody maybeEntry s0 =
    case maybeEntry of
        Just entry ->
            if Mono.specMapIsEmpty entry.instances then
                case translate defBody s0 of
                    ( e, s1 ) ->
                        ( [ Mono.MonoDef name e ], s1 )

            else
                -- Instances iterate in recording order, the order their `$N` names were given in.
                Engine.traverse
                    (\( ord, inst ) sx ->
                        case retranslateAtInstance name ord defBody inst.monoType sx of
                            ( e, sx1 ) ->
                                ( Mono.MonoDef inst.freshName (MonoTraverse.renameLocal name inst.freshName e), sx1 )
                    )
                    (List.indexedMap Tuple.pair (Mono.specMapValues entry.instances))
                    s0

        Nothing ->
            ( [], s0 )



-- ====== CASE / DECISION TREE ======


{-| Translates a case's decision tree: test paths are typed from the case
root (`specializeDtPath`), inline leaves are translated with their type
connected to the case's, and each branch is translated in its own scope.
-}
specializeDecider : Can.Type TypeIds.MVarId -> Name -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> Step (Mono.Decider Mono.MonoChoice)
specializeDecider caseCanType root decider s0 =
    case decider of
        TOpt.Leaf choice ->
            case specializeChoice caseCanType choice s0 of
                ( mc, s1 ) ->
                    ( Mono.Leaf mc, s1 )

        TOpt.Chain testChain success failure ->
            case
                Engine.traverse
                    (\( path, test ) sx ->
                        case specializeDtPath root path sx of
                            ( mp, sx1 ) ->
                                ( ( mp, test ), sx1 )
                    )
                    testChain
                    s0
            of
                ( monoTestChain, s1 ) ->
                    case Engine.scoped (specializeDecider caseCanType root success) s1 of
                        ( monoSuccess, s2 ) ->
                            case Engine.scoped (specializeDecider caseCanType root failure) s2 of
                                ( monoFailure, s3 ) ->
                                    ( Mono.Chain monoTestChain monoSuccess monoFailure, s3 )

        TOpt.FanOut path edges fallback ->
            case specializeDtPath root path s0 of
                ( monoPath, s1 ) ->
                    case
                        Engine.traverse
                            (\( test, dec ) sx ->
                                case Engine.scoped (specializeDecider caseCanType root dec) sx of
                                    ( md, sx1 ) ->
                                        ( ( test, md ), sx1 )
                            )
                            edges
                            s1
                    of
                        ( monoEdges, s2 ) ->
                            case Engine.scoped (specializeDecider caseCanType root fallback) s2 of
                                ( monoFallback, s3 ) ->
                                    ( Mono.FanOut monoPath monoEdges monoFallback, s3 )


{-| Translates a decision-tree leaf: an inline expression is translated with
its type connected to the case's type; a jump is kept.
-}
specializeChoice : Can.Type TypeIds.MVarId -> TOpt.Choice TypeIds.MVarId -> Step Mono.MonoChoice
specializeChoice caseCanType choice s0 =
    case choice of
        TOpt.Inline expr ->
            case translate expr (connectTypes (TOpt.typeOf expr) caseCanType s0) of
                ( me, s1 ) ->
                    ( Mono.Inline me, s1 )

        TOpt.Jump index ->
            ( Mono.Jump index, s0 )


{-| Translates a case's shared branch bodies, each in its own scope with its
type connected to the case's type.
-}
specializeJumps : Can.Type TypeIds.MVarId -> List ( Int, TOpt.Expr TypeIds.MVarId ) -> Step (List ( Int, Mono.MonoExpr ))
specializeJumps caseCanType jumps s0 =
    Engine.traverse
        (\( idx, expr ) sx ->
            case Engine.scoped (\sy -> translate expr (connectTypes (TOpt.typeOf expr) caseCanType sy)) sx of
                ( me, sx1 ) ->
                    ( ( idx, me ), sx1 )
        )
        jumps
        s0


{-| Counts, under `lss.report`, how the lambda sets of a case's classified
type compare with those of each branch, position by position
(`caseanno|<classified>|<branch>`, labelled by `annoCellLabel`). A cell such
as `top|k1` is a position where a branch names one member and the classified
type has ⊤. Both the shared branch bodies and the decision tree's inline
leaves are compared.
-}
caseAnnoCensus : Mono.MonoType -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Engine.S -> Engine.S
caseAnnoCensus classified decider jumps s =
    if not s.env.lss.report then
        s

    else
        deciderAnnoFold classified
            decider
            (List.foldl (\( _, e ) acc -> annoPairFold classified (Mono.typeOf e) acc) s jumps)


{-| Compares the classified type with each inline leaf of a decision tree,
for `caseAnnoCensus`.
-}
deciderAnnoFold : Mono.MonoType -> Mono.Decider Mono.MonoChoice -> Engine.S -> Engine.S
deciderAnnoFold classified decider s =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            annoPairFold classified (Mono.typeOf e) s

        Mono.Leaf (Mono.Jump _) ->
            s

        Mono.Chain _ yes no ->
            deciderAnnoFold classified no (deciderAnnoFold classified yes s)

        Mono.FanOut _ edges def ->
            List.foldl (\( _, d ) acc -> deciderAnnoFold classified d acc)
                (deciderAnnoFold classified def s)
                edges


{-| Compares two types' lambda sets position by position under the
`caseanno` prefix.
-}
annoPairFold : Mono.MonoType -> Mono.MonoType -> Engine.S -> Engine.S
annoPairFold =
    annoPairFoldWith "caseanno"


{-| Counts, under `prefix`, one census cell for each pair of lambda sets at
the same position of two types, walking functions, lists, tuples, records and
custom types where their shapes agree and skipping where they do not.
-}
annoPairFoldWith : String -> Mono.MonoType -> Mono.MonoType -> Engine.S -> Engine.S
annoPairFoldWith prefix a b s =
    case ( a, b ) of
        ( Mono.MFunction _ annoA argsA retA, Mono.MFunction _ annoB argsB retB ) ->
            if List.length argsA == List.length argsB then
                List.foldl (\( x, y ) acc -> annoPairFoldWith prefix x y acc)
                    (annoPairFoldWith prefix retA retB (bumpAnnoCell prefix annoA annoB s))
                    (List.map2 Tuple.pair argsA argsB)

            else
                s

        ( Mono.MList _ xa, Mono.MList _ xb ) ->
            annoPairFoldWith prefix xa xb s

        ( Mono.MTuple _ xsa, Mono.MTuple _ xsb ) ->
            if List.length xsa == List.length xsb then
                List.foldl (\( x, y ) acc -> annoPairFoldWith prefix x y acc) s (List.map2 Tuple.pair xsa xsb)

            else
                s

        ( Mono.MRecord _ fa, Mono.MRecord _ fb ) ->
            Dict.foldl
                (\k va acc ->
                    case Dict.get k fb of
                        Just vb ->
                            annoPairFoldWith prefix va vb acc

                        Nothing ->
                            acc
                )
                s
                fa

        ( Mono.MCustom _ _ _ xsa, Mono.MCustom _ _ _ xsb ) ->
            if List.length xsa == List.length xsb then
                List.foldl (\( x, y ) acc -> annoPairFoldWith prefix x y acc) s (List.map2 Tuple.pair xsa xsb)

            else
                s

        _ ->
            s


{-| Counts one census cell named by `prefix` and the labels of two
annotations.
-}
bumpAnnoCell : String -> Mono.LambdaSetAnno -> Mono.LambdaSetAnno -> Engine.S -> Engine.S
bumpAnnoCell prefix a b s =
    Engine.bumpArgFlowCensus (prefix ++ "|" ++ annoCellLabel a ++ "|" ++ annoCellLabel b) s


{-| Counts, under `lss.report`, how a destructor's classified type compares
with the type projected from its root's bound type, position by position
(`destranno|<classified>|<projected>`).
-}
destrAnnoCensus : Mono.MonoType -> Mono.MonoType -> Engine.S -> Engine.S
destrAnnoCensus classified projected s =
    if not s.env.lss.report then
        s

    else
        annoPairFoldWith "destranno" classified projected s


{-| Counts, under `lss.report` and when the classified type has a ⊤, how a
destructor that reads a constructor field compares with the union of that
field's type over every spec of the constructor created so far
(`destrBnow|<classified>|<union>`), or that there are none.
-}
destrBNowCensus : Mono.MonoType -> Mono.MonoPath -> Engine.S -> Engine.S
destrBNowCensus classified monoPath s =
    if not (s.env.lss.report && Mono.hasTopAnno classified) then
        s

    else
        case monoPath of
            Mono.MonoIndex fieldIx (Mono.CustomContainer ctorName) _ subPath ->
                case Mono.getMonoPathType subPath of
                    Mono.MCustom _ ctorHome _ _ ->
                        case ctorFieldUnion ctorHome ctorName fieldIx s of
                            Just unionT ->
                                annoPairFoldWith "destrBnow" classified unionT s

                            Nothing ->
                                Engine.bumpArgFlowCensus "destrBnow|noEntries" s

                    _ ->
                        s

            _ ->
                s


{-| Returns field `fieldIx`'s type combined over every spec of the
constructor, by `Mono.enrichAnnotations`, or `Nothing` when there is none.
Each spec's type is read as curried, so the field is the first parameter
after `fieldIx` stages.
-}
ctorFieldUnion : ModuleName.Canonical -> Name -> Int -> Engine.S -> Maybe Mono.MonoType
ctorFieldUnion ctorHome ctorName fieldIx s =
    let
        gkey =
            Mono.toComparableGlobal (Mono.Global ctorHome ctorName)
    in
    List.foldl
        (\specId acc ->
            case Array.get specId s.registry.reverseMapping of
                Just (Just ( _, t )) ->
                    case ctorFieldAt fieldIx t of
                        Just ft ->
                            case acc of
                                Just u ->
                                    Just (Mono.enrichAnnotations u ft)

                                Nothing ->
                                    Just ft

                        Nothing ->
                            acc

                _ ->
                    acc
        )
        Nothing
        (Engine.specIdsForGlobal gkey s)


{-| Returns the first parameter type of stage `i` of a function type.
-}
ctorFieldAt : Int -> Mono.MonoType -> Maybe Mono.MonoType
ctorFieldAt i t =
    case t of
        Mono.MFunction _ _ (a :: _) r ->
            if i <= 0 then
                Just a

            else
                ctorFieldAt (i - 1) r

        _ ->
            Nothing


{-| Returns the census label for an annotation: `k1` for a one-member set,
`kN` for any other set, `var`, `top` or `part`.
-}
annoCellLabel : Mono.LambdaSetAnno -> String
annoCellLabel anno =
    case anno of
        Mono.LSet [ _ ] ->
            "k1"

        Mono.LSet _ ->
            "kN"

        Mono.LVar _ ->
            "var"

        Mono.LTop _ ->
            "top"

        Mono.LPartial _ ->
            "part"


{-| Returns a case's type for when its classified type has type variables:
the structure of the first branch (the shared bodies first, then the decision
tree's inline leaves), with lambda sets joined over every branch
(`joinBranchTypes`). With no branch it returns `fallback`.

Taking the first branch's sets alone would be wrong: one branch's one-member
set would stand for the whole case even when another branch's set is unknown,
and a call through it could then be bound to the wrong function.

-}
inferCaseType : List ( Int, Mono.MonoExpr ) -> Mono.Decider Mono.MonoChoice -> Mono.MonoType -> Mono.MonoType
inferCaseType jumps decider fallback =
    case List.map (\( _, e ) -> Mono.typeOf e) jumps ++ deciderLeafTypes decider of
        first :: rest ->
            List.foldl (\t acc -> joinBranchTypes acc t) first rest

        [] ->
            fallback


{-| Returns the type of every inline leaf of a decision tree, success before
failure and edges before the fallback.
-}
deciderLeafTypes : Mono.Decider Mono.MonoChoice -> List Mono.MonoType
deciderLeafTypes decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            [ Mono.typeOf e ]

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ yes no ->
            deciderLeafTypes yes ++ deciderLeafTypes no

        Mono.FanOut _ edges def ->
            List.concatMap (\( _, d ) -> deciderLeafTypes d) edges ++ deciderLeafTypes def


{-| Returns `acc` with each lambda set joined, position by position, with the
one at the same position of `next`. Where the two shapes disagree, `acc` is
kept from that point down.

A position where either side is an `LSet` or `LPartial` is joined by
`Mono.unionAnno`. Where both are a set variable or ⊤, `acc`'s annotation is
kept: two set variables from separate read-backs are numbered independently,
and joining them would give ⊤ for no reason.

-}
joinBranchTypes : Mono.MonoType -> Mono.MonoType -> Mono.MonoType
joinBranchTypes acc next =
    case ( acc, next ) of
        ( Mono.MFunction _ annoA argsA retA, Mono.MFunction _ annoB argsB retB ) ->
            if List.length argsA == List.length argsB then
                Mono.mFunction (joinBranchAnno annoA annoB) (List.map2 joinBranchTypes argsA argsB) (joinBranchTypes retA retB)

            else
                acc

        ( Mono.MList _ xa, Mono.MList _ xb ) ->
            Mono.mList (joinBranchTypes xa xb)

        ( Mono.MTuple _ xsa, Mono.MTuple _ xsb ) ->
            if List.length xsa == List.length xsb then
                Mono.mTuple (List.map2 joinBranchTypes xsa xsb)

            else
                acc

        ( Mono.MRecord _ fieldsA, Mono.MRecord _ fieldsB ) ->
            if Dict.keys fieldsA == Dict.keys fieldsB then
                Mono.mRecord (Dict.map (\k ta -> joinBranchTypes ta (Maybe.withDefault ta (Dict.get k fieldsB))) fieldsA)

            else
                acc

        ( Mono.MCustom _ homeA nameA argsA, Mono.MCustom _ homeB nameB argsB ) ->
            if homeA == homeB && nameA == nameB && List.length argsA == List.length argsB then
                Mono.mCustom homeA nameA (List.map2 joinBranchTypes argsA argsB)

            else
                acc

        _ ->
            acc


{-| Joins two annotations as `joinBranchTypes` describes for one position.
-}
joinBranchAnno : Mono.LambdaSetAnno -> Mono.LambdaSetAnno -> Mono.LambdaSetAnno
joinBranchAnno acc next =
    case ( acc, next ) of
        ( Mono.LSet _, _ ) ->
            Mono.unionAnno acc next

        ( _, Mono.LSet _ ) ->
            Mono.unionAnno acc next

        ( Mono.LPartial _, _ ) ->
            Mono.unionAnno acc next

        ( _, Mono.LPartial _ ) ->
            Mono.unionAnno acc next

        _ ->
            acc


{-| Translates a decision-tree test path, typing each step from the type the
variable environment binds to the case root. Aborts the build when the root is
unbound.
-}
specializeDtPath : Name -> TypedPath.Path -> Step Mono.MonoDtPath
specializeDtPath root path s0 =
    case path of
        TypedPath.Empty ->
            case Engine.lookupVar root s0 of
                ( Just t, s1 ) ->
                    ( Mono.DtRoot root t, s1 )

                ( Nothing, s1 ) ->
                    ( Engine.crashFailure (EngineBug ("case root not in varEnv: " ++ root)), s1 )

        TypedPath.Index index hint subPath ->
            case specializeDtPath root subPath s0 of
                ( monoSubPath, s1 ) ->
                    let
                        i =
                            Index.toMachine index
                    in
                    case projIndexType (dtHintToProj hint) i (Mono.dtPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.DtIndex i (dtHintToKind hint) resultType monoSubPath, s2 )

        TypedPath.Unbox subPath ->
            case specializeDtPath root subPath s0 of
                ( monoSubPath, s1 ) ->
                    case computeUnboxResultType (Mono.dtPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.DtUnbox resultType monoSubPath, s2 )



-- ====== DESTRUCTURE ======


{-| Translates a destructor: its path is typed from the root's bound type
(`specializePath`) and its type is classified.

With LSS on and a ⊤ in the classified type, the classified type is enriched
with the lambda sets of the type projected down the path from the root
(`Mono.enrichAnnotations`), which can carry sets that came in through the
root's type arguments. Sets carried only by a constructor's declared field
types are not recovered here; reading the constructor's specs now could miss
constructions not yet translated.

-}
specializeDestructor : TOpt.Destructor TypeIds.MVarId -> Step Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path meta) s0 =
    case specializePath path s0 of
        ( monoPath, sP ) ->
            case classifyAs Mono.tkClassDestr meta.tipe sP of
                ( monoType0, sD ) ->
                    let
                        monoType =
                            if not (sD.env.lss.enabled && Mono.hasTopAnno monoType0) then
                                monoType0

                            else
                                Mono.enrichAnnotations monoType0 (Mono.getMonoPathType monoPath)

                        sD1 =
                            destrBNowCensus monoType0
                                monoPath
                                (destrAnnoCensus monoType0 (Mono.getMonoPathType monoPath) sD)
                    in
                    ( Mono.MonoDestructor name monoPath monoType, sD1 )


{-| Translates a destructor path, typing each step from the type the
variable environment binds to the root. Aborts the build when the root is
unbound or a step does not fit its container's type.
-}
specializePath : TOpt.Path -> Step Mono.MonoPath
specializePath path s0 =
    case path of
        TOpt.Root name ->
            case Engine.lookupVar name s0 of
                ( Just t, s1 ) ->
                    ( Mono.MonoRoot name t, s1 )

                ( Nothing, s1 ) ->
                    ( Engine.crashFailure (EngineBug ("destruct root not in varEnv: " ++ name)), s1 )

        TOpt.Index index hint subPath ->
            case specializePath subPath s0 of
                ( monoSubPath, s1 ) ->
                    let
                        i =
                            Index.toMachine index
                    in
                    case projIndexType (hintToProj hint) i (Mono.getMonoPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.MonoIndex i (hintToKind hint) resultType monoSubPath, s2 )

        TOpt.ArrayIndex idx subPath ->
            case specializePath subPath s0 of
                ( monoSubPath, s1 ) ->
                    case computeArrayElementType (Mono.getMonoPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.MonoIndex idx (Mono.CustomContainer "") resultType monoSubPath, s2 )

        TOpt.Field fieldName subPath ->
            case specializePath subPath s0 of
                ( monoSubPath, s1 ) ->
                    case Mono.getMonoPathType monoSubPath of
                        Mono.MRecord _ fields ->
                            case Dict.get fieldName fields of
                                Just t ->
                                    ( Mono.MonoField fieldName t monoSubPath, s1 )

                                Nothing ->
                                    ( Engine.crashFailure (EngineBug ("field not in record: " ++ fieldName)), s1 )

                        _ ->
                            ( Engine.crashFailure (EngineBug "field projection: container not Mono.mRecord"), s1 )

        TOpt.Unbox subPath ->
            case specializePath subPath s0 of
                ( monoSubPath, s1 ) ->
                    case computeUnboxResultType (Mono.getMonoPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.MonoUnbox resultType monoSubPath, s2 )



-- ====== PROJECTION-TYPE COMPUTATION ======


{-| The kind of container one indexed path step reads from: a list, a tuple,
or the named constructor of a custom type.
-}
type ProjKind
    = PList
    | PTuple
    | PCustom Name


{-| Returns the type at `index` of a container. For a list, index 0 is the
head, whose type is the element type, and any other index is the tail, whose
type is the list's. Aborts the build when the container does not match `kind`.
-}
projIndexType : ProjKind -> Int -> Mono.MonoType -> Step Mono.MonoType
projIndexType kind index container s0 =
    case kind of
        PList ->
            case container of
                Mono.MList _ elem ->
                    if index == 0 then
                        ( elem, s0 )

                    else
                        ( container, s0 )

                _ ->
                    ( Engine.crashFailure (EngineBug "list projection: container not Mono.mList"), s0 )

        PTuple ->
            case container of
                Mono.MTuple _ elems ->
                    case List.head (List.drop index elems) of
                        Just t ->
                            ( t, s0 )

                        Nothing ->
                            ( Engine.crashFailure (EngineBug "tuple projection: index out of range"), s0 )

                _ ->
                    ( Engine.crashFailure (EngineBug "tuple projection: container not Mono.mTuple"), s0 )

        PCustom ctorName ->
            computeCustomFieldType ctorName index container s0


{-| Returns the element type of an `Array` type, aborting the build for any
other type.
-}
computeArrayElementType : Mono.MonoType -> Step Mono.MonoType
computeArrayElementType container s0 =
    case container of
        Mono.MCustom _ _ "Array" [ elem ] ->
            ( elem, s0 )

        _ ->
            ( Engine.crashFailure (EngineBug "array projection: container not Array"), s0 )


{-| Returns the type of field `index` of constructor `ctorName`, with the
custom type's arguments substituted for its parameters. Aborts the build when
the container is not a custom type, or the type or field is not found.
-}
computeCustomFieldType : Name -> Int -> Mono.MonoType -> Step Mono.MonoType
computeCustomFieldType ctorName index container s0 =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion s0.env.globalTypeEnv home typeName of
                Just (Can.Union unionData) ->
                    case findCtorArg ctorName index unionData.alts of
                        Just canArgType ->
                            instantiateUnionType unionData.vars typeArgs canArgType s0

                        Nothing ->
                            ( Engine.crashFailure (EngineBug ("ctor field not found: " ++ ctorName ++ "@" ++ String.fromInt index)), s0 )

                Nothing ->
                    ( Engine.crashFailure (EngineBug ("union not found: " ++ typeName)), s0 )

        _ ->
            ( Engine.crashFailure (EngineBug "custom field projection: container not Mono.mCustom"), s0 )


{-| Returns the type of the single field of a custom type with one
constructor of one field, with the type's arguments substituted. Aborts the
build for any other type.
-}
computeUnboxResultType : Mono.MonoType -> Step Mono.MonoType
computeUnboxResultType container s0 =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion s0.env.globalTypeEnv home typeName of
                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor c ] ->
                            case c.args of
                                [ canArgType ] ->
                                    instantiateUnionType unionData.vars typeArgs canArgType s0

                                _ ->
                                    ( Engine.crashFailure (EngineBug "unbox: constructor is not single-arg"), s0 )

                        _ ->
                            ( Engine.crashFailure (EngineBug "unbox: type is not single-constructor"), s0 )

                Nothing ->
                    ( Engine.crashFailure (EngineBug ("unbox: union not found: " ++ typeName)), s0 )

        _ ->
            ( Engine.crashFailure (EngineBug "unbox: container not Mono.mCustom"), s0 )


{-| Returns the declared type of field `index` of the constructor named
`ctorName`.
-}
findCtorArg : Name -> Int -> List Can.Ctor -> Maybe (Can.Type Name)
findCtorArg ctorName index alts =
    case List.filter (\(Can.Ctor c) -> c.name == ctorName) alts of
        (Can.Ctor c) :: _ ->
            List.head (List.drop index c.args)

        [] ->
            Nothing


{-| Returns a constructor field's declared type with the custom type's
parameters, `vars`, replaced by the container's type arguments. Each parameter
gets a new variable id, and the type is converted with those ids bound to the
arguments.
-}
instantiateUnionType : List Name -> List Mono.MonoType -> Can.Type Name -> Step Mono.MonoType
instantiateUnionType vars typeArgs canArgType s0 =
    case allocFreshIds (List.length vars) s0 of
        ( ids, s1 ) ->
            let
                nameToId =
                    Dict.fromList (List.map2 Tuple.pair vars ids)

                subst =
                    Dict.fromList (List.map2 (\id t -> ( Id.toComparable id, t )) ids typeArgs)

                convertedArg =
                    Analysis.convertCanTypeNameToMVarId nameToId canArgType

                ( mt, intern1 ) =
                    Zonk.canTypeToMonoWithI s1.superTable subst convertedArg s1.intern
            in
            ( mt, { s1 | intern = intern1 } )


{-| Returns `n` new type variable ids.
-}
allocFreshIds : Int -> Step (List TypeIds.MVarId)
allocFreshIds n s0 =
    Engine.traverse (\_ -> allocFreshId) (List.repeat n ()) s0


{-| Returns a new type variable id from the engine's counter.
-}
allocFreshId : Step TypeIds.MVarId
allocFreshId =
    \s -> ( s.nextMVarId, { s | nextMVarId = Id.succ s.nextMVarId } )


{-| Returns the container kind a destructor path step's hint names.
-}
hintToKind : TOpt.ContainerHint -> Mono.ContainerKind
hintToKind hint =
    case hint of
        TOpt.HintList ->
            Mono.ListContainer

        TOpt.HintTuple2 ->
            Mono.Tuple2Container

        TOpt.HintTuple3 ->
            Mono.Tuple3Container

        TOpt.HintCustom name ->
            Mono.CustomContainer name


{-| Returns the projection a destructor path step's hint calls for.
-}
hintToProj : TOpt.ContainerHint -> ProjKind
hintToProj hint =
    case hint of
        TOpt.HintList ->
            PList

        TOpt.HintTuple2 ->
            PTuple

        TOpt.HintTuple3 ->
            PTuple

        TOpt.HintCustom name ->
            PCustom name


{-| Returns the container kind a decision-tree path step's hint names; an
unknown hint is a custom container with an empty name.
-}
dtHintToKind : TypedPath.ContainerHint -> Mono.ContainerKind
dtHintToKind hint =
    case hint of
        TypedPath.HintList ->
            Mono.ListContainer

        TypedPath.HintTuple2 ->
            Mono.Tuple2Container

        TypedPath.HintTuple3 ->
            Mono.Tuple3Container

        TypedPath.HintCustom name ->
            Mono.CustomContainer name

        TypedPath.HintUnknown ->
            Mono.CustomContainer ""


{-| Returns the projection a decision-tree path step's hint calls for; an
unknown hint is a custom constructor with an empty name.
-}
dtHintToProj : TypedPath.ContainerHint -> ProjKind
dtHintToProj hint =
    case hint of
        TypedPath.HintList ->
            PList

        TypedPath.HintTuple2 ->
            PTuple

        TypedPath.HintTuple3 ->
            PTuple

        TypedPath.HintCustom name ->
            PCustom name

        TypedPath.HintUnknown ->
            PCustom ""



-- ====== HELPERS ======


{-| Returns a global's type annotation, if the environment has one.
-}
lookupAnnotation : TOpt.Global -> Step (Maybe (Can.Annotation TypeIds.MVarId))
lookupAnnotation global s =
    ( DMap.get TOpt.toComparableGlobal global s.env.annotations, s )


{-| Converts a TypedOptimized global name to a monomorphized one.
-}
toptToMonoGlobal : TOpt.Global -> Mono.Global
toptToMonoGlobal (TOpt.Global home name) =
    Mono.Global home name


{-| Returns a label for an expression's form, used in the message of an
unsupported-expression failure.
-}
nodeKind : TOpt.Expr TypeIds.MVarId -> String
nodeKind expr =
    case expr of
        TOpt.Function _ _ _ _ ->
            "closure/lambda (M4)"

        TOpt.TrackedFunction _ _ _ _ ->
            "closure/lambda (M4)"

        TOpt.Case _ _ _ _ _ ->
            "case/decision-tree (M3)"

        TOpt.Accessor _ _ _ ->
            "accessor (M3)"

        TOpt.Destruct _ _ _ ->
            "destructure (M3)"

        TOpt.VarDebug _ _ _ _ _ ->
            "Debug reference (M6)"

        TOpt.VarCycle _ _ _ _ ->
            "cycle reference (M6)"

        TOpt.Shader _ _ _ _ ->
            "shader (M6)"

        _ ->
            "expression"
