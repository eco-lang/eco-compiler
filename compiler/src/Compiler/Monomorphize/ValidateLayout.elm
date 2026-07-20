module Compiler.Monomorphize.ValidateLayout exposing (validate)

{-| MONO_029 layout-agreement validator (R0 of
plans/solver-layout-connectivity-reconciliation.md). Engine-agnostic,
opt-in via `ECO_MONO_VALIDATE=1`: walks the final MonoGraph and reports
layout-disagreeing views of one runtime value. Heap slot layout is a pure
function of the recorded type (only Int/Float/Char unboxed — REP rules), so
two views of one value whose ABI kinds differ mean some emission site must
read or write the wrong representation.

Checks (violations are strings; the caller fails the compile on any):

1.  Destructure paths: a `MonoIndex` element type whose ABI kind disagrees
    with the destructor's leaf type (the erased-container / concrete-leaf
    shape behind the foldMGo miscompile), and element-vs-parent-slot
    disagreements along tuple paths.
2.  `MonoTailCall` argument types vs the enclosing tail function's
    parameter types (loop-state yields are coercion-free, so ABI kinds must
    agree — mono-level mirror of `TailRec.checkedYieldOperands`).
3.  `MonoTupleCreate` element expression types vs the recorded tuple node
    type's slots (construct-side agreement).

Closure-capture / call-arg interior checks were prototyped (2026-07-20)
for the all-globals-keying record-field-boxedness class and REMOVED: at
the mono-type level, keying's disagreements are erased-vs-concrete
(benign — the erased consumer is a polymorphic pass-through that never
derefs the field; the whole E2E corpus compiles CORRECTLY under
all-globals keying), which a per-node boxedness check cannot distinguish
from the malign concrete-raw-vs-concrete-boxed case, while the real
crash (self-compile-scale solver Unify pattern) never surfaces as a
call-boundary field flip at all. MONO_029 is enforced by engine
connectivity (R1/R2), not a per-node validator, for exactly this reason.

@docs validate

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.MonoTraverse as Traverse
import Dict


{-| Validate a pruned MonoGraph. Returns violation descriptions (empty = clean).
-}
validate : Mono.MonoGraph -> List String
validate (Mono.MonoGraph graph) =
    Array.foldl
        (\( specId, maybeNode ) acc ->
            case maybeNode of
                Nothing ->
                    acc

                Just node ->
                    validateNode specId node acc
        )
        []
        (Array.indexedMap Tuple.pair graph.nodes)


validateNode : Int -> Mono.MonoNode -> List String -> List String
validateNode specId node acc0 =
    let
        ( frames0, expr ) =
            case node of
                Mono.MonoDefine e _ ->
                    ( Dict.empty, Just e )

                Mono.MonoTailFunc params body _ ->
                    ( Dict.singleton "" params, Just body )

                _ ->
                    ( Dict.empty, Nothing )
    in
    case expr of
        Nothing ->
            acc0

        Just e ->
            let
                -- All loop frames in this node: the top MonoTailFunc (name
                -- unknown at node level — TailCalls to it are matched via the
                -- catch-all "" frame) plus every local MonoTailDef by name.
                frames =
                    Traverse.foldExpr
                        (\ex fs ->
                            case ex of
                                Mono.MonoLet (Mono.MonoTailDef n ps _) _ _ ->
                                    Dict.insert n ps fs

                                _ ->
                                    fs
                        )
                        frames0
                        e
            in
            Traverse.foldExpr (checkExpr specId frames) acc0 e


checkExpr : Int -> Dict.Dict Name (List ( Name, Mono.MonoType )) -> Mono.MonoExpr -> List String -> List String
checkExpr specId frames expr acc =
    case expr of
        Mono.MonoDestruct (Mono.MonoDestructor name path leafType) _ _ ->
            checkPath specId name leafType path acc

        Mono.MonoTailCall callee args _ ->
            let
                params =
                    case Dict.get callee frames of
                        Just ps ->
                            Just ps

                        Nothing ->
                            Dict.get "" frames
            in
            case params of
                Nothing ->
                    acc

                Just ps ->
                    List.foldl
                        (\( argName, argExpr ) a ->
                            case List.filter (\( pn, _ ) -> pn == argName) ps of
                                ( _, pType ) :: _ ->
                                    if abiKind (Mono.typeOf argExpr) /= abiKind pType then
                                        violation specId
                                            ("MonoTailCall " ++ callee ++ " arg " ++ argName ++ ": " ++ kindName (Mono.typeOf argExpr) ++ " vs loop param " ++ kindName pType)
                                            a

                                    else
                                        a

                                [] ->
                                    a
                        )
                        acc
                        args

        Mono.MonoTupleCreate _ elems nodeType ->
            case nodeType of
                Mono.MTuple slotTypes ->
                    List.foldl
                        (\( i, ( elemExpr, slotType ) ) a ->
                            if abiKind (Mono.typeOf elemExpr) /= abiKind slotType then
                                violation specId
                                    ("MonoTupleCreate slot " ++ String.fromInt i ++ ": element " ++ kindName (Mono.typeOf elemExpr) ++ " vs slot " ++ kindName slotType)
                                    a

                            else
                                a
                        )
                        acc
                        (List.indexedMap Tuple.pair (List.map2 Tuple.pair elems slotTypes))

                _ ->
                    acc

        _ ->
            acc


