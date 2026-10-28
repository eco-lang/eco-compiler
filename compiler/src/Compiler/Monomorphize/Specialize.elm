module Compiler.Monomorphize.Specialize exposing (specializeNode)

{-| Monomorphization makes one copy of each polymorphic global for every
concrete type it is used at, and this module makes one such copy: it turns one
node of the typed optimized graph, requested at one MonoType, into a
monomorphized node.

To specialize a node is to walk its body under a _substitution_, a map from the
type variables of its canonical types to MonoTypes (`Compiler.Monomorphize.TypeSubst`
owns the unification and application rules), starting from the node's type
unified with the requested type. Canonical types in the body are replaced by
their MonoTypes under the substitution. Every global the body refers to, at the
type it is used at there, is put on the worklist as a specialization of its own
(`Compiler.Monomorphize.State` describes the worklist) rather than specialized
here. The exception is a recursive group: all its members are specialized
together, under one shared substitution. A number variable left open stays open;
this module never defaults it to `Int`.

Most of the file follows from one fact: a type is often known only from how a
value is used, not from the value itself. A _demand_ is the MonoType a consumer
requires of an expression, such as a callee's parameter type, the type of the
conditional a branch belongs to, or a record field's type. Three mechanisms
carry demands back to the expressions that need them.

Some call arguments (field accessors, references to copied `let` definitions,
and global references or calls whose type is still open) are held back until
unifying the callee with all the arguments gives each parameter's type, and are
then specialized against it. A conditional's type, when it has no variables,
is pushed onto each branch before the branch is specialized.

Local definitions can be polymorphic too, and are copied per demand. A
let-bound function is copied once per type its body uses it at, and a let-bound
value that is not a function, but whose type contains a function and a free
type variable, once per type it is demanded at. In both cases the body is
specialized first, with the definition on a stack in the state (`localMulti` or
`valueMulti`); each use records the copy it needs, and one definition per
recorded copy is emitted afterwards. A copied value whose type has a number
variable is a _number-multi target_: each numeric demand on it records its own
copy. A value whose type is numbers in tuples, records, lists or custom types
becomes one even when it holds no function; it is
specialized eagerly with the number left open, and every other numeric demand
adds a copy. Destructuring a copied value chooses a copy through a _partial
container_, a type for the whole value that is known only at the destructured
position.

Types stay curried: a lambda `\x y -> e` becomes a closure of two parameters
whose type is a function returning a function. Nothing here makes the two
agree. A reference to a kernel gets its ABI type, the type that decides which
of its arguments are boxed (`Compiler.Monomorphize.KernelAbi`), which can
differ from the type it is used at.

`specializeNode` is the only export. It reads the global being specialized
from the state's current global, which the caller sets.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.AST.Intern exposing (Intern)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds exposing (MVarId)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Id as Id
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.State as State exposing (LocalMultiState, MVarEnv, MonoState, SchemeInfo, Substitution, ValueMultiState, VarEnv, WorkItem(..))
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set as EverySet
import Dict
import Set
import Utils.Crash



-- ========== INTERNAL TYPES ==========


{-| An argument of a call, either already specialized or held back until the
callee's parameter types are known.

Some arguments cannot be specialized from their own types: those types are
still open, and only unifying the callee with all the arguments says what the
argument must be. Such an argument is held back, and the type it contributes
to that unification is its own type under the caller's substitution. Once the
callee's parameter type at this position is known, the argument is specialized
against it.

`ResolvedArg` is an argument specialized straight away.

`PendingAccessor` is a field accessor (`.name`). It becomes the accessor global
at the record type taken from the parameter type, not from its own type.

`PendingExpr` is a reference to a global or a nested call whose type under the
caller's substitution still has variables. It carries that substitution and
its canonical type; the parameter type is unified into the substitution before
the expression is specialized.

`LocalFunArg` is a reference to a let-bound function being copied once per use
type. When the parameter type is a function, the copy at that type is used.

`PendingNumberValue` is a reference to a number-multi binding. The parameter
type is the demand, and the copy at that type is recorded and used.

-}
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name (Can.Type MVarId)
    | PendingExpr (TOpt.Expr MVarId) Substitution (Can.Type MVarId)
    | LocalFunArg Name (Can.Type MVarId)
    | PendingNumberValue Name (Can.Type MVarId)



-- ========== SCHEME INFO ==========


{-| Returns the scheme of a callee whose type is `funcCanType`, with every
variable given a fresh id, so that bindings made at this call site reach no
other.

For a global the scheme is built once from the global's annotation, cached in
`accum.schemeCache`, and refreshed with fresh ids on every later use; a global
with no annotation entry crashes. For `Nothing` (a local or anonymous callee)
the scheme is built from `funcCanType` and not cached.

-}
getOrBuildSchemeInfo : Can.Type MVarId -> Maybe TOpt.Global -> MonoState -> ( SchemeInfo, MonoState )
getOrBuildSchemeInfo funcCanType maybeGlobal state =
    case maybeGlobal of
        Just global ->
            let
                accum =
                    state.accum
            in
            case Data.Map.get TOpt.toComparableGlobal global accum.schemeCache of
                Just cachedInfo ->
                    -- Without fresh ids, Just Float from one call site of Maybe.map
                    -- would leak into Just Bool at another.
                    let
                        ( info, mvarEnv1 ) =
                            TypeSubst.refreshSchemeInfo state.ctx.mvarEnv cachedInfo

                        ctx1 =
                            let
                                ctx =
                                    state.ctx
                            in
                            { ctx | mvarEnv = mvarEnv1 }
                    in
                    ( info, { state | ctx = ctx1 } )

                Nothing ->
                    let
                        canonicalCanTypeForScheme : Can.Type MVarId
                        canonicalCanTypeForScheme =
                            case Data.Map.get TOpt.toComparableGlobal global state.ctx.annotations of
                                Just (Can.Forall _ annType) ->
                                    annType

                                Nothing ->
                                    Utils.Crash.crash ("getOrBuildSchemeInfo: no annotation entry for global " ++ TOpt.toComparableGlobal global)

                        ( info, mvarEnv1 ) =
                            TypeSubst.buildSchemeInfo state.ctx.mvarEnv canonicalCanTypeForScheme

                        newCache =
                            Data.Map.insert TOpt.toComparableGlobal global info accum.schemeCache

                        ctx1 =
                            let
                                ctx =
                                    state.ctx
                            in
                            { ctx | mvarEnv = mvarEnv1 }
                    in
                    ( info, { state | accum = { accum | schemeCache = newCache }, ctx = ctx1 } )

        Nothing ->
            let
                ( info, mvarEnv1 ) =
                    TypeSubst.buildSchemeInfo state.ctx.mvarEnv funcCanType

                ctx1 =
                    let
                        ctx =
                            state.ctx
                    in
                    { ctx | mvarEnv = mvarEnv1 }
            in
            ( info, { state | ctx = ctx1 } )



-- ========== FREEVARS HELPERS ==========


{-| Returns whether `global` has an annotation entry whose `Can.Forall`
generalizes no type variable. A global with no annotation entry is not
monomorphic by this test.
-}
isMonomorphicGlobal : TOpt.Global -> MonoState -> Bool
isMonomorphicGlobal global state =
    case Data.Map.get TOpt.toComparableGlobal global state.ctx.annotations of
        Just (Can.Forall freeVars _) ->
            Dict.isEmpty freeVars

        Nothing ->
            False


{-| Returns the MonoType `canType` becomes under `subst`, as
`TypeSubst.applySubstFiltered` describes, reading the state's `MVarEnv`.

The returned state carries the grown hash-consing table (`accum.intern`).
Dropping it loses only sharing, not correctness.

-}
applySubstFV : MonoState -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MonoState )
applySubstFV state subst canType =
    applySubstFVWithEnv state.ctx.mvarEnv state subst canType


{-| Returns what `applySubstFV` returns, but reads `mvarEnv` instead of the
state's own `MVarEnv`, while still threading the state's hash-consing table.
-}
applySubstFVWithEnv : MVarEnv -> MonoState -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MonoState )
applySubstFVWithEnv mvarEnv state subst canType =
    let
        accum =
            state.accum

        ( monoType, intern1 ) =
            TypeSubst.applySubstFiltered mvarEnv subst canType accum.intern
    in
    ( monoType, { state | accum = { accum | intern = intern1 } } )


{-| Returns whether `to` is a more concrete version of `from`: `from` is a
variable and `to` is not, or `recordWidened` holds.
-}
isMoreConcrete : Mono.MonoType -> Mono.MonoType -> Bool
isMoreConcrete from to =
    case ( from, to ) of
        ( Mono.MVar _ _, Mono.MVar _ _ ) ->
            False

        ( Mono.MVar _ _, _ ) ->
            True

        _ ->
            recordWidened from to


{-| Returns whether `to` has a record with strictly more fields than the
record at the same position in `from`, including all of `from`'s field names.
Function and tuple types are compared position by position when their arities
match; any one position widening is enough.
-}
recordWidened : Mono.MonoType -> Mono.MonoType -> Bool
recordWidened from to =
    case ( from, to ) of
        ( Mono.MRecord _ fromFields, Mono.MRecord _ toFields ) ->
            let
                fromKeys =
                    Dict.keys fromFields

                toKeys =
                    Dict.keys toFields
            in
            List.length toKeys
                > List.length fromKeys
                && List.all (\k -> Dict.member k toFields) fromKeys

        ( Mono.MFunction _ _ fromArgs fromRet, Mono.MFunction _ _ toArgs toRet ) ->
            (List.length fromArgs == List.length toArgs)
                && (List.any identity (List.map2 recordWidened fromArgs toArgs)
                        || recordWidened fromRet toRet
                   )

        ( Mono.MTuple _ fromElems, Mono.MTuple _ toElems ) ->
            List.length fromElems
                == List.length toElems
                && List.any identity (List.map2 recordWidened fromElems toElems)

        _ ->
            False


{-| Returns the `SpecId` of `global` at `rawMonoType`, creating the registry
entry if needed, and pushes it on the worklist unless the `scheduled` set already
holds it, so no id is queued twice.

The type is refreshed with `TypeSubst.refreshConstraints` before keying, so a
variable tainted as a number keys as `Int` and shares the explicit-`Int`
specialization.

-}
enqueueSpec :
    Mono.Global
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.SpecId, MonoState )
enqueueSpec global rawMonoType state =
    let
        monoType =
            TypeSubst.refreshConstraints state.ctx.mvarEnv rawMonoType

        accum =
            state.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId global monoType accum.registry
    in
    if BitSet.member specId accum.scheduled then
        ( specId, { state | accum = { accum | registry = newRegistry } } )

    else
        ( specId
        , { state
            | accum =
                { accum
                    | registry = newRegistry
                    , scheduled = BitSet.insertGrowing specId accum.scheduled
                    , worklist = SpecializeGlobal specId :: accum.worklist
                }
          }
        )


{-| Returns whether `name` is a let-bound function currently being copied once
per use type (an entry on the `localMulti` stack).
-}
isLocalMultiTarget : Name -> MonoState -> Bool
isLocalMultiTarget name state =
    List.any (\ls -> ls.defName == name) state.ctx.localMulti


{-| Returns the name of the copy of the let-bound function `defName` at
`funcMonoType0`, recording a new copy made under `callSubst` if none exists for
that type yet.

The type is refreshed with `TypeSubst.refreshConstraints` before it is used as
the key. Naming is as `updateLocalMultiStack` describes.

-}
getOrCreateLocalInstance :
    Name
    -> Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Name, MonoState )
getOrCreateLocalInstance defName funcMonoType0 callSubst state =
    let
        funcMonoType =
            TypeSubst.refreshConstraints state.ctx.mvarEnv funcMonoType0

        ( updatedStack, freshName ) =
            updateLocalMultiStack defName funcMonoType callSubst state.ctx.localMulti
    in
    ( freshName
    , { state
        | ctx =
            let
                ctx =
                    state.ctx
            in
            { ctx | localMulti = updatedStack }
      }
    )


{-| Returns the `localMulti` stack with a copy of `defName` at `funcMonoType`
recorded on the innermost entry for `defName`, and that copy's name. An existing
copy for the type is returned unchanged. A new copy is named `defName` if it is
the first, and `defName$N` when N copies exist already. Crashes when no entry
is for `defName`.
-}
updateLocalMultiStack :
    Name
    -> Mono.MonoType
    -> Substitution
    -> List LocalMultiState
    -> ( List LocalMultiState, Name )
updateLocalMultiStack defName funcMonoType callSubst stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.updateLocalMultiStack: defName not found in stack: " ++ defName)

        localState :: rest ->
            if localState.defName == defName then
                case Mono.specMapGet funcMonoType localState.instances of
                    Just info ->
                        ( stack, info.freshName )

                    Nothing ->
                        let
                            freshIndex =
                                Mono.specMapSize localState.instances

                            freshName =
                                if freshIndex == 0 then
                                    defName

                                else
                                    defName ++ "$" ++ String.fromInt freshIndex

                            newInfo =
                                { freshName = freshName
                                , monoType = funcMonoType
                                , subst = callSubst
                                }

                            newInstances =
                                Mono.specMapInsert funcMonoType newInfo localState.instances

                            newLocalState =
                                { localState | instances = newInstances }
                        in
                        ( newLocalState :: rest, freshName )

            else
                let
                    ( updatedRest, freshName ) =
                        updateLocalMultiStack defName funcMonoType callSubst rest
                in
                ( localState :: updatedRest, freshName )



-- ========== VALUE-MULTI SPECIALIZATION ==========


{-| Returns whether a function type occurs anywhere in `canType`, looking
through aliases. Type variables count as not containing one.
-}
typeContainsLambda : Can.Type MVarId -> Bool
typeContainsLambda canType =
    case canType of
        Can.TLambda _ _ _ ->
            True

        Can.TType _ _ args ->
            List.any typeContainsLambda args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ t) acc -> acc || typeContainsLambda t) False fields

        Can.TTuple a b rest ->
            typeContainsLambda a || typeContainsLambda b || List.any typeContainsLambda rest

        Can.TAlias _ _ _ (Can.Filled inner) ->
            typeContainsLambda inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            typeContainsLambda inner

        Can.TVar _ ->
            False

        Can.TUnit ->
            False


{-| Returns whether `canType` has a free type variable that `mvarEnv` does not
record as a number.
-}
hasNonNumberVar : MVarEnv -> Can.Type MVarId -> Bool
hasNonNumberVar mvarEnv canType =
    let
        varIds =
            KernelAbi.freeVarIds canType []
    in
    List.any
        (\mvarId ->
            not (State.isNumberVar mvarId mvarEnv)
        )
        varIds


{-| Returns whether a let binding of type `defCanType` should be copied once per
use type (value-multi specialization): its type contains a function and has a
free type variable of any kind.

The `let` case of `specializeExpr` asks this only for a binding whose own type
is not a function.

-}
shouldUseValueMulti : MVarEnv -> Can.Type MVarId -> Bool
shouldUseValueMulti mvarEnv defCanType =
    typeContainsLambda defCanType
        && (hasNonNumberVar mvarEnv defCanType || hasUnresolvedNumberVar mvarEnv defCanType)


{-| Returns whether `defCanType` has a free type variable that `mvarEnv`
records as a number, at any depth.
-}
hasUnresolvedNumberVar : MVarEnv -> Can.Type MVarId -> Bool
hasUnresolvedNumberVar mvarEnv defCanType =
    List.any
        (\mvarId -> State.isNumberVar mvarId mvarEnv)
        (KernelAbi.freeVarIds defCanType [])


{-| Returns whether `mt`, the eagerly specialized type of a number-carrying
let, is a shape whose numeric instances this module records: a shape of `Int`,
`Float` and open number variables in tuples, non-empty records, lists and
custom types.

A tuple, record or list qualifies only when every component does, so
`{ x : number, y : String }` does not. A custom type qualifies when at least
one argument qualifies and every other argument mentions no number at all
(`Result e Int` qualifies). Functions, other primitives and boxed variables do
not qualify.

-}
isNumericFixableShape : Mono.MonoType -> Bool
isNumericFixableShape mt =
    case mt of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MTuple _ ts ->
            List.all isNumericFixableShape ts

        Mono.MRecord _ fields ->
            not (Dict.isEmpty fields) && List.all isNumericFixableShape (Dict.values fields)

        Mono.MList _ t ->
            isNumericFixableShape t

        Mono.MCustom _ _ _ args ->
            List.any isNumericFixableShape args
                && List.all (\a -> isNumericFixableShape a || not (monoTypeMentionsNumeric a)) args

        Mono.MVar _ Mono.CNumber ->
            True

        _ ->
            False


{-| Returns whether `name` is a number-multi target: an entry on the
`valueMulti` stack whose type has a free number variable, so each numeric
demand on it records its own instance.
-}
isNumberMultiTarget : Name -> MonoState -> Bool
isNumberMultiTarget name state =
    case findValueMultiEntry name state.ctx.valueMulti of
        Just ( _, defCanType ) ->
            hasUnresolvedNumberVar state.ctx.mvarEnv defCanType

        Nothing ->
            False


