module TestLogic.Type.PostSolve.PostSolveNonRegressionInvariants exposing
    ( NodeKind(..)
    , Violation
    , checkPost005
    , checkPost006
    , collectNodeKinds
    , formatViolations
    )

{-| Checks that PostSolve leaves alone the node types the solver had already
worked out, so that a PostSolve that overwrites a solved type is caught, within
the exemptions and the loose matching described below.

Expressions and patterns in a canonical module carry node ids, and the two
share one id space. The solver records an optional type per id, held in a
`PostSolve.NodeTypes` array indexed by id, and `Compiler.Type.PostSolve`
rewrites some of those entries. Here the array before PostSolve gives each
node's _pre-type_ and the array after it gives its _post-type_. A pre-type is
_structured_ when it is anything other than a bare `Can.TVar`. A _node kind_
(`NodeKind`) sorts each id into a kernel reference, a record accessor, or
anything else, because the checks exempt some of them, as described below.

There are two checks, and each returns a list of `Violation`s, empty when the
check passes.

`checkPost005` looks at every node with a structured pre-type, except kernel
references, and requires a post-type that matches it. Matching is loose: any
type variable matches any other type variable, with no consistent renaming
required, so `a -> a` matches `a -> b`. Record extension variables only need to
be present on both sides or absent on both, and arrow slots, record field
indices and alias argument names are ignored. A PostSolve that renames or
splits the variables inside a structured type therefore passes this check.

`checkPost006` looks at every node with a structured pre-type and a post-type,
except kernel references and record accessors, and requires that every type
variable name in the post-type also occurs in the pre-type. A `Can.Type` has no
binders, so every variable name counts, including record extension variables
and the variables inside an alias's arguments and its body.

`collectNodeKinds` builds the node kinds both checks take, and
`formatViolations` renders a list of violations as a failure message.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Type.PostSolve as PostSolve
import Data.Map as Dict
import Data.Set as EverySet
import Dict as StdDict


{-| One node that failed one of the two checks.

`invariant` is `"POST_005"` for a failure of `checkPost005` and `"POST_006"`
for one of `checkPost006`. `kind` is the node's kind as text, `"Unknown"` when
the check's `nodeKinds` has no entry for the id. When the node has no post-type
at all, `postType` is `Can.TUnit` as a stand-in and `details` says the node
disappeared.

-}
type alias Violation =
    { invariant : String
    , nodeId : Int
    , kind : String
    , preType : Can.Type Name
    , postType : Can.Type Name
    , details : String
    }


{-| The kind of a node, as far as the checks need to tell nodes apart.

`KVarKernel` is a reference to a kernel value, which both checks skip.
`KAccessor` is a record accessor such as `.name`, which only `checkPost006`
skips. `KOther` is every other expression and every pattern.

-}
type NodeKind
    = KVarKernel
    | KAccessor
    | KOther


{-| Returns a violation for each node whose structured pre-type, in
`nodeTypesPre`, was changed or dropped in `nodeTypesPost`.

Kernel references in `nodeKinds` are skipped, and a node with no recorded kind
is checked. Types are compared with the loose matching the module docstring
describes, so a renaming of type variables is not reported. The violations come
highest node id first.

-}
checkPost005 :
    Dict.Dict Int Int NodeKind
    -> PostSolve.NodeTypes
    -> PostSolve.NodeTypes
    -> List Violation
checkPost005 nodeKinds nodeTypesPre nodeTypesPost =
    Array.foldl
        (\maybePreType ( nodeId, acc ) ->
            case maybePreType of
                Nothing ->
                    ( nodeId + 1, acc )

                Just preType ->
                    ( nodeId + 1
                    , if nodeId < 0 then
                        acc

                      else
                        case Dict.get identity nodeId nodeKinds of
                            Just KVarKernel ->
                                acc

                            _ ->
                                case preType of
                                    Can.TVar _ ->
                                        acc

                                    _ ->
                                        case Array.get nodeId nodeTypesPost |> Maybe.andThen identity of
                                            Nothing ->
                                                { invariant = "POST_005"
                                                , nodeId = nodeId
                                                , kind = nodeKindToString (Dict.get identity nodeId nodeKinds)
                                                , preType = preType
                                                , postType = Can.TUnit
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
        )
        ( 0, [] )
        nodeTypesPre
        |> Tuple.second


{-| Returns a violation for each node whose post-type, in `nodeTypesPost`, has a
type variable name that its structured pre-type, in `nodeTypesPre`, does not.

Kernel references and record accessors in `nodeKinds` are skipped, as is any
node whose pre-type is missing or a bare type variable. A node with no
post-type is not reported here. Each violation's `details` lists the new names
in sorted order, and the violations come highest node id first.

-}
checkPost006 :
    Dict.Dict Int Int NodeKind
    -> PostSolve.NodeTypes
    -> PostSolve.NodeTypes
    -> List Violation
checkPost006 nodeKinds nodeTypesPre nodeTypesPost =
    Array.foldl
        (\maybePostType ( nodeId, acc ) ->
            case maybePostType of
                Nothing ->
                    ( nodeId + 1, acc )

                Just postType ->
                    ( nodeId + 1
                    , if nodeId < 0 then
                        acc

                      else
                        case Dict.get identity nodeId nodeKinds of
                            Just KVarKernel ->
                                acc

                            Just KAccessor ->
                                acc

                            _ ->
                                case Array.get nodeId nodeTypesPre |> Maybe.andThen identity of
                                    Nothing ->
                                        acc

                                    Just preType ->
                                        case preType of
                                            Can.TVar _ ->
                                                acc

                                            _ ->
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
                                                                |> EverySet.toList
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
        )
        ( 0, [] )
        nodeTypesPost
        |> Tuple.second


{-| Returns whether every name in `setA` is also in `setB`.
-}
isSubset : EverySet.EverySet String String -> EverySet.EverySet String String -> Bool
isSubset setA setB =
    EverySet.diff setA setB
        |> EverySet.isEmpty



-- ============================================================================
-- LOOSE TYPE MATCHING
-- ============================================================================


{-| Returns whether two types have the same shape, treating every type variable
as matching every other.

This is weaker than alpha-equivalence: no consistent renaming is required, so
`a -> a` matches `a -> b`. A type variable never matches a non-variable type.
Arrow slots are ignored. Type constructors and aliases must have the same home
module and name.

-}
alphaEq : Can.Type Name -> Can.Type Name -> Bool
alphaEq a b =
    case ( a, b ) of
        ( Can.TVar _, Can.TVar _ ) ->
            True

        ( Can.TType h1 n1 as1, Can.TType h2 n2 as2 ) ->
            h1 == h2 && n1 == n2 && alphaEqList as1 as2

        ( Can.TLambda _ a1 r1, Can.TLambda _ a2 r2 ) ->
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


{-| Returns whether two lists of types have the same length and match
element by element under `alphaEq`.
-}
alphaEqList : List (Can.Type Name) -> List (Can.Type Name) -> Bool
alphaEqList xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: xr, y :: yr ) ->
            alphaEq x y && alphaEqList xr yr

        _ ->
            False


{-| Returns whether two record extensions are both absent or both present,
whatever the extension variables are called.
-}
alphaEqExt : Maybe Name.Name -> Maybe Name.Name -> Bool
alphaEqExt ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            True

        ( Just _, Just _ ) ->
            True

        _ ->
            False


{-| Returns whether two records have the same field names, with each field's
type matching under `alphaEq`. Field indices are ignored.
-}
alphaEqFields :
    StdDict.Dict Name.Name (Can.FieldType Name)
    -> StdDict.Dict Name.Name (Can.FieldType Name)
    -> Bool
alphaEqFields fields1 fields2 =
    let
        list1 =
            StdDict.toList fields1

        list2 =
            StdDict.toList fields2
    in
    if List.length list1 /= List.length list2 then
        False

    else
        List.all
            (\( ( k1, Can.FieldType _ t1 ), ( k2, Can.FieldType _ t2 ) ) ->
                k1 == k2 && alphaEq t1 t2
            )
            (List.map2 Tuple.pair list1 list2)


{-| Returns whether two alias argument lists have the same length and their
types match position by position under `alphaEq`. Argument names are ignored.
-}
alphaEqArgs : List ( Name.Name, Can.Type Name ) -> List ( Name.Name, Can.Type Name ) -> Bool
alphaEqArgs args1 args2 =
    case ( args1, args2 ) of
        ( [], [] ) ->
            True

        ( ( _, t1 ) :: r1, ( _, t2 ) :: r2 ) ->
            alphaEq t1 t2 && alphaEqArgs r1 r2

        _ ->
            False


{-| Returns whether two alias bodies are both `Holey` or both `Filled`, with
matching types under `alphaEq`.
-}
alphaEqAlias : Can.AliasType Name -> Can.AliasType Name -> Bool
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


{-| Returns every type variable name that occurs anywhere in `tipe`.

That includes record extension variables, and both the arguments and the body
of an alias, so a parameter name inside a `Holey` alias body is counted too.

-}
freeTypeVars : Can.Type Name -> EverySet.EverySet String String
freeTypeVars tipe =
    case tipe of
        Can.TVar name ->
            EverySet.insert identity name EverySet.empty

        Can.TType _ _ args ->
            List.foldl
                (\t acc -> EverySet.union acc (freeTypeVars t))
                EverySet.empty
                args

        Can.TLambda _ a b ->
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
                    StdDict.foldl
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


{-| Returns the kind of every expression and pattern node in the module's
declarations, keyed by node id.

Kernel references are `KVarKernel`, record accessors are `KAccessor`, and every
other expression and every pattern is `KOther`.

-}
collectNodeKinds : Can.Module -> Dict.Dict Int Int NodeKind
collectNodeKinds (Can.Module modData) =
    collectDeclsNodeKinds modData.decls Dict.empty


{-| Adds to `acc` the kinds of the nodes in every definition of `decls`.
-}
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


{-| Adds to `acc` the kinds of the nodes in a definition's argument patterns
and body.
-}
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


{-| Adds to `acc` the kind of an expression node and of every expression and
pattern node inside it.
-}
collectExprNodeKinds : Can.Expr -> Dict.Dict Int Int NodeKind -> Dict.Dict Int Int NodeKind
collectExprNodeKinds (A.At _ exprInfo) acc =
    let
        nodeId =
            exprInfo.id

        ( kind, childAcc ) =
            case exprInfo.node of
                Can.VarKernel _ _ _ ->
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
                            Dict.foldl
                                (\_ (Can.FieldUpdate _ e) a -> collectExprNodeKinds e a)
                                acc
                                fields
                    in
                    ( KOther, collectExprNodeKinds expr fAcc )

                Can.Record fields ->
                    ( KOther
                    , Dict.foldl
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


{-| Adds to `acc` the kinds of the nodes in a case branch's pattern and body.
-}
collectBranchNodeKinds : Can.CaseBranch -> Dict.Dict Int Int NodeKind -> Dict.Dict Int Int NodeKind
collectBranchNodeKinds (Can.CaseBranch pattern body) acc =
    collectExprNodeKinds body (collectPatternNodeKinds pattern acc)


{-| Adds to `acc` a pattern node and every pattern node inside it, all as
`KOther`.
-}
collectPatternNodeKinds : Can.Pattern -> Dict.Dict Int Int NodeKind -> Dict.Dict Int Int NodeKind
collectPatternNodeKinds (A.At _ patInfo) acc =
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


{-| Returns the violations as text, one block per violation in list order,
separated by blank lines. Each block names the check, node id and kind, then
the pre-type, the post-type and the details.

Types are shown in brief: a type constructor by its name and arguments with no
home module, an alias by its name alone, and a record without its fields.

-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map formatViolation
        |> String.join "\n\n"


{-| Returns one violation as a block of text, for `formatViolations`.
-}
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


{-| Returns a brief rendering of a type for a violation message. A type
constructor shows its name and arguments, an alias only its name, and a record
only its extension variable, if any.
-}
typeToString : Can.Type Name -> String
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

        Can.TLambda _ a b ->
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


{-| Returns the name of a node kind for a violation message, or `"Unknown"`
for an id that has no recorded kind.
-}
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
