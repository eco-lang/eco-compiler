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
the exemptions and the matching described below.

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
references, and requires a post-type that is alpha-equivalent to it: the same
shape under one consistent, one-to-one renaming of type variables, record
extension variables included, so `a -> a` matches `b -> b` but not `a -> b`.
Arrow slots, record field indices and alias argument names are ignored. A
PostSolve that splits or merges the variables inside a structured type fails
this check; one that only renames them consistently passes it.

`checkPost006` looks at every node with a structured pre-type and a post-type,
except kernel references and record accessors, and requires that every type
variable name in the post-type also occurs in the pre-type. A `Can.Type` has no
binders, so every variable name counts, including record extension variables
the variables of an alias's arguments, and those of a `Filled` alias's body.

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
is checked. Types are compared up to alpha-equivalence, as `alphaEq`
describes, so only a consistent renaming of type variables is not reported.
The violations come highest node id first.

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
                    , case Dict.get identity nodeId nodeKinds of
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
                    , case Dict.get identity nodeId nodeKinds of
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
-- ALPHA EQUIVALENCE
-- ============================================================================


{-| A renaming between the type variables of two types, kept in both
directions so that it stays one-to-one.
-}
type alias Renaming =
    ( StdDict.Dict Name.Name Name.Name, StdDict.Dict Name.Name Name.Name )


{-| Returns whether two types are alpha-equivalent: the same shape, with one
consistent one-to-one renaming between their type variables, record
extension variables included. So `a -> b` matches `x -> y` but not `x -> x`.
Arrow slots, record field indices and alias argument names are ignored. Type
constructors and aliases must have the same home module and name; an alias
matches only an alias, and two `Holey` aliases are compared by their
arguments, since the same alias has the same body.
-}
alphaEq : Can.Type Name -> Can.Type Name -> Bool
alphaEq a b =
    alphaEqWith ( StdDict.empty, StdDict.empty ) a b /= Nothing


{-| Extends `renaming` to cover `v1` standing for `v2`, or gives `Nothing` when
either is already paired with something else.
-}
bindVar : Name.Name -> Name.Name -> Renaming -> Maybe Renaming
bindVar v1 v2 (( forward, backward ) as renaming) =
    case ( StdDict.get v1 forward, StdDict.get v2 backward ) of
        ( Nothing, Nothing ) ->
            Just ( StdDict.insert v1 v2 forward, StdDict.insert v2 v1 backward )

        ( Just w2, Just w1 ) ->
            if w2 == v2 && w1 == v1 then
                Just renaming

            else
                Nothing

        _ ->
            Nothing


{-| `alphaEq`, threading the renaming built so far.
-}
alphaEqWith : Renaming -> Can.Type Name -> Can.Type Name -> Maybe Renaming
alphaEqWith renaming a b =
    case ( a, b ) of
        ( Can.TVar v1, Can.TVar v2 ) ->
            bindVar v1 v2 renaming

        ( Can.TType h1 n1 as1, Can.TType h2 n2 as2 ) ->
            if h1 == h2 && n1 == n2 then
                alphaEqList renaming as1 as2

            else
                Nothing

        ( Can.TLambda _ a1 r1, Can.TLambda _ a2 r2 ) ->
            alphaEqWith renaming a1 a2
                |> Maybe.andThen (\r -> alphaEqWith r r1 r2)

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            let
                extRenaming =
                    case ( ext1, ext2 ) of
                        ( Nothing, Nothing ) ->
                            Just renaming

                        ( Just e1, Just e2 ) ->
                            bindVar e1 e2 renaming

                        _ ->
                            Nothing
            in
            extRenaming |> Maybe.andThen (\r -> alphaEqFields r fields1 fields2)

        ( Can.TUnit, Can.TUnit ) ->
            Just renaming

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            alphaEqList renaming (a1 :: b1 :: cs1) (a2 :: b2 :: cs2)

        ( Can.TAlias h1 n1 args1 at1, Can.TAlias h2 n2 args2 at2 ) ->
            if h1 == h2 && n1 == n2 then
                alphaEqList renaming (List.map Tuple.second args1) (List.map Tuple.second args2)
                    |> Maybe.andThen
                        (\r ->
                            case ( at1, at2 ) of
                                ( Can.Holey _, Can.Holey _ ) ->
                                    Just r

                                ( Can.Filled t1, Can.Filled t2 ) ->
                                    alphaEqWith r t1 t2

                                _ ->
                                    Nothing
                        )

            else
                Nothing

        _ ->
            Nothing


{-| Returns the renaming under which two lists of types have the same length
and match element by element, if there is one.
-}
alphaEqList : Renaming -> List (Can.Type Name) -> List (Can.Type Name) -> Maybe Renaming
alphaEqList renaming xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            Just renaming

        ( x :: xr, y :: yr ) ->
            alphaEqWith renaming x y
                |> Maybe.andThen (\r -> alphaEqList r xr yr)

        _ ->
            Nothing


{-| Returns the renaming under which two records have the same field names,
with each field's type matching. Field indices are ignored.
-}
alphaEqFields :
    Renaming
    -> StdDict.Dict Name.Name (Can.FieldType Name)
    -> StdDict.Dict Name.Name (Can.FieldType Name)
    -> Maybe Renaming
alphaEqFields renaming fields1 fields2 =
    if StdDict.keys fields1 /= StdDict.keys fields2 then
        Nothing

    else
        alphaEqList renaming
            (List.map (\(Can.FieldType _ t) -> t) (StdDict.values fields1))
            (List.map (\(Can.FieldType _ t) -> t) (StdDict.values fields2))



-- ============================================================================
-- FREE TYPE VARIABLES
-- ============================================================================


{-| Returns every type variable name that occurs in `tipe`.

That includes record extension variables, the arguments of an alias, and the
body of a `Filled` alias. A `Holey` alias body is written in the alias's own
parameter names, which its arguments stand for, so it is not read.

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
                        Can.Holey _ ->
                            EverySet.empty

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