{-| Returns whether `Int`, `Float` or an open number variable occurs anywhere in
`mt`, including inside function types.
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


{-| Records an instance of the value-multi binding `name` at the type a
consumer demands, `resolvedShape`, and returns the instance's name and type.

The binding's own canonical type is unified with `resolvedShape` on top of
`subst`, so the instance's substitution binds the binding's own variables, and
the instance type is that canonical type under it. Returns `Nothing` when
`name` is not on the `valueMulti` stack.

-}
recordNumberInstanceAgainstShape : Name -> Mono.MonoType -> Substitution -> MonoState -> Maybe ( Name, Mono.MonoType, MonoState )
recordNumberInstanceAgainstShape name resolvedShape subst state =
    case findValueMultiEntry name state.ctx.valueMulti of
        Just ( _, defCanType ) ->
            let
                ( enrichedSubst, mvarEnv1 ) =
                    TypeSubst.unifyExtend state.ctx.mvarEnv defCanType resolvedShape subst

                stateE0 =
                    setMVarEnv mvarEnv1 state

                ( instMonoType, stateE ) =
                    applySubstFV stateE0 enrichedSubst defCanType

                ( freshName, state1 ) =
                    getOrCreateValueInstance name instMonoType enrichedSubst stateE
            in
            Just ( freshName, instMonoType, state1 )

        Nothing ->
            Nothing


{-| Returns a reference to the instance of the number-multi binding `name` at
the type this reference has, `canType` under `subst`, recording that instance
if it is new.

The reference's own type is the demand at this site, for example `Float` for a
branch of an `if` whose type is `Float`. When `name` is not on the
`valueMulti` stack, the reference keeps `name` and takes its type from the
variable environment, or failing that from `canType`.

-}
resolveNumberMultiVarRef : Name -> Can.Type MVarId -> Substitution -> MonoState -> ( Mono.MonoExpr, MonoState )
resolveNumberMultiVarRef name canType subst state =
    let
        ( resolvedShape, stateI ) =
            applySubstFV state subst canType

        recorded =
            recordNumberInstanceAgainstShape name resolvedShape subst stateI
    in
    case recorded of
        Just ( freshName, instMonoType, state1 ) ->
            ( Mono.MonoVarLocal freshName instMonoType, state1 )

        Nothing ->
            case State.lookupVar name stateI.ctx.varEnv of
                Just envType ->
                    ( Mono.MonoVarLocal name envType, stateI )

                Nothing ->
                    ( Mono.MonoVarLocal name resolvedShape, stateI )


{-| Returns whether `name` is a let-bound value currently being copied once per
use type (an entry on the `valueMulti` stack).
-}
isValueMultiTarget : Name -> MonoState -> Bool
isValueMultiTarget name state =
    List.any (\entry -> entry.defName == name) state.ctx.valueMulti


{-| Returns the name and the reference's canonical type when `expr` is a local
variable reference to a value-multi binding.
-}
getValueMultiVar : TOpt.Expr MVarId -> MonoState -> Maybe ( Name, Can.Type MVarId )
getValueMultiVar expr state =
    case expr of
        TOpt.VarLocal name meta ->
            if isValueMultiTarget name state then
                Just ( name, meta.tipe )

            else
                Nothing

        TOpt.TrackedVarLocal _ name meta ->
            if isValueMultiTarget name state then
                Just ( name, meta.tipe )

            else
                Nothing

        _ ->
            Nothing


{-| Returns the root name of `path` and the binding's canonical type, as the
`valueMulti` stack records it, when that root is a value-multi binding.
-}
getValueMultiRootFromPath : TOpt.Path -> MonoState -> Maybe ( Name, Can.Type MVarId )
getValueMultiRootFromPath path state =
    case path of
        TOpt.Root name ->
            findValueMultiEntry name state.ctx.valueMulti

        TOpt.Index _ _ subPath ->
            getValueMultiRootFromPath subPath state

        TOpt.ArrayIndex _ subPath ->
            getValueMultiRootFromPath subPath state

        TOpt.Field _ subPath ->
            getValueMultiRootFromPath subPath state

        TOpt.Unbox subPath ->
            getValueMultiRootFromPath subPath state


{-| Returns the name and canonical type of the innermost `valueMulti` entry for
`name`.
-}
findValueMultiEntry : Name -> List ValueMultiState -> Maybe ( Name, Can.Type MVarId )
findValueMultiEntry name stack =
    case stack of
        [] ->
            Nothing

        entry :: rest ->
            if entry.defName == name then
                Just ( entry.defName, entry.defCanType )

            else
                findValueMultiEntry name rest


{-| Returns `path` with its root renamed from `oldName` to `newName`; a root
with another name is left alone.
-}
rewriteRootInPath : Name -> Name -> TOpt.Path -> TOpt.Path
rewriteRootInPath oldName newName path =
    case path of
        TOpt.Root name ->
            if name == oldName then
                TOpt.Root newName

            else
                path

        TOpt.Index idx hint subPath ->
            TOpt.Index idx hint (rewriteRootInPath oldName newName subPath)

        TOpt.ArrayIndex idx subPath ->
            TOpt.ArrayIndex idx (rewriteRootInPath oldName newName subPath)

        TOpt.Field fieldName subPath ->
            TOpt.Field fieldName (rewriteRootInPath oldName newName subPath)

        TOpt.Unbox subPath ->
            TOpt.Unbox (rewriteRootInPath oldName newName subPath)


{-| Returns the custom type that constructor `ctorName` builds when its field
number `fieldIdx` has type `leafMono`, with every type argument that field does
not determine left as a fresh variable.

The constructor's scheme is unified with `leafMono` at that field, so both
fields of `Pair number number` pin the one shared argument. The constructor is
looked up in the home module of `rootCanType`. Returns `Nothing` when
`rootCanType` is not a named type, the constructor is not a `Ctor` or `Box`
node, or it has no such field.

-}
customContainerForField : Can.Type MVarId -> Name -> Int -> Mono.MonoType -> MonoState -> Maybe ( Mono.MonoType, MonoState )
customContainerForField rootCanType ctorName fieldIdx leafMono state =
    case rootCanType of
        Can.TType home _ _ ->
            let
                ctorGlobal =
                    TOpt.Global home ctorName

                maybeCtorCanType =
                    case Data.Map.get TOpt.toComparableGlobal ctorGlobal state.ctx.toptNodes of
                        Just (TOpt.Ctor _ _ ct) ->
                            Just ct

                        Just (TOpt.Box ct) ->
                            Just ct

                        _ ->
                            Nothing
            in
            case maybeCtorCanType of
                Just ctorCanType ->
                    let
                        ( schemeInfo, state1 ) =
                            getOrBuildSchemeInfo ctorCanType (Just ctorGlobal) state
                    in
                    case List.drop fieldIdx schemeInfo.argTypes of
                        fieldCanType :: _ ->
                            let
                                ( subst1, mvarEnv1 ) =
                                    TypeSubst.unifyExtend state1.ctx.mvarEnv fieldCanType leafMono Dict.empty

                                state2a =
                                    setMVarEnv mvarEnv1 state1

                                ( customMono, state2 ) =
                                    applySubstFV state2a subst1 schemeInfo.resultType
                            in
                            Just ( customMono, state2 )

                        [] ->
                            Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns a type for the root of `path` that has `leafMonoType` at the place
the path leads to and fresh boxed variables (or, for a custom type, fresh type
arguments) everywhere else: a _partial container_.

The steps are taken from the one nearest the leaf back to the root. A tuple step puts
the leaf at its index among fresh variables, a field step makes a one-field
record, and a custom-type step goes through `customContainerForField`. An unbox
step builds the custom type when `rootCanType` names a union with exactly one
constructor, and otherwise passes the leaf through unchanged. Returns `Nothing`
for a list or array index step, or when a custom-type step cannot be built.

-}
buildPartialContainer : Can.Type MVarId -> TOpt.Path -> Mono.MonoType -> MonoState -> Maybe ( Mono.MonoType, MonoState )
buildPartialContainer rootCanType path leafMonoType state =
    case path of
        TOpt.Root _ ->
            Just ( leafMonoType, state )

        TOpt.Index idx hint subPath ->
            case hint of
                TOpt.HintTuple2 ->
                    let
                        ( fillerId, env1 ) =
                            State.freshMVar Mono.CEcoValue state.ctx.mvarEnv

                        state1 =
                            setMVarEnv env1 state

                        filler =
                            Mono.MVar fillerId Mono.CEcoValue

                        elems =
                            case Index.toMachine idx of
                                0 ->
                                    [ leafMonoType, filler ]

                                _ ->
                                    [ filler, leafMonoType ]
                    in
                    buildPartialContainer rootCanType subPath (Mono.mTuple elems) state1

                TOpt.HintTuple3 ->
                    let
                        ( fillerA, envA ) =
                            State.freshMVar Mono.CEcoValue state.ctx.mvarEnv

                        ( fillerB, envB ) =
                            State.freshMVar Mono.CEcoValue envA

                        state1 =
                            setMVarEnv envB state

                        mvA =
                            Mono.MVar fillerA Mono.CEcoValue

                        mvB =
                            Mono.MVar fillerB Mono.CEcoValue

                        elems =
                            case Index.toMachine idx of
                                0 ->
                                    [ leafMonoType, mvA, mvB ]

                                1 ->
                                    [ mvA, leafMonoType, mvB ]

                                _ ->
                                    [ mvA, mvB, leafMonoType ]
                    in
                    buildPartialContainer rootCanType subPath (Mono.mTuple elems) state1

                TOpt.HintCustom ctorName ->
                    case customContainerForField rootCanType ctorName (Index.toMachine idx) leafMonoType state of
                        Just ( customMono, stateC ) ->
                            buildPartialContainer rootCanType subPath customMono stateC

                        Nothing ->
                            Nothing

                TOpt.HintList ->
                    Nothing

        TOpt.Field fieldName subPath ->
            buildPartialContainer rootCanType
                subPath
                (Mono.mRecord (Dict.singleton fieldName leafMonoType))
                state

        TOpt.Unbox subPath ->
            -- The constructor is looked up, not assumed to share the type's name.
            let
                customAttempt =
                    case rootCanType of
                        Can.TType home typeName _ ->
                            case Analysis.lookupUnion state.ctx.globalTypeEnv home typeName of
                                Just (Can.Union unionData) ->
                                    case unionData.alts of
                                        [ Can.Ctor ctorData ] ->
                                            customContainerForField rootCanType ctorData.name 0 leafMonoType state

                                        _ ->
                                            Nothing

                                Nothing ->
                                    Nothing

                        _ ->
                            Nothing
            in
            case customAttempt of
                Just ( customMono, stateC ) ->
                    buildPartialContainer rootCanType subPath customMono stateC

                Nothing ->
                    buildPartialContainer rootCanType subPath leafMonoType state

        TOpt.ArrayIndex _ _ ->
            Nothing


{-| Returns the specialized form of a destructuring `dname = <destructorPath
into rootName>` followed by `body`, where `rootName` is a number-multi target.

The body is specialized first, with `dname` itself pushed as a number-multi
target whose one instance is its eagerly specialized type (with any number
variable left open). Each use of `dname` in the body then records an instance
at the numeric type it demands. Afterwards one `MonoDestruct` is emitted per
recorded instance: a partial container with that instance's type at the path
(`buildPartialContainer`) selects an instance of the root, and the destructor
projects from it. The eager instance's destructor is emitted only when the body
refers to `dname` under its own name. An instance whose partial container
cannot be built gets no destructor.

-}
specializeNumberDestruct :
    Name
    -> TOpt.Path
    -> TOpt.Meta MVarId
    -> Name
    -> Can.Type MVarId
    -> TOpt.Expr MVarId
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
specializeNumberDestruct dname destructorPath destructorMeta rootName rootCanType body subst state =
    let
        fieldCanType =
            destructorMeta.tipe

        ( eagerLeaf, stateI0 ) =
            applySubstFV state subst fieldCanType

        intKey =
            TypeSubst.refreshConstraints state.ctx.mvarEnv eagerLeaf

        -- Never specialized: this function pops the entry itself and emits
        -- destructors, not lets.
        placeholderDef =
            TOpt.Def A.zero dname (TOpt.VarLocal dname destructorMeta) fieldCanType

        seededEntry =
            { defName = dname
            , defCanType = fieldCanType
            , def = placeholderDef
            , instances =
                Mono.specMapSingleton intKey
                    { freshName = dname
                    , monoType = eagerLeaf
                    , subst = subst
                    , derivedDestructorNames = Set.empty
                    }
            }

        stateForBody =
            { stateI0
                | ctx =
                    let
                        c =
                            stateI0.ctx
                    in
                    { c
                        | valueMulti = seededEntry :: c.valueMulti
                        , varEnv = State.insertVar dname eagerLeaf c.varEnv
                    }
            }

        ( monoBody, stateAfterBody ) =
            specializeExpr body subst stateForBody

        ( dnameEntry, restStack ) =
            case stateAfterBody.ctx.valueMulti of
                top :: rest ->
                    ( top, rest )

                [] ->
                    Utils.Crash.crash "Specialize.specializeNumberDestruct: valueMulti underflow"

        statePopped =
            { stateAfterBody
                | ctx =
                    let
                        c =
                            stateAfterBody.ctx
                    in
                    { c | valueMulti = restStack }
            }

        dnameUsed =
            exprReferencesLocal dname monoBody

        -- The eager instance (freshName == dname) only if the body refers to it.
        instancesToEmit =
            Mono.specMapValues dnameEntry.instances
                |> List.filter (\info -> info.freshName /= dname || dnameUsed)

        ( destructorsRev, stateFinal ) =
            List.foldl
                (\info ( acc, st ) ->
                    case buildPartialContainer rootCanType destructorPath info.monoType st of
                        Just ( partialContainerMono, stateP ) ->
                            let
                                ( refinedSubst, mvarEnv1 ) =
                                    TypeSubst.unifyExtend stateP.ctx.mvarEnv rootCanType partialContainerMono info.subst

                                stateR0 =
                                    setMVarEnv mvarEnv1 stateP

                                ( rootInstanceMonoType, stateR ) =
                                    applySubstFV stateR0 refinedSubst rootCanType

                                ( freshRootName, stateI ) =
                                    getOrCreateValueInstance rootName rootInstanceMonoType refinedSubst stateR

                                -- Must be keyed as getOrCreateValueInstance keys, or the
                                -- tag lookup misses and crashes.
                                instanceKey =
                                    TypeSubst.refreshConstraints stateR.ctx.mvarEnv rootInstanceMonoType

                                taggedStack =
                                    tagValueInstanceWithDestructor rootName instanceKey info.freshName stateI.ctx.valueMulti

                                stateT =
                                    { stateI
                                        | ctx =
                                            let
                                                c =
                                                    stateI.ctx
                                            in
                                            { c
                                                | valueMulti = taggedStack
                                                , varEnv = State.insertVar freshRootName rootInstanceMonoType c.varEnv
                                            }
                                    }

                                rewrittenDestructor =
                                    TOpt.Destructor info.freshName
                                        (rewriteRootInPath rootName freshRootName destructorPath)
                                        destructorMeta

                                monoDestructor =
                                    specializeDestructor stateT.accum.intern
                                        rewrittenDestructor
                                        refinedSubst
                                        stateT.ctx.mvarEnv
                                        stateT.ctx.varEnv
                                        stateT.ctx.globalTypeEnv
                                        stateT.ctx.currentGlobal

                                (Mono.MonoDestructor destructorName _ destructorType) =
                                    monoDestructor

                                stateV =
                                    { stateT
                                        | ctx =
                                            let
                                                c =
                                                    stateT.ctx
                                            in
                                            { c | varEnv = State.insertVar destructorName destructorType c.varEnv }
                                    }
                            in
                            ( monoDestructor :: acc, stateV )

                        Nothing ->
                            ( acc, st )
                )
                ( [], statePopped )
                instancesToEmit

        finalExpr =
            List.foldl
                (\md accExpr -> Mono.MonoDestruct md accExpr (Mono.typeOf accExpr))
                monoBody
                destructorsRev
    in
    ( finalExpr, stateFinal )


{-| Returns whether `expr` contains a local variable reference to `name`, as
`MonoTraverse.foldExpr` visits it.
-}
exprReferencesLocal : Name -> Mono.MonoExpr -> Bool
exprReferencesLocal name expr =
    Traverse.foldExpr
        (\e acc ->
            acc
                || (case e of
                        Mono.MonoVarLocal n _ ->
                            n == name

                        _ ->
                            False
                   )
        )
        False
        expr


{-| Returns `state` with its `MVarEnv` replaced by `env`.
-}
setMVarEnv : MVarEnv -> MonoState -> MonoState
setMVarEnv env state =
    { state
        | ctx =
            let
                c =
                    state.ctx
            in
            { c | mvarEnv = env }
    }


{-| Returns the type of applying a function of type `monoType` to `numArgs`
arguments: exactly that many parameters are removed, across as many nested
function types as it takes, so a partial application keeps the rest. A
non-function type is returned as it is.
-}
peelCallResult : Int -> Mono.MonoType -> Mono.MonoType
peelCallResult numArgs monoType =
    if numArgs <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ anno params result ->
                let
                    pcount =
                        List.length params
                in
                if pcount > numArgs then
                    Mono.mFunction anno (List.drop numArgs params) result

                else if pcount == numArgs then
                    result

                else
                    peelCallResult (numArgs - pcount) result

            _ ->
                monoType


{-| Returns the name of the copy of the value-multi binding `defName` at
`monoType0`, recording a new copy made under `currentSubst` if none exists for
that type yet.

The type is refreshed with `TypeSubst.refreshConstraints` before it is used as
the key, so a lookup of the instance by key must refresh too. Naming, and the
merging of substitutions on an existing copy, are as `updateValueMultiStack`
describes.

-}
getOrCreateValueInstance :
    Name
    -> Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Name, MonoState )
getOrCreateValueInstance defName monoType0 currentSubst state =
    let
        monoType =
            TypeSubst.refreshConstraints state.ctx.mvarEnv monoType0

        ( updatedStack, freshName_ ) =
            updateValueMultiStack defName monoType currentSubst state.ctx.valueMulti
    in
    ( freshName_
    , { state
        | ctx =
            let
                ctx =
                    state.ctx
            in
            { ctx | valueMulti = updatedStack }
      }
    )


{-| Returns the `valueMulti` stack with a copy of `defName` at `monoType`
recorded on the innermost entry for `defName`, and that copy's name.

A new copy is named `defName` if it is the first, and `defName$vN` when N
copies exist already. When a copy for the type exists, bindings of
`currentSubst` for variables its substitution does not yet bind are added to
it; existing bindings win. Crashes when no entry is for `defName`.

-}
updateValueMultiStack :
    Name
    -> Mono.MonoType
    -> Substitution
    -> List ValueMultiState
    -> ( List ValueMultiState, Name )
updateValueMultiStack defName monoType currentSubst stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.updateValueMultiStack: defName not found in stack: " ++ defName)

        entry :: rest ->
            if entry.defName == defName then
                case Mono.specMapGet monoType entry.instances of
                    Just info ->
                        -- A second destructor on the same root (the setter of
                        -- `( getter, setter )`) can bind variables the first never
                        -- mentioned; existing bindings may have been refined since.
                        let
                            newInfo =
                                { info | subst = Dict.union info.subst currentSubst }

                            newInstances =
                                Mono.specMapInsert monoType newInfo entry.instances

                            newEntry =
                                { entry | instances = newInstances }
                        in
                        ( newEntry :: rest, info.freshName )

                    Nothing ->
                        let
                            freshIndex =
                                Mono.specMapSize entry.instances

                            freshName_ =
                                if freshIndex == 0 then
                                    defName

                                else
                                    defName ++ "$v" ++ String.fromInt freshIndex

                            newInfo =
                                { freshName = freshName_
                                , monoType = monoType
                                , subst = currentSubst
                                , derivedDestructorNames = Set.empty
                                }

                            newInstances =
                                Mono.specMapInsert monoType newInfo entry.instances

                            newEntry =
                                { entry | instances = newInstances }
                        in
                        ( newEntry :: rest, freshName_ )

            else
                let
                    ( updatedRest, freshName_ ) =
                        updateValueMultiStack defName monoType currentSubst rest
                in
                ( entry :: updatedRest, freshName_ )


{-| Returns the `valueMulti` stack with `destructorName`, a local bound by
destructuring, recorded as derived from the instance of `defName` keyed by
`instanceKey`, so that a later call of that local can find the instance to
refine (`refineValueMultiForDestructorCall`).

Crashes when there is no entry for `defName` or no instance under `instanceKey`;
the key must be refreshed as `getOrCreateValueInstance` refreshes it.

-}
tagValueInstanceWithDestructor :
    Name
    -> Mono.MonoType
    -> Name
    -> List ValueMultiState
    -> List ValueMultiState
tagValueInstanceWithDestructor defName instanceKey destructorName stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.tagValueInstanceWithDestructor: defName not found: " ++ defName)

        entry :: rest ->
            if entry.defName == defName then
                case Mono.specMapGet instanceKey entry.instances of
                    Just info ->
                        let
                            newInfo =
                                { info
                                    | derivedDestructorNames =
                                        Set.insert destructorName info.derivedDestructorNames
                                }

                            newInstances =
                                Mono.specMapInsert instanceKey newInfo entry.instances
                        in
                        { entry | instances = newInstances } :: rest

                    Nothing ->
                        Utils.Crash.crash
                            ("Specialize.tagValueInstanceWithDestructor: instance key not found for "
                                ++ defName
                                ++ " / "
                                ++ Mono.monoTypeToDebugString instanceKey
                            )

            else
                entry :: tagValueInstanceWithDestructor defName instanceKey destructorName rest


{-| Refines the value-multi instance from which the local `funcName` was
destructured, by unifying the parameters of `funcCanType` with the call's
argument types `argTypes` on top of the instance's substitution
(`TypeSubst.unifyArgsOnly`). Returns the refined substitution, the `MVarEnv`
after, and the stack with the instance updated.

The innermost entry with an instance tagged with `funcName` is used. Returns
`Nothing` when no instance is tagged with it.

-}
refineValueMultiForDestructorCall :
    Name
    -> Can.Type MVarId
    -> List Mono.MonoType
    -> MVarEnv
    -> List ValueMultiState
    -> Maybe ( Substitution, MVarEnv, List ValueMultiState )
refineValueMultiForDestructorCall funcName funcCanType argTypes mvarEnv stack =
    case stack of
        [] ->
            Nothing

        entry :: rest ->
            case findInstanceByDestructor funcName (Mono.specMapToList entry.instances) of
                Just ( instanceKey, info ) ->
                    let
                        ( newSubst, newEnv ) =
                            TypeSubst.unifyArgsOnly mvarEnv funcCanType argTypes info.subst

                        newInfo =
                            { info | subst = newSubst }

                        newInstances =
                            Mono.specMapInsert instanceKey newInfo entry.instances

                        newEntry =
                            { entry | instances = newInstances }
                    in
                    Just ( newSubst, newEnv, newEntry :: rest )

                Nothing ->
                    case refineValueMultiForDestructorCall funcName funcCanType argTypes mvarEnv rest of
                        Just ( newSubst, newEnv, newRest ) ->
                            Just ( newSubst, newEnv, entry :: newRest )

                        Nothing ->
                            Nothing


