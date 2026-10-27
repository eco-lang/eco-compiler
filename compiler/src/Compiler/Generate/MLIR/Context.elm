module Compiler.Generate.MLIR.Context exposing
    ( Context, FuncSignature, PendingLambda, TypeRegistry, VarInfo
    , initContext, withInlineBodies, withEcoConfig, withCtorBySpec, withMapTemplates
    , freshVar, freshOpId, lookupVar, addVarMapping, addDecoderExpr, ctxForSiblingRegion, ctxAfterBranchOp, resetDefinedSsaVars
    , getOrCreateTypeIdForMonoType, registerKernelCall
    , buildSignatures, kernelFuncSignatureFromType
    , hasKernelImplementation
    , KernelDeclInfo
    , registerKernelInstance
    , PsplitInfo, SlotPlan, SplitParamInfo, SplitSpec(..), SretInfo, residualResultType, withConstCtorBySpec, withConstThunkBySpec, withNullConsBySpec, withPsplitPromoted, withSretPromoted
    )

{-| MLIR code generation is a pure fold over each function's expression
tree, so every piece of state it needs travels in one record, the `Context`,
threaded through every generator. This module defines that record and the
operations that read and update it.

The state falls into four kinds.

  - Counters. `freshVar` and `freshOpId` hand out the next SSA variable name
    (`%N`) and operation id (`opN`) from a counter.
  - Lexical scope. `varMappings` maps an Elm name to the SSA variable that
    holds its value and that variable's MLIR type, and `definedSsaVars` is the
    set of SSA variables visible at the current point. MLIR regions scope SSA
    values: a value defined in one alternative of a branch is not visible in
    a sibling alternative, nor after the branch op. `ctxForSiblingRegion` and
    `ctxAfterBranchOp` carry the counters and accumulators forward across a
    branch while putting the scope back.
  - Accumulators. Lambdas and functions to emit later, the kernel
    declarations the module will need, the eco/system effect managers
    reached, and the debug type graph, all collected as code is generated.
  - Tables installed once at codegen entry and only read afterwards: the
    function signatures, the inlinable bodies, the constructor shapes, the
    three constant maps, the `$sret` and `$psplit` promotions, the project
    configuration and the `List.map` templates. The signature table is
    passed to `initContext`; the others start empty (or at their default)
    and a `with*` function installs each.

A _signature table_ is an `Array` indexed by SpecId, holding the parameter and
result types of each callable node; `buildSignatures` makes it.

A _kernel declaration_ is the `func.func private` that the emitted module
needs for every kernel symbol it calls. Each symbol has exactly one ABI: a
second registration with different argument or result types crashes the
compile.

The debug type graph gives every `MonoType` printed by `eco.dbg` a numeric
TypeId; `getOrCreateTypeIdForMonoType` registers the types reached from a
type before the type itself.


# Types

@docs Context, FuncSignature, PendingLambda, TypeRegistry, VarInfo


# Building a context

@docs initContext, withInlineBodies, withEcoConfig, withCtorBySpec, withMapTemplates


# Names and scope

@docs freshVar, freshOpId, lookupVar, addVarMapping, addDecoderExpr, ctxForSiblingRegion, ctxAfterBranchOp, resetDefinedSsaVars


# Type graph and kernel calls

@docs getOrCreateTypeIdForMonoType, registerKernelCall


# Signatures

@docs buildSignatures, kernelFuncSignatureFromType


# Kernel fallback

@docs hasKernelImplementation


# Kernel declarations

@docs KernelDeclInfo


# Kernel instances

@docs registerKernelInstance


# Promotions and constant tables

@docs PsplitInfo, SlotPlan, SplitParamInfo, SplitSpec, SretInfo, residualResultType, withConstCtorBySpec, withConstThunkBySpec, withNullConsBySpec, withPsplitPromoted, withSretPromoted

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Eco.Config as Config
import Compiler.Generate.MLIR.KernelAbi as KernelAbi
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.Mode as Mode
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Compiler.GlobalOpt.MapTemplate as MapTemplate
import Dict
import Mlir.Mlir exposing (MlirOp, MlirType)
import Set
import Utils.Crash exposing (crash)



-- ====== CONTEXT ======


{-| The parameter and result types of one callable node, as code generation
sees it.

`returnType` is what a call that supplies all of `paramTypes` returns, which
for a staged definition is itself a function type (see `residualResultType`).
A definition or port whose body is not a closure or tail-recursive
function, and an enum, has no parameters. `evaluatorBoxesAll` is `True`
only for externs and effect-manager leaves, whose closure evaluator takes
every parameter as `!eco.value`.

-}
type alias FuncSignature =
    { paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    , evaluatorBoxesAll : Bool
    }


{-| A tuple or constructor value held as one SSA variable per field rather
than as one boxed value, a _scalar-split_ value.

`slots` are the SSA variables holding the fields in layout order, each with
its MLIR type: an unboxed primitive or an `!eco.value`, as the layout stores
that field. `split` says how the fields map back onto the boxed value.

-}
type alias SplitParamInfo =
    { slots : List ( String, MlirType )
    , split : SplitSpec
    }


{-| How a boxed value is split into scalar slots.

`SplitTuple` splits a tuple and `SplitCtor` a constructor; each carries the
layout that places the fields.

-}
type SplitSpec
    = SplitTuple Types.TupleLayout
    | SplitCtor Types.CtorLayout


{-| The result promotion of one function that has a `$sret` worker: a
version of the function that returns each field of its tuple result as a
separate result instead of one boxed tuple.

`slotTypes` are the MLIR types of those results, in the order of `layout`.

-}
type alias SretInfo =
    { layout : Types.TupleLayout
    , slotTypes : List MlirType
    }


{-| Returns the context with the `$sret` result promotions installed, keyed
by SpecId.
-}
withSretPromoted : Dict.Dict Int SretInfo -> Context -> Context
withSretPromoted d ctx =
    { ctx | sretPromoted = d }


{-| The parameter promotion of one function that has a `$psplit` worker: a
version of the function that takes some boxed parameters as their fields.

`paramPlans` has one entry per parameter of the original function, in order;
`Nothing` means that parameter is passed as it is.

-}
type alias PsplitInfo =
    { paramPlans : List (Maybe SlotPlan)
    }


{-| The plan for one promoted parameter of a `$psplit` worker: how the boxed
value is split, and the MLIR type of each slot it becomes.
-}
type alias SlotPlan =
    { spec : SplitSpec
    , slotTypes : List MlirType
    }


{-| Returns the context with the `$psplit` parameter promotions installed,
keyed by SpecId.
-}
withPsplitPromoted : Dict.Dict Int PsplitInfo -> Context -> Context
withPsplitPromoted d ctx =
    { ctx | psplitPromoted = d }


{-| Returns the signature of a kernel function of type `funcType`: every
arrow flattened into one parameter list, and the final result type.
-}
kernelFuncSignatureFromType : Mono.MonoType -> FuncSignature
kernelFuncSignatureFromType funcType =
    let
        ( argTypes, retType ) =
            Mono.decomposeFunctionType funcType
    in
    { paramTypes = argTypes
    , returnType = retType
    , evaluatorBoxesAll = False
    }


{-| Whether a core function whose intrinsic did not match may fall back to
calling its kernel implementation. It is `False`: no such fallback is taken.
-}
hasKernelImplementation : Bool
hasKernelImplementation =
    False


{-| The SSA variable that holds a name's value, and that variable's MLIR
type.
-}
type alias VarInfo =
    { ssaVar : String
    , mlirType : MlirType
    }


{-| The state threaded through code generation; the module docstring
describes its four kinds of field.

Several fields mean more than their names say. `signatures` is the signature
table. `currentLetSiblings` maps the names bound by the let chain being
generated to their placeholder SSA variables, so that its bindings can refer
to one another. `fwdRefdLetNames` holds the names of that chain referred to
by an earlier binding of it; it is computed only when the chain holds a tuple
or constructor that could be promoted, and is empty otherwise.
`tailRecLetBody` is the real loop body while the lets of a tail-recursive
step are generated, and `Nothing` otherwise. `splitAggParams` holds the
scalar-split values in scope, by name: tail-loop parameters, `$psplit`
worker parameters and promoted let bindings. `sretTailLayout` is set only
while the result of a `$sret` worker's body is generated.

The three constant maps, `nullConsBySpec`, `constCtorBySpec` and
`constThunkBySpec`, let a reference to an arity-0 spec emit its constant
value, or the thunk's body, in place of a call; the spec's own function is
still emitted. `nullConsBySpec` gives the tag of a nullary constructor or
enum that is a null-cons constant, and `constCtorBySpec` the name of a
nullary constructor that is a well-known constant such as `Nothing`.

An absent entry in `mapTemplates` means the `List.map` spec has no licence
for the template; the table is empty when the `list.mapTemplate` setting is
off.

-}
type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , pendingFuncOps : List MlirOp
    , signatures : Array (Maybe FuncSignature)
    , varMappings : Dict.Dict String VarInfo
    , currentLetSiblings : Dict.Dict String VarInfo
    , kernelDecls : Dict.Dict String KernelDeclInfo -- by symbol name
    , ecoSystemManagers : Set.Set String -- home modules of the eco/system effect-manager leaves reached
    , typeRegistry : TypeRegistry
    , decoderExprs : Dict.Dict String Mono.MonoExpr -- let-bound expressions, by name, for decoder fusion
    , currentFuncName : String -- for crash messages only
    , localEvaluatorParams : Dict.Dict String (List MlirType) -- a local naming a known function -> its evaluator\'s parameter types
    , definedSsaVars : Set.Set String
    , inlineBodies : Dict.Dict Int ( List ( Name.Name, Mono.MonoType ), Mono.MonoExpr )
    , ctorBySpec : Dict.Dict Int Mono.CtorShape
    , nullConsBySpec : Dict.Dict Int Int
    , constThunkBySpec : Dict.Dict Int Mono.MonoExpr
    , constCtorBySpec : Dict.Dict Int String
    , fwdRefdLetNames : Set.Set String
    , tailRecLetBody : Maybe Mono.MonoExpr
    , splitAggParams : Dict.Dict String SplitParamInfo
    , sretPromoted : Dict.Dict Int SretInfo
    , psplitPromoted : Dict.Dict Int PsplitInfo
    , sretTailLayout : Maybe Types.TupleLayout
    , ecoConfig : Config.EcoConfig
    , mapTemplates : MapTemplate.Templates
    }


