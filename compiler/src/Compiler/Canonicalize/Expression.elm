module Compiler.Canonicalize.Expression exposing
    ( EResult, FreeLocals, Uses(..), IdState
    , canonicalizeWithIds, gatherTypedArgsWithIds
    , verifyBindingsWithIds
    )

{-| Canonicalize Elm expressions from source AST to canonical AST.

This module handles the transformation of all expression forms including literals,
variables, function applications, let bindings, case expressions, records, and more.
It tracks free variable usage to detect unused bindings and recursive definitions,
performs binary operator precedence resolution, and validates pattern bindings.


# Results and Tracking

@docs EResult, FreeLocals, Uses, IdState


# Canonicalization

@docs canonicalizeWithIds, gatherTypedArgsWithIds


# Validation

@docs verifyBindingsWithIds

-}

import Basics.Extra exposing (flip)
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.SyntaxVersion as SV exposing (SyntaxVersion)
import Compiler.AST.Utils.Binop as Binop
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Canonicalize.Ids as Ids
import Compiler.Canonicalize.Pattern as Pattern
import Compiler.Canonicalize.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Compiler.Reporting.Warning as W
import Data.Graph as Graph
import Data.Map as Dict exposing (Dict)
import Prelude
import System.TypeCheck.IO as IO
import Utils.Main as Utils



-- ====== RESULTS ======


{-| Result type for expression canonicalization that tracks free variable usage.

The info parameter `i` is typically `FreeLocals` during expression canonicalization,
allowing the result to accumulate information about which local variables are referenced.

-}
type alias EResult i w a =
    ReportingResult.RResult i w Error.Error a


{-| Dictionary tracking which local variables are used and how they are used.

Maps variable names to their usage counts (direct vs delayed). Used to detect
unused bindings and recursive definitions during canonicalization.

-}
type alias FreeLocals =
    Dict String Name.Name Uses


{-| Tracks how many times a variable is used, distinguishing direct from delayed usage.

Direct usage occurs when a variable is referenced in an immediately-evaluated context.
Delayed usage occurs when a variable is captured in a lambda or other delayed context.
This distinction helps detect problematic recursive definitions.

-}
type Uses
    = Uses
        { direct : Int
        , delayed : Int
        }


{-| State for tracking expression IDs during canonicalization.
Re-exported from Compiler.Canonicalize.Ids for convenience.
-}
type alias IdState =
    Ids.IdState


{-| Create a canonical expression with an ID.
-}
makeExpr : A.Region -> IdState -> Can.Expr_ -> ( Can.Expr, IdState )
makeExpr region state node =
    let
        ( id, newState ) =
            Ids.allocId state
    in
    ( A.At region { id = id, node = node }, newState )



-- ====== CANONICALIZE ======


{-| Transform a source expression with ID state threading.

Like canonicalize but also threads an IdState through to assign unique IDs
to each expression. Returns both the canonical expression and the updated state.

-}
canonicalizeWithIds : SyntaxVersion -> Env.Env -> IdState -> Src.Expr -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
canonicalizeWithIds syntaxVersion env state (A.At region expression) =
    canonicalizeNode syntaxVersion env state region expression