{-| Returns the first of `pairs` (key and instance) whose instance is tagged
with the destructured local `funcName`.
-}
findInstanceByDestructor :
    Name
    -> List ( Mono.MonoType, State.ValueInstanceInfo )
    -> Maybe ( Mono.MonoType, State.ValueInstanceInfo )
findInstanceByDestructor funcName pairs =
    case pairs of
        [] ->
            Nothing

        ( key, info ) :: rest ->
            if Set.member funcName info.derivedDestructorNames then
                Just ( key, info )

            else
                findInstanceByDestructor funcName rest


{-| Returns the closure that the lambda `lambdaExpr`, of type `canType`,
becomes under `subst`.

The closure has one parameter per syntactic parameter of this one lambda node,
so `\x y -> body` gives one closure of two parameters while `\x -> \y -> body`
gives a closure of one whose body is another closure. Its type is `canType`
under `subst` unchanged, which is curried, one parameter per arrow: `\x y ->
body` at `Int -> Int -> Int` has two parameters and the type
`Int -> (Int -> Int)`. Nothing here makes the two agree.

The function type is unified back into `subst` before the parameters and body
are specialized, so what the context fixes about the whole function reaches the
lambda's own variables. Captures are the free locals of the specialized body
(`Closure.computeClosureCaptures`), and the closure gets the next anonymous
lambda id of the current module. Crashes if `lambdaExpr` is not a lambda.

-}
specializeLambda :
    TOpt.Expr MVarId
    -> Can.Type MVarId
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
specializeLambda lambdaExpr canType subst state =
    let
        ( monoType0, stateI ) =
            applySubstFV state subst canType

        -- The returned env carries number taints and must be threaded on.
        ( refinedSubst, refinedEnv ) =
            TypeSubst.unifyExtend state.ctx.mvarEnv canType monoType0 subst

        ( params, bodyExpr ) =
            case lambdaExpr of
                TOpt.Function _ ps body _ ->
                    ( ps, body )

                TOpt.TrackedFunction _ trackedPs body _ ->
                    ( List.map (\( locName, ty ) -> ( A.toValue locName, ty )) trackedPs, body )

                _ ->
                    Utils.Crash.crash
                        "specializeLambda: called with non-lambda expression"

        ( monoParams, stateP ) =
            List.foldr
                (\( name, paramCanType ) ( acc, st ) ->
                    let
                        ( paramMono, st1 ) =
                            applySubstFV st refinedSubst paramCanType
                    in
                    ( ( name, paramMono ) :: acc, st1 )
                )
                ( [], stateI )
                params

        ctx =
            stateP.ctx

        lambdaId =
            Mono.AnonymousLambda ctx.currentModule ctx.lambdaCounter

        newVarEnv =
            List.foldl
                (\( name, monoParamType ) ve ->
                    State.insertVar name monoParamType ve
                )
                (State.pushFrame ctx.varEnv)
                monoParams

        stateWithLambda =
            { stateP
                | ctx =
                    { ctx
                        | lambdaCounter = ctx.lambdaCounter + 1
                        , varEnv = newVarEnv
                        , mvarEnv = refinedEnv
                    }
            }

        ( monoBody, stateAfter0 ) =
            specializeExpr bodyExpr refinedSubst stateWithLambda

        stateAfter =
            { stateAfter0
                | ctx =
                    let
                        ctx0 =
                            stateAfter0.ctx
                    in
                    { ctx0 | varEnv = State.popFrame ctx0.varEnv }
            }

        captures =
            Closure.computeClosureCaptures monoParams monoBody

        closureInfo =
            { lambdaId = lambdaId
            , srcLambda = Nothing
            , lssMember = Nothing
            , captures = captures
            , params = monoParams
            , closureKind = Nothing
            , captureAbi = Nothing
            }

        monoTypeFixed : Mono.MonoType
        monoTypeFixed =
            monoType0
    in
    ( Mono.MonoClosure closureInfo monoBody monoTypeFixed, stateAfter )



-- ========== NODE SPECIALIZATION ==========


{-| Returns the `MonoCtor` node for the constructor `ctorName` of the current
global, with tag `tag` and `arity` fields, at `requestedMonoType`.

The layout's field types come from the constructor's scheme, with fresh ids
(`getOrBuildSchemeInfo`), unified with the requested type; the node's type is
what the requested type returns after `arity` arguments. Crashes when the
current global is not a `Global`.

-}
specializeCtorViaScheme : Name.Name -> Int -> Int -> Can.Type MVarId -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeCtorViaScheme ctorName tag arity canType requestedMonoType state =
    let
        ctorGlobal =
            case state.ctx.currentGlobal of
                Just (Mono.Global canonical name) ->
                    TOpt.Global canonical name

                _ ->
                    Utils.Crash.crash "specializeCtorViaScheme: currentGlobal is not a Global — ctors must always have a currentGlobal"

        ( schemeInfo, state1 ) =
            getOrBuildSchemeInfo canType (Just ctorGlobal) state

        ( subst, mvarEnv1 ) =
            TypeSubst.unify state1.ctx.mvarEnv schemeInfo.schemeType requestedMonoType

        ctorMonoType =
            TypeSubst.applySubstPureRO state1.accum.intern mvarEnv1 subst schemeInfo.schemeType

        shape =
            buildCtorShapeFromArity ctorName tag arity ctorMonoType

        ctorResultType =
            extractCtorResultType arity requestedMonoType

        ctx2 =
            let
                ctx =
                    state1.ctx
            in
            { ctx | mvarEnv = mvarEnv1 }
    in
    ( Mono.MonoCtor shape ctorResultType, { state1 | ctx = ctx2 } )


{-| Returns the node that the global `ctorName`, defined by `node`, becomes when
specialized at `requestedMonoType`, with every specialization its body needs
enqueued on the worklist.

`ctorName` is the global's own name. It names a constructor's layout, it goes
into the tag of a constructor or enumeration value, and when `node` is a link
it is replaced by the linked global's name. The state's current global must be
the global being specialized.

A definition unifies both its declared type and its body's type with the
request, since the declared type can be concrete while the body's inner types
still have variables. The node's type is the specialized body's type, which
need not be the requested type; a definition whose body is not a closure is
left that way here.

A constructor (`Ctor`, or `Box` with tag 0 and one field) becomes a `MonoCtor`
whose field types come from the constructor's type, with fresh variables,
unified with the request, and whose type is what the requested type returns
after all the fields are applied. An enumeration value becomes a `MonoEnum`. A
link is followed to the linked node, keeping the current global; a link to a
missing node, and a kernel, become a `MonoExtern` of the requested type. An
effect manager becomes a `MonoManagerLeaf` naming the current global's module.

A member of a recursive group is specialized together with every other member,
under one substitution obtained from the requested member, and the other
members' nodes are stored in the state at their own `SpecId`s rather than
enqueued. A group whose current global is missing becomes a `MonoExtern`.

A port, requested at a function type of one parameter, becomes a closure with
no captures that calls the kernel `Platform.leaf` with the port's name: an
incoming port passes its argument on, and an outgoing port passes its argument
through the port's encoder first. An incoming port also enqueues its decoder as
another specialization of the same global, at the decoder's type, which is not
a function; that request is specialized as a plain value definition of the
decoder. Each port is recorded once in the state's port registrations, an
incoming one with its decoder's `SpecId`.

The constructor and enumeration cases, and the port cases requested at a
function type, crash when the current global is not a `Global`, and a
recursive group crashes when the current global is an accessor.

-}
specializeNode : Name.Name -> TOpt.Node MVarId -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeNode ctorName node requestedMonoType state =
    case node of
        TOpt.Define expr _ meta ->
            let
                canType =
                    meta.tipe

                ( subst0, env0 ) =
                    TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType

                ( subst, env1 ) =
                    TypeSubst.unifyExtend env0 (TOpt.typeOf expr) requestedMonoType subst0

                ( monoExpr, state1 ) =
                    specializeExpr expr subst (setMVarEnv env1 state)

                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )

        TOpt.TrackedDefine _ expr deps meta ->
            specializeNode ctorName (TOpt.Define expr deps meta) requestedMonoType state

        TOpt.Ctor index arity canType ->
            let
                ctorHome =
                    case state.ctx.currentGlobal of
                        Just (Mono.Global canonical _) ->
                            canonical

                        _ ->
                            Utils.Crash.crash "specializeNode TOpt.Ctor: currentGlobal must be a Global"
            in
            specializeCtorViaScheme ctorName (CtorTag.effective ctorHome ctorName index) arity canType requestedMonoType state

        TOpt.Enum tag canType ->
            let
                ( unifSubst, envU ) =
                    TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType

                monoType =
                    TypeSubst.applySubstPureRO state.accum.intern envU unifSubst canType

                enumHome =
                    case state.ctx.currentGlobal of
                        Just (Mono.Global canonical _) ->
                            canonical

                        _ ->
                            Utils.Crash.crash "specializeNode TOpt.Enum: currentGlobal must be a Global"
            in
            ( Mono.MonoEnum (CtorTag.effective enumHome ctorName tag) monoType, setMVarEnv envU state )

        TOpt.Box canType ->
            specializeCtorViaScheme ctorName 0 1 canType requestedMonoType state

        TOpt.Link linkedGlobal ->
            case Data.Map.get TOpt.toComparableGlobal linkedGlobal state.ctx.toptNodes of
                Nothing ->
                    ( Mono.MonoExtern requestedMonoType, state )

                Just linkedNode ->
                    let
                        linkedName =
                            case linkedGlobal of
                                TOpt.Global _ name ->
                                    name
                    in
                    specializeNode linkedName linkedNode requestedMonoType state

        TOpt.Kernel _ _ ->
            ( Mono.MonoExtern requestedMonoType, state )

        TOpt.Manager _ ->
            let
                homeModuleName =
                    case state.ctx.currentGlobal of
                        Just (Mono.Global (ModuleName.Canonical _ modName) _) ->
                            Name.toElmString modName

                        _ ->
                            "Unknown"
            in
            ( Mono.MonoManagerLeaf homeModuleName requestedMonoType, state )

        TOpt.Cycle _ valueDefs funcDefs _ ->
            specializeCycle valueDefs funcDefs requestedMonoType state

        TOpt.PortIncoming expr _ meta ->
            case requestedMonoType of
                Mono.MFunction _ _ _ _ ->
                    specializePortNode True expr meta.tipe requestedMonoType state

                _ ->
                    -- The decoder specialization that the port's own
                    -- specialization enqueued.
                    let
                        decoderCanType =
                            TOpt.typeOf expr

                        ( subst, envU ) =
                            TypeSubst.unify state.ctx.mvarEnv decoderCanType requestedMonoType

                        ( monoExpr, state1 ) =
                            specializeExpr expr subst (setMVarEnv envU state)
                    in
                    ( Mono.MonoDefine monoExpr requestedMonoType, state1 )

        TOpt.PortOutgoing expr _ meta ->
            specializePortNode False expr meta.tipe requestedMonoType state


{-| Returns the node for the current global, a port, at `requestedMonoType`,
which must be a function of one parameter; `incoming` says which way the port
goes and `expr` is its decoder or encoder, of type `canType`.

The node is a closure with no captures. An incoming port
`port bar : (payload -> msg) -> Sub msg` becomes

    \tagger -> Elm_Kernel_Platform_leaf "bar" tagger

and its decoder is enqueued as another specialization of the same global, at
the decoder's own type. An outgoing port `port foo : payload -> Cmd msg`
becomes

    \p -> Elm_Kernel_Platform_leaf "foo" (encoder p)

so the payload is encoded before it reaches the leaf. Either way the port is
recorded in the state's port registrations, an incoming one with its
decoder's `SpecId`.

Crashes when the current global is not a `Global` or the requested type is not
a one-parameter function.

-}
specializePortNode :
    Bool
    -> TOpt.Expr MVarId
    -> Can.Type MVarId
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializePortNode incoming expr canType requestedMonoType state =
    let
        ( portGlobal, portName ) =
            case state.ctx.currentGlobal of
                Just ((Mono.Global _ name) as g) ->
                    ( g, Name.toElmString name )

                _ ->
                    Utils.Crash.crash "specializePortNode: currentGlobal must be a Global"

        ( subst, portEnv ) =
            TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType

        ( paramType, resultType ) =
            case requestedMonoType of
                Mono.MFunction _ _ [ p ] r ->
                    ( p, r )

                _ ->
                    Utils.Crash.crash
                        ("specializePortNode: port '"
                            ++ portName
                            ++ "' must have a single-parameter function type"
                        )

        region =
            A.zero

        ctx =
            state.ctx

        lambdaId =
            Mono.AnonymousLambda ctx.currentModule ctx.lambdaCounter

        stateWithLambda =
            { state | ctx = { ctx | lambdaCounter = ctx.lambdaCounter + 1, mvarEnv = portEnv } }

        paramName =
            "_eco_port_arg"

        paramVar =
            Mono.MonoVarLocal paramName paramType

        nameLit =
            Mono.MonoLiteral (Mono.LStr portName) Mono.MString

        leafKernel valueType =
            Mono.MonoVarKernel region
                "Elm"
                "Platform"
                "leaf"
                (Mono.mFunction Mono.topDeclOther [ Mono.MString, valueType ] resultType)

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
                Mono.MonoCall region
                    (leafKernel paramType)
                    [ nameLit, paramVar ]
                    resultType
                    Mono.defaultCallInfo

            wrapper =
                Mono.MonoClosure closureInfo body requestedMonoType

            decoderMonoType =
                TypeSubst.applySubstPureRO stateWithLambda.accum.intern stateWithLambda.ctx.mvarEnv subst (TOpt.typeOf expr)

            ( decoderSpecId, state1 ) =
                enqueueSpec portGlobal decoderMonoType stateWithLambda

            state2 =
                recordPortRegistration
                    { name = portName
                    , key = Mono.toComparableGlobal portGlobal
                    , incoming = True
                    , decoderSpecId = Just decoderSpecId
                    }
                    state1
        in
        ( Mono.MonoPortIncoming wrapper requestedMonoType, state2 )

    else
        let
            ( encoderMono, state1 ) =
                specializeExpr expr subst stateWithLambda

            encodedType =
                case Mono.typeOf encoderMono of
                    Mono.MFunction _ _ _ r ->
                        r

                    t ->
                        t

            encodedExpr =
                Mono.MonoCall region
                    encoderMono
                    [ paramVar ]
                    encodedType
                    Mono.defaultCallInfo

            body =
                Mono.MonoCall region
                    (leafKernel encodedType)
                    [ nameLit, encodedExpr ]
                    resultType
                    Mono.defaultCallInfo

            wrapper =
                Mono.MonoClosure closureInfo body requestedMonoType

            state2 =
                recordPortRegistration
                    { name = portName
                    , key = Mono.toComparableGlobal portGlobal
                    , incoming = False
                    , decoderSpecId = Nothing
                    }
                    state1
        in
        ( Mono.MonoPortOutgoing wrapper requestedMonoType, state2 )


{-| Adds `reg` to the state's port registrations unless one with the same
global key is already there, so several specializations of one port share one
registration. Two different ports with the same bare name are both kept.
-}
recordPortRegistration : Mono.PortRegistration -> MonoState -> MonoState
recordPortRegistration reg state =
    let
        accum =
            state.accum
    in
    if List.any (\p -> p.key == reg.key) accum.ports then
        state

    else
        { state | accum = { accum | ports = reg :: accum.ports } }


{-| Returns the node for the current global, a member of the mutually recursive
group with values `valueDefs` and functions `funcDefs`, at `requestedMonoType`,
as `specializeFunctionCycle` builds it.

Returns a `MonoExtern` when there is no current global, and crashes when it is
an accessor.

-}
specializeCycle :
    List ( Name, TOpt.Expr MVarId )
    -> List (TOpt.Def MVarId)
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeCycle valueDefs funcDefs requestedMonoType state =
    case ( List.isEmpty funcDefs, state.ctx.currentGlobal ) of
        ( True, Just (Mono.Global requestedCanonical requestedName) ) ->
            specializeFunctionCycle
                requestedCanonical
                requestedName
                valueDefs
                []
                requestedMonoType
                state

        ( True, Nothing ) ->
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Nothing ) ->
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Just (Mono.Global requestedCanonical requestedName) ) ->
            specializeFunctionCycle
                requestedCanonical
                requestedName
                valueDefs
                funcDefs
                requestedMonoType
                state

        ( _, Just (Mono.Accessor _) ) ->
            Utils.Crash.crash "Specialize.specializeCycle: Accessor should not appear in cycles"


{-| Adds to `accNodes` the `MonoDefine` node for the value `name` of a cycle in
module `requestedCanonical`, specialized under the cycle's shared substitution.

The node is stored at its registry `SpecId`, which is keyed by
`requestedMonoType` for the requested member and by its type under the shared
substitution otherwise. A member whose `SpecId` already has a node is skipped.
The node's type is the specialized expression's type.

-}
specializeValueInCycle :
    ModuleName.Canonical
    -> Name
    -> Mono.MonoType
    -> Substitution
    -> ( Name, TOpt.Expr MVarId )
    -> ( Array.Array (Maybe Mono.MonoNode), MonoState )
    -> ( Array.Array (Maybe Mono.MonoNode), MonoState )
specializeValueInCycle requestedCanonical requestedName requestedMonoType sharedSubst ( name, expr ) ( accNodes, accState ) =
    let
        globalVal =
            Mono.Global requestedCanonical name

        canType =
            TOpt.typeOf expr

        monoTypeFromExpr =
            TypeSubst.applySubstPureRO accState.accum.intern accState.ctx.mvarEnv sharedSubst canType

        monoTypeForSpecId =
            if name == requestedName then
                requestedMonoType

            else
                monoTypeFromExpr

        accum =
            accState.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId globalVal monoTypeForSpecId accum.registry

        accState1 =
            { accState | accum = { accum | registry = newRegistry } }
    in
    if arrayHasNode specId accNodes then
        ( accNodes, accState1 )

    else
        let
            ( monoExpr, accState2 ) =
                specializeExpr expr sharedSubst accState1

            monoNode =
                Mono.MonoDefine monoExpr (Mono.typeOf monoExpr)

            nextNodes =
                arraySetGrowing specId (Just monoNode) accNodes
        in
        ( nextNodes, accState2 )


{-| Returns the node for `requestedName`, a member of a mutually recursive group
in module `requestedCanonical`, at `requestedMonoType`, after specializing every
member of the group under one shared substitution.

The shared substitution comes from unifying the requested member's type, as a
function in `funcDefs` or a value in `valueDefs`, with the requested type. Every
function (`specializeFunc`) and then every value (`specializeValueInCycle`) gets
a node in the state's node array at its own `SpecId`, unless one is there
already, so the other members are specialized here at the types the shared
substitution gives them, not through the worklist. Returns a `MonoExtern` if no
node was made for the requested member.

-}
specializeFunctionCycle :
    ModuleName.Canonical
    -> Name
    -> List ( Name, TOpt.Expr MVarId )
    -> List (TOpt.Def MVarId)
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFunctionCycle requestedCanonical requestedName valueDefs funcDefs requestedMonoType state =
    let
        maybeRequestedDef =
            List.filter (defHasName requestedName) funcDefs
                |> List.head

        maybeRequestedExpr =
            List.filter (\( n, _ ) -> n == requestedName) valueDefs
                |> List.head

        ( substFromFunc, envFromFunc ) =
            case maybeRequestedDef of
                Just def ->
                    TypeSubst.unify
                        state.ctx.mvarEnv
                        (getDefCanonicalType def)
                        requestedMonoType

                Nothing ->
                    ( Dict.empty, state.ctx.mvarEnv )

        ( sharedSubst, sharedEnv ) =
            case maybeRequestedExpr of
                Just ( _, expr ) ->
                    TypeSubst.unifyExtend
                        envFromFunc
                        (TOpt.typeOf expr)
                        requestedMonoType
                        substFromFunc

                Nothing ->
                    ( substFromFunc, envFromFunc )

        ( nodesAfterFuncs, stateAfterFuncs ) =
            List.foldl
                (specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst)
                ( state.accum.nodes, setMVarEnv sharedEnv state )
                funcDefs

        ( newNodes, stateAfter ) =
            List.foldl
                (specializeValueInCycle requestedCanonical requestedName requestedMonoType sharedSubst)
                ( nodesAfterFuncs, stateAfterFuncs )
                valueDefs

        requestedGlobal =
            Mono.Global requestedCanonical requestedName

        ( requestedSpecId, _ ) =
            Registry.getOrCreateSpecId requestedGlobal requestedMonoType stateAfter.accum.registry
    in
    case Array.get requestedSpecId newNodes |> Maybe.andThen identity of
        Just requestedNode ->
            ( requestedNode
            , { stateAfter
                | accum =
                    let
                        a =
                            stateAfter.accum
                    in
                    { a | nodes = newNodes }
              }
            )

        Nothing ->
            ( Mono.MonoExtern requestedMonoType
            , { stateAfter
                | accum =
                    let
                        a =
                            stateAfter.accum
                    in
                    { a | nodes = newNodes }
              }
            )