{-| The debug type graph built so far: a TypeId for every registered
`MonoType`, as `eco.dbg` uses for typed printing.

`typeInfos` lists the registered types newest first. `ctorShapes` gives the
constructors of each custom type, so that their field types are registered
too.

-}
type alias TypeRegistry =
    { nextTypeId : Int
    , typeIds : Mono.LayoutMap Int
    , typeInfos : List ( Int, Mono.MonoType )
    , ctorShapes : Mono.LayoutMap (List Mono.CtorShape)
    }


{-| A lambda whose body is to be generated later as a function of its own.

`siblingMappings` are the let-bound names of the enclosing let chain the body
may refer to. `selfBindingName` is the Elm name by which a local
tail-recursive function refers to itself.

-}
type alias PendingLambda =
    { name : String
    , captures : List ( Name.Name, Mono.MonoType )
    , params : List ( Name.Name, Mono.MonoType )
    , body : Mono.MonoExpr
    , returnType : Mono.MonoType
    , siblingMappings : Dict.Dict String VarInfo
    , isTailRecursive : Bool
    , selfBindingName : Maybe String
    }


{-| Creates a context with zeroed counters, empty scope and accumulators, the
given signature table, and the given constructor shapes in its type graph.
Every other table is empty, `ecoConfig` is `Config.default` and
`mapTemplates` is `MapTemplate.empty`, until a `with*` function installs it.
-}
initContext : Mode.Mode -> Mono.SpecializationRegistry -> Array (Maybe FuncSignature) -> Mono.LayoutMap (List Mono.CtorShape) -> Context
initContext mode registry signatures initialCtorShapes =
    { nextVar = 0
    , nextOpId = 0
    , mode = mode
    , registry = registry
    , pendingLambdas = []
    , pendingFuncOps = []
    , signatures = signatures
    , varMappings = Dict.empty
    , currentLetSiblings = Dict.empty
    , kernelDecls = Dict.empty
    , ecoSystemManagers = Set.empty
    , typeRegistry =
        { emptyTypeRegistry
            | ctorShapes = initialCtorShapes
        }
    , decoderExprs = Dict.empty
    , currentFuncName = ""
    , localEvaluatorParams = Dict.empty
    , definedSsaVars = Set.empty
    , inlineBodies = Dict.empty
    , ctorBySpec = Dict.empty
    , nullConsBySpec = Dict.empty
    , constCtorBySpec = Dict.empty
    , constThunkBySpec = Dict.empty
    , fwdRefdLetNames = Set.empty
    , tailRecLetBody = Nothing
    , splitAggParams = Dict.empty
    , sretPromoted = Dict.empty
    , psplitPromoted = Dict.empty
    , sretTailLayout = Nothing
    , ecoConfig = Config.default
    , mapTemplates = MapTemplate.empty
    }


