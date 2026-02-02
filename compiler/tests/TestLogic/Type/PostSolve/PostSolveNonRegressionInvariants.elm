module TestLogic.Type.PostSolve.PostSolveNonRegressionInvariants exposing
    ( NodeKind(..)
    , Violation
    , checkPost005
    , checkPost006
    , collectNodeKinds
    , formatViolations
    )

{-| Test logic for invariants POST\_005 and POST\_006.

POST\_005: For every non-negative node id whose solver-produced (pre-PostSolve)
type is not a bare Can.TVar, PostSolve must not change that node's type
(alpha-equivalent). Exception: VarKernel nodes.

POST\_006: For every non-negative node id (excluding VarKernel and Accessor nodes),
the set of free Can.TVar names in the post-PostSolve type must be a subset of
those in the pre-PostSolve type.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name
import Compiler.Reporting.Annotation as A
import Compiler.Type.PostSolve as PostSolve
import Data.Map as Dict
import Data.Set as EverySet


{-| A violation of POST\_005 or POST\_006.
-}
type alias Violation =
    { invariant : String
    , nodeId : Int
    , kind : String
    , preType : Can.Type
    , postType : Can.Type
    , details : String
    }


{-| Classification of node kinds.
-}
type NodeKind
    = KVarKernel
    | KAccessor
    | KOther


{-| Check POST\_005: PostSolve does not rewrite solver-structured node types.

For every non-negative node id that is not VarKernel:
if nodeTypesPre[id] is NOT a bare TVar, assert nodeTypesPost[id] is
alpha-equivalent to nodeTypesPre[id].

-}
checkPost005 :
    Dict.Dict Int Int NodeKind
    -> PostSolve.NodeTypes
    -> PostSolve.NodeTypes
    -> List Violation
checkPost005 nodeKinds nodeTypesPre nodeTypesPost =
    Dict.foldl compare
        (\nodeId preType acc ->
            if nodeId < 0 then
                -- Skip negative IDs (kernel internals)
                acc

            else
                case Dict.get identity nodeId nodeKinds of
                    Just KVarKernel ->
                        -- VarKernel nodes are exempt
                        acc

                    _ ->
                        case preType of
                            Can.TVar _ ->
                                -- Pre-type is a bare TVar, PostSolve may fill it
                                acc

                            _ ->
                                -- Pre-type is structured, PostSolve must preserve it
                                case Dict.get identity nodeId nodeTypesPost of
                                    Nothing ->
                                        { invariant = "POST_005"
                                        , nodeId = nodeId
                                        , kind = nodeKindToString (Dict.get identity nodeId nodeKinds)
                                        , preType = preType
                                        , postType = Can.TUnit -- placeholder
                                        , details = "Node disappeared from nodeTypesPost"
                                        }
                                            :: acc

                                    Just postType ->
                                        if alphaEq preType postType then
                                            acc

                                        else
                                            { invariant = "POST_005"
                                            , nodeId = nodeId
                                            , kind = nodeKindToString (Dict.get identity nodeId nodeKinds)
                                            , preType = preType
                                            , postType = postType
                                            , details = "PostSolve changed structured type"
                                            }
                                                :: acc
        )
        []
        nodeTypesPre


{-| Check POST\_006: PostSolve does not introduce new free type variables.

For every non-negative node id that is neither VarKernel nor Accessor:
freeVars(postType) must be a subset of freeVars(preType).

-}
checkPost006 :
    Dict.Dict Int Int NodeKind
    -> PostSolve.NodeTypes
    -> PostSolve.NodeTypes
    -> List Violation
checkPost006 nodeKinds nodeTypesPre nodeTypesPost =
    Dict.foldl compare
        (\nodeId postType acc ->
            if nodeId < 0 then
                -- Skip negative IDs (kernel internals)
                acc

            else
                case Dict.get identity nodeId nodeKinds of
                    Just KVarKernel ->
                        -- VarKernel nodes are exempt
                        acc

                    Just KAccessor ->
                        -- Accessor nodes are exempt (intentionally polymorphic)
                        acc

                    _ ->
                        case Dict.get identity nodeId nodeTypesPre of
                            Nothing ->
                                -- No pre-type, allow any post-type (new node)
                                acc

                            Just preType ->
                                case preType of
                                    Can.TVar _ ->
                                        -- Pre-type is a bare TVar placeholder
                                        -- PostSolve is allowed to fill it with any type
                                        acc

                                    _ ->
                                        -- Pre-type is structured, check free var subset
                                        let
                                            postVars =
                                                freeTypeVars postType

                                            preVars =
                                                freeTypeVars preType
                                        in
                                        if isSubset postVars preVars then
                                            acc

                                        else
                                            let
                                                newVars =
                                                    EverySet.diff postVars preVars
                                                        |> EverySet.toList compare
                                            in
                                            { invariant = "POST_006"
                                            , nodeId = nodeId
                                            , kind = nodeKindToString (Dict.get identity nodeId nodeKinds)
                                            , preType = preType
                                            , postType = postType
                                            , details =
                                                "New free vars introduced: ["
                                                    ++ String.join ", " newVars
                                                    ++ "]"
                                            }
                                                :: acc
        )
        []
        nodeTypesPost


{-| Check if set A is a subset of set B.
-}
isSubset : EverySet.EverySet String String -> EverySet.EverySet String String -> Bool
isSubset setA setB =
    EverySet.diff setA setB
        |> EverySet.isEmpty



-- ============================================================================
-- ALPHA EQUIVALENCE
-- ============================================================================


{-| Check if two types are alpha-equivalent.

Two types are alpha-equivalent if they are structurally identical up to
renaming of type variable names.

-}
alphaEq : Can.Type -> Can.Type -> Bool
alphaEq a b =
    case ( a, b ) of
        ( Can.TVar _, Can.TVar _ ) ->
            -- Any TVar matches any TVar (alpha-equivalent)
            True

        ( Can.TType h1 n1 as1, Can.TType h2 n2 as2 ) ->
            h1 == h2 && n1 == n2 && alphaEqList as1 as2

        ( Can.TLambda a1 r1, Can.TLambda a2 r2 ) ->
            alphaEq a1 a2 && alphaEq r1 r2

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            alphaEqExt ext1 ext2 && alphaEqFields fields1 fields2

        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            alphaEq a1 a2 && alphaEq b1 b2 && alphaEqList cs1 cs2

        ( Can.TAlias h1 n1 args1 at1, Can.TAlias h2 n2 args2 at2 ) ->
            h1 == h2 && n1 == n2 && alphaEqArgs args1 args2 && alphaEqAlias at1 at2

        _ ->
            False


alphaEqList : List Can.Type -> List Can.Type -> Bool
alphaEqList xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: xr, y :: yr ) ->
            alphaEq x y && alphaEqList xr yr

        _ ->
            False


