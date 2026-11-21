module Compiler.Monomorphize.RepresentationMeets exposing
    ( Meet, Via(..), collect, collectWithMoveOnly, translate, Components, components, componentOf
    , SlotKind(..), slotKindOf
    , movesOnly
    , validate
    )

{-| Representation meets (plans/constructor-representation-levels.md §5, unit V):
every place where the monomorphized graph records two different `MonoType`s for
one runtime value, such as an argument and the parameter it is passed to, or a
variable's binding and a use of it. A kernel call is not a meet: a kernel's
parameters are type variables by its boxed ABI, and what a kernel may do with a
value is the concern of the kernel-visibility set (`Compiler.MonoOpt.KernelVisible`).

MONO_029 promises that two such views agree at every interior position: either
both are concretely equal or both are erased. `ValidateLayout` checks only part
of that. A representation pass that changes how a type is laid out per
instantiation (an unboxed wrapper, a nullable `Maybe`) must know every view a
value has, or a concrete view and an erased view of the same value would read
it differently. This module finds the views, groups them into components, and
checks the result.

A `Meet` is two types for one value, and whether they meet at the top of the
value (`root`) or inside it, under a constructor, list, tuple, record or
function arrow. Call-boundary boxing (CGEN_001) repairs a root disagreement
between an unboxed primitive and `!eco.value`; nothing repairs an interior one.

@docs Meet, Via, collect, collectWithMoveOnly, translate, Components, components, componentOf
@docs SlotKind, slotKindOf
@docs movesOnly
@docs validate

-}

import Array
import Compiler.IR.Kernel.Visibility as Visibility
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as Traverse
import Data.NonEmptyList as NE
import Dict exposing (Dict)
import Set exposing (Set)


{-| Two types recorded for one value, met at its top (`root`) or inside it.
`spec` is the SpecId of the node it was found in and `site` names the kind of
place; both are only printed (`validate`), so they are kept apart rather than
formatted into one string for every meet.
-}
type alias Meet =
    { a : Mono.MonoType
    , b : Mono.MonoType
    , root : Bool
    , spec : Int
    , site : String
    , via : Via
    }


{-| What the second view of a meet is (plans/constructor-representation-followups.md
F4). `ViaKernelAlias home name` marks a meet between a use of a global and the
global's node when that node is a pure forward of the kernel `home.name`
(`MonoDefine (MonoVarKernel …)`): the shared specialization AliasForward keeps
for a kernel whose ABI is not fixed, whose types are the kernel's, with type
variables where the kernel's are. Every other meet is `ViaOther`. A meet's `b`
is the node's view (`splitAt site useType nodeType`), at every interior position
too.
-}
type Via
    = ViaKernelAlias String String
    | ViaOther