{-| Returns the context with the table of inlinable function bodies
installed: for each SpecId, the parameters and body of the function. Bytes
encoder fusion reads it to see into the functions an encoder calls.
-}
withInlineBodies : Dict.Dict Int ( List ( Name.Name, Mono.MonoType ), Mono.MonoExpr ) -> Context -> Context
withInlineBodies bodies ctx =
    { ctx | inlineBodies = bodies }


{-| Returns the context with the constructor shape of each constructor spec
installed, keyed by SpecId.
-}
withCtorBySpec : Dict.Dict Int Mono.CtorShape -> Context -> Context
withCtorBySpec d ctx =
    { ctx | ctorBySpec = d }


{-| Returns the context with the null-cons constant map installed: for each
nullary constructor or enum spec that is a null-cons constant, its tag.
-}
withNullConsBySpec : Dict.Dict Int Int -> Context -> Context
withNullConsBySpec d ctx =
    { ctx | nullConsBySpec = d }


{-| Returns the context with the well-known constant map installed: for each
nullary constructor spec that is a well-known constant, its constructor name.
-}
withConstCtorBySpec : Dict.Dict Int String -> Context -> Context
withConstCtorBySpec d ctx =
    { ctx | constCtorBySpec = d }


{-| Returns the context with the constant-thunk map installed: for each
arity-0 spec admitted as a constant thunk, its body.
-}
withConstThunkBySpec : Dict.Dict Int Mono.MonoExpr -> Context -> Context
withConstThunkBySpec d ctx =
    { ctx | constThunkBySpec = d }