{-| Helper to canonicalize the inner expression node and wrap with ID.

This converts the old-style canonicalization (returning Expr\_) to the new style
(returning Expr with ID). For now, uses the passed state for ID assignment.

-}
canonicalizeNode : SyntaxVersion -> Env.Env -> IdState -> A.Region -> Src.Expr_ -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
canonicalizeNode syntaxVersion env state0 region expression =
    let
        -- Helper to wrap an Expr_ result with an ID
        wrapNode : Can.Expr_ -> ( Can.Expr, IdState )
        wrapNode node =
            makeExpr region state0 node

        -- Helper to wrap an Expr_ RResult with ID
        wrapResult : EResult FreeLocals (List W.Warning) Can.Expr_ -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
        wrapResult =
            ReportingResult.map wrapNode
    in
    case expression of
        Src.Str string _ ->
            wrapResult (ReportingResult.ok (Can.Str string))

        Src.Chr char ->
            wrapResult (ReportingResult.ok (Can.Chr char))

        Src.Int int _ ->
            wrapResult (ReportingResult.ok (Can.Int int))

        Src.Float float _ ->
            wrapResult (ReportingResult.ok (Can.Float float))

        Src.Var varType name ->
            wrapResult <|
                case varType of
                    Src.LowVar ->
                        findVar region env name

                    Src.CapVar ->
                        ReportingResult.map (toVarCtor name) (Env.findCtor region env name)

        Src.VarQual varType prefix name ->
            wrapResult <|
                case varType of
                    Src.LowVar ->
                        findVarQual region env prefix name

                    Src.CapVar ->
                        ReportingResult.map (toVarCtor name) (Env.findCtorQual region env prefix name)

        Src.List exprs _ ->
            let
                ( listId, stateAfterList ) =
                    Ids.allocId state0
            in
            traverseExprsWithIds syntaxVersion env stateAfterList (List.map Tuple.second exprs)
                |> ReportingResult.map
                    (\( citems, finalState ) ->
                        ( A.At region { id = listId, node = Can.List citems }, finalState )
                    )

        Src.Op op ->
            wrapResult
                (Env.findBinop region env op
                    |> ReportingResult.map
                        (\(Env.Binop binopData) ->
                            Can.VarOperator op binopData.home binopData.name binopData.annotation
                        )
                )

        Src.Negate expr ->
            let
                ( negateId, stateAfterNegate ) =
                    Ids.allocId state0
            in
            canonicalizeWithIds syntaxVersion env stateAfterNegate expr
                |> ReportingResult.map
                    (\( cexpr, finalState ) ->
                        ( A.At region { id = negateId, node = Can.Negate cexpr }, finalState )
                    )

        Src.Binops ops final ->
            canonicalizeBinopsWithIds syntaxVersion region env state0 (List.map (Tuple.mapSecond Src.c2Value) ops) final

        Src.Lambda ( _, srcArgs ) ( _, body ) ->
            -- Allocate the Lambda's ID first, then use remaining state for patterns and body
            let
                ( lambdaId, stateAfterLambda ) =
                    Ids.allocId state0
            in
            delayedUsageWithIds <|
                (Pattern.verifyWithIds Error.DPLambdaArgs
                    (Pattern.traverseWithIds syntaxVersion env stateAfterLambda (List.map Src.c1Value srcArgs))
                    |> ReportingResult.andThen
                        (\( args, andThenings, stateAfterPatterns ) ->
                            Env.addLocals andThenings env
                                |> ReportingResult.andThen
                                    (\newEnv ->
                                        verifyBindingsWithIds W.Pattern andThenings (canonicalizeWithIds syntaxVersion newEnv stateAfterPatterns body)
                                            |> ReportingResult.map
                                                (\( ( cbody, finalState ), freeLocals ) ->
                                                    let
                                                        lambdaExpr : Can.Expr
                                                        lambdaExpr =
                                                            A.At region { id = lambdaId, node = Can.Lambda args cbody }
                                                    in
                                                    ( ( lambdaExpr, finalState ), freeLocals )
                                                )
                                    )
                        )
                )

        Src.Call func args ->
            let
                ( callId, stateAfterCall ) =
                    Ids.allocId state0
            in
            canonicalizeWithIds syntaxVersion env stateAfterCall func
                |> ReportingResult.andThen
                    (\( cfunc, stateAfterFunc ) ->
                        traverseExprsWithIds syntaxVersion env stateAfterFunc (List.map Src.c1Value args)
                            |> ReportingResult.map
                                (\( cargs, finalState ) ->
                                    ( A.At region { id = callId, node = Can.Call cfunc cargs }, finalState )
                                )
                    )

        Src.If firstBranch branches finally ->
            let
                ( ifId, stateAfterIf ) =
                    Ids.allocId state0
            in
            traverseIfBranchesWithIds syntaxVersion
                env
                stateAfterIf
                (List.map (Src.c1Value >> Tuple.mapBoth Src.c2Value Src.c2Value) (firstBranch :: branches))
                |> ReportingResult.andThen
                    (\( cBranches, stateAfterBranches ) ->
                        canonicalizeWithIds syntaxVersion env stateAfterBranches (Src.c1Value finally)
                            |> ReportingResult.map
                                (\( cfinally, finalState ) ->
                                    ( A.At region { id = ifId, node = Can.If cBranches cfinally }, finalState )
                                )
                    )

        Src.Let defs _ expr ->
            canonicalizeLetWithIds syntaxVersion region env state0 (List.map Src.c2Value defs) expr

        Src.Case expr branches ->
            -- Allocate the Case's ID first, then thread state through scrutinee and branches
            let
                ( caseId, stateAfterCase ) =
                    Ids.allocId state0
            in
            canonicalizeWithIds syntaxVersion env stateAfterCase (Src.c2Value expr)
                |> ReportingResult.andThen
                    (\( cexpr, stateAfterScrutinee ) ->
                        traverseCaseBranchesWithIds syntaxVersion env stateAfterScrutinee (List.map (Tuple.mapBoth Src.c2Value Src.c1Value) branches)
                            |> ReportingResult.map
                                (\( cBranches, finalState ) ->
                                    let
                                        caseExpr : Can.Expr
                                        caseExpr =
                                            A.At region { id = caseId, node = Can.Case cexpr cBranches }
                                    in
                                    ( caseExpr, finalState )
                                )
                    )

        Src.Accessor field ->
            let
                ( accessorId, newState ) =
                    Ids.allocId state0
            in
            ReportingResult.ok ( A.At region { id = accessorId, node = Can.Accessor field }, newState )

        Src.Access record field ->
            let
                ( accessId, stateAfterAccess ) =
                    Ids.allocId state0
            in
            canonicalizeWithIds syntaxVersion env stateAfterAccess record
                |> ReportingResult.map
                    (\( crecord, finalState ) ->
                        ( A.At region { id = accessId, node = Can.Access crecord field }, finalState )
                    )

        Src.Update ( _, name ) ( _, fields ) ->
            let
                ( updateId, stateAfterUpdate ) =
                    Ids.allocId state0
            in
            canonicalizeWithIds syntaxVersion env stateAfterUpdate name
                |> ReportingResult.andThen
                    (\( cname, stateAfterName ) ->
                        Dups.checkLocatedFields (List.map (Src.c2EolValue >> Tuple.mapBoth Src.c1Value Src.c1Value) fields)
                            |> ReportingResult.andThen
                                (\fieldDict ->
                                    traverseUpdateFieldsWithIds syntaxVersion env stateAfterName fieldDict
                                        |> ReportingResult.map
                                            (\( cfields, finalState ) ->
                                                ( A.At region { id = updateId, node = Can.Update cname cfields }, finalState )
                                            )
                                )
                    )

        Src.Record ( _, fields ) ->
            let
                ( recordId, stateAfterRecord ) =
                    Ids.allocId state0
            in
            Dups.checkLocatedFields (List.map (Src.c2EolValue >> Tuple.mapBoth Src.c1Value Src.c1Value) fields)
                |> ReportingResult.andThen
                    (\fieldDict ->
                        traverseDictWithIds syntaxVersion env stateAfterRecord fieldDict
                            |> ReportingResult.map
                                (\( cfields, finalState ) ->
                                    ( A.At region { id = recordId, node = Can.Record cfields }, finalState )
                                )
                    )

        Src.Unit ->
            let
                ( unitId, newState ) =
                    Ids.allocId state0
            in
            ReportingResult.ok ( A.At region { id = unitId, node = Can.Unit }, newState )

        Src.Tuple ( _, a ) ( _, b ) cs ->
            let
                ( tupleId, stateAfterTuple ) =
                    Ids.allocId state0
            in
            canonicalizeWithIds syntaxVersion env stateAfterTuple a
                |> ReportingResult.andThen
                    (\( ca, stateAfterA ) ->
                        canonicalizeWithIds syntaxVersion env stateAfterA b
                            |> ReportingResult.andThen
                                (\( cb, stateAfterB ) ->
                                    canonicalizeTupleExtrasWithIds syntaxVersion region env stateAfterB (List.map Src.c2Value cs)
                                        |> ReportingResult.map
                                            (\( cextras, finalState ) ->
                                                ( A.At region { id = tupleId, node = Can.Tuple ca cb cextras }, finalState )
                                            )
                                )
                    )

        Src.Shader src tipe ->
            let
                ( shaderId, newState ) =
                    Ids.allocId state0
            in
            ReportingResult.ok ( A.At region { id = shaderId, node = Can.Shader src tipe }, newState )

        Src.Parens ( _, expr ) ->
            canonicalizeWithIds syntaxVersion env state0 expr