{-| Walk a destructor path: the head `MonoIndex`'s element type must agree
with the destructor leaf, and every tuple `MonoIndex` must agree with its
parent's slot type.
-}
checkPath : Int -> Name -> Mono.MonoType -> Mono.MonoPath -> List String -> List String
checkPath specId name leafType path acc0 =
    let
        acc1 =
            case path of
                Mono.MonoIndex _ kind elemType _ ->
                    -- CustomContainer slots are excluded: both construct and
                    -- project consult the shared CtorLayout registry
                    -- (MONO_013 / REP_HEAP_001), so per-node type
                    -- disagreement there does not imply layout disagreement.
                    -- Tuple/list slots are per-site typed (layout-static).
                    -- Direction matters: a RAW element with a BOXED leaf is a
                    -- legal scalar coercion (project raw, box for the erased
                    -- consumer — the pre-existing unboxed-field arm); the
                    -- miscompile class is a BOXED/erased element view over a
                    -- leaf that demands a raw primitive (nothing can be
                    -- emitted — the MONO_029 crash arms).
                    if perSiteTyped kind && abiKind leafType /= KBoxed && abiKind elemType /= abiKind leafType then
                        violation specId
                            ("destructor " ++ name ++ ": path element " ++ kindName elemType ++ " vs leaf " ++ kindName leafType)
                            acc0

                    else
                        acc0

                _ ->
                    acc0
    in
    checkPathChain specId name path acc1


perSiteTyped : Mono.ContainerKind -> Bool
perSiteTyped kind =
    case kind of
        Mono.CustomContainer _ ->
            False

        _ ->
            True


checkPathChain : Int -> Name -> Mono.MonoPath -> List String -> List String
checkPathChain specId name path acc =
    case path of
        Mono.MonoIndex i _ elemType subPath ->
            let
                acc1 =
                    case Mono.getMonoPathType subPath of
                        Mono.MTuple slotTypes ->
                            case List.head (List.drop i slotTypes) of
                                Just slotType ->
                                    if abiKind slotType /= abiKind elemType then
                                        violation specId
                                            ("destructor " ++ name ++ ": tuple slot " ++ String.fromInt i ++ " " ++ kindName slotType ++ " vs projected " ++ kindName elemType)
                                            acc

                                    else
                                        acc

                                Nothing ->
                                    acc

                        _ ->
                            acc
            in
            checkPathChain specId name subPath acc1

        Mono.MonoField _ _ subPath ->
            checkPathChain specId name subPath acc

        Mono.MonoUnbox _ subPath ->
            checkPathChain specId name subPath acc

        Mono.MonoRoot _ _ ->
            acc


violation : Int -> String -> List String -> List String
violation specId msg acc =
    ("MONO_029 violation (spec " ++ String.fromInt specId ++ "): " ++ msg) :: acc


{-| The heap/ABI representation class of a recorded type: raw i64 / raw f64 /
raw u16, or a boxed word. Everything not Int/Float/Char is boxed (REP rules;
Bool is boxed True/False constants; erased residuals are boxed per MONO_003).
CNumber residuals close to MInt in Prune, so post-prune they read as raw-int.
-}
type AbiKind
    = KRawInt
    | KRawFloat
    | KRawChar
    | KBoxed


abiKind : Mono.MonoType -> AbiKind
abiKind t =
    case t of
        Mono.MInt ->
            KRawInt

        Mono.MFloat ->
            KRawFloat

        Mono.MChar ->
            KRawChar

        Mono.MVar _ Mono.CNumber ->
            KRawInt

        _ ->
            KBoxed


kindName : Mono.MonoType -> String
kindName t =
    case abiKind t of
        KRawInt ->
            "raw-int"

        KRawFloat ->
            "raw-float"

        KRawChar ->
            "raw-char"

        KBoxed ->
            "boxed"