{-| Adds to `accNodes` the node for the function `def` of a cycle in module
`requestedCanonical`, specialized under the cycle's shared substitution
(`specializeFuncDefInCycle`).

The node is stored at its registry `SpecId`, keyed by `requestedMonoType` for
the requested member, so that it matches what callers asked for, and by the
definition's type under the shared substitution otherwise. A member whose
`SpecId` already has a node is skipped.

-}
specializeFunc :
    ModuleName.Canonical
    -> Name
    -> Mono.MonoType
    -> Substitution
    -> TOpt.Def MVarId
    -> ( Array.Array (Maybe Mono.MonoNode), MonoState )
    -> ( Array.Array (Maybe Mono.MonoNode), MonoState )
specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst def ( accNodes, accState ) =
    let
        name =
            getDefName def

        globalFun =
            Mono.Global requestedCanonical name

        canType =
            getDefCanonicalType def

        monoTypeFromDef =
            TypeSubst.applySubstPureRO accState.accum.intern accState.ctx.mvarEnv sharedSubst canType

        monoTypeForSpecId =
            if name == requestedName then
                requestedMonoType

            else
                monoTypeFromDef

        accum =
            accState.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId globalFun monoTypeForSpecId accum.registry

        accState1 =
            { accState | accum = { accum | registry = newRegistry } }
    in
    if arrayHasNode specId accNodes then
        ( accNodes, accState1 )

    else
        let
            ( monoNode, accState2 ) =
                specializeFuncDefInCycle sharedSubst def accState1

            nextNodes =
                arraySetGrowing specId (Just monoNode) accNodes
        in
        ( nextNodes, accState2 )


{-| Returns the node for one function of a cycle under `subst`.

A plain definition becomes a `MonoDefine` of its specialized body, typed by
that body. A tail-recursive definition becomes a `MonoTailFunc` whose
parameters are typed under `subst` and then unified back into it before the
body is specialized; its type is the whole function type, not the result type,
because the `TailDef` field it is made from holds the type of the whole
definition.

-}
specializeFuncDefInCycle :
    Substitution
    -> TOpt.Def MVarId
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFuncDefInCycle subst def state =
    case def of
        TOpt.Def _ _ expr _ ->
            let
                ( monoExpr, state1 ) =
                    specializeExpr expr subst state

                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )

        TOpt.TailDef _ _ args body returnType _ ->
            let
                monoArgs =
                    List.map (specializeArg state.accum.intern state.ctx.mvarEnv subst) args

                ctx =
                    state.ctx

                newVarEnv =
                    List.foldl
                        (\( name, monoParamType ) ve -> State.insertVar name monoParamType ve)
                        (State.pushFrame ctx.varEnv)
                        monoArgs

                stateWithParams =
                    { state | ctx = { ctx | varEnv = newVarEnv, mvarEnv = augmentedEnv } }

                ( augmentedSubstRaw, augmentedEnv ) =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) ( s, e ) ->
                            TypeSubst.unifyExtend e canParamType monoParamType s
                        )
                        ( subst, state.ctx.mvarEnv )
                        (List.map2 Tuple.pair args monoArgs)

                ( monoBody, state1pre ) =
                    specializeExpr body augmentedSubstRaw stateWithParams

                state1 =
                    { state1pre
                        | ctx =
                            let
                                ctx1 =
                                    state1pre.ctx
                            in
                            { ctx1 | varEnv = State.popFrame ctx1.varEnv }
                    }

                -- `returnType` holds the whole definition's type, so this is the
                -- function type, not the result type.
                monoFuncType =
                    TypeSubst.applySubstPureRO state.accum.intern state.ctx.mvarEnv augmentedSubstRaw returnType
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoFuncType, state1 )



-- ========== EXPRESSION SPECIALIZATION ==========


{-| Returns the specialized form of `destructor` (one variable bound by a path
into a root variable) followed by `body`, under `subst`, where the root is not
handled body-first by `specializeNumberDestruct`.

When the root is a value-multi binding whose type under `subst` still has
variables, a partial container with the destructor's own type at the path
(`buildPartialContainer`) is unified into the root's type. That picks, or
records, the root's instance at the refined type; the destructor is tagged on
that instance and projects from it, and the body is specialized under the
refined substitution. A root whose type has no variables, or whose partial
container cannot be built, is used as it is.

The bound variable enters the environment at its own type under the (possibly
refined) substitution before the body is specialized. The result's type is
`meta`'s type under `subst`, or the body's type when that still has variables.

-}
specializeGeneralDestruct : TOpt.Destructor MVarId -> TOpt.Expr MVarId -> TOpt.Meta MVarId -> Substitution -> MonoState -> ( Mono.MonoExpr, MonoState )
specializeGeneralDestruct destructor body meta subst state =
    let
        canType =
            meta.tipe

        ( monoType0, stateI0 ) =
            applySubstFV state subst canType

        (TOpt.Destructor dname destructorPath destructorMeta) =
            destructor

        maybeValueMultiRefinement =
            case getValueMultiRootFromPath destructorPath stateI0 of
                Just ( rootName, rootCanType ) ->
                    let
                        ( rootResolved, stateRR ) =
                            applySubstFV stateI0 subst rootCanType
                    in
                    if not (Mono.containsAnyMVar rootResolved) then
                        -- Refining a concrete root is harmful, not just redundant: in
                        -- `(v, v, v)` the fillers of the other slots rebind the shared
                        -- variable to a fresh boxed one, so the root's instance would no
                        -- longer match the unboxed layout of the value.
                        Nothing

                    else
                        let
                            ( eagerLeaf, stateRE ) =
                                applySubstFV stateRR subst destructorMeta.tipe

                            destrMonoType0 =
                                eagerLeaf
                        in
                        case buildPartialContainer rootCanType destructorPath destrMonoType0 stateRE of
                            Just ( partialContainerMono, stateP ) ->
                                let
                                    ( refinedSubst, mvarEnv1 ) =
                                        TypeSubst.unifyExtend stateP.ctx.mvarEnv
                                            rootCanType
                                            partialContainerMono
                                            subst

                                    stateR0 =
                                        setMVarEnv mvarEnv1 stateP

                                    ( rootInstanceMonoType, stateR ) =
                                        applySubstFV stateR0 refinedSubst rootCanType

                                    ( freshRootName, stateI ) =
                                        getOrCreateValueInstance rootName
                                            rootInstanceMonoType
                                            refinedSubst
                                            stateR

                                    -- Not refreshed as getOrCreateValueInstance refreshes its
                                    -- key; the tag lookup crashes if the two differ.
                                    instanceKey =
                                        rootInstanceMonoType

                                    taggedStack =
                                        tagValueInstanceWithDestructor rootName
                                            instanceKey
                                            dname
                                            stateI.ctx.valueMulti

                                    stateT =
                                        { stateI
                                            | ctx =
                                                let
                                                    ct =
                                                        stateI.ctx
                                                in
                                                { ct | valueMulti = taggedStack }
                                        }

                                    rewrittenDestructor =
                                        TOpt.Destructor dname
                                            (rewriteRootInPath rootName
                                                freshRootName
                                                destructorPath
                                            )
                                            destructorMeta

                                    stateWithRoot =
                                        { stateT
                                            | ctx =
                                                let
                                                    c =
                                                        stateT.ctx
                                                in
                                                { c
                                                    | varEnv =
                                                        State.insertVar freshRootName
                                                            rootInstanceMonoType
                                                            c.varEnv
                                                }
                                        }
                                in
                                Just ( rewrittenDestructor, refinedSubst, stateWithRoot )

                            Nothing ->
                                Nothing

                Nothing ->
                    Nothing

        ( effectiveDestructor, effectiveSubst, stateForDestruct ) =
            case maybeValueMultiRefinement of
                Just triple ->
                    triple

                Nothing ->
                    ( destructor, subst, stateI0 )

        monoDestructor =
            specializeDestructor stateForDestruct.accum.intern
                effectiveDestructor
                effectiveSubst
                stateForDestruct.ctx.mvarEnv
                stateForDestruct.ctx.varEnv
                stateForDestruct.ctx.globalTypeEnv
                stateForDestruct.ctx.currentGlobal

        (Mono.MonoDestructor destructorName _ destructorType) =
            monoDestructor

        stateWithVar =
            { stateForDestruct
                | ctx =
                    let
                        cd =
                            stateForDestruct.ctx
                    in
                    { cd | varEnv = State.insertVar destructorName destructorType cd.varEnv }
            }

        ( monoBody, stateAfter ) =
            specializeExpr body effectiveSubst stateWithVar

        monoType =
            if Mono.containsAnyMVar monoType0 then
                Mono.typeOf monoBody

            else
                monoType0
    in
    ( Mono.MonoDestruct monoDestructor monoBody monoType, stateAfter )


{-| Returns the `MonoLet` of the single, already specialized definition
`monoDef` of `defName`, for a let that is not copied per use type, together
with its body.

The binding's type is `defCanType` under `subst`, read with the `MVarEnv` of
`state` (the state before the definition was specialized). The type of the
specialized definition is used instead when that type has variables, or when
the definition has a record with more fields at some position (`recordWidened`);
it is then also unified back into the substitution. `probeBody` is a body
already specialized in an earlier attempt: it is kept when the type was not
replaced, and otherwise, or when it is `Nothing`, the body is specialized here
with `defName` in scope. The let's type is `monoType0`, or the body's type when
`monoType0` has variables.

-}
finishEagerLet :
    MonoState
    -> TOpt.Expr MVarId
    -> Maybe Mono.MonoExpr
    -> Name
    -> Can.Type MVarId
    -> Mono.MonoType
    -> Substitution
    -> Mono.MonoDef
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
finishEagerLet state body probeBody defName defCanType monoType0 subst monoDef state1 =
    let
        ( defMonoType0, state1I ) =
            applySubstFVWithEnv state.ctx.mvarEnv state1 subst defCanType

        exprMonoType =
            monoDefExprType monoDef

        useExprType =
            Mono.containsAnyMVar defMonoType0 || recordWidened defMonoType0 exprMonoType

        defMonoType =
            if useExprType then
                exprMonoType

            else
                defMonoType0

        ( enrichedSubst, enrichedEnv ) =
            if useExprType then
                TypeSubst.unifyExtend state1I.ctx.mvarEnv defCanType defMonoType subst

            else
                ( subst, state1I.ctx.mvarEnv )

        stateWithVar =
            { state1I
                | ctx =
                    let
                        c =
                            state1I.ctx
                    in
                    { c
                        | varEnv = State.insertVar defName defMonoType c.varEnv
                        , mvarEnv = enrichedEnv
                    }
            }

        ( monoBody2, state2 ) =
            case ( probeBody, useExprType ) of
                ( Just pb, False ) ->
                    ( pb, stateWithVar )

                _ ->
                    specializeExpr body enrichedSubst stateWithVar
    in
    ( Mono.MonoLet monoDef
        monoBody2
        (if Mono.containsAnyMVar monoType0 then
            Mono.typeOf monoBody2

         else
            monoType0
        )
    , state2
    )