{-| Canonicalize extra tuple elements (3rd, 4th, etc.) while threading IdState.
-}
canonicalizeTupleExtrasWithIds : SyntaxVersion -> A.Region -> Env.Env -> IdState -> List Src.Expr -> EResult FreeLocals (List W.Warning) ( List Can.Expr, IdState )
canonicalizeTupleExtrasWithIds syntaxVersion region env state extras =
    case extras of
        [] ->
            ReportingResult.ok ( [], state )

        [ three ] ->
            canonicalizeWithIds syntaxVersion env state three
                |> ReportingResult.map (\( e, s ) -> ( [ e ], s ))

        _ ->
            case syntaxVersion of
                SV.Elm ->
                    ReportingResult.throw (Error.TupleLargerThanThree region)

                SV.Guida ->
                    traverseExprsWithIds syntaxVersion env state extras


{-| Traverse a list of expressions while threading IdState through each.
-}
traverseExprsWithIds : SyntaxVersion -> Env.Env -> IdState -> List Src.Expr -> EResult FreeLocals (List W.Warning) ( List Can.Expr, IdState )
traverseExprsWithIds syntaxVersion env state exprs =
    case exprs of
        [] ->
            ReportingResult.ok ( [], state )

        expr :: rest ->
            canonicalizeWithIds syntaxVersion env state expr
                |> ReportingResult.andThen
                    (\( cexpr, stateAfter ) ->
                        traverseExprsWithIds syntaxVersion env stateAfter rest
                            |> ReportingResult.map
                                (\( crest, finalState ) ->
                                    ( cexpr :: crest, finalState )
                                )
                    )


{-| Traverse a dict of expressions while threading IdState through each.
The dict is converted to a list, traversed, then converted back.
-}
traverseDictWithIds :
    SyntaxVersion
    -> Env.Env
    -> IdState
    -> Dict String (A.Located Name) Src.Expr
    -> EResult FreeLocals (List W.Warning) ( Dict String (A.Located Name) Can.Expr, IdState )
traverseDictWithIds syntaxVersion env state dict =
    let
        entries : List ( A.Located Name, Src.Expr )
        entries =
            Dict.toList A.compareLocated dict
    in
    traverseDictEntriesWithIds syntaxVersion env state entries []
        |> ReportingResult.map
            (\( resultEntries, finalState ) ->
                ( Dict.fromList A.toValue resultEntries, finalState )
            )


traverseDictEntriesWithIds :
    SyntaxVersion
    -> Env.Env
    -> IdState
    -> List ( A.Located Name, Src.Expr )
    -> List ( A.Located Name, Can.Expr )
    -> EResult FreeLocals (List W.Warning) ( List ( A.Located Name, Can.Expr ), IdState )
traverseDictEntriesWithIds syntaxVersion env state entries acc =
    case entries of
        [] ->
            ReportingResult.ok ( List.reverse acc, state )

        ( key, srcExpr ) :: rest ->
            canonicalizeWithIds syntaxVersion env state srcExpr
                |> ReportingResult.andThen
                    (\( canExpr, stateAfter ) ->
                        traverseDictEntriesWithIds syntaxVersion env stateAfter rest (( key, canExpr ) :: acc)
                    )


{-| Traverse update fields while threading IdState through each, producing FieldUpdate values.
-}
traverseUpdateFieldsWithIds :
    SyntaxVersion
    -> Env.Env
    -> IdState
    -> Dict String (A.Located Name) Src.Expr
    -> EResult FreeLocals (List W.Warning) ( Dict String (A.Located Name) Can.FieldUpdate, IdState )
traverseUpdateFieldsWithIds syntaxVersion env state dict =
    let
        entries : List ( A.Located Name, Src.Expr )
        entries =
            Dict.toList A.compareLocated dict
    in
    traverseUpdateEntriesWithIds syntaxVersion env state entries []
        |> ReportingResult.map
            (\( resultEntries, finalState ) ->
                ( Dict.fromList A.toValue resultEntries, finalState )
            )


traverseUpdateEntriesWithIds :
    SyntaxVersion
    -> Env.Env
    -> IdState
    -> List ( A.Located Name, Src.Expr )
    -> List ( A.Located Name, Can.FieldUpdate )
    -> EResult FreeLocals (List W.Warning) ( List ( A.Located Name, Can.FieldUpdate ), IdState )
traverseUpdateEntriesWithIds syntaxVersion env state entries acc =
    case entries of
        [] ->
            ReportingResult.ok ( List.reverse acc, state )

        ( (A.At fieldRegion _) as key, srcExpr ) :: rest ->
            canonicalizeWithIds syntaxVersion env state srcExpr
                |> ReportingResult.andThen
                    (\( canExpr, stateAfter ) ->
                        let
                            fieldUpdate : Can.FieldUpdate
                            fieldUpdate =
                                Can.FieldUpdate fieldRegion canExpr
                        in
                        traverseUpdateEntriesWithIds syntaxVersion env stateAfter rest (( key, fieldUpdate ) :: acc)
                    )



-- ====== CANONICALIZE IF BRANCH ======


{-| Canonicalize an if branch (condition and body) while threading IdState.
-}
canonicalizeIfBranchWithIds : SyntaxVersion -> Env.Env -> IdState -> ( Src.Expr, Src.Expr ) -> EResult FreeLocals (List W.Warning) ( ( Can.Expr, Can.Expr ), IdState )
canonicalizeIfBranchWithIds syntaxVersion env state ( condition, branch ) =
    canonicalizeWithIds syntaxVersion env state condition
        |> ReportingResult.andThen
            (\( ccond, stateAfterCond ) ->
                canonicalizeWithIds syntaxVersion env stateAfterCond branch
                    |> ReportingResult.map
                        (\( cbranch, finalState ) ->
                            ( ( ccond, cbranch ), finalState )
                        )
            )


{-| Traverse if branches while threading IdState through each.
-}
traverseIfBranchesWithIds : SyntaxVersion -> Env.Env -> IdState -> List ( Src.Expr, Src.Expr ) -> EResult FreeLocals (List W.Warning) ( List ( Can.Expr, Can.Expr ), IdState )
traverseIfBranchesWithIds syntaxVersion env state branches =
    case branches of
        [] ->
            ReportingResult.ok ( [], state )

        branch :: rest ->
            canonicalizeIfBranchWithIds syntaxVersion env state branch
                |> ReportingResult.andThen
                    (\( cbranch, stateAfter ) ->
                        traverseIfBranchesWithIds syntaxVersion env stateAfter rest
                            |> ReportingResult.map
                                (\( crest, finalState ) ->
                                    ( cbranch :: crest, finalState )
                                )
                    )



-- ====== CANONICALIZE CASE BRANCH ======