{-| Whether the meet `m` only moves its value through a type variable: its
second view is a type variable (`m.b`, the node's side) of a pure-forward alias
of a kernel that `Compiler.IR.Kernel.Visibility.kernelUse` lists and that is not
a `Debug` kernel. Such a kernel never looks inside a value of a type variable
(the review that built the table defines it so); a single value crosses into it
boxed (REP_ABI_001) and a container carries the slot kinds the kernel reads, as
`List Float` and `Array Int` already do. So the meet constrains no
representation: `EraseWrappers`, `NullableMaybe` and `validate` skip it. A
`Debug` kernel at a type variable prints untyped, and an unlisted kernel may
look inside, so neither is move-only; kernel visibility does not see through an
alias's type variable, so for those this rule is the only protection.
-}
movesOnly : Meet -> Bool
movesOnly m =
    case ( m.via, m.b ) of
        ( ViaKernelAlias home name, Mono.MVar _ _ ) ->
            home /= "Debug" && Dict.member ( home, name ) Visibility.kernelUse

        _ ->
            False


{-| How a value of a type is held in a heap slot: unboxed as an Int, a Float or
a Char, or boxed.
-}
type SlotKind
    = KInt
    | KFloat
    | KChar
    | KBoxed


{-| The slot kind of a type (REP_HEAP_001: only Int, Float and Char are
unboxed).
-}
slotKindOf : Mono.MonoType -> SlotKind
slotKindOf t =
    case t of
        Mono.MInt ->
            KInt

        Mono.MFloat ->
            KFloat

        Mono.MChar ->
            KChar

        _ ->
            KBoxed



-- ====== COLLECTION ======


type alias Env =
    Dict String Mono.MonoType


{-| Every meet of two different types in `graph`, each split into its parts, except the meets
that only move a value through a kernel alias's type variable (`movesOnly`): no representation
choice is constrained by one (plans/constructor-representation-followups.md F4), so they are not
collected.
-}
collect : Mono.MonoGraph -> List Meet
collect graph =
    collectWith False graph


{-| `collect` with the move-only meets kept, for the census that counts them.
-}
collectWithMoveOnly : Mono.MonoGraph -> List Meet
collectWithMoveOnly graph =
    collectWith True graph


collectWith : Bool -> Mono.MonoGraph -> List Meet
collectWith keepMoveOnly (Mono.MonoGraph g) =
    let
        -- Each node's type once, not at every reference to it (a constructor's is built).
        nodeTypes : Array.Array (Maybe ( Mono.MonoType, Via ))
        nodeTypes =
            Array.map (Maybe.andThen nodeTypeOfNode) g.nodes

        nodeTypeOf : Int -> Maybe ( Mono.MonoType, Via )
        nodeTypeOf specId =
            Array.get specId nodeTypes |> Maybe.andThen identity

        nodeTypeOfNode : Mono.MonoNode -> Maybe ( Mono.MonoType, Via )
        nodeTypeOfNode node =
            case node of
                Mono.MonoCtor _ shape t ->
                    if List.isEmpty shape.fieldTypes then
                        Just ( t, ViaOther )

                    else
                        Just ( Mono.mFunction Mono.topSynth shape.fieldTypes t, ViaOther )

                Mono.MonoEnum _ _ _ t ->
                    Just ( t, ViaOther )

                Mono.MonoDefine (Mono.MonoVarKernel _ _ home name _) _ ->
                    Just ( Mono.nodeType node, ViaKernelAlias home name )

                _ ->
                    Just ( Mono.nodeType node, ViaOther )
    in
    Array.foldl
        (\maybeNode ( acc, i ) ->
            case maybeNode of
                Just node ->
                    ( nodeMeets nodeTypeOf node []
                        |> List.filterMap
                            (\m ->
                                if keepMoveOnly || not (movesOnly m) then
                                    Just { m | spec = i }

                                else
                                    Nothing
                            )
                        |> (\ms -> ms ++ acc)
                    , i + 1
                    )

                Nothing ->
                    ( acc, i + 1 )
        )
        ( [], 0 )
        g.nodes
        |> Tuple.first


nodeMeets : (Int -> Maybe ( Mono.MonoType, Via )) -> Mono.MonoNode -> List Meet -> List Meet
nodeMeets nodeTypeOf node acc =
    case node of
        Mono.MonoDefine expr t ->
            splitAt "define" (Mono.typeOf expr) t True (exprMeets nodeTypeOf Dict.empty expr acc)

        Mono.MonoTailFunc params expr _ ->
            exprMeets nodeTypeOf (Dict.fromList params) expr acc

        Mono.MonoPortIncoming expr _ ->
            exprMeets nodeTypeOf Dict.empty expr acc

        Mono.MonoPortOutgoing expr _ ->
            exprMeets nodeTypeOf Dict.empty expr acc

        _ ->
            acc


{-| The meets of a graph whose every type was rewritten by `f`, from the meets
of the graph before: each meet's two types rewritten and split again, so that a
pair `f` makes layout-equal drops out and a part the rewritten types newly
differ in is recorded. A pass that rewrites types (`EraseWrappers`) uses it
instead of collecting again. It is not the same list as a fresh `collect`: an
expression the pass removes (an erased constructor call) leaves its meets
behind, rewritten. `Compiler.Pipeline.Steps.representation` checks, under
validation, that the difference never changes a decision taken from the meets.
A meet the rewrite makes move-only (an erased wrapper of a type variable on the
node side) is dropped, as `collect` drops one.
-}
translate : (Mono.MonoType -> Mono.MonoType) -> List Meet -> List Meet
translate f meets =
    List.foldl
        (\m acc ->
            List.filterMap
                (\m1 ->
                    let
                        m2 =
                            { m1 | spec = m.spec, via = m.via }
                    in
                    if movesOnly m2 then
                        Nothing

                    else
                        Just m2
                )
                (splitAt m.site (f m.a) (f m.b) m.root [])
                ++ acc
        )
        []
        meets


{-| Records the meet of `a` and `b`, and of their corresponding parts, when
they differ.
-}
split : Mono.MonoType -> Mono.MonoType -> Bool -> List Meet -> List Meet
split a b root acc =
    splitAt "" a b root acc