{-| Adds the field `fieldName` of a record literal, specialized, to the front of
the accumulated fields.

When `monoFieldTypes` (the record's type under the substitution) has the field,
the field expression's type is first unified with it, so that a lambda stored
in a field gets the type the record says it has. The order in which fields are
visited is the caller's fold order, and it decides the order of enqueued
specializations.

-}
specializeRecordField :
    Substitution
    -> Dict.Dict Name Mono.MonoType
    -> Name
    -> TOpt.Expr MVarId
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeRecordField subst monoFieldTypes fieldName fieldExpr ( acc, st ) =
    let
        ( refinedSubst, refinedEnv ) =
            case Dict.get fieldName monoFieldTypes of
                Just fieldMonoType ->
                    TypeSubst.unifyExtend st.ctx.mvarEnv (TOpt.typeOf fieldExpr) fieldMonoType subst

                Nothing ->
                    ( subst, st.ctx.mvarEnv )

        ( monoExpr, newSt ) =
            specializeExpr fieldExpr refinedSubst (setMVarEnv refinedEnv st)
    in
    ( ( fieldName, monoExpr ) :: acc, newSt )


{-| Returns the record type whose fields have the types of the specialized
field expressions `monoFields`.

A record literal takes its type from its fields rather than from its canonical
type under the substitution, so that each slot's type matches the value stored
in it.

-}
recordMonoTypeFromFields : List ( Name, Mono.MonoExpr ) -> Mono.MonoType
recordMonoTypeFromFields monoFields =
    Mono.mRecord
        (List.foldl
            (\( fn, e ) acc -> Dict.insert fn (Mono.typeOf e) acc)
            Dict.empty
            monoFields
        )


{-| Returns `expr` specialized under `subst`, with every global specialization it
refers to enqueued and every let-bound copy it demands recorded.

Types are `expr`'s canonical types under `subst`. Where that still leaves a
variable, many cases take the type from what was specialized instead: a list
from its first element, a conditional or case from a branch, a let from its
body, a tail call from the called function's type in scope. Tuples and record
literals always take their type from their parts, and a record update's type is
the result fields over the input record's fields. A record access takes the
field's type from the record's own type when that is more concrete
(`isMoreConcrete`).

A reference to a global, an enumeration value, a boxed constructor, a member
of the current recursive group or an accessor whose type is known is enqueued
(`enqueueSpec`). An accessor whose record type is still open becomes a
`MonoAccessorValue`, which `Compiler.Monomorphize.ResolveAccessorValues`
resolves later. A kernel reference gets the type `deriveKernelAbiType` gives it.

A call specializes its arguments as `processCallArgs` describes and unifies
them with the callee. A global with a monomorphic annotation is applied
directly; any other global goes through its freshened scheme, unified also with
the call's own result type; a kernel's type is its ABI type, and a concrete ABI
result type is preferred over the call's own. A local function destructured
from a value-multi copy refines that copy; a let-bound function being copied
per use type unifies only the arguments, because it shares its variables with
the enclosing scope; anything else goes through a scheme built for it.

A `let` of a function is copied once per type its body uses it at (named
`name`, `name$1`, ...), or specialized once when the body never uses it. A
`let` of a non-function value whose type contains a function and a free
variable is copied once per demanded type (`name`, `name$v1`, ...). A `let`
whose type has a number variable and a shape `isNumericFixableShape` accepts is
specialized eagerly and copied again for each other numeric demand. Any other
`let` is specialized once (`finishEagerLet`). A destructuring whose root is a
number-multi binding, whose bound value is a single number and whose path
`buildPartialContainer` accepts, is specialized body-first
(`specializeNumberDestruct`); other destructurings go through
`specializeGeneralDestruct`.

Every branch of an `if` or `case` is specialized with the conditional's type
pushed onto it when that type is concrete (`pushExpectedType`). A shader
becomes unit.

-}
specializeExpr : TOpt.Expr MVarId -> Substitution -> MonoState -> ( Mono.MonoExpr, MonoState )
specializeExpr expr subst state =
    case expr of
        TOpt.Bool _ value _ ->
            ( Mono.MonoLiteral (Mono.LBool value) Mono.MBool, state )

        TOpt.Chr _ value _ ->
            ( Mono.MonoLiteral (Mono.LChar value) Mono.MChar, state )

        TOpt.Str _ value _ ->
            ( Mono.MonoLiteral (Mono.LStr value) Mono.MString, state )

        TOpt.Int _ value meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType
            in
            case monoType of
                Mono.MFloat ->
                    ( Mono.MonoLiteral (Mono.LFloat (toFloat value)) monoType, stateI )

                _ ->
                    ( Mono.MonoLiteral (Mono.LInt value) monoType, stateI )

        TOpt.Float _ value meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType
            in
            ( Mono.MonoLiteral (Mono.LFloat value) monoType, stateI )

        TOpt.VarLocal name meta ->
            if isLocalMultiTarget name state then
                let
                    ( monoTypeFromMeta, stateI ) =
                        applySubstFV state subst meta.tipe

                    ( freshName, state1 ) =
                        getOrCreateLocalInstance name monoTypeFromMeta subst stateI
                in
                ( Mono.MonoVarLocal freshName monoTypeFromMeta, state1 )

            else if isNumberMultiTarget name state then
                resolveNumberMultiVarRef name meta.tipe subst state

            else
                case State.lookupVar name state.ctx.varEnv of
                    Just envType ->
                        ( Mono.MonoVarLocal name envType, state )

                    Nothing ->
                        let
                            ( monoTypeFromMeta, stateI ) =
                                applySubstFV state subst meta.tipe
                        in
                        ( Mono.MonoVarLocal name monoTypeFromMeta, stateI )

        TOpt.TrackedVarLocal _ name meta ->
            specializeExpr (TOpt.VarLocal name meta) subst state

        TOpt.VarGlobal region global meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                ( monoType, stateM ) =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Data.Map.get TOpt.toComparableGlobal global stateI.ctx.toptNodes of
                                Just (TOpt.Define _ _ defMeta) ->
                                    applySubstFV stateI subst defMeta.tipe

                                Just (TOpt.TrackedDefine _ _ _ defMeta) ->
                                    applySubstFV stateI subst defMeta.tipe

                                Just (TOpt.Enum _ enumCanType) ->
                                    applySubstFV stateI subst enumCanType

                                Just (TOpt.Ctor _ _ ctorCanType) ->
                                    applySubstFV stateI subst ctorCanType

                                _ ->
                                    ( monoType0, stateI )

                        _ ->
                            ( monoType0, stateI )

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType stateM
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarEnum region global _ meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                ( monoType, stateM ) =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Data.Map.get TOpt.toComparableGlobal global stateI.ctx.toptNodes of
                                Just (TOpt.Enum _ enumCanType) ->
                                    applySubstFV stateI subst enumCanType

                                _ ->
                                    ( monoType0, stateI )

                        _ ->
                            ( monoType0, stateI )

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType stateM
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarBox region global meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType stateI
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarCycle region canonical name meta ->
            let
                -- The member's own definition type, not the reference's.
                schemeType =
                    case Data.Map.get TOpt.toComparableGlobal (TOpt.Global canonical name) state.ctx.toptNodes of
                        Just (TOpt.Define _ _ defMeta) ->
                            defMeta.tipe

                        Just (TOpt.TrackedDefine _ _ _ defMeta) ->
                            defMeta.tipe

                        Just (TOpt.Cycle _ _ funcDefs _) ->
                            let
                                maybeDef =
                                    List.filter (\d -> getDefName d == name) funcDefs |> List.head
                            in
                            case maybeDef of
                                Just def ->
                                    getDefCanonicalType def

                                Nothing ->
                                    meta.tipe

                        _ ->
                            meta.tipe

                monoType =
                    TypeSubst.applySubstPureRO state.accum.intern state.ctx.mvarEnv subst schemeType

                monoGlobal =
                    Mono.Global canonical name

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType state
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarDebug region name _ _ meta ->
            let
                canType =
                    meta.tipe

                ( funcMonoType, state1 ) =
                    freshenDebugAbi "Debug" (deriveKernelAbiType state.accum.intern state.ctx.mvarEnv ( "Debug", name ) canType subst) state
            in
            ( Mono.MonoVarKernel region "Elm" "Debug" name funcMonoType, state1 )

        TOpt.VarKernel region kernelPrefix home name meta ->
            let
                canType =
                    meta.tipe

                ( funcMonoType, state1 ) =
                    freshenDebugAbi home (deriveKernelAbiType state.accum.intern state.ctx.mvarEnv ( home, name ) canType subst) state
            in
            ( Mono.MonoVarKernel region kernelPrefix home name funcMonoType, state1 )

        TOpt.List region exprs meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                ( monoExprs, stateAfter ) =
                    specializeExprs exprs subst stateI

                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        case monoExprs of
                            first :: _ ->
                                Mono.mList (Mono.typeOf first)

                            [] ->
                                monoType0

                    else
                        monoType0
            in
            ( Mono.MonoList region monoExprs monoType, stateAfter )

        TOpt.Function srcLam params body meta ->
            let
                canType =
                    meta.tipe
            in
            specializeLambda (TOpt.Function srcLam params body meta) canType subst state

        TOpt.TrackedFunction srcLam params body meta ->
            let
                canType =
                    meta.tipe
            in
            specializeLambda (TOpt.TrackedFunction srcLam params body meta) canType subst state

        TOpt.Call region func args meta ->
            let
                canType =
                    meta.tipe

                ( processedArgs, argTypes, state1 ) =
                    processCallArgs args subst state

                -- Not used for a let-bound function copied per use type, which
                -- starts again from `subst`.
                ( substForCall, mvarEnv1 ) =
                    refineSubstFromArgExprs state1.ctx.mvarEnv args argTypes subst

                state1r =
                    let
                        ctx =
                            state1.ctx
                    in
                    { state1 | ctx = { ctx | mvarEnv = mvarEnv1 } }
            in
            case func of
                TOpt.VarGlobal funcRegion global funcMeta ->
                    let
                        isMonoGlobal =
                            isMonomorphicGlobal global state1r

                        funcCanType : Can.Type MVarId
                        funcCanType =
                            case Data.Map.get TOpt.toComparableGlobal global state1r.ctx.annotations of
                                Just (Can.Forall _ annType) ->
                                    annType

                                Nothing ->
                                    funcMeta.tipe
                    in
                    if isMonoGlobal then
                        -- The annotation generalizes nothing, so no scheme is needed.
                        let
                            funcMonoType =
                                TypeSubst.applySubstPureRO state1r.accum.intern state1r.ctx.mvarEnv substForCall funcCanType

                            state1m =
                                state1r

                            paramTypes =
                                TypeSubst.extractParamTypes funcMonoType

                            ( monoArgs, state2 ) =
                                resolveProcessedArgs processedArgs paramTypes substForCall state1m

                            ( resultMonoType, state2I ) =
                                callResultMonoType
                                    state2.ctx.mvarEnv
                                    state2
                                    substForCall
                                    canType

                            monoGlobal =
                                toptGlobalToMono global

                            ( specId, newState ) =
                                enqueueSpec monoGlobal funcMonoType state2I

                            monoFunc =
                                Mono.MonoVarGlobal funcRegion specId funcMonoType
                        in
                        ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                        , newState
                        )

                    else
                        let
                            ( schemeInfo, state1a ) =
                                getOrBuildSchemeInfo funcCanType (Just global) state1r

                            ( callSubst, funcMonoTypeRaw, callEnv ) =
                                TypeSubst.unifyCallSiteDirectWithExpected
                                    state1a.accum.intern
                                    state1a.ctx.mvarEnv
                                    schemeInfo.argTypes
                                    schemeInfo.resultType
                                    argTypes
                                    (Just canType)
                                    substForCall

                            state1e =
                                setMVarEnv callEnv state1a

                            funcMonoType =
                                funcMonoTypeRaw

                            paramTypes =
                                TypeSubst.extractParamTypes funcMonoType

                            ( monoArgs, state2 ) =
                                resolveProcessedArgs processedArgs paramTypes callSubst state1e

                            ( resultMonoType, state2I ) =
                                callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                            monoGlobal =
                                toptGlobalToMono global

                            ( specId, newState ) =
                                enqueueSpec monoGlobal funcMonoType state2I

                            monoFunc =
                                Mono.MonoVarGlobal funcRegion specId funcMonoType
                        in
                        ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, newState )

                TOpt.VarKernel funcRegion kernelPrefix home name funcMeta ->
                    let
                        funcCanType =
                            funcMeta.tipe

                        ( schemeInfo, state1a ) =
                            getOrBuildSchemeInfo funcCanType Nothing state1r

                        ( callSubst, _, callEnv ) =
                            TypeSubst.unifyCallSiteDirect state1a.accum.intern state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall

                        -- The ABI type is derived from the kernel's own type, not the
                        -- freshened scheme.
                        ( funcMonoType, state1e ) =
                            freshenDebugAbi home
                                (deriveKernelAbiType state.accum.intern state.ctx.mvarEnv ( home, name ) funcCanType callSubst)
                                (setMVarEnv callEnv state1a)

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1e

                        -- A concrete ABI result type wins over the call's own type,
                        -- which may still have variables from a polymorphic wrapper
                        -- (Parser.findSubString returning (Int, Int, Int)).
                        abiResultType =
                            peelCallResult (List.length argTypes) funcMonoType

                        ( resultMonoType, state2I ) =
                            if Mono.containsAnyMVar abiResultType then
                                callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                            else
                                ( abiResultType, state2 )

                        monoFunc =
                            Mono.MonoVarKernel funcRegion kernelPrefix home name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state2I )

                TOpt.VarDebug funcRegion name _ _ funcMeta ->
                    let
                        funcCanType =
                            funcMeta.tipe

                        ( schemeInfo, state1a ) =
                            getOrBuildSchemeInfo funcCanType Nothing state1r

                        ( callSubst, _, callEnv ) =
                            TypeSubst.unifyCallSiteDirect state1a.accum.intern state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall

                        ( funcMonoType, state1e ) =
                            freshenDebugAbi "Debug"
                                (deriveKernelAbiType state.accum.intern state.ctx.mvarEnv ( "Debug", name ) funcCanType callSubst)
                                (setMVarEnv callEnv state1a)

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1e

                        abiResultType =
                            peelCallResult (List.length argTypes) funcMonoType

                        ( resultMonoType, state2I ) =
                            if Mono.containsAnyMVar abiResultType then
                                callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                            else
                                ( abiResultType, state2 )

                        monoFunc =
                            Mono.MonoVarKernel funcRegion "Elm" "Debug" name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state2I )

                _ ->
                    let
                        funcCanType =
                            TOpt.typeOf func

                        maybeFuncName =
                            case func of
                                TOpt.VarLocal name _ ->
                                    Just name

                                TOpt.TrackedVarLocal _ name _ ->
                                    Just name

                                _ ->
                                    Nothing

                        maybeDestructorRefinement =
                            case maybeFuncName of
                                Just fname ->
                                    refineValueMultiForDestructorCall fname
                                        funcCanType
                                        argTypes
                                        state1r.ctx.mvarEnv
                                        state1r.ctx.valueMulti

                                Nothing ->
                                    Nothing

                        localMultiName =
                            case maybeFuncName of
                                Just name ->
                                    if isLocalMultiTarget name state1 then
                                        Just name

                                    else
                                        Nothing

                                Nothing ->
                                    Nothing
                    in
                    case maybeDestructorRefinement of
                        Just ( callSubst, newEnv, newStack ) ->
                            let
                                state1d0 =
                                    let
                                        ctx =
                                            state1r.ctx
                                    in
                                    { state1r
                                        | ctx =
                                            { ctx
                                                | mvarEnv = newEnv
                                                , valueMulti = newStack
                                            }
                                    }

                                ( funcMonoType, state1d ) =
                                    applySubstFV state1d0 callSubst funcCanType

                                paramTypes =
                                    TypeSubst.extractParamTypes funcMonoType

                                ( monoArgs, state2 ) =
                                    resolveProcessedArgs processedArgs paramTypes callSubst state1d

                                ( resultMonoType, state2I ) =
                                    callResultMonoType state2.ctx.mvarEnv state2 callSubst canType

                                ( monoFunc, state3 ) =
                                    specializeExpr func callSubst state2I
                            in
                            ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                            , state3
                            )

                        Nothing ->
                            case localMultiName of
                                Just name ->
                                    -- A let-bound function shares its variables with the
                                    -- enclosing scope, so they are not freshened.
                                    let
                                        ( callSubst, callEnv ) =
                                            TypeSubst.unifyArgsOnly state1.ctx.mvarEnv funcCanType argTypes subst

                                        state1e0 =
                                            setMVarEnv callEnv state1

                                        ( funcMonoType, state1e ) =
                                            applySubstFV state1e0 callSubst funcCanType

                                        paramTypes =
                                            TypeSubst.extractParamTypes funcMonoType

                                        ( monoArgs, state2 ) =
                                            resolveProcessedArgs processedArgs paramTypes callSubst state1e

                                        ( resultMonoType, state2I ) =
                                            callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                                        ( freshName, state3 ) =
                                            getOrCreateLocalInstance name funcMonoType callSubst state2I

                                        monoFunc =
                                            Mono.MonoVarLocal freshName funcMonoType
                                    in
                                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                                    , state3
                                    )

                                Nothing ->
                                    let
                                        ( schemeInfo, state1a ) =
                                            getOrBuildSchemeInfo funcCanType Nothing state1r

                                        ( callSubst, funcMonoTypeRaw, callEnv ) =
                                            TypeSubst.unifyCallSiteDirect state1a.accum.intern state1a.ctx.mvarEnv schemeInfo.argTypes schemeInfo.resultType argTypes substForCall

                                        state1e =
                                            setMVarEnv callEnv state1a

                                        funcMonoType =
                                            funcMonoTypeRaw

                                        paramTypes =
                                            TypeSubst.extractParamTypes funcMonoType

                                        ( monoArgs, state2 ) =
                                            resolveProcessedArgs processedArgs paramTypes callSubst state1e

                                        ( resultMonoType, state2I ) =
                                            callResultMonoType state1e.ctx.mvarEnv state2 callSubst canType

                                        ( monoFunc, state3 ) =
                                            specializeExpr func callSubst state2I
                                    in
                                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                                    , state3
                                    )

        TOpt.TailCall name args meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                ( monoArgs, stateAfter ) =
                    specializeNamedExprs args subst stateI

                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        case State.lookupVar name stateAfter.ctx.varEnv of
                            Just funcType ->
                                Mono.resultTypeOf funcType

                            Nothing ->
                                monoType0

                    else
                        monoType0
            in
            ( Mono.MonoTailCall name monoArgs monoType, stateAfter )

        TOpt.If branches final meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateI ) =
                    applySubstFV state subst canType

                -- The `if`'s type is the demand on every branch: in
                -- `(if c then n else 0) * 1.5` the branch `n` must become a Float.
                ( monoBranches, state1 ) =
                    specializeBranches monoType0 branches subst stateI

                ( monoFinal, state2 ) =
                    let
                        ( pushedSubst, pushedEnv ) =
                            pushExpectedType state1.ctx.mvarEnv monoType0 (TOpt.typeOf final) subst
                    in
                    specializeExpr final pushedSubst (setMVarEnv pushedEnv state1)

                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        Mono.typeOf monoFinal

                    else
                        monoType0
            in
            ( Mono.MonoIf monoBranches monoFinal monoType, state2 )

        TOpt.Let def body meta ->
            let
                canType =
                    meta.tipe

                ( monoType0, stateL ) =
                    applySubstFV state subst canType

                defName =
                    getDefName def

                defCanType =
                    getDefCanonicalType def
            in
            case defCanType of
                Can.TLambda _ _ _ ->
                    let
                        newEntry =
                            { defName = defName
                            , instances = Mono.specMapEmpty
                            }

                        stateForBody =
                            { stateL
                                | ctx =
                                    let
                                        c =
                                            stateL.ctx
                                    in
                                    { c | localMulti = newEntry :: c.localMulti }
                            }

                        ( monoBody, stateAfterBody ) =
                            specializeExpr body subst stateForBody
                    in
                    case stateAfterBody.ctx.localMulti of
                        topEntry :: restOfStack ->
                            if Mono.specMapIsEmpty topEntry.instances then
                                let
                                    ( monoDef, state1 ) =
                                        specializeDef def
                                            subst
                                            { stateAfterBody
                                                | ctx =
                                                    let
                                                        cab =
                                                            stateAfterBody.ctx
                                                    in
                                                    { cab | localMulti = restOfStack }
                                            }
                                in
                                finishEagerLet stateL body (Just monoBody) defName defCanType monoType0 subst monoDef state1

                            else
                                let
                                    instancesList =
                                        Mono.specMapValues topEntry.instances

                                    ( instanceDefs, stateWithDefs ) =
                                        List.foldl
                                            (\info ( defsAcc, stAcc ) ->
                                                let
                                                    ( mergedSubst, mergedEnv ) =
                                                        TypeSubst.unifyExtend stAcc.ctx.mvarEnv defCanType info.monoType subst

                                                    ( monoDef0, st1 ) =
                                                        specializeDef def mergedSubst (setMVarEnv mergedEnv stAcc)

                                                    monoDef =
                                                        renameMonoDef info.freshName monoDef0
                                                in
                                                ( monoDef :: defsAcc, st1 )
                                            )
                                            ( []
                                            , { stateAfterBody
                                                | ctx =
                                                    let
                                                        cab2 =
                                                            stateAfterBody.ctx
                                                    in
                                                    { cab2 | localMulti = restOfStack }
                                              }
                                            )
                                            instancesList

                                    stateWithVars =
                                        List.foldl
                                            (\info st ->
                                                { st
                                                    | ctx =
                                                        let
                                                            cst =
                                                                st.ctx
                                                        in
                                                        { cst
                                                            | varEnv =
                                                                State.insertVar info.freshName info.monoType cst.varEnv
                                                        }
                                                }
                                            )
                                            stateWithDefs
                                            instancesList

                                    finalExpr =
                                        List.foldl
                                            (\def_ accBody -> Mono.MonoLet def_ accBody (Mono.typeOf accBody))
                                            monoBody
                                            instanceDefs
                                in
                                ( finalExpr, stateWithVars )

                        [] ->
                            let
                                ( monoDef, state1 ) =
                                    specializeDef def subst stateAfterBody
                            in
                            finishEagerLet stateL body (Just monoBody) defName defCanType monoType0 subst monoDef state1

                _ ->
                    if shouldUseValueMulti stateL.ctx.mvarEnv defCanType then
                        let
                            newEntry =
                                { defName = defName
                                , defCanType = defCanType
                                , def = def
                                , instances = Mono.specMapEmpty
                                }

                            -- A destructuring let is a let followed by destructs whose root
                            -- is defName, and they look the root up in the environment.
                            ( prelimDefMonoType, stateI ) =
                                applySubstFV stateL subst defCanType

                            stateForBody =
                                { stateI
                                    | ctx =
                                        let
                                            cvm =
                                                stateI.ctx
                                        in
                                        { cvm
                                            | valueMulti = newEntry :: cvm.valueMulti
                                            , varEnv = State.insertVar defName prelimDefMonoType cvm.varEnv
                                        }
                                }

                            ( monoBody, stateAfterBody ) =
                                specializeExpr body subst stateForBody
                        in
                        case stateAfterBody.ctx.valueMulti of
                            topEntry :: restOfStack ->
                                if Mono.specMapIsEmpty topEntry.instances then
                                    let
                                        ( monoDef, state1 ) =
                                            specializeDef def
                                                subst
                                                { stateAfterBody
                                                    | ctx =
                                                        let
                                                            cvmf =
                                                                stateAfterBody.ctx
                                                        in
                                                        { cvmf | valueMulti = restOfStack }
                                                }
                                    in
                                    finishEagerLet stateL body (Just monoBody) defName defCanType monoType0 subst monoDef state1

                                else
                                    -- `info.monoType` is only the instance key; `info.subst` has
                                    -- since been refined by destructors and their calls, so the
                                    -- instance type is derived again from it.
                                    let
                                        instancesList =
                                            Mono.specMapValues topEntry.instances

                                        ( instanceDefs, stateWithDefs ) =
                                            List.foldl
                                                (\info ( defsAcc, stAcc ) ->
                                                    let
                                                        ( instanceDefMonoType0, stAcc1 ) =
                                                            applySubstFVWithEnv stateAfterBody.ctx.mvarEnv stAcc info.subst defCanType

                                                        ( mergedSubst, mergedEnv ) =
                                                            TypeSubst.unifyExtend
                                                                stAcc1.ctx.mvarEnv
                                                                defCanType
                                                                instanceDefMonoType0
                                                                info.subst

                                                        ( monoDef0, st1 ) =
                                                            specializeDef def mergedSubst (setMVarEnv mergedEnv stAcc1)

                                                        monoDef =
                                                            renameMonoDef info.freshName monoDef0
                                                    in
                                                    ( monoDef :: defsAcc, st1 )
                                                )
                                                ( []
                                                , { stateAfterBody
                                                    | ctx =
                                                        let
                                                            cvmi =
                                                                stateAfterBody.ctx
                                                        in
                                                        { cvmi | valueMulti = restOfStack }
                                                  }
                                                )
                                                instancesList

                                        stateWithVars =
                                            List.foldl
                                                (\info st ->
                                                    let
                                                        ( instanceDefMonoType0, st1 ) =
                                                            applySubstFVWithEnv stateAfterBody.ctx.mvarEnv st info.subst defCanType
                                                    in
                                                    { st1
                                                        | ctx =
                                                            let
                                                                cvmv =
                                                                    st1.ctx
                                                            in
                                                            { cvmv
                                                                | varEnv =
                                                                    State.insertVar info.freshName instanceDefMonoType0 cvmv.varEnv
                                                            }
                                                    }
                                                )
                                                stateWithDefs
                                                instancesList

                                        finalExpr =
                                            List.foldl
                                                (\def_ accBody -> Mono.MonoLet def_ accBody (Mono.typeOf accBody))
                                                monoBody
                                                instanceDefs
                                    in
                                    ( finalExpr, stateWithVars )

                            [] ->
                                Utils.Crash.crash "Specialize: valueMulti stack underflow in Let"

                    else if hasUnresolvedNumberVar stateL.ctx.mvarEnv defCanType && isNumericFixableShape (Tuple.first (applySubstFV stateL subst defCanType)) then
                        -- The definition is specialized before the body, not deferred:
                        -- specializing it after the body would scramble the instance
                        -- recording of any let-bound function it calls. The eager copy
                        -- (number variables left open) seeds the value-multi entry, and
                        -- each other numeric demand in the body adds a copy.
                        let
                            ( eagerMonoType0, stateI ) =
                                applySubstFV stateL subst defCanType

                            ( eagerDef, stateEager ) =
                                specializeDef def subst stateI

                            eagerExprMonoType =
                                monoDefExprType eagerDef

                            eagerMonoType =
                                if Mono.containsAnyMVar eagerMonoType0 || recordWidened eagerMonoType0 eagerExprMonoType then
                                    eagerExprMonoType

                                else
                                    eagerMonoType0

                            intKey =
                                TypeSubst.refreshConstraints stateL.ctx.mvarEnv eagerMonoType

                            seededEntry =
                                { defName = defName
                                , defCanType = defCanType
                                , def = def
                                , instances =
                                    Mono.specMapSingleton intKey
                                        { freshName = defName
                                        , monoType = eagerMonoType
                                        , subst = subst
                                        , derivedDestructorNames = Set.empty
                                        }
                                }

                            stateForBody =
                                { stateEager
                                    | ctx =
                                        let
                                            cn =
                                                stateEager.ctx
                                        in
                                        { cn
                                            | valueMulti = seededEntry :: cn.valueMulti
                                            , varEnv = State.insertVar defName eagerMonoType cn.varEnv
                                        }
                                }

                            ( monoBody, stateAfterBody ) =
                                specializeExpr body subst stateForBody
                        in
                        case stateAfterBody.ctx.valueMulti of
                            topEntry :: restOfStack ->
                                let
                                    -- Every instance but the eager one, whatever numeric
                                    -- type the body demanded.
                                    floatInstances =
                                        Mono.specMapValues (Mono.specMapRemove intKey topEntry.instances)

                                    stateRest =
                                        { stateAfterBody
                                            | ctx =
                                                let
                                                    cr =
                                                        stateAfterBody.ctx
                                                in
                                                { cr | valueMulti = restOfStack }
                                        }

                                    ( floatDefs, stateWithDefs ) =
                                        List.foldl
                                            (\info ( defsAcc, stAcc ) ->
                                                let
                                                    ( instanceDefMonoType0, stAcc1 ) =
                                                        applySubstFVWithEnv stateAfterBody.ctx.mvarEnv stAcc info.subst defCanType

                                                    ( mergedSubst, mergedEnv ) =
                                                        TypeSubst.unifyExtend stAcc1.ctx.mvarEnv defCanType instanceDefMonoType0 info.subst

                                                    ( md0, st1 ) =
                                                        specializeDef def mergedSubst (setMVarEnv mergedEnv stAcc1)

                                                    md =
                                                        renameMonoDef info.freshName md0
                                                in
                                                ( md :: defsAcc, st1 )
                                            )
                                            ( [], stateRest )
                                            floatInstances

                                    stateWithVars =
                                        List.foldl
                                            (\info st ->
                                                let
                                                    ( instanceDefMonoType0, st1 ) =
                                                        applySubstFVWithEnv stateAfterBody.ctx.mvarEnv st info.subst defCanType
                                                in
                                                { st1
                                                    | ctx =
                                                        let
                                                            cv =
                                                                st1.ctx
                                                        in
                                                        { cv | varEnv = State.insertVar info.freshName instanceDefMonoType0 cv.varEnv }
                                                }
                                            )
                                            stateWithDefs
                                            floatInstances

                                    bodyWithFloats =
                                        List.foldl
                                            (\d acc -> Mono.MonoLet d acc (Mono.typeOf acc))
                                            monoBody
                                            floatDefs
                                in
                                ( Mono.MonoLet eagerDef
                                    bodyWithFloats
                                    (if Mono.containsAnyMVar monoType0 then
                                        Mono.typeOf bodyWithFloats

                                     else
                                        monoType0
                                    )
                                , stateWithVars
                                )

                            [] ->
                                Utils.Crash.crash "Specialize: number-multi stack underflow in Let"

                    else
                        let
                            ( monoDef, state1 ) =
                                specializeDef def subst stateL
                        in
                        finishEagerLet stateL body Nothing defName defCanType monoType0 subst monoDef state1

        TOpt.Destruct destructor body meta ->
            let
                (TOpt.Destructor dname destructorPath destructorMeta) =
                    destructor
            in
            case getValueMultiRootFromPath destructorPath state of
                Just ( rootName, rootCanType ) ->
                    -- A path buildPartialContainer rejects must not go body-first:
                    -- the destructor would be dropped and its variable left unbound.
                    if isNumberMultiTarget rootName state then
                        let
                            ( eagerLeaf, stateI ) =
                                applySubstFV state subst destructorMeta.tipe

                            fieldIsScalarNumber =
                                case eagerLeaf of
                                    Mono.MInt ->
                                        True

                                    Mono.MFloat ->
                                        True

                                    Mono.MVar _ Mono.CNumber ->
                                        True

                                    _ ->
                                        False
                        in
                        if
                            fieldIsScalarNumber
                                && (case buildPartialContainer rootCanType destructorPath eagerLeaf stateI of
                                        Just _ ->
                                            True

                                        Nothing ->
                                            False
                                   )
                        then
                            specializeNumberDestruct dname destructorPath destructorMeta rootName rootCanType body subst stateI

                        else
                            specializeGeneralDestruct destructor body meta subst stateI

                    else
                        specializeGeneralDestruct destructor body meta subst state

                Nothing ->
                    specializeGeneralDestruct destructor body meta subst state

        TOpt.Case label root decider jumps meta ->
            let
                canType =
                    meta.tipe

                ( monoTypeFromCan, stateI ) =
                    applySubstFV state subst canType

                savedVarEnv =
                    stateI.ctx.varEnv

                ( monoDecider0, state1 ) =
                    specializeDecider monoTypeFromCan root decider subst stateI

                state1WithResetVarEnv =
                    { state1
                        | ctx =
                            let
                                cc =
                                    state1.ctx
                            in
                            { cc | varEnv = savedVarEnv }
                    }

                ( monoJumps0, state2 ) =
                    specializeJumps monoTypeFromCan jumps subst state1WithResetVarEnv
            in
            ( Mono.MonoCase label
                root
                monoDecider0
                monoJumps0
                (if Mono.containsAnyMVar monoTypeFromCan then
                    inferCaseType monoDecider0 monoJumps0 monoTypeFromCan

                 else
                    monoTypeFromCan
                )
            , state2
            )

        TOpt.Accessor region fieldName meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType
            in
            if ResolveAccessorValues.accessorTypeNeedsDefer monoType then
                ( Mono.MonoAccessorValue region fieldName monoType, stateI )

            else
                let
                    accessorGlobal =
                        Mono.Accessor fieldName

                    ( specId, newState ) =
                        enqueueSpec accessorGlobal monoType stateI
                in
                ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.Access record _ fieldName meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateA ) =
                    applySubstFV state subst canType
            in
            case getValueMultiVar record stateA of
                Just ( varName, recordCanType ) ->
                    if isNumberMultiTarget varName stateA then
                        case recordNumberInstanceAgainstShape varName (Mono.mRecord (Dict.singleton fieldName monoType)) subst stateA of
                            Just ( freshName, instMonoType, state1 ) ->
                                ( Mono.MonoRecordAccess (Mono.MonoVarLocal freshName instMonoType) fieldName monoType, state1 )

                            Nothing ->
                                ( Mono.MonoRecordAccess (Mono.MonoVarLocal varName monoType) fieldName monoType, stateA )

                    else
                        let
                            partialRecordMono =
                                Mono.mRecord (Dict.singleton fieldName monoType)

                            ( enrichedSubst, enrichedEnv ) =
                                TypeSubst.unifyExtend stateA.ctx.mvarEnv recordCanType partialRecordMono subst

                            stateE0 =
                                setMVarEnv enrichedEnv stateA

                            ( recordMonoType, stateE ) =
                                applySubstFV stateE0 enrichedSubst recordCanType

                            ( freshName, state1 ) =
                                getOrCreateValueInstance varName recordMonoType enrichedSubst stateE
                        in
                        ( Mono.MonoRecordAccess (Mono.MonoVarLocal freshName recordMonoType) fieldName monoType, state1 )

                Nothing ->
                    let
                        ( monoRecord, stateAfter ) =
                            specializeExpr record subst stateA

                        -- A field whose canonical type has an unbound row variable
                        -- substitutes to a narrower record than the value carries.
                        refinedMonoType =
                            case Mono.typeOf monoRecord of
                                Mono.MRecord _ fields ->
                                    case Dict.get fieldName fields of
                                        Just fieldMono ->
                                            if isMoreConcrete monoType fieldMono then
                                                fieldMono

                                            else
                                                monoType

                                        Nothing ->
                                            monoType

                                _ ->
                                    monoType
                    in
                    ( Mono.MonoRecordAccess monoRecord fieldName refinedMonoType, stateAfter )

        TOpt.Update _ record updates meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stateI ) =
                    applySubstFV state subst canType

                ( monoRecord, state1 ) =
                    specializeExpr record subst stateI

                recordMonoType =
                    Mono.typeOf monoRecord

                getFieldMonoType fieldName =
                    case recordMonoType of
                        Mono.MRecord _ fieldMap ->
                            Dict.get fieldName fieldMap

                        _ ->
                            Nothing

                ( monoUpdates, state2 ) =
                    Data.Map.foldl
                        (\locName updateExpr ( acc, st ) ->
                            let
                                fieldName =
                                    A.toValue locName

                                ( refinedSubst, refinedEnv ) =
                                    case getFieldMonoType fieldName of
                                        Just fieldMonoType ->
                                            TypeSubst.unifyExtend st.ctx.mvarEnv (TOpt.typeOf updateExpr) fieldMonoType subst

                                        Nothing ->
                                            ( subst, st.ctx.mvarEnv )

                                ( monoExpr, newSt ) =
                                    specializeExpr updateExpr refinedSubst (setMVarEnv refinedEnv st)
                            in
                            ( ( fieldName, monoExpr ) :: acc, newSt )
                        )
                        ( [], state1 )
                        updates

                resultMonoType =
                    case ( recordMonoType, monoType ) of
                        ( Mono.MRecord _ recordFields, Mono.MRecord _ resultFields ) ->
                            Mono.mRecord (Dict.union resultFields recordFields)

                        ( Mono.MRecord _ _, _ ) ->
                            Utils.Crash.crash "Specialize.TOpt.Update: record with non-record result type"

                        _ ->
                            Utils.Crash.crash "Specialize.TOpt.Update: input expression is not a record"
            in
            ( Mono.MonoRecordUpdate monoRecord monoUpdates resultMonoType, state2 )

        TOpt.Record fields meta ->
            let
                canType =
                    meta.tipe

                -- Guides each field's substitution only; the record's type comes
                -- from the specialized fields.
                ( refinementMonoType, stateI ) =
                    applySubstFV state subst canType

                monoFieldTypes =
                    case refinementMonoType of
                        Mono.MRecord _ fieldMap ->
                            fieldMap

                        _ ->
                            Dict.empty

                ( monoFields, stateAfter ) =
                    Dict.foldl
                        (specializeRecordField subst monoFieldTypes)
                        ( [], stateI )
                        fields
            in
            ( Mono.MonoRecordCreate monoFields (recordMonoTypeFromFields monoFields), stateAfter )

        TOpt.TrackedRecord _ fields meta ->
            let
                canType =
                    meta.tipe

                ( refinementMonoType, stateI ) =
                    applySubstFV state subst canType

                monoFieldTypes =
                    case refinementMonoType of
                        Mono.MRecord _ fieldMap ->
                            fieldMap

                        _ ->
                            Dict.empty

                ( monoFields, stateAfter ) =
                    Data.Map.foldl
                        (\locName fieldExpr accSt ->
                            specializeRecordField subst monoFieldTypes (A.toValue locName) fieldExpr accSt
                        )
                        ( [], stateI )
                        fields
            in
            ( Mono.MonoRecordCreate monoFields (recordMonoTypeFromFields monoFields), stateAfter )

        TOpt.Unit _ ->
            ( Mono.MonoUnit, state )

        TOpt.Tuple region a b rest _ ->
            let
                ( monoA, state1 ) =
                    specializeExpr a subst state

                ( monoB, state2 ) =
                    specializeExpr b subst state1

                ( monoRest, state3 ) =
                    specializeExprs rest subst state2

                allExprs =
                    monoA :: monoB :: monoRest

                -- From the elements, not meta.tipe, so the slot types match the
                -- values stored even where a canonical variable is unbound.
                monoType =
                    Mono.mTuple (List.map Mono.typeOf allExprs)
            in
            ( Mono.MonoTupleCreate region allExprs monoType, state3 )

        TOpt.Shader _ _ _ _ ->
            ( Mono.MonoUnit, state )