{-| Canonicalize a case branch while threading IdState through pattern and expression.
-}
canonicalizeCaseBranchWithIds : SyntaxVersion -> Env.Env -> IdState -> ( Src.Pattern, Src.Expr ) -> EResult FreeLocals (List W.Warning) ( Can.CaseBranch, IdState )
canonicalizeCaseBranchWithIds syntaxVersion env state ( pattern, expr ) =
    directUsageWithIds
        (Pattern.verifyWithIds Error.DPCaseBranch
            (Pattern.canonicalizeWithIds syntaxVersion env state pattern)
            |> ReportingResult.andThen
                (\( cpattern, andThenings, stateAfterPattern ) ->
                    Env.addLocals andThenings env
                        |> ReportingResult.andThen
                            (\newEnv ->
                                verifyBindingsWithIds W.Pattern andThenings (canonicalizeWithIds syntaxVersion newEnv stateAfterPattern expr)
                                    |> ReportingResult.map
                                        (\( ( cexpr, finalState ), freeLocals ) ->
                                            ( ( Can.CaseBranch cpattern cexpr, finalState ), freeLocals )
                                        )
                            )
                )
        )


{-| Traverse case branches while threading IdState through each branch.
-}
traverseCaseBranchesWithIds :
    SyntaxVersion
    -> Env.Env
    -> IdState
    -> List ( Src.Pattern, Src.Expr )
    -> EResult FreeLocals (List W.Warning) ( List Can.CaseBranch, IdState )
traverseCaseBranchesWithIds syntaxVersion env state branches =
    case branches of
        [] ->
            ReportingResult.ok ( [], state )

        branch :: rest ->
            canonicalizeCaseBranchWithIds syntaxVersion env state branch
                |> ReportingResult.andThen
                    (\( canBranch, stateAfterBranch ) ->
                        traverseCaseBranchesWithIds syntaxVersion env stateAfterBranch rest
                            |> ReportingResult.map
                                (\( canRest, finalState ) ->
                                    ( canBranch :: canRest, finalState )
                                )
                    )



-- ====== CANONICALIZE BINOPS ======


{-| Canonicalize binary operators with proper precedence and associativity,
threading IdState through all expressions.
-}
canonicalizeBinopsWithIds :
    SyntaxVersion
    -> A.Region
    -> Env.Env
    -> IdState
    -> List ( Src.Expr, A.Located Name.Name )
    -> Src.Expr
    -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
canonicalizeBinopsWithIds syntaxVersion overallRegion env state ops final =
    let
        canonicalizeOpsWithIds :
            IdState
            -> List ( Src.Expr, A.Located Name )
            -> List ( Can.Expr, Env.Binop )
            -> EResult FreeLocals (List W.Warning) ( List ( Can.Expr, Env.Binop ), IdState )
        canonicalizeOpsWithIds st opsToProcess acc =
            case opsToProcess of
                [] ->
                    ReportingResult.ok ( List.reverse acc, st )

                ( expr, A.At region op ) :: rest ->
                    canonicalizeWithIds syntaxVersion env st expr
                        |> ReportingResult.andThen
                            (\( cexpr, stAfter ) ->
                                Env.findBinop region env op
                                    |> ReportingResult.andThen
                                        (\binop ->
                                            canonicalizeOpsWithIds stAfter rest (( cexpr, binop ) :: acc)
                                        )
                            )
    in
    canonicalizeOpsWithIds state ops []
        |> ReportingResult.andThen
            (\( cOps, stateAfterOps ) ->
                canonicalizeWithIds syntaxVersion env stateAfterOps final
                    |> ReportingResult.andThen
                        (\( cfinal, stateAfterFinal ) ->
                            case cOps of
                                [] ->
                                    ReportingResult.ok ( cfinal, stateAfterFinal )

                                _ ->
                                    runBinopStepperWithIds overallRegion stateAfterFinal (MoreWithIds stateAfterFinal cOps cfinal)
                        )
            )


type StepWithIds
    = DoneWithIds Can.Expr IdState
    | MoreWithIds IdState (List ( Can.Expr, Env.Binop )) Can.Expr
    | ErrorWithIds Env.Binop Env.Binop


{-| A function that, given state and a right operand, produces a binop expression and updated state.
-}
type alias MakeBinopFn =
    IdState -> Can.Expr -> ( Can.Expr, IdState )


runBinopStepperWithIds : A.Region -> IdState -> StepWithIds -> EResult FreeLocals w ( Can.Expr, IdState )
runBinopStepperWithIds overallRegion _ step =
    case step of
        DoneWithIds expr finalState ->
            ReportingResult.ok ( expr, finalState )

        MoreWithIds innerState [] expr ->
            ReportingResult.ok ( expr, innerState )

        MoreWithIds innerState (( expr, op ) :: rest) final ->
            toBinopStepWithIds innerState (toBinopWithIds op expr) op rest final
                |> runBinopStepperWithIds overallRegion innerState

        ErrorWithIds (Env.Binop binopData1) (Env.Binop binopData2) ->
            ReportingResult.throw (Error.Binop overallRegion binopData1.op binopData2.op)


toBinopStepWithIds :
    IdState
    -> MakeBinopFn
    -> Env.Binop
    -> List ( Can.Expr, Env.Binop )
    -> Can.Expr
    -> StepWithIds
toBinopStepWithIds currentState makeBinop ((Env.Binop rootBinopData) as rootOp) middle final =
    let
        rootAssociativity =
            rootBinopData.associativity

        rootPrecedence =
            rootBinopData.precedence
    in
    case middle of
        [] ->
            let
                ( result, finalState ) =
                    makeBinop currentState final
            in
            DoneWithIds result finalState

        ( expr, (Env.Binop opBinopData) as op ) :: rest ->
            let
                associativity =
                    opBinopData.associativity

                precedence =
                    opBinopData.precedence
            in
            if precedence < rootPrecedence then
                -- Lower precedence: apply makeBinop first, then return More for caller to handle
                let
                    ( combined, newState ) =
                        makeBinop currentState expr
                in
                MoreWithIds newState (( combined, op ) :: rest) final

            else if precedence > rootPrecedence then
                -- Higher precedence: process inner operators first, then apply makeBinop
                case toBinopStepWithIds currentState (toBinopWithIds op expr) op rest final of
                    DoneWithIds newLast innerState ->
                        let
                            ( result, finalState ) =
                                makeBinop innerState newLast
                        in
                        DoneWithIds result finalState

                    MoreWithIds innerState newMiddle newLast ->
                        toBinopStepWithIds innerState makeBinop rootOp newMiddle newLast

                    ErrorWithIds a b ->
                        ErrorWithIds a b

            else
                -- Same precedence: check associativity
                case ( rootAssociativity, associativity ) of
                    ( Binop.Left, Binop.Left ) ->
                        -- Left associative: apply makeBinop first, then continue with result
                        let
                            ( combined, newState ) =
                                makeBinop currentState expr
                        in
                        toBinopStepWithIds newState (toBinopWithIds op combined) op rest final

                    ( Binop.Right, Binop.Right ) ->
                        -- Right associative: compose makeBinop with toBinopWithIds
                        -- First apply inner (toBinopWithIds op expr), then outer (makeBinop)
                        -- Use composeBinopStep helper to ensure JavaScript captures makeBinop's
                        -- VALUE, not the variable reference. Without this, JavaScript's function-scoped
                        -- `var` causes all closures to share the same variable, leading to infinite
                        -- recursion when the loop variable is reassigned.
                        toBinopStepWithIds currentState (composeBinopStep makeBinop op expr) op rest final

                    _ ->
                        ErrorWithIds rootOp op