splitAt : String -> Mono.MonoType -> Mono.MonoType -> Bool -> List Meet -> List Meet
splitAt site a b root acc =
    -- Two views that differ only in lambda sets or in the ids of erased type variables lay a value out
    -- alike; they are not a meet.
    if Mono.eqKeyLayout a b then
        acc

    else
        case ( a, b ) of
            ( Mono.MVar _ _, _ ) ->
                { a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc

            ( _, Mono.MVar _ _ ) ->
                { a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc

            ( Mono.MList _ x, Mono.MList _ y ) ->
                splitAt site x y False ({ a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc)

            ( Mono.MTuple _ xs, Mono.MTuple _ ys ) ->
                List.foldl (\( x, y ) ac -> splitAt site x y False ac)
                    ({ a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc)
                    (List.map2 Tuple.pair (Mono.tupleToList xs) (Mono.tupleToList ys))

            ( Mono.MRecord _ xs, Mono.MRecord _ ys ) ->
                Dict.foldl
                    (\name x ac ->
                        case Dict.get name ys of
                            Just y ->
                                splitAt site x y False ac

                            Nothing ->
                                ac
                    )
                    ({ a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc)
                    xs

            ( Mono.MCustom _ h1 n1 xs, Mono.MCustom _ h2 n2 ys ) ->
                if h1 == h2 && n1 == n2 then
                    List.foldl (\( x, y ) ac -> splitAt site x y False ac)
                        ({ a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc)
                        (List.map2 Tuple.pair xs ys)

                else
                    { a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc

            ( Mono.MFunction _ _ ps r, Mono.MFunction _ _ qs s ) ->
                if List.length ps == List.length qs then
                    List.foldl (\( x, y ) ac -> splitAt site x y False ac)
                        (splitAt site r s False ({ a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc))
                        (List.map2 Tuple.pair ps qs)

                else
                    { a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc

            _ ->
                { a = a, b = b, root = root, spec = -1, site = site, via = ViaOther } :: acc


{-| The type left after applying a function of type `t` to `n` arguments, when
`n` ends exactly at a stage boundary.
-}
applied : Int -> Mono.MonoType -> Maybe Mono.MonoType
applied n t =
    if n == 0 then
        Just t

    else
        case t of
            Mono.MFunction _ _ params result ->
                let
                    k =
                        List.length params
                in
                if n >= k then
                    applied (n - k) result

                else
                    Nothing

            _ ->
                Nothing


exprMeets : (Int -> Maybe ( Mono.MonoType, Via )) -> Env -> Mono.MonoExpr -> List Meet -> List Meet
exprMeets nodeTypeOf env expr acc =
    let
        recur e a =
            exprMeets nodeTypeOf env e a

        children a =
            List.foldl recur a (Traverse.childrenOf expr)
    in
    case expr of
        Mono.MonoVarLocal name t ->
            case Dict.get name env of
                Just bound ->
                    splitAt "local" bound t True acc

                Nothing ->
                    acc

        Mono.MonoVarGlobal _ specId t ->
            case nodeTypeOf specId of
                Just ( nt, via ) ->
                    if Mono.eqKeyLayout t nt then
                        acc

                    else
                        List.map (\m -> { m | via = via }) (splitAt ("global->" ++ String.fromInt specId) t nt True [])
                            ++ acc

                Nothing ->
                    acc

        Mono.MonoCall _ (Mono.MonoVarKernel _ _ _ _ _) _ _ _ ->
            -- A kernel's parameters are type variables by its boxed ABI (KernelAbi); what a kernel
            -- may do with a value is the kernel-visibility set's concern (KernelVisible), not a meet.
            children acc

        Mono.MonoCall _ func args t _ ->
            let
                ft =
                    Mono.typeOf func

                ( params, _ ) =
                    Mono.decomposeFunctionType ft

                acc1 =
                    List.foldl (\( arg, p ) ac -> splitAt "callArg" (Mono.typeOf arg) p True ac)
                        acc
                        (List.map2 Tuple.pair args params)

                acc2 =
                    case applied (List.length args) ft of
                        Just r ->
                            splitAt "callResult" r t True acc1

                        Nothing ->
                            acc1
            in
            children acc2

        Mono.MonoClosure info body _ ->
            let
                env1 =
                    List.foldl (\( n, e, _ ) d -> Dict.insert n (Mono.typeOf e) d)
                        (List.foldl (\( n, t ) d -> Dict.insert n t d) env info.params)
                        info.captures

                acc1 =
                    List.foldl (\( _, e, _ ) ac -> recur e ac) acc info.captures
            in
            exprMeets nodeTypeOf env1 body acc1

        Mono.MonoLet def body t ->
            let
                ( env1, acc1 ) =
                    case def of
                        Mono.MonoDef name e ->
                            ( Dict.insert name (Mono.typeOf e) env, exprMeets nodeTypeOf (Dict.insert name (Mono.typeOf e) env) e acc )

                        Mono.MonoTailDef _ params e ->
                            ( env, exprMeets nodeTypeOf (List.foldl (\( n, pt ) d -> Dict.insert n pt d) env params) e acc )
            in
            splitAt "letBody" (Mono.typeOf body) t True (exprMeets nodeTypeOf env1 body acc1)

        Mono.MonoDestruct (Mono.MonoDestructor name path ty) inner t ->
            let
                env1 =
                    Dict.insert name ty env

                acc1 =
                    pathRootMeet env path (splitAt "destructPath" (Mono.getMonoPathType path) ty True acc)
            in
            splitAt "destructBody" (Mono.typeOf inner) t True (exprMeets nodeTypeOf env1 inner acc1)

        Mono.MonoCase _ _ decider jumps t ->
            let
                acc1 =
                    deciderRootMeets env decider acc

                branchTypes =
                    List.map (Mono.typeOf << Tuple.second) jumps ++ inlineLeafTypes decider []

                acc2 =
                    List.foldl (\bt ac -> splitAt "caseBranch" bt t True ac) acc1 branchTypes

            in
            children acc2

        Mono.MonoIf branches final t ->
            let
                acc1 =
                    List.foldl (\( _, e ) ac -> splitAt "if" (Mono.typeOf e) t True ac) (split (Mono.typeOf final) t True acc) branches
            in
            children acc1

        Mono.MonoList _ items t ->
            case t of
                Mono.MList _ elem ->
                    children (List.foldl (\i ac -> splitAt "list" (Mono.typeOf i) elem True ac) acc items)

                _ ->
                    children acc

        Mono.MonoTupleCreate _ elems t ->
            case t of
                Mono.MTuple _ slots ->
                    children (List.foldl (\( e, s ) ac -> splitAt "tuple" (Mono.typeOf e) s True ac) acc (List.map2 Tuple.pair (Mono.tupleToList elems) (Mono.tupleToList slots)))

                _ ->
                    children acc

        Mono.MonoRecordCreate fields t ->
            case t of
                Mono.MRecord _ fts ->
                    children
                        (List.foldl
                            (\( n, e ) ac ->
                                case Dict.get n fts of
                                    Just ft ->
                                        splitAt "record" (Mono.typeOf e) ft True ac

                                    Nothing ->
                                        ac
                            )
                            acc
                            fields
                        )

                _ ->
                    children acc

        Mono.MonoRecordAccess inner name t ->
            case Mono.typeOf inner of
                Mono.MRecord _ fts ->
                    case Dict.get name fts of
                        Just ft ->
                            children (splitAt "access" ft t True acc)

                        Nothing ->
                            children acc

                _ ->
                    children acc

        _ ->
            children acc


pathRootMeet : Env -> Mono.MonoPath -> List Meet -> List Meet
pathRootMeet env path acc =
    case path of
        Mono.MonoRoot name t ->
            case Dict.get name env of
                Just bound ->
                    splitAt "pathRoot" bound t True acc

                Nothing ->
                    acc

        Mono.MonoIndex _ _ _ inner ->
            pathRootMeet env inner acc

        Mono.MonoField _ _ inner ->
            pathRootMeet env inner acc

        Mono.MonoUnbox _ inner ->
            pathRootMeet env inner acc


dtRootMeet : Env -> Mono.MonoDtPath -> List Meet -> List Meet
dtRootMeet env path acc =
    case path of
        Mono.DtRoot name t ->
            case Dict.get name env of
                Just bound ->
                    splitAt "dtRoot" bound t True acc

                Nothing ->
                    acc

        Mono.DtIndex _ _ _ inner ->
            dtRootMeet env inner acc

        Mono.DtUnbox _ inner ->
            dtRootMeet env inner acc


deciderRootMeets : Env -> Mono.Decider a -> List Meet -> List Meet
deciderRootMeets env decider acc =
    case decider of
        Mono.Leaf _ ->
            acc

        Mono.Chain tests success failure ->
            NE.foldr (\( p, _ ) ac -> dtRootMeet env p ac) acc tests
                |> deciderRootMeets env success
                |> deciderRootMeets env failure

        Mono.FanOut path edges fallback ->
            NE.foldr (\( _, d ) ac -> deciderRootMeets env d ac) (dtRootMeet env path acc) edges
                |> deciderRootMeets env fallback


inlineLeafTypes : Mono.Decider Mono.MonoChoice -> List Mono.MonoType -> List Mono.MonoType
inlineLeafTypes decider acc =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Mono.typeOf e :: acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            inlineLeafTypes failure (inlineLeafTypes success acc)

        Mono.FanOut _ edges fallback ->
            NE.foldr (\( _, d ) ac -> inlineLeafTypes d ac) (inlineLeafTypes fallback acc) edges



-- ====== COMPONENTS ======


{-| The types of a graph grouped by the meets between them: two types are in
one component when some value is viewed as both, directly or through other
views. Each distinct type (under the layout key) gets a dense `Int` id; `rep`
maps an id to its component's id, `members` a component's id to its types.
-}
type alias Components =
    { ids : Mono.LayoutMap Int
    , rep : Dict Int Int
    , members : Dict Int (List Mono.MonoType)
    }


{-| The components of the meets `keep` selects.
-}
components : (Meet -> Bool) -> List Meet -> Components
components keep meets =
    let
        selected =
            List.filter keep meets

        intern t ( ids, types ) =
            case Mono.layoutMapGet t ids of
                Just _ ->
                    ( ids, types )

                Nothing ->
                    ( Mono.layoutMapInsert t (Dict.size types) ids, Dict.insert (Dict.size types) t types )

        ( idOf, typeOfId ) =
            List.foldl (\m acc -> intern m.b (intern m.a acc)) ( Mono.layoutMapEmpty, Dict.empty ) selected

        idFor t =
            Mono.layoutMapGet t idOf |> Maybe.withDefault -1

        adjacency : Dict Int (List Int)
        adjacency =
            List.foldl
                (\m d ->
                    let
                        ka =
                            idFor m.a

                        kb =
                            idFor m.b
                    in
                    d
                        |> Dict.update ka (\l -> Just (kb :: Maybe.withDefault [] l))
                        |> Dict.update kb (\l -> Just (ka :: Maybe.withDefault [] l))
                )
                Dict.empty
                selected

        flood : List Int -> Set Int -> Set Int
        flood stack seen =
            case stack of
                [] ->
                    seen

                k :: rest ->
                    if Set.member k seen then
                        flood rest seen

                    else
                        flood ((Dict.get k adjacency |> Maybe.withDefault []) ++ rest) (Set.insert k seen)

        ( rep, members ) =
            Dict.foldl
                (\k _ ( r, m ) ->
                    if Dict.member k r then
                        ( r, m )

                    else
                        let
                            comp =
                                flood [ k ] Set.empty
                        in
                        ( Set.foldl (\c rr -> Dict.insert c k rr) r comp
                        , Dict.insert k (Set.toList comp |> List.filterMap (\c -> Dict.get c typeOfId)) m
                        )
                )
                ( Dict.empty, Dict.empty )
                adjacency
    in
    { ids = idOf, rep = rep, members = members }


{-| The types in `t`'s component, `t` among them; just `t` when no meet
involves it.
-}
componentOf : Components -> Mono.MonoType -> List Mono.MonoType
componentOf comps t =
    case Mono.layoutMapGet t comps.ids |> Maybe.andThen (\i -> Dict.get i comps.rep) of
        Just r ->
            Dict.get r comps.members |> Maybe.withDefault [ t ]

        Nothing ->
            [ t ]



-- ====== VALIDATION ======


{-| Checks a graph after the representation passes: every interior meet joins
two types of the same slot kind (MONO_029), and no meet joins a nullable type
(`Mono.ReprInfo.nullable`) to any other type (MONO_033). A meet that only moves
its value through a kernel alias's type variable is not collected (`collect`).
Returns one message per violation, at most 50.
-}
validate : Mono.MonoGraph -> List String
validate ((Mono.MonoGraph g) as graph) =
    let
        isNullable t =
            Mono.layoutMapMember t g.repr.nullable

        bad m =
            if not m.root && slotKindOf m.a /= slotKindOf m.b then
                Just
                    ("MONO_029 violation (spec " ++ String.fromInt m.spec ++ " " ++ m.site ++ "): interior slot kinds differ: "
                        ++ Mono.monoTypeToDebugString m.a
                        ++ " vs "
                        ++ Mono.monoTypeToDebugString m.b
                    )

            else if (isNullable m.a || isNullable m.b) && not (Mono.eqKeyLayout m.a m.b) then
                Just
                    ("MONO_033 violation (spec " ++ String.fromInt m.spec ++ " " ++ m.site ++ "): a nullable type meets another view: "
                        ++ Mono.toComparableLayoutType m.a
                        ++ " vs "
                        ++ Mono.toComparableLayoutType m.b
                    )

            else
                Nothing
    in
    collect graph
        |> List.filterMap bad
        |> List.take 50