{-| Returns the context with the project configuration installed.
-}
withEcoConfig : Config.EcoConfig -> Context -> Context
withEcoConfig cfg ctx =
    { ctx | ecoConfig = cfg }


{-| Returns the context with the `List.map` template table installed.
-}
withMapTemplates : MapTemplate.Templates -> Context -> Context
withMapTemplates t ctx =
    { ctx | mapTemplates = t }


{-| The type graph with no types registered and TypeIds starting at 0.
-}
emptyTypeRegistry : TypeRegistry
emptyTypeRegistry =
    { nextTypeId = 0
    , typeIds = Mono.layoutMapEmpty
    , typeInfos = []
    , ctorShapes = Mono.layoutMapEmpty
    }


{-| Returns the TypeId of `monoType`, registering it first if it is new.

Registering a type registers the new types reached from it first, so they
get smaller TypeIds than it does. The nested types of a custom
type are its type arguments and its constructors' field types, leaving out a
field of the custom type itself. The types are explored with an explicit
worklist rather than by recursion, so a deeply nested type does not
overflow the stack.

-}
getOrCreateTypeIdForMonoType : Mono.MonoType -> Context -> ( Int, Context )
getOrCreateTypeIdForMonoType monoType ctx =
    let
        getNestedTypes : Mono.MonoType -> Context -> List Mono.MonoType
        getNestedTypes mt c =
            case mt of
                Mono.MList _ elemType ->
                    [ elemType ]

                Mono.MTuple _ elementTypes ->
                    elementTypes

                Mono.MRecord _ fields ->
                    Dict.values fields

                Mono.MCustom _ _ _ args ->
                    let
                        ctorShapesForType =
                            Mono.layoutMapGet mt c.typeRegistry.ctorShapes
                                |> Maybe.withDefault []

                        fieldTypes =
                            List.concatMap .fieldTypes ctorShapesForType
                                |> List.filter
                                    (\ft ->
                                        not (Mono.eqKeyLayout ft mt)
                                    )
                    in
                    args ++ fieldTypes

                Mono.MFunction _ _ argTypes resultType ->
                    argTypes ++ [ resultType ]

                Mono.MInt ->
                    []

                Mono.MFloat ->
                    []

                Mono.MChar ->
                    []

                Mono.MBool ->
                    []

                Mono.MString ->
                    []

                Mono.MUnit ->
                    []

                Mono.MVar _ _ ->
                    []

        registerSingleType : Mono.MonoType -> Context -> Context
        registerSingleType mt c =
            let
                reg =
                    c.typeRegistry
            in
            case Mono.layoutMapGet mt reg.typeIds of
                Just _ ->
                    c

                Nothing ->
                    let
                        typeId =
                            reg.nextTypeId

                        newReg =
                            { nextTypeId = typeId + 1
                            , typeIds = Mono.layoutMapInsert mt typeId reg.typeIds
                            , typeInfos = ( typeId, mt ) :: reg.typeInfos
                            , ctorShapes = reg.ctorShapes
                            }
                    in
                    { c | typeRegistry = newReg }

        -- toRegister is in reverse discovery order, so a fold registers the
        -- starting type last; queued is the set of types already in it.
        processWorklist : List Mono.MonoType -> List Mono.MonoType -> Mono.LayoutMap () -> Context -> Context
        processWorklist pending toRegister queued c =
            case pending of
                [] ->
                    List.foldl registerSingleType c toRegister

                current :: rest ->
                    if Mono.layoutMapMember current c.typeRegistry.typeIds then
                        processWorklist rest toRegister queued c

                    else if Mono.layoutMapMember current queued then
                        processWorklist rest toRegister queued c

                    else
                        let
                            nested =
                                getNestedTypes current c
                        in
                        processWorklist (nested ++ rest)
                            (current :: toRegister)
                            (Mono.layoutMapInsert current () queued)
                            c
    in
    case Mono.layoutMapGet monoType ctx.typeRegistry.typeIds of
        Just typeId ->
            ( typeId, ctx )

        Nothing ->
            let
                finalCtx =
                    processWorklist [ monoType ] [] Mono.layoutMapEmpty ctx
            in
            case Mono.layoutMapGet monoType finalCtx.typeRegistry.typeIds of
                Just typeId ->
                    ( typeId, finalCtx )

                Nothing ->
                    -- Unreachable: processWorklist registers monoType.
                    ( 0, finalCtx )