{-| Returns the type of the first shared branch in `jumps` or, when there is
none, the type `inferFromDecider` finds in `decider`, with `fallback` as the
last resort. The first branch's type is taken whether or not it has variables.
-}
inferCaseType : Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Mono.MonoType -> Mono.MonoType
inferCaseType decider jumps fallback =
    case jumps of
        ( _, expr ) :: _ ->
            Mono.typeOf expr

        [] ->
            inferFromDecider decider fallback


{-| Returns the type of the inline branch reached by following the success
edge of every test chain and the first edge of every fan-out in `decider`, or
`fallback` when that leaf is a jump.
-}
inferFromDecider : Mono.Decider Mono.MonoChoice -> Mono.MonoType -> Mono.MonoType
inferFromDecider decider fallback =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            Mono.typeOf expr

        Mono.Leaf (Mono.Jump _) ->
            fallback

        Mono.Chain _ yes _ ->
            inferFromDecider yes fallback

        Mono.FanOut _ branches def ->
            case branches of
                ( _, d ) :: _ ->
                    inferFromDecider d fallback

                [] ->
                    inferFromDecider def fallback



-- ========== EXPRESSION LIST HELPERS ==========


{-| Returns each of `exprs` specialized under `subst`, in order, with the state
threaded from first to last.
-}
specializeExprs : List (TOpt.Expr MVarId) -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeExprs exprs subst state =
    let
        ( revAcc, finalState ) =
            List.foldl
                (\e ( acc, st ) ->
                    let
                        ( me, st1 ) =
                            specializeExpr e subst st
                    in
                    ( me :: acc, st1 )
                )
                ( [], state )
                exprs
    in
    ( List.reverse revAcc, finalState )


{-| Returns `subst` extended by unifying each argument's canonical type with
its MonoType in `argTypes`, paired by position.

This brings what the arguments' types reveal, such as `a = Int` from an
argument of type `List Int`, into the caller's substitution, where the callee's
own types might not provide it.

-}
refineSubstFromArgExprs :
    MVarEnv
    -> List (TOpt.Expr MVarId)
    -> List Mono.MonoType
    -> Substitution
    -> ( Substitution, MVarEnv )
refineSubstFromArgExprs mvarEnv args argTypes subst =
    List.foldl
        (\( expr, argMono ) ( s, env ) ->
            TypeSubst.unifyExtend env (TOpt.typeOf expr) argMono s
        )
        ( subst, mvarEnv )
        (List.map2 Tuple.pair args argTypes)


{-| Returns each of `args` as a `ProcessedArg`, in order, together with the
MonoType each contributes to the call's unification, as `processCallArg`
decides.
-}
processCallArgs :
    List (TOpt.Expr MVarId)
    -> Substitution
    -> MonoState
    -> ( List ProcessedArg, List Mono.MonoType, MonoState )
processCallArgs args subst state =
    let
        ( revArgs, revTypes, finalState ) =
            List.foldl (processCallArg subst) ( [], [], state ) args
    in
    ( List.reverse revArgs, List.reverse revTypes, finalState )


{-| Adds `arg` to the front of the accumulated arguments and their types.

An accessor is always held back. A reference to a let-bound function being
copied per use type, or to a number-multi binding, is held back. A global
reference or a call whose type under `subst` still has variables is held back.
Everything else, kernels included, is specialized at once and contributes its
specialized type.

-}
processCallArg : Substitution -> TOpt.Expr MVarId -> ( List ProcessedArg, List Mono.MonoType, MonoState ) -> ( List ProcessedArg, List Mono.MonoType, MonoState )
processCallArg subst arg ( accArgs, accTypes, st ) =
    case arg of
        TOpt.Accessor region fieldName accessorMeta ->
            let
                accessorCanType =
                    accessorMeta.tipe

                monoType =
                    TypeSubst.applySubstPureRO st.accum.intern st.ctx.mvarEnv subst accessorCanType
            in
            ( PendingAccessor region fieldName accessorCanType :: accArgs
            , monoType :: accTypes
            , st
            )

        TOpt.VarKernel _ _ _ _ _ ->
            let
                ( monoExpr, st1 ) =
                    specializeExpr arg subst st
            in
            ( ResolvedArg monoExpr :: accArgs
            , Mono.typeOf monoExpr :: accTypes
            , st1
            )

        TOpt.VarLocal name localMeta ->
            let
                localCanType =
                    localMeta.tipe
            in
            if isLocalMultiTarget name st then
                let
                    ( monoType, st1 ) =
                        applySubstFV st subst localCanType
                in
                ( LocalFunArg name localCanType :: accArgs
                , monoType :: accTypes
                , st1
                )

            else if isNumberMultiTarget name st then
                -- Its open number type lets a sibling argument or the expected
                -- result decide the number.
                ( PendingNumberValue name localCanType :: accArgs
                , TypeSubst.applySubstPureRO st.accum.intern st.ctx.mvarEnv subst localCanType :: accTypes
                , st
                )

            else
                let
                    ( monoExpr, st1 ) =
                        specializeExpr arg subst st
                in
                ( ResolvedArg monoExpr :: accArgs
                , Mono.typeOf monoExpr :: accTypes
                , st1
                )

        TOpt.TrackedVarLocal _ name trackedLocalMeta ->
            processCallArg subst (TOpt.VarLocal name trackedLocalMeta) ( accArgs, accTypes, st )

        TOpt.Call _ _ _ meta ->
            let
                canType =
                    meta.tipe

                ( monoType, stI ) =
                    applySubstFV st subst canType
            in
            if Mono.containsAnyMVar monoType then
                ( PendingExpr arg subst canType :: accArgs
                , monoType :: accTypes
                , stI
                )

            else
                let
                    ( monoExpr, st1 ) =
                        specializeExpr arg subst stI
                in
                ( ResolvedArg monoExpr :: accArgs
                , Mono.typeOf monoExpr :: accTypes
                , st1
                )

        _ ->
            case arg of
                TOpt.VarGlobal _ _ meta ->
                    let
                        canType =
                            meta.tipe

                        -- An open number stays open, so a sibling argument can make it
                        -- Float (`Array Float` in `Array.foldl (+) 0.0 arr`).
                        monoType =
                            TypeSubst.applySubstPureRO st.accum.intern st.ctx.mvarEnv subst canType
                    in
                    if Mono.containsAnyMVar monoType then
                        ( PendingExpr arg subst canType :: accArgs
                        , monoType :: accTypes
                        , st
                        )

                    else
                        let
                            ( monoExpr, st1 ) =
                                specializeExpr arg subst st
                        in
                        ( ResolvedArg monoExpr :: accArgs
                        , Mono.typeOf monoExpr :: accTypes
                        , st1
                        )

                _ ->
                    let
                        ( monoExpr, st1 ) =
                            specializeExpr arg subst st
                    in
                    ( ResolvedArg monoExpr :: accArgs
                    , Mono.typeOf monoExpr :: accTypes
                    , st1
                    )


{-| Returns the specialized expression for `processedArg`, given the callee's
parameter type at its position (`Nothing` when the callee has fewer parameters
than the call has arguments) and the call's substitution `subst`.

An accessor becomes the accessor global at `{record} -> field`, with the record
taken from the parameter type: either a function from that record, or the
record itself. It crashes when the parameter type is neither or the record
lacks the field. A held-back expression is specialized under its saved
substitution, extended with the parameter type. A let-bound function or a
number-multi binding uses its copy at the parameter type, as `ProcessedArg`
describes; without a usable parameter type the reference keeps its name and is
typed under `subst`.

-}
resolveProcessedArg :
    ProcessedArg
    -> Maybe Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