{-| Create a MakeBinopFn that builds a binary operator expression.

Given an operator and left operand, returns a function that takes state and
right operand to produce the complete binop expression.

-}
toBinopWithIds : Env.Binop -> Can.Expr -> MakeBinopFn
toBinopWithIds (Env.Binop binopData) left =
    \state right ->
        let
            ( id, newState ) =
                Ids.allocId state

            region =
                A.mergeRegions (A.toRegion left) (A.toRegion right)
        in
        ( A.At region { id = id, node = Can.Binop binopData.op binopData.home binopData.name binopData.annotation left right }
        , newState
        )


{-| Compose a binop step by wrapping an outer MakeBinopFn with an inner toBinopWithIds.

This helper function is crucial for correct JavaScript code generation. When the Elm compiler
generates a tail-recursive loop with closures, JavaScript's function-scoped `var` causes all
closures in the loop to share the same variable binding. By extracting the composition into
a separate function, we force JavaScript to capture the CURRENT VALUE of outerMakeBinop as
a function parameter, rather than capturing a shared variable that gets overwritten.

Without this pattern, the closures would all reference the same `outerMakeBinop` variable,
which after the loop points to the last closure, causing infinite self-recursion.

-}
composeBinopStep : MakeBinopFn -> Env.Binop -> Can.Expr -> MakeBinopFn
composeBinopStep outerMakeBinop op expr =
    \state right ->
        let
            ( inner, state1 ) =
                toBinopWithIds op expr state right
        in
        outerMakeBinop state1 inner


{-| Canonicalize a let expression, detecting cycles and threading IdState.
-}
canonicalizeLetWithIds : SyntaxVersion -> A.Region -> Env.Env -> IdState -> List (A.Located Src.Def) -> Src.Expr -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
canonicalizeLetWithIds syntaxVersion letRegion env state defs body =
    directUsageWithIds <|
        (Dups.detect (Error.DuplicatePattern Error.DPLetBinding)
            (List.foldl addBindings Dups.none defs)
            |> ReportingResult.andThen
                (\andThenings ->
                    Env.addLocals andThenings env
                        |> ReportingResult.andThen
                            (\newEnv ->
                                verifyBindingsWithIds W.Def andThenings <|
                                    (foldDefNodesWithIds syntaxVersion newEnv state [] defs
                                        |> ReportingResult.andThen
                                            (\( nodes, stateAfterDefs ) ->
                                                canonicalizeWithIds syntaxVersion newEnv stateAfterDefs body
                                                    |> ReportingResult.andThen
                                                        (\( cbody, stateAfterBody ) ->
                                                            detectCyclesWithIds letRegion stateAfterBody (Graph.stronglyConnComp nodes) cbody
                                                        )
                                            )
                                    )
                            )
                )
        )


{-| Fold over def nodes while threading IdState through each.
-}
foldDefNodesWithIds :
    SyntaxVersion
    -> Env.Env
    -> IdState
    -> List Node
    -> List (A.Located Src.Def)
    -> EResult FreeLocals (List W.Warning) ( List Node, IdState )
foldDefNodesWithIds syntaxVersion env state acc defs =
    case defs of
        [] ->
            ReportingResult.ok ( acc, state )

        def :: rest ->
            addDefNodesWithIds syntaxVersion env state acc def
                |> ReportingResult.andThen
                    (\( newAcc, newState ) ->
                        foldDefNodesWithIds syntaxVersion env newState newAcc rest
                    )


addBindings : A.Located Src.Def -> Dups.Tracker A.Region -> Dups.Tracker A.Region
addBindings (A.At _ def) andThenings =
    case def of
        Src.Define (A.At region name) _ _ _ ->
            Dups.insert name region region andThenings

        Src.Destruct pattern _ ->
            addBindingsHelp andThenings pattern


addBindingsHelp : Dups.Tracker A.Region -> Src.Pattern -> Dups.Tracker A.Region
addBindingsHelp andThenings (A.At region pattern) =
    case pattern of
        Src.PAnything _ ->
            andThenings

        Src.PVar name ->
            Dups.insert name region region andThenings

        Src.PRecord ( _, fields ) ->
            let
                addField : Src.C2 (A.Located Name) -> Dups.Tracker A.Region -> Dups.Tracker A.Region
                addField ( _, A.At fieldRegion name ) dict =
                    Dups.insert name fieldRegion fieldRegion dict
            in
            List.foldl addField andThenings fields

        Src.PUnit _ ->
            andThenings

        Src.PTuple a b cs ->
            List.foldl (flip addBindingsHelp) andThenings (List.map Src.c2Value (a :: b :: cs))

        Src.PCtor _ _ patterns ->
            List.foldl (flip addBindingsHelp) andThenings (List.map Src.c1Value patterns)

        Src.PCtorQual _ _ _ patterns ->
            List.foldl (flip addBindingsHelp) andThenings (List.map Src.c1Value patterns)

        Src.PList ( _, patterns ) ->
            List.foldl (flip addBindingsHelp) andThenings (List.map Src.c2Value patterns)

        Src.PCons ( _, hd ) ( _, tl ) ->
            addBindingsHelp (addBindingsHelp andThenings hd) tl

        Src.PAlias ( _, aliasPattern ) ( _, A.At nameRegion name ) ->
            addBindingsHelp andThenings aliasPattern |> Dups.insert name nameRegion nameRegion

        Src.PChr _ ->
            andThenings

        Src.PStr _ _ ->
            andThenings

        Src.PInt _ _ ->
            andThenings

        Src.PParens ( _, parensPattern ) ->
            addBindingsHelp andThenings parensPattern