{-| Returns the context in which to generate the next alternative region of
a branch op: `afterPrevious`, the context after the previous alternative,
with `varMappings`, `localEvaluatorParams` and `definedSsaVars` taken from
`base`, the context before the branch op.
-}
ctxForSiblingRegion : Context -> Context -> Context
ctxForSiblingRegion base afterPrevious =
    { afterPrevious
        | varMappings = base.varMappings
        , localEvaluatorParams = base.localEvaluatorParams
        , definedSsaVars = base.definedSsaVars
    }


{-| Returns the context in which to continue after a branch op: `afterBranch`,
the context after its last alternative, with `varMappings` taken from `base`,
the context before the op, and `definedSsaVars` set to that of `base` plus
`resultVars`, the op's results. `localEvaluatorParams` is left as
`afterBranch` has it.
-}
ctxAfterBranchOp : Context -> Context -> List String -> Context
ctxAfterBranchOp base afterBranch resultVars =
    { afterBranch
        | varMappings = base.varMappings
        , definedSsaVars = List.foldl Set.insert base.definedSsaVars resultVars
    }


{-| Returns a new SSA variable name, and the context with it counted and
recorded in `definedSsaVars`.
-}
freshVar : Context -> ( String, Context )
freshVar ctx =
    let
        varName =
            "%" ++ String.fromInt ctx.nextVar
    in
    ( varName
    , { ctx | nextVar = ctx.nextVar + 1, definedSsaVars = Set.insert varName ctx.definedSsaVars }
    )


{-| Returns a new operation id, and the context with it counted.
-}
freshOpId : Context -> ( String, Context )
freshOpId ctx =
    ( "op" ++ String.fromInt ctx.nextOpId
    , { ctx | nextOpId = ctx.nextOpId + 1 }
    )


{-| Returns the SSA variable bound to `name` in `varMappings`, and its MLIR
type. Crashes the compile if `name` is not bound, naming the function being
generated.
-}
lookupVar : Context -> String -> ( String, MlirType )
lookupVar ctx name =
    case Dict.get name ctx.varMappings of
        Just info ->
            ( info.ssaVar, info.mlirType )

        Nothing ->
            crash
                ("lookupVar: unbound variable "
                    ++ name
                    ++ " [in "
                    ++ ctx.currentFuncName
                    ++ "; in-scope mono_inline: "
                    ++ String.join "," (List.filter (String.startsWith "mono_inline") (Dict.keys ctx.varMappings))
                    ++ "]"
                )