resolveProcessedArg processedArg maybeParamType subst state =
    case processedArg of
        ResolvedArg monoExpr ->
            ( monoExpr, state )

        PendingAccessor region fieldName _ ->
            case maybeParamType of
                Just (Mono.MFunction _ _ [ Mono.MRecord _ fields ] _) ->
                    let
                        fieldType =
                            case Dict.get fieldName fields of
                                Just ft ->
                                    ft

                                Nothing ->
                                    Utils.Crash.crash ("Specialize.resolveProcessedArg: Field " ++ fieldName ++ " not found in record. This is a compiler bug.")

                        recordType =
                            Mono.mRecord fields

                        accessorMonoType =
                            Mono.mFunction Mono.topDeclOther [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newState ) =
                            enqueueSpec accessorGlobal accessorMonoType state
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                Just (Mono.MRecord _ fields) ->
                    let
                        fieldType =
                            case Dict.get fieldName fields of
                                Just ft ->
                                    ft

                                Nothing ->
                                    Utils.Crash.crash ("Specialize.resolveProcessedArg: Field " ++ fieldName ++ " not found in record (direct). This is a compiler bug.")

                        recordType =
                            Mono.mRecord fields

                        accessorMonoType =
                            Mono.mFunction Mono.topDeclOther [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newState ) =
                            enqueueSpec accessorGlobal accessorMonoType state
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                _ ->
                    Utils.Crash.crash "Specialize.resolveProcessedArg: Accessor argument did not receive a record parameter type after monomorphization. This is a compiler bug."

        PendingExpr savedExpr savedSubst canType ->
            let
                ( refinedSubst, refinedEnv ) =
                    case maybeParamType of
                        Just paramType ->
                            TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType savedSubst

                        Nothing ->
                            ( savedSubst, state.ctx.mvarEnv )
            in
            specializeExpr savedExpr refinedSubst (setMVarEnv refinedEnv state)

        LocalFunArg name canType ->
            case maybeParamType of
                Just paramType ->
                    case paramType of
                        Mono.MFunction _ _ _ _ ->
                            let
                                ( refinedSubst, refinedEnv ) =
                                    TypeSubst.unifyExtend state.ctx.mvarEnv canType paramType subst

                                stateU0 =
                                    setMVarEnv refinedEnv state

                                ( funcMonoType, stateU ) =
                                    applySubstFV stateU0 refinedSubst canType
                            in
                            if isLocalMultiTarget name stateU then
                                let
                                    ( freshName, state1 ) =
                                        getOrCreateLocalInstance
                                            name
                                            funcMonoType
                                            refinedSubst
                                            stateU
                                in
                                ( Mono.MonoVarLocal freshName funcMonoType, state1 )

                            else
                                ( Mono.MonoVarLocal name funcMonoType, stateU )

                        _ ->
                            let
                                ( monoType, state1 ) =
                                    applySubstFV state subst canType
                            in
                            ( Mono.MonoVarLocal name monoType, state1 )

                Nothing ->
                    let
                        ( monoType, state1 ) =
                            applySubstFV state subst canType
                    in
                    ( Mono.MonoVarLocal name monoType, state1 )

        PendingNumberValue name canType ->
            case maybeParamType of
                Just paramType ->
                    case recordNumberInstanceAgainstShape name paramType subst state of
                        Just ( freshName, instMonoType, state1 ) ->
                            ( Mono.MonoVarLocal freshName instMonoType, state1 )

                        Nothing ->
                            let
                                ( monoType, state1 ) =
                                    applySubstFV state subst canType
                            in
                            ( Mono.MonoVarLocal name monoType, state1 )

                Nothing ->
                    let
                        ( monoType, state1 ) =
                            applySubstFV state subst canType
                    in
                    ( Mono.MonoVarLocal name monoType, state1 )


{-| Returns each of `processedArgs` resolved by `resolveProcessedArg` against
the parameter type at the same position in `paramTypes`, in order.
-}
resolveProcessedArgs :
    List ProcessedArg
    -> List Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( List Mono.MonoExpr, MonoState )
resolveProcessedArgs processedArgs paramTypes subst state =
    let
        step processedArg ( acc, st, remainingParams ) =
            let
                ( maybeParam, rest ) =
                    case remainingParams of
                        p :: ps ->
                            ( Just p, ps )

                        [] ->
                            ( Nothing, [] )

                ( monoExpr, st1 ) =
                    resolveProcessedArg processedArg maybeParam subst st
            in
            ( monoExpr :: acc, st1, rest )

        ( revArgs, finalState, _ ) =
            List.foldl step ( [], state, paramTypes ) processedArgs
    in
    ( List.reverse revArgs, finalState )


{-| Returns each named expression specialized under `subst`, in order, keeping
its name.
-}
specializeNamedExprs :
    List ( Name, TOpt.Expr MVarId )
    -> Substitution
    -> MonoState
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeNamedExprs namedExprs subst state =
    let
        ( revAcc, finalState ) =
            List.foldl
                (\( name, e ) ( acc, st ) ->
                    let
                        ( me, st1 ) =
                            specializeExpr e subst st
                    in
                    ( ( name, me ) :: acc, st1 )
                )
                ( [], state )
                namedExprs
    in
    ( List.reverse revAcc, finalState )


{-| Returns `subst` extended by unifying a branch's canonical type `bodyCanType`
with `expectedMono`, the type of the whole conditional, when `expectedMono` has
no variables; otherwise `subst` unchanged.

A branch whose own type still says `number` is thereby specialized at the type
the conditional has, such as `Float`.

-}
pushExpectedType : MVarEnv -> Mono.MonoType -> Can.Type MVarId -> Substitution -> ( Substitution, MVarEnv )
pushExpectedType mvarEnv expectedMono bodyCanType subst =
    if Mono.containsAnyMVar expectedMono then
        ( subst, mvarEnv )

    else
        TypeSubst.unifyExtend mvarEnv bodyCanType expectedMono subst


{-| Returns the condition and body of each `if` branch specialized, in order,
each body after `pushExpectedType` with `expectedMono`.

Every body is specialized in the variable environment the branches started
with. Conditions are not reset that way, and the environment left at the end
is whatever the last body left.

-}
specializeBranches :
    Mono.MonoType
    -> List ( TOpt.Expr MVarId, TOpt.Expr MVarId )
    -> Substitution
    -> MonoState
    -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), MonoState )
specializeBranches expectedMono branches subst state =
    let
        savedVarEnv =
            state.ctx.varEnv

        ( revAcc, finalState ) =
            List.foldl
                (\( cond, body ) ( acc, st ) ->
                    let
                        ( mCond, st1 ) =
                            specializeExpr cond subst st

                        st1WithResetVarTypes =
                            { st1
                                | ctx =
                                    let
                                        c =
                                            st1.ctx
                                    in
                                    { c | varEnv = savedVarEnv }
                            }

                        ( mBody, st2 ) =
                            let
                                ( pushedSubst, pushedEnv ) =
                                    pushExpectedType st1.ctx.mvarEnv expectedMono (TOpt.typeOf body) subst
                            in
                            specializeExpr body pushedSubst (setMVarEnv pushedEnv st1WithResetVarTypes)
                    in
                    ( ( mCond, mBody ) :: acc, st2 )
                )
                ( [], state )
                branches
    in
    ( List.reverse revAcc, finalState )



-- ========== CONSTRUCTOR HELPERS ==========


{-| Returns what a function of type `monoType` returns once `n` arguments are
applied, removing whole parameter lists, so that a parameter list of several
arguments counts for all of them.
-}
extractCtorResultType : Int -> Mono.MonoType -> Mono.MonoType
extractCtorResultType n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ _ args result ->
                extractCtorResultType (n - List.length args) result

            _ ->
                monoType



-- ========== CYCLE SPECIALIZATION HELPERS ==========


{-| Returns whether `def` defines `targetName`.
-}
defHasName : Name -> TOpt.Def MVarId -> Bool
defHasName targetName def =
    case def of
        TOpt.Def _ name _ _ ->
            name == targetName

        TOpt.TailDef _ name _ _ _ _ ->
            name == targetName


{-| Returns the name `def` defines.
-}
getDefName : TOpt.Def MVarId -> Name
getDefName def =
    case def of
        TOpt.Def _ name _ _ ->
            name

        TOpt.TailDef _ name _ _ _ _ ->
            name


{-| Returns the canonical type of `def`. For a plain definition it is the stored
type. For a tail-recursive one it is the parameter types put in front of the
stored type (`buildFuncType`); that stored type is already the whole
definition's type, so the parameters appear twice.
-}
getDefCanonicalType : TOpt.Def MVarId -> Can.Type MVarId
getDefCanonicalType def =
    case def of
        TOpt.Def _ _ _ canType ->
            canType

        TOpt.TailDef _ _ args _ returnType _ ->
            buildFuncType args returnType



-- ========== DEFINITION SPECIALIZATION HELPERS ==========


{-| Returns the local definition `def` specialized under `subst`, keeping its
name. A tail-recursive definition's parameters are typed under `subst`, put in
scope, and unified back into the substitution before its body is specialized.
-}
specializeDef : TOpt.Def MVarId -> Substitution -> MonoState -> ( Mono.MonoDef, MonoState )
specializeDef def subst state =
    case def of
        TOpt.Def _ name expr _ ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoDef name monoExpr, stateAfter )

        TOpt.TailDef _ name args expr _ _ ->
            let
                monoArgs =
                    List.map (specializeArg state.accum.intern state.ctx.mvarEnv subst) args

                ctx =
                    state.ctx

                newVarEnv =
                    List.foldl
                        (\( pname, monoParamType ) ve ->
                            State.insertVar pname monoParamType ve
                        )
                        (State.pushFrame ctx.varEnv)
                        monoArgs

                stateWithParams =
                    { state | ctx = { ctx | varEnv = newVarEnv, mvarEnv = augmentedEnv } }

                ( augmentedSubstRaw, augmentedEnv ) =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) ( s, e ) ->
                            TypeSubst.unifyExtend e canParamType monoParamType s
                        )
                        ( subst, state.ctx.mvarEnv )
                        (List.map2 Tuple.pair args monoArgs)

                ( monoExpr, stateAfterPre ) =
                    specializeExpr expr augmentedSubstRaw stateWithParams

                stateAfter =
                    { stateAfterPre
                        | ctx =
                            let
                                c =
                                    stateAfterPre.ctx
                            in
                            { c | varEnv = State.popFrame c.varEnv }
                    }
            in
            ( Mono.MonoTailDef name monoArgs monoExpr, stateAfter )


{-| Returns the destructor binding `name`, with its path typed step by step
from the root's type in `varEnv` (`specializePath`) and its own type under
`subst`.
-}
specializeDestructor : Intern -> TOpt.Destructor MVarId -> Substitution -> MVarEnv -> VarEnv -> TypeEnv.GlobalTypeEnv -> Maybe Mono.Global -> Mono.MonoDestructor
specializeDestructor intern (TOpt.Destructor name path meta) subst mvarEnv varEnv globalTypeEnv currentGlobal =
    let
        monoPath =
            specializePath intern mvarEnv path varEnv globalTypeEnv currentGlobal name

        monoType =
            TypeSubst.applySubstPureRO intern mvarEnv subst meta.tipe
    in
    Mono.MonoDestructor name monoPath monoType


{-| Returns `path` with a type at every step, each computed from the type of
the step before it, starting from the root variable's type in `varEnv`.

The step types never come from the destructor's canonical type. Crashes when
the root is not in `varEnv` (naming `destructorName` and `currentGlobal`) or a
step does not fit its container type.

-}
specializePath : Intern -> MVarEnv -> TOpt.Path -> VarEnv -> TypeEnv.GlobalTypeEnv -> Maybe Mono.Global -> Name -> Mono.MonoPath
specializePath intern mvarEnv path varEnv globalTypeEnv currentGlobal destructorName =
    case path of
        TOpt.Index index hint subPath ->
            let
                monoSubPath =
                    specializePath intern mvarEnv subPath varEnv globalTypeEnv currentGlobal destructorName

                containerType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    computeIndexProjectionType intern mvarEnv globalTypeEnv hint (Index.toMachine index) containerType
            in
            Mono.MonoIndex (Index.toMachine index) (hintToKind hint) resultType monoSubPath

        TOpt.ArrayIndex idx subPath ->
            let
                monoSubPath =
                    specializePath intern mvarEnv subPath varEnv globalTypeEnv currentGlobal destructorName

                containerType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    computeArrayElementType containerType
            in
            Mono.MonoIndex idx (Mono.CustomContainer "") resultType monoSubPath

        TOpt.Field fieldName subPath ->
            let
                monoSubPath =
                    specializePath intern mvarEnv subPath varEnv globalTypeEnv currentGlobal destructorName

                recordType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    case recordType of
                        Mono.MRecord _ fields ->
                            case Dict.get fieldName fields of
                                Just fieldMonoType ->
                                    fieldMonoType

                                Nothing ->
                                    Utils.Crash.crash
                                        ("Specialize.specializePath: Field '"
                                            ++ fieldName
                                            ++ "' not found in record type. This is a compiler bug."
                                        )

                        _ ->
                            Utils.Crash.crash
                                ("Specialize.specializePath: Expected Mono.mRecord for field path but got: "
                                    ++ Mono.monoTypeToDebugString recordType
                                )
            in
            Mono.MonoField fieldName resultType monoSubPath

        TOpt.Unbox subPath ->
            let
                monoSubPath =
                    specializePath intern mvarEnv subPath varEnv globalTypeEnv currentGlobal destructorName

                containerType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    computeUnboxResultType intern mvarEnv globalTypeEnv containerType
            in
            Mono.MonoUnbox resultType monoSubPath

        TOpt.Root name ->
            let
                rootType =
                    case State.lookupVar name varEnv of
                        Just ty ->
                            ty

                        Nothing ->
                            Utils.Crash.crash ("Specialize.specializePath: Root variable '" ++ name ++ "' not found in VarEnv. Destructor: '" ++ destructorName ++ "'. VarEnv keys: [" ++ String.join ", " (State.varEnvKeys varEnv) ++ "]. Global: " ++ debugGlobal currentGlobal)
            in
            Mono.MonoRoot name rootType


{-| Returns a readable name for `mg`, for crash messages.
-}
debugGlobal : Maybe Mono.Global -> String
debugGlobal mg =
    case mg of
        Nothing ->
            "Nothing"

        Just (Mono.Global (ModuleName.Canonical _ modName) name) ->
            Name.toElmString modName ++ "." ++ name

        Just (Mono.Accessor name) ->
            "Accessor(" ++ name ++ ")"


{-| Returns the type of the element at `index` of a container of type
`containerType`, as `hint` says the container is.

For a list, index 0 is the head and has the element type, and any other index
is the tail and has the list's type. Tuples and custom types are handled by
`computeTupleElementType` and `computeCustomFieldType`. Crashes when the
container type does not fit the hint.

-}
computeIndexProjectionType : Intern -> MVarEnv -> TypeEnv.GlobalTypeEnv -> TOpt.ContainerHint -> Int -> Mono.MonoType -> Mono.MonoType
computeIndexProjectionType intern mvarEnv globalTypeEnv hint index containerType =
    case hint of
        TOpt.HintList ->
            case containerType of
                Mono.MList _ elemType ->
                    if index == 0 then
                        elemType

                    else
                        containerType

                _ ->
                    Utils.Crash.crash ("Specialize.computeIndexProjectionType: HintList at index " ++ String.fromInt index ++ " - Expected Mono.mList but got: " ++ Mono.monoTypeToDebugString containerType)

        TOpt.HintTuple2 ->
            computeTupleElementType index containerType

        TOpt.HintTuple3 ->
            computeTupleElementType index containerType

        TOpt.HintCustom ctorName ->
            computeCustomFieldType intern mvarEnv globalTypeEnv ctorName index containerType