type alias Node =
    ( Binding, Name.Name, List Name.Name )


type Binding
    = Define Can.Def
    | Edge (A.Located Name.Name)
    | Destruct Can.Pattern Can.Expr


{-| Process a definition node while threading IdState through pattern canonicalization.
-}
addDefNodesWithIds : SyntaxVersion -> Env.Env -> IdState -> List Node -> A.Located Src.Def -> EResult FreeLocals (List W.Warning) ( List Node, IdState )
addDefNodesWithIds syntaxVersion env state nodes (A.At _ def) =
    case def of
        Src.Define ((A.At _ name) as aname) srcArgs ( _, body ) maybeType ->
            case maybeType of
                Nothing ->
                    Pattern.verifyWithIds (Error.DPFuncArgs name)
                        (Pattern.traverseWithIds syntaxVersion env state (List.map Src.c1Value srcArgs))
                        |> ReportingResult.andThen
                            (\( args, argBindings, stateAfterArgs ) ->
                                Env.addLocals argBindings env
                                    |> ReportingResult.andThen
                                        (\newEnv ->
                                            verifyBindingsWithIds W.Pattern argBindings (canonicalizeWithIds syntaxVersion newEnv stateAfterArgs body)
                                                |> ReportingResult.andThen
                                                    (\( ( cbody, stateAfterBody ), freeLocals ) ->
                                                        let
                                                            cdef : Can.Def
                                                            cdef =
                                                                Can.Def aname args cbody

                                                            node : ( Binding, Name, List Name )
                                                            node =
                                                                ( Define cdef, name, Dict.keys compare freeLocals )
                                                        in
                                                        logLetLocalsWithIds args freeLocals ( node :: nodes, stateAfterBody )
                                                    )
                                        )
                            )

                Just ( _, ( _, tipe ) ) ->
                    Type.toAnnotation syntaxVersion env tipe
                        |> ReportingResult.andThen
                            (\(Can.Forall freeVars ctipe) ->
                                -- Use Pattern.verify (not verifyWithIds) because gatherTypedArgsWithIds
                                -- already threads IdState internally and returns it in the result tuple
                                Pattern.verify (Error.DPFuncArgs name)
                                    (gatherTypedArgsWithIds syntaxVersion env name state (List.map Src.c1Value srcArgs) ctipe Index.first [])
                                    |> ReportingResult.andThen
                                        (\( ( ( args, resultType ), stateAfterArgs ), argBindings ) ->
                                            Env.addLocals argBindings env
                                                |> ReportingResult.andThen
                                                    (\newEnv ->
                                                        verifyBindingsWithIds W.Pattern argBindings (canonicalizeWithIds syntaxVersion newEnv stateAfterArgs body)
                                                            |> ReportingResult.andThen
                                                                (\( ( cbody, stateAfterBody ), freeLocals ) ->
                                                                    let
                                                                        cdef : Can.Def
                                                                        cdef =
                                                                            Can.TypedDef aname freeVars args cbody resultType

                                                                        node : ( Binding, Name, List Name )
                                                                        node =
                                                                            ( Define cdef, name, Dict.keys compare freeLocals )
                                                                    in
                                                                    logLetLocalsWithIds args freeLocals ( node :: nodes, stateAfterBody )
                                                                )
                                                    )
                                        )
                            )

        Src.Destruct pattern ( _, body ) ->
            Pattern.verifyWithIds Error.DPDestruct
                (Pattern.canonicalizeWithIds syntaxVersion env state pattern)
                |> ReportingResult.andThen
                    (\( cpattern, _, stateAfterPattern ) ->
                        ReportingResult.RResult
                            (\fs ws ->
                                case canonicalizeWithIds syntaxVersion env stateAfterPattern body of
                                    ReportingResult.RResult k ->
                                        case k Dict.empty ws of
                                            ReportingResult.ROk freeLocals warnings ( cbody, stateAfterBody ) ->
                                                let
                                                    names : List (A.Located Name)
                                                    names =
                                                        getPatternNames [] pattern

                                                    name : Name
                                                    name =
                                                        Name.fromManyNames (List.map A.toValue names)

                                                    node : ( Binding, Name, List Name )
                                                    node =
                                                        ( Destruct cpattern cbody, name, Dict.keys compare freeLocals )
                                                in
                                                ReportingResult.ROk
                                                    (Utils.mapUnionWith identity compare combineUses fs freeLocals)
                                                    warnings
                                                    ( List.foldl (addEdge [ name ]) (node :: nodes) names, stateAfterBody )

                                            ReportingResult.RErr freeLocals warnings errors ->
                                                ReportingResult.RErr (Utils.mapUnionWith identity compare combineUses freeLocals fs) warnings errors
                            )
                    )


{-| Like logLetLocals but preserves IdState in the result.
-}
logLetLocalsWithIds : List arg -> FreeLocals -> ( value, IdState ) -> EResult FreeLocals w ( value, IdState )
logLetLocalsWithIds args letLocals ( value, idState ) =
    ReportingResult.RResult
        (\freeLocals warnings ->
            ReportingResult.ROk
                (Utils.mapUnionWith identity
                    compare
                    combineUses
                    freeLocals
                    (case args of
                        [] ->
                            letLocals

                        _ ->
                            Dict.map (\_ -> delayUse) letLocals
                    )
                )
                warnings
                ( value, idState )
        )


addEdge : List Name.Name -> A.Located Name.Name -> List Node -> List Node
addEdge edges ((A.At _ name) as aname) nodes =
    ( Edge aname, name, edges ) :: nodes


getPatternNames : List (A.Located Name.Name) -> Src.Pattern -> List (A.Located Name.Name)
getPatternNames names (A.At region pattern) =
    case pattern of
        Src.PAnything _ ->
            names

        Src.PVar name ->
            A.At region name :: names

        Src.PRecord ( _, fields ) ->
            List.map Src.c2Value fields ++ names

        Src.PAlias ( _, ptrn ) ( _, name ) ->
            getPatternNames (name :: names) ptrn

        Src.PUnit _ ->
            names

        Src.PTuple ( _, a ) ( _, b ) cs ->
            List.foldl (flip getPatternNames) (getPatternNames (getPatternNames names a) b) (List.map Src.c2Value cs)

        Src.PCtor _ _ args ->
            List.foldl (flip getPatternNames) names (List.map Src.c1Value args)

        Src.PCtorQual _ _ _ args ->
            List.foldl (flip getPatternNames) names (List.map Src.c1Value args)

        Src.PList ( _, patterns ) ->
            List.foldl (flip getPatternNames) names (List.map Src.c2Value patterns)

        Src.PCons ( _, hd ) ( _, tl ) ->
            getPatternNames (getPatternNames names hd) tl

        Src.PChr _ ->
            names

        Src.PStr _ _ ->
            names

        Src.PInt _ _ ->
            names

        Src.PParens ( _, parensPattern ) ->
            getPatternNames names parensPattern