{-| Returns the context with `name` bound to `ssaVar` of type `mlirTy`, and
`ssaVar` recorded in `definedSsaVars`.
-}
addVarMapping : String -> String -> MlirType -> Context -> Context
addVarMapping name ssaVar mlirTy ctx =
    let
        info : VarInfo
        info =
            { ssaVar = ssaVar
            , mlirType = mlirTy
            }
    in
    { ctx | varMappings = Dict.insert name info ctx.varMappings, definedSsaVars = Set.insert ssaVar ctx.definedSsaVars }


{-| Returns the context with `definedSsaVars` set to exactly `initialVars`, as
at the start of a new function.
-}
resetDefinedSsaVars : List String -> Context -> Context
resetDefinedSsaVars initialVars ctx =
    { ctx | definedSsaVars = Set.fromList initialVars }


{-| Returns the context with `expr` recorded as the expression bound to
`name`, so that bytes decoder fusion can see through a variable to the
decoder it names.
-}
addDecoderExpr : String -> Mono.MonoExpr -> Context -> Context
addDecoderExpr name expr ctx =
    { ctx | decoderExprs = Dict.insert name expr ctx.decoderExprs }



-- ======= KERNEL DECLARATION TRACKING


{-| The declaration recorded for one kernel symbol: its ABI argument and
result types, and whether it is a gc-leaf.

`gcLeaf` is `True` only when some registration through
`registerKernelInstance` found the kernel's row in `KernelFacts` and the row
is `gcLeafEligible`; it is `False` for a kernel with no row and for one
registered only through `registerKernelCall`. Some instance symbols carry an
`_Int`, `_Float` or `_Char` suffix, so the row is looked up from the instance
key, not the symbol name.

-}
type alias KernelDeclInfo =
    { symbolName : String
    , abiArgTypes : List MlirType
    , abiResultType : MlirType
    , gcLeaf : Bool
    }


{-| Returns the context with kernel symbol `name` recorded as a declaration
whose ABI is the call site's own MLIR types, and with `gcLeaf` false.

Crashes the compile if `name` is already recorded with different argument or
result types.

-}
registerKernelCall : Context -> String -> List MlirType -> MlirType -> Context
registerKernelCall ctx name callSiteArgTypes callSiteReturnType =
    insertKernelDecl ctx
        { symbolName = name
        , abiArgTypes = callSiteArgTypes
        , abiResultType = callSiteReturnType
        , gcLeaf = False
        }


{-| Returns the ABI that `KernelAbi.deriveKernelInstanceAbi` gives the kernel
instance `key`, and the context with its declaration recorded. The
declaration is a gc-leaf when the kernel's `KernelFacts` row is
`gcLeafEligible`.

Crashes the compile if the symbol is already recorded with different
argument or result types.

-}
registerKernelInstance : KernelAbi.KernelInstanceKey -> Context -> ( KernelAbi.KernelInstanceAbi, Context )
registerKernelInstance key ctx =
    let
        abi : KernelAbi.KernelInstanceAbi
        abi =
            KernelAbi.deriveKernelInstanceAbi key

        info : KernelDeclInfo
        info =
            { symbolName = abi.symbolName
            , abiArgTypes = abi.abiArgTypes
            , abiResultType = abi.abiResultType
            , gcLeaf =
                KernelFacts.lookup ( key.prefix, key.home, key.name )
                    |> Maybe.map KernelFacts.gcLeafEligible
                    |> Maybe.withDefault False
            }
    in
    ( abi, insertKernelDecl ctx info )


{-| Returns the context with `info` recorded for its symbol. When the symbol is
already recorded with the same types, the entry is kept and becomes a
gc-leaf if `info` is one; with different types, the compile crashes.
-}
insertKernelDecl : Context -> KernelDeclInfo -> Context
insertKernelDecl ctx info =
    case Dict.get info.symbolName ctx.kernelDecls of
        Nothing ->
            { ctx | kernelDecls = Dict.insert info.symbolName info ctx.kernelDecls }

        Just existing ->
            if existing.abiArgTypes == info.abiArgTypes && existing.abiResultType == info.abiResultType then
                if info.gcLeaf && not existing.gcLeaf then
                    { ctx | kernelDecls = Dict.insert info.symbolName { existing | gcLeaf = True } ctx.kernelDecls }

                else
                    ctx

            else
                let
                    showTypes ts =
                        ts |> List.map Types.mlirTypeToString |> String.join ", "
                in
                crash
                    ("Kernel signature mismatch for "
                        ++ info.symbolName
                        ++ ": existing ("
                        ++ showTypes existing.abiArgTypes
                        ++ " -> "
                        ++ Types.mlirTypeToString existing.abiResultType
                        ++ ") vs new ("
                        ++ showTypes info.abiArgTypes
                        ++ " -> "
                        ++ Types.mlirTypeToString info.abiResultType
                        ++ ") [in "
                        ++ ctx.currentFuncName
                        ++ "]"
                    )