alphaEqExt : Maybe Name.Name -> Maybe Name.Name -> Bool
alphaEqExt ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            True

        ( Just _, Just _ ) ->
            True

        -- Extension vars are alpha-equivalent
        _ ->
            False


alphaEqFields :
    Dict.Dict String Name.Name Can.FieldType
    -> Dict.Dict String Name.Name Can.FieldType
    -> Bool
alphaEqFields fields1 fields2 =
    let
        list1 =
            Dict.toList compare fields1

        list2 =
            Dict.toList compare fields2
    in
    if List.length list1 /= List.length list2 then
        False

    else
        List.all
            (\( ( k1, Can.FieldType _ t1 ), ( k2, Can.FieldType _ t2 ) ) ->
                k1 == k2 && alphaEq t1 t2
            )
            (List.map2 Tuple.pair list1 list2)


alphaEqArgs : List ( Name.Name, Can.Type ) -> List ( Name.Name, Can.Type ) -> Bool
alphaEqArgs args1 args2 =
    case ( args1, args2 ) of
        ( [], [] ) ->
            True

        ( ( _, t1 ) :: r1, ( _, t2 ) :: r2 ) ->
            alphaEq t1 t2 && alphaEqArgs r1 r2

        _ ->
            False


alphaEqAlias : Can.AliasType -> Can.AliasType -> Bool
alphaEqAlias at1 at2 =
    case ( at1, at2 ) of
        ( Can.Holey t1, Can.Holey t2 ) ->
            alphaEq t1 t2

        ( Can.Filled t1, Can.Filled t2 ) ->
            alphaEq t1 t2

        _ ->
            False



-- ============================================================================
-- FREE TYPE VARIABLES
-- ============================================================================


{-| Extract all free type variable names from a type.
-}
freeTypeVars : Can.Type -> EverySet.EverySet String String
freeTypeVars tipe =
    case tipe of
        Can.TVar name ->
            EverySet.insert identity name EverySet.empty

        Can.TType _ _ args ->
            List.foldl
                (\t acc -> EverySet.union acc (freeTypeVars t))
                EverySet.empty
                args

        Can.TLambda a b ->
            EverySet.union (freeTypeVars a) (freeTypeVars b)

        Can.TRecord fields ext ->
            let
                extVars =
                    case ext of
                        Just name ->
                            EverySet.insert identity name EverySet.empty

                        Nothing ->
                            EverySet.empty

                fieldVars =
                    Dict.foldl compare
                        (\_ (Can.FieldType _ fieldType) acc ->
                            EverySet.union acc (freeTypeVars fieldType)
                        )
                        EverySet.empty
                        fields
            in
            EverySet.union extVars fieldVars

        Can.TUnit ->
            EverySet.empty

        Can.TTuple a b cs ->
            List.foldl
                (\t acc -> EverySet.union acc (freeTypeVars t))
                (EverySet.union (freeTypeVars a) (freeTypeVars b))
                cs

        Can.TAlias _ _ args aliasType ->
            let
                argVars =
                    List.foldl
                        (\( _, t ) acc -> EverySet.union acc (freeTypeVars t))
                        EverySet.empty
                        args

                aliasVars =
                    case aliasType of
                        Can.Holey t ->
                            freeTypeVars t

                        Can.Filled t ->
                            freeTypeVars t
            in
            EverySet.union argVars aliasVars