{-| Match function argument patterns against a type signature, producing typed arguments.

This function processes a type-annotated function definition by pairing each argument
pattern with its corresponding type from the signature. It:

  - Iterates through the function type, extracting argument types from nested lambdas
  - Canonicalizes each argument pattern with IdState threading
  - Pairs each pattern with its type annotation
  - Returns the list of typed argument patterns, the final return type, and updated IdState
  - Reports an error if there are more patterns than types in the signature

This is used when processing function definitions with explicit type annotations.

-}
gatherTypedArgsWithIds :
    SyntaxVersion
    -> Env.Env
    -> Name.Name
    -> IdState
    -> List Src.Pattern
    -> Can.Type
    -> Index.ZeroBased
    -> List ( Can.Pattern, Can.Type )
    -> EResult Pattern.DupsDict w ( ( List ( Can.Pattern, Can.Type ), Can.Type ), IdState )
gatherTypedArgsWithIds syntaxVersion env name state srcArgs tipe index revTypedArgs =
    case srcArgs of
        [] ->
            ReportingResult.ok ( ( List.reverse revTypedArgs, tipe ), state )

        srcArg :: otherSrcArgs ->
            case Type.iteratedDealias tipe of
                Can.TLambda argType resultType ->
                    Pattern.canonicalizeWithIds syntaxVersion env state srcArg
                        |> ReportingResult.andThen
                            (\( arg, stateAfterArg ) ->
                                gatherTypedArgsWithIds syntaxVersion env name stateAfterArg otherSrcArgs resultType (Index.next index) (( arg, argType ) :: revTypedArgs)
                            )

                _ ->
                    let
                        ( A.At start _, A.At end _ ) =
                            ( Prelude.head srcArgs, Prelude.last srcArgs )
                    in
                    ReportingResult.throw (Error.AnnotationTooShort (A.mergeRegions start end) name index (List.length srcArgs))


checkCycle : List Binding -> List Can.Def -> EResult i w (List Can.Def)
checkCycle andThenings defs =
    case andThenings of
        [] ->
            ReportingResult.ok defs

        andThening :: otherBindings ->
            case andThening of
                Define ((Can.Def name args _) as def) ->
                    if List.isEmpty args then
                        ReportingResult.throw (Error.RecursiveLet name (toNames otherBindings defs))

                    else
                        checkCycle otherBindings (def :: defs)

                Define ((Can.TypedDef name _ args _ _) as def) ->
                    if List.isEmpty args then
                        ReportingResult.throw (Error.RecursiveLet name (toNames otherBindings defs))

                    else
                        checkCycle otherBindings (def :: defs)

                Edge name ->
                    ReportingResult.throw (Error.RecursiveLet name (toNames otherBindings defs))

                Destruct _ _ ->
                    -- a Destruct cannot appear in a cycle without any Edge values
                    -- so we just keep going until we get to the edges
                    checkCycle otherBindings defs


toNames : List Binding -> List Can.Def -> List Name.Name
toNames andThenings revDefs =
    case andThenings of
        [] ->
            List.reverse (List.map getDefName revDefs)

        andThening :: otherBindings ->
            case andThening of
                Define def ->
                    getDefName def :: toNames otherBindings revDefs

                Edge (A.At _ name) ->
                    name :: toNames otherBindings revDefs

                Destruct _ _ ->
                    toNames otherBindings revDefs


getDefName : Can.Def -> Name.Name
getDefName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


{-| Like detectCycles but threads IdState and allocates IDs for Let/LetDestruct/LetRec nodes.
-}
detectCyclesWithIds : A.Region -> IdState -> List (Graph.SCC Binding) -> Can.Expr -> EResult i w ( Can.Expr, IdState )
detectCyclesWithIds letRegion state sccs body =
    case sccs of
        [] ->
            ReportingResult.ok ( body, state )

        scc :: subSccs ->
            case scc of
                Graph.AcyclicSCC andThening ->
                    case andThening of
                        Define def ->
                            detectCyclesWithIds letRegion state subSccs body
                                |> ReportingResult.map
                                    (\( innerBody, stateAfterInner ) ->
                                        let
                                            ( letId, finalState ) =
                                                Ids.allocId stateAfterInner
                                        in
                                        ( A.At letRegion { id = letId, node = Can.Let def innerBody }, finalState )
                                    )

                        Edge _ ->
                            detectCyclesWithIds letRegion state subSccs body

                        Destruct pattern expr ->
                            detectCyclesWithIds letRegion state subSccs body
                                |> ReportingResult.map
                                    (\( innerBody, stateAfterInner ) ->
                                        let
                                            ( letId, finalState ) =
                                                Ids.allocId stateAfterInner
                                        in
                                        ( A.At letRegion { id = letId, node = Can.LetDestruct pattern expr innerBody }, finalState )
                                    )

                Graph.CyclicSCC andThenings ->
                    checkCycle andThenings []
                        |> ReportingResult.andThen
                            (\defs ->
                                detectCyclesWithIds letRegion state subSccs body
                                    |> ReportingResult.map
                                        (\( innerBody, stateAfterInner ) ->
                                            let
                                                ( letId, finalState ) =
                                                    Ids.allocId stateAfterInner
                                            in
                                            ( A.At letRegion { id = letId, node = Can.LetRec defs innerBody }, finalState )
                                        )
                            )


logVar : Name.Name -> a -> EResult FreeLocals w a
logVar name value =
    ReportingResult.RResult <|
        \freeLocals warnings ->
            ReportingResult.ROk (Utils.mapInsertWith identity combineUses name oneDirectUse freeLocals) warnings value


oneDirectUse : Uses
oneDirectUse =
    Uses
        { direct = 1
        , delayed = 0
        }


combineUses : Uses -> Uses -> Uses
combineUses (Uses ab) (Uses xy) =
    Uses
        { direct = ab.direct + xy.direct
        , delayed = ab.delayed + xy.delayed
        }


delayUse : Uses -> Uses
delayUse (Uses { direct, delayed }) =
    Uses
        { direct = 0
        , delayed = direct + delayed
        }



-- ====== MANAGING BINDINGS ======