-- ====== SIGNATURE EXTRACTION


{-| Returns what a function of type `monoType` returns once given its first
`numParams` arguments.

A _staged_ definition takes fewer parameters than its type has arrows:
`mk : Int -> Int -> Int` defined as `mk a = \b -> ...` has one parameter, and
returns `Int -> Int`. The arguments beyond `numParams` therefore stay in the
result as a function type. With `numParams` at least the number of arguments,
or a `monoType` that is not a function, the result is the final result type.

-}
residualResultType : Int -> Mono.MonoType -> Mono.MonoType
residualResultType numParams monoType =
    let
        ( allArgTypes, finalLeaf ) =
            Mono.decomposeFunctionType monoType
    in
    if List.length allArgTypes > numParams then
        -- The rebuilt function type keeps the outer arrow's annotation.
        case monoType of
            Mono.MFunction _ anno _ _ ->
                Mono.mFunction anno (List.drop numParams allArgTypes) finalLeaf

            _ ->
                finalLeaf

    else
        finalLeaf


{-| Returns the signature of `node`, or `Nothing` for an extern or
effect-manager leaf whose type is not a function.

A closure or tail-recursive function takes its own parameters, and its
result is the residual result type. Any other definition or port, and an
enum, has no parameters; a constructor's parameters are its field types; an
extern or manager leaf of function type takes all its arrows as parameters.

-}
extractNodeSignature : Mono.MonoNode -> Maybe FuncSignature
extractNodeSignature node =
    case node of
        Mono.MonoDefine expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = residualResultType (List.length closureInfo.params) monoType
                        , evaluatorBoxesAll = False
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , evaluatorBoxesAll = False
                        }

        Mono.MonoTailFunc params _ monoType ->
            let
                returnType =
                    residualResultType (List.length params) monoType
            in
            Just
                { paramTypes = List.map Tuple.second params
                , returnType = returnType
                , evaluatorBoxesAll = False
                }

        Mono.MonoCtor ctorShape monoType ->
            Just
                { paramTypes = ctorShape.fieldTypes
                , returnType = monoType
                , evaluatorBoxesAll = False
                }

        Mono.MonoEnum _ monoType ->
            Just
                { paramTypes = []
                , returnType = monoType
                , evaluatorBoxesAll = False
                }

        Mono.MonoExtern monoType ->
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    let
                        ( argMonoTypes, resultMonoType ) =
                            Mono.decomposeFunctionType monoType
                    in
                    Just
                        { paramTypes = argMonoTypes
                        , returnType = resultMonoType
                        , evaluatorBoxesAll = True
                        }

                _ ->
                    Nothing

        Mono.MonoManagerLeaf _ monoType ->
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    let
                        ( argMonoTypes, resultMonoType ) =
                            Mono.decomposeFunctionType monoType
                    in
                    Just
                        { paramTypes = argMonoTypes
                        , returnType = resultMonoType
                        , evaluatorBoxesAll = True
                        }

                _ ->
                    Nothing

        Mono.MonoPortIncoming expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = residualResultType (List.length closureInfo.params) monoType
                        , evaluatorBoxesAll = False
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , evaluatorBoxesAll = False
                        }

        Mono.MonoPortOutgoing expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = residualResultType (List.length closureInfo.params) monoType
                        , evaluatorBoxesAll = False
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , evaluatorBoxesAll = False
                        }


{-| Returns the signature table for `nodes`, indexed like it: `Nothing` for
an absent node and for a node with no signature.
-}
buildSignatures : Array (Maybe Mono.MonoNode) -> Array (Maybe FuncSignature)
buildSignatures nodes =
    Array.map
        (\maybeNode ->
            maybeNode |> Maybe.andThen extractNodeSignature
        )
        nodes