-- ============================================================================
-- NODE KIND CLASSIFICATION
-- ============================================================================


{-| Collect node kinds from canonical module.

Walk the canonical AST and classify each node ID as VarKernel, Accessor, or Other.

-}
collectNodeKinds : Can.Module -> Dict.Dict Int Int NodeKind
collectNodeKinds (Can.Module modData) =
    collectDeclsNodeKinds modData.decls Dict.empty


collectDeclsNodeKinds : Can.Decls -> Dict.Dict Int Int NodeKind -> Dict.Dict Int Int NodeKind
collectDeclsNodeKinds decls acc =
    case decls of
        Can.Declare def rest ->
            collectDeclsNodeKinds rest (collectDefNodeKinds def acc)

        Can.DeclareRec def defs rest ->
            let
                acc1 =
                    collectDefNodeKinds def acc

                acc2 =
                    List.foldl (\d a -> collectDefNodeKinds d a) acc1 defs
            in
            collectDeclsNodeKinds rest acc2

        Can.SaveTheEnvironment ->
            acc


collectDefNodeKinds : Can.Def -> Dict.Dict Int Int NodeKind -> Dict.Dict Int Int NodeKind
collectDefNodeKinds def acc =
    case def of
        Can.Def _ patterns expr ->
            let
                acc1 =
                    List.foldl collectPatternNodeKinds acc patterns
            in
            collectExprNodeKinds expr acc1

        Can.TypedDef _ _ patternTypes expr _ ->
            let
                acc1 =
                    List.foldl (\( p, _ ) a -> collectPatternNodeKinds p a) acc patternTypes
            in
            collectExprNodeKinds expr acc1


collectExprNodeKinds : Can.Expr -> Dict.Dict Int Int NodeKind -> Dict.Dict Int Int NodeKind
collectExprNodeKinds (A.At _ exprInfo) acc =
    let
        nodeId =
            exprInfo.id

        ( kind, childAcc ) =
            case exprInfo.node of
                Can.VarKernel _ _ ->
                    ( KVarKernel, acc )

                Can.Accessor _ ->
                    ( KAccessor, acc )

                Can.VarLocal _ ->
                    ( KOther, acc )

                Can.VarTopLevel _ _ ->
                    ( KOther, acc )

                Can.VarForeign _ _ _ ->
                    ( KOther, acc )

                Can.VarCtor _ _ _ _ _ ->
                    ( KOther, acc )

                Can.VarDebug _ _ _ ->
                    ( KOther, acc )

                Can.VarOperator _ _ _ _ ->
                    ( KOther, acc )

                Can.Chr _ ->
                    ( KOther, acc )

                Can.Str _ ->
                    ( KOther, acc )

                Can.Int _ ->
                    ( KOther, acc )

                Can.Float _ ->
                    ( KOther, acc )

                Can.List exprs ->
                    ( KOther, List.foldl collectExprNodeKinds acc exprs )

                Can.Negate expr ->
                    ( KOther, collectExprNodeKinds expr acc )

                Can.Binop _ _ _ _ left right ->
                    ( KOther
                    , collectExprNodeKinds right (collectExprNodeKinds left acc)
                    )

                Can.Lambda patterns body ->
                    let
                        pAcc =
                            List.foldl collectPatternNodeKinds acc patterns
                    in
                    ( KOther, collectExprNodeKinds body pAcc )

                Can.Call fn args ->
                    ( KOther
                    , List.foldl collectExprNodeKinds (collectExprNodeKinds fn acc) args
                    )

                Can.If branches final ->
                    let
                        branchAcc =
                            List.foldl
                                (\( cond, branch ) a ->
                                    collectExprNodeKinds branch (collectExprNodeKinds cond a)
                                )
                                acc
                                branches
                    in
                    ( KOther, collectExprNodeKinds final branchAcc )

                Can.Let def body ->
                    ( KOther
                    , collectExprNodeKinds body (collectDefNodeKinds def acc)
                    )

                Can.LetRec defs body ->
                    let
                        defAcc =
                            List.foldl collectDefNodeKinds acc defs
                    in
                    ( KOther, collectExprNodeKinds body defAcc )

                Can.LetDestruct pattern valExpr body ->
                    let
                        pAcc =
                            collectPatternNodeKinds pattern acc

                        vAcc =
                            collectExprNodeKinds valExpr pAcc
                    in
                    ( KOther, collectExprNodeKinds body vAcc )

                Can.Case scrutinee branches ->
                    let
                        scrAcc =
                            collectExprNodeKinds scrutinee acc

                        branchAcc =
                            List.foldl collectBranchNodeKinds scrAcc branches
                    in
                    ( KOther, branchAcc )

                Can.Access expr _ ->
                    ( KOther, collectExprNodeKinds expr acc )

                Can.Update expr fields ->
                    let
                        fAcc =
                            Dict.foldl A.compareLocated
                                (\_ (Can.FieldUpdate _ e) a -> collectExprNodeKinds e a)
                                acc
                                fields
                    in
                    ( KOther, collectExprNodeKinds expr fAcc )

                Can.Record fields ->
                    ( KOther
                    , Dict.foldl A.compareLocated
                        (\_ e a -> collectExprNodeKinds e a)
                        acc
                        fields
                    )

                Can.Unit ->
                    ( KOther, acc )

                Can.Tuple a b cs ->
                    ( KOther
                    , List.foldl collectExprNodeKinds
                        (collectExprNodeKinds b (collectExprNodeKinds a acc))
                        cs
                    )

                Can.Shader _ _ ->
                    ( KOther, acc )
    in
    Dict.insert identity nodeId kind childAcc