addUnusedWarning : W.Context -> Name.Name -> A.Region -> List W.Warning -> List W.Warning
addUnusedWarning context name region warnings =
    W.UnusedVariable region context name :: warnings


{-| Like directUsage but also threads IdState through the result.

Used for Let and Case expressions where pattern canonicalization
needs to share the ID space with expressions.

-}
directUsageWithIds : EResult () w ( ( expr, IdState ), FreeLocals ) -> EResult FreeLocals w ( expr, IdState )
directUsageWithIds (ReportingResult.RResult k) =
    ReportingResult.RResult
        (\freeLocals warnings ->
            case k () warnings of
                ReportingResult.ROk () ws ( ( value, idState ), newFreeLocals ) ->
                    ReportingResult.ROk (Utils.mapUnionWith identity compare combineUses freeLocals newFreeLocals) ws ( value, idState )

                ReportingResult.RErr () ws es ->
                    ReportingResult.RErr freeLocals ws es
        )


{-| Like delayedUsage but also threads IdState through the result.

Used for Lambda expressions where pattern canonicalization
needs to share the ID space with expressions.

-}
delayedUsageWithIds : EResult () w ( ( expr, IdState ), FreeLocals ) -> EResult FreeLocals w ( expr, IdState )
delayedUsageWithIds (ReportingResult.RResult k) =
    ReportingResult.RResult
        (\freeLocals warnings ->
            case k () warnings of
                ReportingResult.ROk () ws ( ( value, idState ), newFreeLocals ) ->
                    let
                        delayedLocals : Dict String Name Uses
                        delayedLocals =
                            Dict.map (\_ -> delayUse) newFreeLocals
                    in
                    ReportingResult.ROk (Utils.mapUnionWith identity compare combineUses freeLocals delayedLocals) ws ( value, idState )

                ReportingResult.RErr () ws es ->
                    ReportingResult.RErr freeLocals ws es
        )


{-| Like verifyBindings but handles a result containing ( expr, IdState ).

The info type parameter allows this to be used in different contexts:

  - With info = () when wrapped with directUsageWithIds/delayedUsageWithIds
  - With info = FreeLocals when used directly in addDefNodesWithIds

-}
verifyBindingsWithIds :
    W.Context
    -> Pattern.Bindings
    -> EResult FreeLocals (List W.Warning) ( expr, IdState )
    -> EResult info (List W.Warning) ( ( expr, IdState ), FreeLocals )
verifyBindingsWithIds context andThenings (ReportingResult.RResult k) =
    ReportingResult.RResult <|
        \info warnings ->
            case k Dict.empty warnings of
                ReportingResult.RErr _ warnings1 errors ->
                    ReportingResult.RErr info warnings1 errors

                ReportingResult.ROk freeLocals warnings1 ( value, idState ) ->
                    let
                        outerFreeLocals : Dict String Name Uses
                        outerFreeLocals =
                            Dict.diff freeLocals andThenings

                        warnings2 : List W.Warning
                        warnings2 =
                            if Dict.size andThenings + Dict.size outerFreeLocals == Dict.size freeLocals then
                                warnings1

                            else
                                Dict.diff andThenings freeLocals |> Dict.foldl compare (addUnusedWarning context) warnings1
                    in
                    ReportingResult.ROk info warnings2 ( ( value, idState ), outerFreeLocals )



-- ====== FIND VARIABLE ======


findVar : A.Region -> Env.Env -> Name -> EResult FreeLocals w Can.Expr_
findVar region env name =
    case Dict.get identity name env.vars of
        Just var ->
            case var of
                Env.Local _ ->
                    logVar name (Can.VarLocal name)

                Env.TopLevel _ ->
                    logVar name (Can.VarTopLevel env.home name)

                Env.Foreign home annotation ->
                    ReportingResult.ok
                        (if home == ModuleName.debug then
                            Can.VarDebug env.home name annotation

                         else
                            Can.VarForeign home name annotation
                        )

                Env.Foreigns h hs ->
                    ReportingResult.throw (Error.AmbiguousVar region Nothing name h hs)

        Nothing ->
            ReportingResult.throw (Error.NotFoundVar region Nothing name (toPossibleNames env.vars env.q_vars))


findVarQual : A.Region -> Env.Env -> Name -> Name -> EResult FreeLocals w Can.Expr_
findVarQual region env prefix name =
    case Dict.get identity prefix env.q_vars of
        Just qualified ->
            case Dict.get identity name qualified of
                Just (Env.Specific home annotation) ->
                    ReportingResult.ok <|
                        if home == ModuleName.debug then
                            Can.VarDebug env.home name annotation

                        else
                            Can.VarForeign home name annotation

                Just (Env.Ambiguous h hs) ->
                    ReportingResult.throw (Error.AmbiguousVar region (Just prefix) name h hs)

                Nothing ->
                    ReportingResult.throw (Error.NotFoundVar region (Just prefix) name (toPossibleNames env.vars env.q_vars))

        Nothing ->
            let
                (IO.Canonical pkg _) =
                    env.home
            in
            if Name.isKernel prefix && Pkg.isKernel pkg then
                Can.VarKernel (Name.getKernel prefix) name |> ReportingResult.ok

            else
                ReportingResult.throw (Error.NotFoundVar region (Just prefix) name (toPossibleNames env.vars env.q_vars))


toPossibleNames : Dict String Name Env.Var -> Env.Qualified Can.Annotation -> Error.PossibleNames
toPossibleNames exposed qualified =
    Error.PossibleNames (Utils.keysSet identity compare exposed) (Dict.map (\_ -> Utils.keysSet identity compare) qualified)



-- ====== FIND CTOR ======


toVarCtor : Name -> Env.Ctor -> Can.Expr_
toVarCtor name ctor =
    case ctor of
        Env.Ctor home typeName (Can.Union unionData) index args ->
            let
                freeVars : Dict String Name ()
                freeVars =
                    Dict.fromList identity (List.map (\v -> ( v, () )) unionData.vars)

                result : Can.Type
                result =
                    Can.TType home typeName (List.map Can.TVar unionData.vars)

                tipe : Can.Type
                tipe =
                    List.foldr Can.TLambda result args
            in
            Can.VarCtor unionData.opts home name index (Can.Forall freeVars tipe)

        Env.RecordCtor home vars tipe ->
            let
                freeVars : Dict String Name ()
                freeVars =
                    Dict.fromList identity (List.map (\v -> ( v, () )) vars)
            in
            Can.VarCtor Can.Normal home name Index.first (Can.Forall freeVars tipe)