{-| Returns the type of element `index` of the tuple type `containerType`.
Crashes when it is not a tuple or the index is out of range.
-}
computeTupleElementType : Int -> Mono.MonoType -> Mono.MonoType
computeTupleElementType index containerType =
    case containerType of
        Mono.MTuple _ elementTypes ->
            case List.drop index elementTypes of
                elemType :: _ ->
                    elemType

                [] ->
                    Utils.Crash.crash ("Specialize.computeTupleElementType: Tuple index " ++ String.fromInt index ++ " out of bounds for tuple with " ++ String.fromInt (List.length elementTypes) ++ " elements")

        _ ->
            Utils.Crash.crash ("Specialize.computeTupleElementType: Expected Mono.mTuple but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Returns the type of field `index` of constructor `ctorName`, in the custom
type `containerType`: the field's declared type with the union's type
parameters replaced by the container's type arguments.

The union is looked up in `globalTypeEnv` and its parameters are given fresh
ids for the substitution (`Analysis.convertCanTypeNameToMVarId`). Crashes when
the container is not a custom type, or the union, constructor or field is
missing.

-}
computeCustomFieldType : Intern -> MVarEnv -> TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Mono.MonoType
computeCustomFieldType intern mvarEnv globalTypeEnv ctorName index containerType =
    case containerType of
        Mono.MCustom _ moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("Specialize.computeCustomFieldType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    case findCtorByName ctorName unionData.alts of
                        Nothing ->
                            Utils.Crash.crash ("Specialize.computeCustomFieldType: Constructor '" ++ ctorName ++ "' not found in union " ++ typeName)

                        Just (Can.Ctor ctorData) ->
                            case List.drop index ctorData.args of
                                canArgType :: _ ->
                                    let
                                        ( nameToId, mvarEnv1 ) =
                                            List.foldl
                                                (\vn ( acc, e ) ->
                                                    let
                                                        ( mid, e1 ) =
                                                            State.freshMVar Mono.CEcoValue e
                                                    in
                                                    ( Dict.insert vn mid acc, e1 )
                                                )
                                                ( Dict.empty, mvarEnv )
                                                unionData.vars

                                        typeVarSubst =
                                            List.foldl
                                                (\( vn, ta ) s ->
                                                    case Dict.get vn nameToId of
                                                        Just mid ->
                                                            Dict.insert (Id.toComparable mid) ta s

                                                        Nothing ->
                                                            s
                                                )
                                                Dict.empty
                                                (List.map2 Tuple.pair unionData.vars typeArgs)

                                        canArgTypeWithIds =
                                            Analysis.convertCanTypeNameToMVarId nameToId canArgType
                                    in
                                    TypeSubst.applySubstPureRO intern mvarEnv1 typeVarSubst canArgTypeWithIds

                                [] ->
                                    Utils.Crash.crash ("Specialize.computeCustomFieldType: Constructor arg index " ++ String.fromInt index ++ " out of bounds for " ++ ctorName)

        _ ->
            Utils.Crash.crash ("Specialize.computeCustomFieldType: Expected Mono.mCustom for ctor '" ++ ctorName ++ "' index " ++ String.fromInt index ++ " but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Returns the first constructor in `alts` named `targetName`.
-}
findCtorByName : Name -> List Can.Ctor -> Maybe Can.Ctor
findCtorByName targetName alts =
    List.filter (\(Can.Ctor ctorData) -> ctorData.name == targetName) alts
        |> List.head


{-| Returns the type of the one field of the custom type `containerType`, which
must have exactly one constructor with exactly one field, with the union's
type parameters replaced as `computeCustomFieldType` replaces them. Crashes
otherwise.
-}
computeUnboxResultType : Intern -> MVarEnv -> TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Mono.MonoType
computeUnboxResultType intern mvarEnv globalTypeEnv containerType =
    case containerType of
        Mono.MCustom _ moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("Specialize.computeUnboxResultType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor ctorData ] ->
                            case ctorData.args of
                                [ canArgType ] ->
                                    let
                                        ( nameToId, mvarEnv1 ) =
                                            List.foldl
                                                (\vn ( acc, e ) ->
                                                    let
                                                        ( mid, e1 ) =
                                                            State.freshMVar Mono.CEcoValue e
                                                    in
                                                    ( Dict.insert vn mid acc, e1 )
                                                )
                                                ( Dict.empty, mvarEnv )
                                                unionData.vars

                                        typeVarSubst =
                                            List.foldl
                                                (\( vn, ta ) s ->
                                                    case Dict.get vn nameToId of
                                                        Just mid ->
                                                            Dict.insert (Id.toComparable mid) ta s

                                                        Nothing ->
                                                            s
                                                )
                                                Dict.empty
                                                (List.map2 Tuple.pair unionData.vars typeArgs)

                                        canArgTypeWithIds =
                                            Analysis.convertCanTypeNameToMVarId nameToId canArgType
                                    in
                                    TypeSubst.applySubstPureRO intern mvarEnv1 typeVarSubst canArgTypeWithIds

                                _ ->
                                    Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-arg constructor but got " ++ String.fromInt (List.length ctorData.args) ++ " args for " ++ typeName)

                        _ ->
                            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-constructor type but got " ++ String.fromInt (List.length unionData.alts) ++ " constructors for " ++ typeName)

        _ ->
            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected Mono.mCustom but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Returns the element type of `containerType`, which must be a custom type
named `Array` with one argument; crashes otherwise. The type's module is not
checked.
-}
computeArrayElementType : Mono.MonoType -> Mono.MonoType
computeArrayElementType containerType =
    case containerType of
        Mono.MCustom _ _ "Array" [ elemType ] ->
            elemType

        _ ->
            Utils.Crash.crash ("Specialize.computeArrayElementType: Expected Array type but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Returns the container kind of a destructuring path step for `hint`.
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

        TOpt.HintCustom ctorName ->
            Mono.CustomContainer ctorName


{-| Returns the container kind of a decision-tree path step for `hint`. An
unknown hint becomes a custom container with an empty constructor name.
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

        TypedPath.HintCustom ctorName ->
            Mono.CustomContainer ctorName

        TypedPath.HintUnknown ->
            Mono.CustomContainer ""


{-| Returns the destructuring hint that matches the decision-tree hint `hint`,
so that `computeIndexProjectionType` can type decision-tree steps. An unknown
hint becomes a custom hint with an empty constructor name.
-}
dtHintToTOptHint : TypedPath.ContainerHint -> TOpt.ContainerHint
dtHintToTOptHint hint =
    case hint of
        TypedPath.HintList ->
            TOpt.HintList

        TypedPath.HintTuple2 ->
            TOpt.HintTuple2

        TypedPath.HintTuple3 ->
            TOpt.HintTuple3

        TypedPath.HintCustom ctorName ->
            TOpt.HintCustom ctorName

        TypedPath.HintUnknown ->
            TOpt.HintCustom ""


{-| Returns the decision-tree path `dtPath` from the case root `rootName`, with a
type at every step computed from the step before it, starting from the root's
type in `varEnv`. Crashes when the root is not in `varEnv`.
-}
specializeDtPath : Intern -> MVarEnv -> Name -> TypedPath.Path -> VarEnv -> TypeEnv.GlobalTypeEnv -> Mono.MonoDtPath
specializeDtPath intern mvarEnv rootName dtPath varEnv globalTypeEnv =
    let
        rootType =
            case State.lookupVar rootName varEnv of
                Just ty ->
                    ty

                Nothing ->
                    Utils.Crash.crash ("Specialize.specializeDtPath: Root '" ++ rootName ++ "' not in VarEnv")

        go : TypedPath.Path -> Mono.MonoDtPath
        go path =
            case path of
                TypedPath.Empty ->
                    Mono.DtRoot rootName rootType

                TypedPath.Index index hint subPath ->
                    let
                        monoSubPath =
                            go subPath

                        containerType =
                            Mono.dtPathType monoSubPath

                        resultType =
                            computeIndexProjectionType intern mvarEnv globalTypeEnv (dtHintToTOptHint hint) (Index.toMachine index) containerType
                    in
                    Mono.DtIndex (Index.toMachine index) (dtHintToKind hint) resultType monoSubPath

                TypedPath.Unbox subPath ->
                    let
                        monoSubPath =
                            go subPath

                        containerType =
                            Mono.dtPathType monoSubPath

                        resultType =
                            computeUnboxResultType intern mvarEnv globalTypeEnv containerType
                    in
                    Mono.DtUnbox resultType monoSubPath
    in
    go dtPath


{-| Returns the decision tree `decider` of a case on `rootName`, with its paths
typed and its inline branches specialized, each branch with `expectedMono`, the
case's type, pushed onto it (`pushExpectedType`).

The success and failure subtrees of a test chain, and the edges and fallback of
a fan-out, each start from the variable environment the node started with.

-}
specializeDecider : Mono.MonoType -> Name -> TOpt.Decider (TOpt.Choice MVarId) -> Substitution -> MonoState -> ( Mono.Decider Mono.MonoChoice, MonoState )
specializeDecider expectedMono rootName decider subst state =
    case decider of
        TOpt.Leaf choice ->
            let
                ( monoChoice, stateAfter ) =
                    specializeChoice expectedMono choice subst state
            in
            ( Mono.Leaf monoChoice, stateAfter )

        TOpt.Chain testChain success failure ->
            let
                savedVarEnv =
                    state.ctx.varEnv

                monoTestChain =
                    List.map
                        (\( path, test ) ->
                            ( specializeDtPath state.accum.intern state.ctx.mvarEnv rootName path state.ctx.varEnv state.ctx.globalTypeEnv, test )
                        )
                        testChain

                ( monoSuccess, state1 ) =
                    specializeDecider expectedMono rootName success subst state

                state1WithResetVarEnv =
                    { state1
                        | ctx =
                            let
                                c =
                                    state1.ctx
                            in
                            { c | varEnv = savedVarEnv }
                    }

                ( monoFailure, state2 ) =
                    specializeDecider expectedMono rootName failure subst state1WithResetVarEnv
            in
            ( Mono.Chain monoTestChain monoSuccess monoFailure, state2 )

        TOpt.FanOut path edges fallback ->
            let
                savedVarEnv =
                    state.ctx.varEnv

                monoPath =
                    specializeDtPath state.accum.intern state.ctx.mvarEnv rootName path state.ctx.varEnv state.ctx.globalTypeEnv

                ( monoEdges, state1 ) =
                    specializeEdges expectedMono rootName edges subst state

                state1WithResetVarEnv =
                    { state1
                        | ctx =
                            let
                                c =
                                    state1.ctx
                            in
                            { c | varEnv = savedVarEnv }
                    }

                ( monoFallback, state2 ) =
                    specializeDecider expectedMono rootName fallback subst state1WithResetVarEnv
            in
            ( Mono.FanOut monoPath monoEdges monoFallback, state2 )


{-| Returns a decision-tree leaf specialized: an inline branch with
`expectedMono` pushed onto it, or a jump unchanged.
-}
specializeChoice : Mono.MonoType -> TOpt.Choice MVarId -> Substitution -> MonoState -> ( Mono.MonoChoice, MonoState )
specializeChoice expectedMono choice subst state =
    case choice of
        TOpt.Inline expr ->
            let
                ( pushedSubst, pushedEnv ) =
                    pushExpectedType state.ctx.mvarEnv expectedMono (TOpt.typeOf expr) subst

                ( monoExpr, stateAfter ) =
                    specializeExpr expr pushedSubst (setMVarEnv pushedEnv state)
            in
            ( Mono.Inline monoExpr, stateAfter )

        TOpt.Jump index ->
            ( Mono.Jump index, state )


{-| Returns each fan-out edge with its subtree specialized by
`specializeDecider`, in order, each starting from the variable environment the
fan-out started with.
-}
specializeEdges : Mono.MonoType -> Name -> List ( DT.Test, TOpt.Decider (TOpt.Choice MVarId) ) -> Substitution -> MonoState -> ( List ( DT.Test, Mono.Decider Mono.MonoChoice ), MonoState )
specializeEdges expectedMono rootName edges subst state =
    let
        savedVarEnv =
            state.ctx.varEnv

        ( revAcc, finalState ) =
            List.foldl
                (\( test, decider ) ( acc, st ) ->
                    let
                        stWithResetVarEnv =
                            { st
                                | ctx =
                                    let
                                        c =
                                            st.ctx
                                    in
                                    { c | varEnv = savedVarEnv }
                            }

                        ( monoDecider, newSt ) =
                            specializeDecider expectedMono rootName decider subst stWithResetVarEnv
                    in
                    ( ( test, monoDecider ) :: acc, newSt )
                )
                ( [], state )
                edges
    in
    ( List.reverse revAcc, finalState )


{-| Returns the shared branches of a case, each specialized with `expectedMono`
pushed onto it and starting from the variable environment the branches started
with, in order.
-}
specializeJumps : Mono.MonoType -> List ( Int, TOpt.Expr MVarId ) -> Substitution -> MonoState -> ( List ( Int, Mono.MonoExpr ), MonoState )
specializeJumps expectedMono jumps subst state =
    let
        savedVarEnv =
            state.ctx.varEnv

        ( revAcc, finalState ) =
            List.foldl
                (\( idx, expr ) ( acc, st ) ->
                    let
                        stWithResetVarEnv =
                            { st
                                | ctx =
                                    let
                                        c =
                                            st.ctx
                                    in
                                    { c | varEnv = savedVarEnv }
                            }

                        ( pushedSubst, pushedEnv ) =
                            pushExpectedType st.ctx.mvarEnv expectedMono (TOpt.typeOf expr) subst

                        ( monoExpr, newSt ) =
                            specializeExpr expr pushedSubst (setMVarEnv pushedEnv stWithResetVarEnv)
                    in
                    ( ( idx, monoExpr ) :: acc, newSt )
                )
                ( [], state )
                jumps
    in
    ( List.reverse revAcc, finalState )


{-| Returns the type of a specialized local definition: its body's type, or for
a tail-recursive one a curried function from its parameter types to its body's
type.
-}
monoDefExprType : Mono.MonoDef -> Mono.MonoType
monoDefExprType monoDef =
    case monoDef of
        Mono.MonoDef _ monoExpr ->
            Mono.typeOf monoExpr

        Mono.MonoTailDef _ monoArgs monoExpr ->
            List.foldr
                (\( _, argType ) acc -> Mono.mFunction Mono.topDeclOther [ argType ] acc)
                (Mono.typeOf monoExpr)
                monoArgs


{-| Returns the type of a call whose canonical type is `canType`, under the
substitution the call was specialized with, `callSubst`, read with `mvarEnv`.
-}
callResultMonoType : MVarEnv -> MonoState -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MonoState )
callResultMonoType mvarEnv state callSubst canType =
    applySubstFVWithEnv mvarEnv state callSubst canType


{-| Returns a parameter's name and its type under `subst`.
-}
specializeArg : Intern -> MVarEnv -> Substitution -> ( A.Located Name, Can.Type MVarId ) -> ( Name, Mono.MonoType )
specializeArg intern mvarEnv subst ( locName, canType ) =
    let
        name =
            A.toValue locName

        monoType =
            TypeSubst.applySubstPureRO intern mvarEnv subst canType
    in
    ( name, monoType )


{-| Returns the curried function type from the parameter types of `args` to
`returnType`, built with `Can.tLambda`.
-}
buildFuncType : List ( A.Located Name, Can.Type MVarId ) -> Can.Type MVarId -> Can.Type MVarId
buildFuncType args returnType =
    List.foldr
        (\( _, argType ) acc ->
            Can.tLambda argType acc
        )
        returnType
        args


{-| Returns the layout of a constructor named `ctorName` with tag `tag`: the
parameter types `extractFieldTypes` takes from `ctorMonoType` for `arity`
fields (whole parameter lists, so possibly more than `arity`).
-}
buildCtorShapeFromArity : Name.Name -> Int -> Int -> Mono.MonoType -> Mono.CtorShape
buildCtorShapeFromArity ctorName tag arity ctorMonoType =
    let
        fieldTypes =
            extractFieldTypes arity ctorMonoType
    in
    { name = ctorName
    , tag = tag
    , fieldTypes = fieldTypes
    }


{-| Returns the parameter types of the function type `monoType` across nested
function types, taking whole parameter lists until at least `n` have been
taken, so it can return more than `n`. Stops early at a type that is not a
function.
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


{-| Returns whether `monoType` has no boxed type variable. An open number
variable counts as monomorphic, since it is closed to `Int` before code
generation.
-}
isFullyMonomorphicType : Mono.MonoType -> Bool
isFullyMonomorphicType monoType =
    case monoType of
        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MVar _ Mono.CEcoValue ->
            False

        Mono.MList _ inner ->
            isFullyMonomorphicType inner

        Mono.MFunction _ _ args result ->
            List.all isFullyMonomorphicType args
                && isFullyMonomorphicType result

        Mono.MTuple _ elems ->
            List.all isFullyMonomorphicType elems

        Mono.MRecord _ fields ->
            Dict.foldl
                (\_ fieldType acc -> acc && isFullyMonomorphicType fieldType)
                True
                fields

        Mono.MCustom _ _ _ args ->
            List.all isFullyMonomorphicType args

        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MBool ->
            True

        Mono.MChar ->
            True

        Mono.MString ->
            True

        Mono.MUnit ->
            True



-- ========== KERNEL ABI TYPE DERIVATION ==========


{-| Gives the `CEcoValue` variables of a kernel's ABI type fresh ids from the
state's `MVarEnv` when the kernel's home module is always polymorphic
(`Debug`); any other kernel's ABI type is returned unchanged. Kept at their
source ids the variables may be number variables of the enclosing definition
(`bump n = Debug.log "n" (n + 1)`), which `Compiler.Monomorphize.Prune` would
close to `MInt` even in a `Float` specialization, giving the kernel an unboxed
`Int` parameter. The solver engine does the same in
`Compiler.MonoSolver.Translate.deriveKernelAbiTypeWith`.
-}
freshenDebugAbi : String -> Mono.MonoType -> MonoState -> ( Mono.MonoType, MonoState )
freshenDebugAbi home abiType state =
    if not (EverySet.member List.singleton home KernelAbi.alwaysPolymorphicModules) then
        ( abiType, state )

    else
        freshenKernelAbiVars abiType state


{-| Returns `abiType` with its boxed variables renumbered from the state's next
free id (`KernelAbi.remapEcoVarsFresh`), and the state with that counter
advanced.
-}
freshenKernelAbiVars : Mono.MonoType -> MonoState -> ( Mono.MonoType, MonoState )
freshenKernelAbiVars abiType state =
    let
        env =
            state.ctx.mvarEnv

        ( freshAbi, nextId ) =
            KernelAbi.remapEcoVarsFresh env.nextId abiType
    in
    ( freshAbi, setMVarEnv { env | nextId = nextId } state )


{-| Returns the kernel ABI type for a reference to the kernel `kernelId` of
canonical type `canFuncType`, under the call's substitution `callSubst`.

Under `KernelAbi.UseSubstitution` it is the canonical type under the
substitution. Under `PreserveVars` it is the type under the substitution only
when the kernel is in `KernelAbi.suffixSelectingKernels` and that type is
monomorphic by `isFullyMonomorphicType`, which counts an open number variable
as monomorphic; otherwise every type variable is boxed
(`KernelAbi.canTypeToMonoType_preserveVars`), a number variable included.

-}
deriveKernelAbiType : Intern -> MVarEnv -> ( String, String ) -> Can.Type MVarId -> Substitution -> Mono.MonoType
deriveKernelAbiType intern mvarEnv kernelId canFuncType callSubst =
    let
        monoAfterSubst : Mono.MonoType
        monoAfterSubst =
            TypeSubst.applySubstPureRO intern mvarEnv callSubst canFuncType

        mode : KernelAbi.KernelAbiMode
        mode =
            KernelAbi.deriveKernelAbiMode kernelId canFuncType
    in
    case mode of
        KernelAbi.UseSubstitution ->
            monoAfterSubst

        KernelAbi.PreserveVars ->
            if
                EverySet.member KernelAbi.comparePair kernelId KernelAbi.suffixSelectingKernels
                    && isFullyMonomorphicType monoAfterSubst
            then
                monoAfterSubst

            else
                Tuple.first (KernelAbi.canTypeToMonoType_preserveVars mvarEnv canFuncType)



-- ========== GLOBAL CONVERSIONS ==========


{-| Returns the monomorphized global for the same module and name.
-}
toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name



-- ========== LOCAL FUNCTION CLONE HELPERS ==========


{-| Returns `def` bound under `newName`. A tail-recursive definition also has
its self tail calls renamed (`renameTailCalls`).
-}
renameMonoDef : Name -> Mono.MonoDef -> Mono.MonoDef
renameMonoDef newName def =
    case def of
        Mono.MonoDef oldName expr ->
            Mono.MonoDef newName (Traverse.renameLocal oldName newName expr)

        Mono.MonoTailDef oldName args expr ->
            Mono.MonoTailDef newName args (renameTailCalls oldName newName expr)


{-| Returns `expr` with every tail call of `oldName` made a tail call of
`newName`, at any depth, and every tail-recursive local definition named
`oldName` renamed too; no other reference is renamed.
-}
renameTailCalls : Name -> Name -> Mono.MonoExpr -> Mono.MonoExpr
renameTailCalls oldName newName expr =
    case expr of
        Mono.MonoTailCall name args resultType ->
            Mono.MonoTailCall
                (if name == oldName then
                    newName

                 else
                    name
                )
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) args)
                resultType

        Mono.MonoCall region func args resultType callInfo ->
            Mono.MonoCall region
                (renameTailCalls oldName newName func)
                (List.map (renameTailCalls oldName newName) args)
                resultType
                callInfo

        Mono.MonoIf branches final resultType ->
            Mono.MonoIf
                (List.map (\( c, t ) -> ( renameTailCalls oldName newName c, renameTailCalls oldName newName t )) branches)
                (renameTailCalls oldName newName final)
                resultType

        Mono.MonoLet def_ body resultType ->
            let
                newDef =
                    case def_ of
                        Mono.MonoDef n bound ->
                            Mono.MonoDef n (renameTailCalls oldName newName bound)

                        Mono.MonoTailDef n params bound ->
                            Mono.MonoTailDef
                                (if n == oldName then
                                    newName

                                 else
                                    n
                                )
                                params
                                (renameTailCalls oldName newName bound)
            in
            Mono.MonoLet newDef (renameTailCalls oldName newName body) resultType

        Mono.MonoClosure info body closureType ->
            Mono.MonoClosure info (renameTailCalls oldName newName body) closureType

        Mono.MonoList region items t ->
            Mono.MonoList region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoTupleCreate region items t ->
            Mono.MonoTupleCreate region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoRecordCreate fields t ->
            Mono.MonoRecordCreate
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) fields)
                t

        Mono.MonoRecordUpdate record updates t ->
            Mono.MonoRecordUpdate
                (renameTailCalls oldName newName record)
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) updates)
                t

        Mono.MonoRecordAccess record fieldName t ->
            Mono.MonoRecordAccess (renameTailCalls oldName newName record) fieldName t

        Mono.MonoDestruct destructor body t ->
            Mono.MonoDestruct destructor (renameTailCalls oldName newName body) t

        Mono.MonoCase scrutName scrutVar decider jumps t ->
            Mono.MonoCase scrutName
                scrutVar
                (renameTailCallsDecider oldName newName decider)
                (List.map (\( i, e ) -> ( i, renameTailCalls oldName newName e )) jumps)
                t

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


{-| Returns `decider` with tail calls renamed in every inline branch, as
`renameTailCalls` renames them.
-}
renameTailCallsDecider : Name -> Name -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
renameTailCallsDecider oldName newName decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (renameTailCallsChoice oldName newName choice)

        Mono.Chain tests success failure ->
            Mono.Chain tests
                (renameTailCallsDecider oldName newName success)
                (renameTailCallsDecider oldName newName failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, renameTailCallsDecider oldName newName d )) edges)
                (renameTailCallsDecider oldName newName fallback)


{-| Returns a decision-tree leaf with tail calls renamed in an inline branch; a
jump is unchanged.
-}
renameTailCallsChoice : Name -> Name -> Mono.MonoChoice -> Mono.MonoChoice
renameTailCallsChoice oldName newName choice =
    case choice of
        Mono.Inline e ->
            Mono.Inline (renameTailCalls oldName newName e)

        Mono.Jump i ->
            Mono.Jump i



-- ========== ARRAY HELPERS ==========


{-| Returns whether `arr` holds a `Just` at `index`.
-}
arrayHasNode : Int -> Array.Array (Maybe a) -> Bool
arrayHasNode index arr =
    case Array.get index arr of
        Just (Just _) ->
            True

        _ ->
            False


{-| Returns `arr` with `value` at `index`, first padding the array with
`Nothing` up to that index when it is too short.
-}
arraySetGrowing : Int -> Maybe a -> Array.Array (Maybe a) -> Array.Array (Maybe a)
arraySetGrowing index value arr =
    let
        len =
            Array.length arr
    in
    if index < len then
        Array.set index value arr

    else
        Array.set index value (Array.append arr (Array.repeat (index - len + 1) Nothing))