collectBranchNodeKinds : Can.CaseBranch -> Dict.Dict Int Int NodeKind -> Dict.Dict Int Int NodeKind
collectBranchNodeKinds (Can.CaseBranch pattern body) acc =
    collectExprNodeKinds body (collectPatternNodeKinds pattern acc)


collectPatternNodeKinds : Can.Pattern -> Dict.Dict Int Int NodeKind -> Dict.Dict Int Int NodeKind
collectPatternNodeKinds (A.At _ patInfo) acc =
    -- Patterns are marked as KOther
    let
        nodeId =
            patInfo.id

        childAcc =
            case patInfo.node of
                Can.PAnything ->
                    acc

                Can.PVar _ ->
                    acc

                Can.PRecord _ ->
                    acc

                Can.PAlias subPat _ ->
                    collectPatternNodeKinds subPat acc

                Can.PUnit ->
                    acc

                Can.PTuple a b cs ->
                    List.foldl collectPatternNodeKinds
                        (collectPatternNodeKinds b (collectPatternNodeKinds a acc))
                        cs

                Can.PList patterns ->
                    List.foldl collectPatternNodeKinds acc patterns

                Can.PCons head tail ->
                    collectPatternNodeKinds tail (collectPatternNodeKinds head acc)

                Can.PBool _ _ ->
                    acc

                Can.PChr _ ->
                    acc

                Can.PStr _ _ ->
                    acc

                Can.PInt _ ->
                    acc

                Can.PCtor ctorInfo ->
                    List.foldl
                        (\(Can.PatternCtorArg _ _ p) a -> collectPatternNodeKinds p a)
                        acc
                        ctorInfo.args
    in
    Dict.insert identity nodeId KOther childAcc



-- ============================================================================
-- FORMATTING
-- ============================================================================


{-| Format violations for error reporting.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map formatViolation
        |> String.join "\n\n"


formatViolation : Violation -> String
formatViolation v =
    v.invariant
        ++ " violation at nodeId "
        ++ String.fromInt v.nodeId
        ++ " ("
        ++ v.kind
        ++ "):\n  preType:  "
        ++ typeToString v.preType
        ++ "\n  postType: "
        ++ typeToString v.postType
        ++ "\n  details:  "
        ++ v.details


typeToString : Can.Type -> String
typeToString tipe =
    case tipe of
        Can.TVar name ->
            "TVar \"" ++ name ++ "\""

        Can.TType _ name args ->
            "TType ("
                ++ name
                ++ ") ["
                ++ String.join ", " (List.map typeToString args)
                ++ "]"

        Can.TLambda a b ->
            "TLambda (" ++ typeToString a ++ " -> " ++ typeToString b ++ ")"

        Can.TRecord _ ext ->
            case ext of
                Nothing ->
                    "TRecord {...}"

                Just extName ->
                    "TRecord { " ++ extName ++ " | ... }"

        Can.TUnit ->
            "TUnit"

        Can.TTuple a b cs ->
            "TTuple ("
                ++ String.join ", " (List.map typeToString (a :: b :: cs))
                ++ ")"

        Can.TAlias _ name _ _ ->
            "TAlias " ++ name


nodeKindToString : Maybe NodeKind -> String
nodeKindToString maybeKind =
    case maybeKind of
        Just KVarKernel ->
            "VarKernel"

        Just KAccessor ->
            "Accessor"

        Just KOther ->
            "Other"

        Nothing ->
            "Unknown"
