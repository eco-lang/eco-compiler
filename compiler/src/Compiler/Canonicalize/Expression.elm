module Compiler.Canonicalize.Expression exposing
    ( EResult, FreeLocals, Uses(..), IdState
    , canonicalizeWithIds, gatherTypedArgsWithIds
    , verifyBindingsWithIds
    , tooManyParams
    )

{-| Turns the parsed form of an expression into its canonical form, in which
every name is resolved to what it refers to, every operator chain is grouped by
precedence, every `let` is split into the groups of bindings that depend on one
another, and every node carries an id.

The walk also records each expression's _free locals_: the local and top-level
value names it mentions (not constructors or operators), each with how often it
is used. References to imported, kernel and `Debug` values are not recorded. A
use is either _direct_, evaluated when the enclosing definition is evaluated,
or _delayed_, inside a lambda or inside the body of a `let` definition that has
parameters, and so evaluated only when that function is called. Free locals
are what an unused-variable warning is decided from, what the dependencies
between `let` bindings are read from, and, through the split into direct and
delayed uses, what tells a recursive value that can never be computed from a
recursive function. They travel in the info slot of the `EResult`. An
expression that binds names (a lambda, a case branch, a `let`, a definition's
parameters) runs its body from an empty map, warns about the bound names its
body never uses, removes them, and adds what is left to the enclosing map.

Name resolution follows `env`. A reference to a value whose home is `Debug`
becomes `VarDebug`, carrying the home of the module being canonicalized. A
qualified reference whose qualifier is no import but the name of a kernel
module (`Elm.Kernel.X` or `Eco.Kernel.X`) becomes `VarKernel` when the module
being canonicalized belongs to a kernel package (`Pkg.isKernel`), without any
check that the name exists; anywhere else it is `NotFoundVar`.

The parser leaves an operator chain such as `a + b * c` flat. Each operator is
looked up for its precedence and associativity and the chain is regrouped:
higher precedence binds tighter, and two operators of equal precedence group to
the left when both are left-associative and to the right when both are
right-associative. Any other pair of equal precedence is an `Error.Binop`.

The names one `let` binds must be distinct. Each binding becomes a node of a
dependency graph, keyed by its name and depending on its free locals. A
destructuring such as `( a, b ) = e` binds several names, so its node is keyed
by `Name.fromManyNames` of them, and each name it binds gets a stand-in node, an
_edge_, that depends on that key. The strongly connected components of the
graph, dependencies first, become nested `Let`, `LetDestruct` and `LetRec`
nodes with the first outermost. A recursive group is accepted only when every
member is a definition with parameters; a member without parameters, or a
destructuring, makes it a `RecursiveLet` error.

Each node takes its id from the `IdState` threaded through the walk, and not
always in pre-order. Most nodes take theirs before their children. An operator
node takes its id when its chain is regrouped, after every operand, and `Let`,
`LetDestruct` and `LetRec` take theirs after the definitions and the body,
innermost first. Parentheses produce no node.

Some expressions exceed what Eco's heap can represent (see
`Compiler.Data.HeapLimits`) and are `TooLarge` errors: a record with more than
`maxRecordFields` fields, a function or lambda with more than `maxStageArity`
parameters, and a closure whose parameters and captured locals together exceed
`maxStageArity`. A tuple of more than three elements is a
`TupleLargerThanThree` error.


# Results and Tracking

@docs EResult, FreeLocals, Uses, IdState


# Canonicalization

@docs canonicalizeWithIds, gatherTypedArgsWithIds


# Validation

@docs verifyBindingsWithIds
@docs tooManyParams

-}

import Basics.Extra exposing (flip)
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.Utils.Binop as Binop
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Environment as Env
import Compiler.Canonicalize.Environment.Dups as Dups
import Compiler.Canonicalize.Ids as Ids
import Compiler.Canonicalize.Pattern as Pattern
import Compiler.Canonicalize.Type as Type
import Compiler.Data.HeapLimits as HeapLimits
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Graph as Graph
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Compiler.Reporting.Warning as W
import Data.Map
import Data.Set as EverySet
import Dict exposing (Dict)
import Prelude
import Utils.Main as Utils



-- ====== RESULTS ======


{-| A reporting result whose errors are canonicalization errors.

While expressions are canonicalized, the info slot `i` holds the `FreeLocals`
gathered so far. This is a name for `ReportingResult.RResult`, not a new type.

-}
type alias EResult i w a =
    ReportingResult.RResult i w Error.Error a


{-| The free locals of an expression: each local or top-level value name it
mentions, with its `Uses`; constructors and operators are not recorded. A name
that is not used is absent rather than mapped to zero uses.
-}
type alias FreeLocals =
    Dict Name.Name Uses


{-| How many times a name is used, counted separately as direct and delayed
uses in the sense of the module docstring.

When an expression is wrapped in a lambda, or becomes the body of a `let`
definition with parameters, all its uses become delayed, so a use counts as
direct only when no function stands between it and the enclosing definition.

-}
type Uses
    = Uses
        { direct : Int
        , delayed : Int
        }


{-| The counter that hands out node ids, `Compiler.Canonicalize.Ids.IdState`
under this module's name.
-}
type alias IdState =
    Ids.IdState


{-| Returns `node` at `region` with the next id from `state`, and the state
after it.
-}
makeExpr : A.Region -> IdState -> Can.Expr_ -> ( Can.Expr, IdState )
makeExpr region state node =
    let
        ( id, newState ) =
            Ids.allocId state
    in
    ( A.At region { id = id, node = node }, newState )



-- ====== CANONICALIZE ======


{-| Canonicalizes an expression in `env`, giving its nodes ids from `state`
onwards, and returns it with the state after the last id it used. Its free
locals are added to the result's info.
-}
canonicalizeWithIds : Env.Env -> IdState -> Src.Expr -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
canonicalizeWithIds env state (A.At region expression) =
    canonicalizeNode env state region expression


{-| Canonicalizes one source node found at `region`, as `canonicalizeWithIds`
does.
-}
canonicalizeNode : Env.Env -> IdState -> A.Region -> Src.Expr_ -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
canonicalizeNode env state0 region expression =
    let
        wrapNode : Can.Expr_ -> ( Can.Expr, IdState )
        wrapNode node =
            makeExpr region state0 node

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
            traverseExprsWithIds env stateAfterList (List.map Tuple.second exprs)
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
            canonicalizeWithIds env stateAfterNegate expr
                |> ReportingResult.map
                    (\( cexpr, finalState ) ->
                        ( A.At region { id = negateId, node = Can.Negate cexpr }, finalState )
                    )

        Src.Binops ops final ->
            canonicalizeBinopsWithIds region env state0 (List.map (Tuple.mapSecond Src.c2Value) ops) final

        Src.Lambda ( _, srcArgs ) ( _, body ) ->
            let
                ( lambdaId, stateAfterLambda ) =
                    Ids.allocId state0
            in
            case tooManyParams region Error.TooManyLambdaParams srcArgs of
                Just err ->
                    ReportingResult.throw err

                Nothing ->
                    delayedUsageWithIds <|
                        (Pattern.verifyWithIds Error.DPLambdaArgs
                            (Pattern.traverseWithIds env stateAfterLambda (List.map Src.c1Value srcArgs))
                            |> ReportingResult.andThen
                                (\( args, andThenings, stateAfterPatterns ) ->
                                    Env.addLocals andThenings env
                                        |> ReportingResult.andThen
                                            (\newEnv ->
                                                verifyBindingsWithIds W.Pattern andThenings (canonicalizeWithIds newEnv stateAfterPatterns body)
                                                    |> ReportingResult.andThen
                                                        (\( ( cbody, finalState ), freeLocals ) ->
                                                            let
                                                                lambdaExpr : Can.Expr
                                                                lambdaExpr =
                                                                    A.At region { id = lambdaId, node = Can.Lambda args cbody }
                                                            in
                                                            checkClosureSlots env
                                                                region
                                                                Nothing
                                                                srcArgs
                                                                freeLocals
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
            canonicalizeWithIds env stateAfterCall func
                |> ReportingResult.andThen
                    (\( cfunc, stateAfterFunc ) ->
                        traverseExprsWithIds env stateAfterFunc (List.map Src.c1Value args)
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
            traverseIfBranchesWithIds
                env
                stateAfterIf
                (List.map (Src.c1Value >> Tuple.mapBoth Src.c2Value Src.c2Value) (firstBranch :: branches))
                |> ReportingResult.andThen
                    (\( cBranches, stateAfterBranches ) ->
                        canonicalizeWithIds env stateAfterBranches (Src.c1Value finally)
                            |> ReportingResult.map
                                (\( cfinally, finalState ) ->
                                    ( A.At region { id = ifId, node = Can.If cBranches cfinally }, finalState )
                                )
                    )

        Src.Let defs _ expr ->
            canonicalizeLetWithIds region env state0 (List.map Src.c2Value defs) expr

        Src.Case expr branches ->
            let
                ( caseId, stateAfterCase ) =
                    Ids.allocId state0
            in
            canonicalizeWithIds env stateAfterCase (Src.c2Value expr)
                |> ReportingResult.andThen
                    (\( cexpr, stateAfterScrutinee ) ->
                        traverseCaseBranchesWithIds env stateAfterScrutinee (List.map (Tuple.mapBoth Src.c2Value Src.c1Value) branches)
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
            canonicalizeWithIds env stateAfterAccess record
                |> ReportingResult.map
                    (\( crecord, finalState ) ->
                        ( A.At region { id = accessId, node = Can.Access crecord field }, finalState )
                    )

        Src.Update ( _, name ) ( _, fields ) ->
            let
                ( updateId, stateAfterUpdate ) =
                    Ids.allocId state0
            in
            canonicalizeWithIds env stateAfterUpdate name
                |> ReportingResult.andThen
                    (\( cname, stateAfterName ) ->
                        Dups.checkLocatedFields (List.map (Src.c2EolValue >> Tuple.mapBoth Src.c1Value Src.c1Value) fields)
                            |> ReportingResult.andThen
                                (\fieldDict ->
                                    traverseUpdateFieldsWithIds env stateAfterName fieldDict
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
            if List.length fields > HeapLimits.maxRecordFields then
                ReportingResult.throw (Error.TooLarge region (Error.TooManyRecordFields Nothing) (List.length fields) HeapLimits.maxRecordFields)

            else
                Dups.checkLocatedFields (List.map (Src.c2EolValue >> Tuple.mapBoth Src.c1Value Src.c1Value) fields)
                    |> ReportingResult.andThen
                        (\fieldDict ->
                            traverseDictWithIds env stateAfterRecord fieldDict
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
            canonicalizeWithIds env stateAfterTuple a
                |> ReportingResult.andThen
                    (\( ca, stateAfterA ) ->
                        canonicalizeWithIds env stateAfterA b
                            |> ReportingResult.andThen
                                (\( cb, stateAfterB ) ->
                                    canonicalizeTupleExtrasWithIds region env stateAfterB (List.map Src.c2Value cs)
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
            canonicalizeWithIds env state0 expr


{-| Canonicalizes the elements of a tuple after its second: none, or a third
alone. Any more is a `TupleLargerThanThree` error at `region`, the tuple's.
-}
canonicalizeTupleExtrasWithIds : A.Region -> Env.Env -> IdState -> List Src.Expr -> EResult FreeLocals (List W.Warning) ( List Can.Expr, IdState )
canonicalizeTupleExtrasWithIds region env state extras =
    case extras of
        [] ->
            ReportingResult.ok ( [], state )

        [ three ] ->
            canonicalizeWithIds env state three
                |> ReportingResult.map (\( e, s ) -> ( [ e ], s ))

        _ ->
            ReportingResult.throw (Error.TupleLargerThanThree region)


{-| Canonicalizes each expression in turn, in order, threading the id state
from one to the next. It runs as a `ReportingResult.loop`, so a long list does
not deepen the stack.
-}
traverseExprsWithIds : Env.Env -> IdState -> List Src.Expr -> EResult FreeLocals (List W.Warning) ( List Can.Expr, IdState )
traverseExprsWithIds env state0 exprs =
    ReportingResult.loop
        (\( remaining, acc, st ) ->
            case remaining of
                [] ->
                    ReportingResult.ok (ReportingResult.Done ( List.reverse acc, st ))

                expr :: rest ->
                    canonicalizeWithIds env st expr
                        |> ReportingResult.map
                            (\( cexpr, stateAfter ) ->
                                ReportingResult.Loop ( rest, cexpr :: acc, stateAfter )
                            )
        )
        ( exprs, [], state0 )


{-| Canonicalizes the field values of a record, in the dict's key order,
threading the id state from one to the next.
-}
traverseDictWithIds :
    Env.Env
    -> IdState
    -> Data.Map.Dict String (A.Located Name) Src.Expr
    -> EResult FreeLocals (List W.Warning) ( Data.Map.Dict String (A.Located Name) Can.Expr, IdState )
traverseDictWithIds env state dict =
    let
        entries : List ( A.Located Name, Src.Expr )
        entries =
            Data.Map.toList dict
    in
    traverseDictEntriesWithIds env state entries []
        |> ReportingResult.map
            (\( resultEntries, finalState ) ->
                ( Data.Map.fromList A.toValue resultEntries, finalState )
            )


{-| Canonicalizes the value of each entry in turn and returns the entries,
after those already in `acc0`, in order. `acc0` is held in reverse order.
-}
traverseDictEntriesWithIds :
    Env.Env
    -> IdState
    -> List ( A.Located Name, Src.Expr )
    -> List ( A.Located Name, Can.Expr )
    -> EResult FreeLocals (List W.Warning) ( List ( A.Located Name, Can.Expr ), IdState )
traverseDictEntriesWithIds env state0 entries acc0 =
    ReportingResult.loop
        (\( remaining, acc, st ) ->
            case remaining of
                [] ->
                    ReportingResult.ok (ReportingResult.Done ( List.reverse acc, st ))

                ( key, srcExpr ) :: rest ->
                    canonicalizeWithIds env st srcExpr
                        |> ReportingResult.map
                            (\( canExpr, stateAfter ) ->
                                ReportingResult.Loop ( rest, ( key, canExpr ) :: acc, stateAfter )
                            )
        )
        ( entries, acc0, state0 )


{-| Canonicalizes the new field values of a record update, in the dict's key
order, threading the id state from one to the next. Each becomes a
`FieldUpdate` carrying the region of the field's name.
-}
traverseUpdateFieldsWithIds :
    Env.Env
    -> IdState
    -> Data.Map.Dict String (A.Located Name) Src.Expr
    -> EResult FreeLocals (List W.Warning) ( Data.Map.Dict String (A.Located Name) Can.FieldUpdate, IdState )
traverseUpdateFieldsWithIds env state dict =
    let
        entries : List ( A.Located Name, Src.Expr )
        entries =
            Data.Map.toList dict
    in
    traverseUpdateEntriesWithIds env state entries []
        |> ReportingResult.map
            (\( resultEntries, finalState ) ->
                ( Data.Map.fromList A.toValue resultEntries, finalState )
            )


{-| Does what `traverseDictEntriesWithIds` does for the fields of a record
update, wrapping each value in a `FieldUpdate` at the region of its field name.
-}
traverseUpdateEntriesWithIds :
    Env.Env
    -> IdState
    -> List ( A.Located Name, Src.Expr )
    -> List ( A.Located Name, Can.FieldUpdate )
    -> EResult FreeLocals (List W.Warning) ( List ( A.Located Name, Can.FieldUpdate ), IdState )
traverseUpdateEntriesWithIds env state0 entries acc0 =
    ReportingResult.loop
        (\( remaining, acc, st ) ->
            case remaining of
                [] ->
                    ReportingResult.ok (ReportingResult.Done ( List.reverse acc, st ))

                ( (A.At fieldRegion _) as key, srcExpr ) :: rest ->
                    canonicalizeWithIds env st srcExpr
                        |> ReportingResult.map
                            (\( canExpr, stateAfter ) ->
                                ReportingResult.Loop ( rest, ( key, Can.FieldUpdate fieldRegion canExpr ) :: acc, stateAfter )
                            )
        )
        ( entries, acc0, state0 )



-- ====== CANONICALIZE IF BRANCH ======


{-| Canonicalizes one condition and the branch it guards, condition first.
-}
canonicalizeIfBranchWithIds : Env.Env -> IdState -> ( Src.Expr, Src.Expr ) -> EResult FreeLocals (List W.Warning) ( ( Can.Expr, Can.Expr ), IdState )
canonicalizeIfBranchWithIds env state ( condition, branch ) =
    canonicalizeWithIds env state condition
        |> ReportingResult.andThen
            (\( ccond, stateAfterCond ) ->
                canonicalizeWithIds env stateAfterCond branch
                    |> ReportingResult.map
                        (\( cbranch, finalState ) ->
                            ( ( ccond, cbranch ), finalState )
                        )
            )


{-| Canonicalizes each condition and branch of an `if` in order, threading the
id state from one to the next. The final `else` branch is not among them.
-}
traverseIfBranchesWithIds : Env.Env -> IdState -> List ( Src.Expr, Src.Expr ) -> EResult FreeLocals (List W.Warning) ( List ( Can.Expr, Can.Expr ), IdState )
traverseIfBranchesWithIds env state0 branches =
    ReportingResult.loop
        (\( remaining, acc, st ) ->
            case remaining of
                [] ->
                    ReportingResult.ok (ReportingResult.Done ( List.reverse acc, st ))

                branch :: rest ->
                    canonicalizeIfBranchWithIds env st branch
                        |> ReportingResult.map
                            (\( cbranch, stateAfter ) ->
                                ReportingResult.Loop ( rest, cbranch :: acc, stateAfter )
                            )
        )
        ( branches, [], state0 )



-- ====== CANONICALIZE CASE BRANCH ======


{-| Canonicalizes one case branch: its pattern, then its body with the
pattern's names in scope.

A name bound twice in the pattern is a `DuplicatePattern` error, and a bound
name the body never uses gets an unused-variable warning. The body's other free
locals are added to the enclosing map with the kind of use they had there.

-}
canonicalizeCaseBranchWithIds : Env.Env -> IdState -> ( Src.Pattern, Src.Expr ) -> EResult FreeLocals (List W.Warning) ( Can.CaseBranch, IdState )
canonicalizeCaseBranchWithIds env state ( pattern, expr ) =
    directUsageWithIds
        (Pattern.verifyWithIds Error.DPCaseBranch
            (Pattern.canonicalizeWithIds env state pattern)
            |> ReportingResult.andThen
                (\( cpattern, andThenings, stateAfterPattern ) ->
                    Env.addLocals andThenings env
                        |> ReportingResult.andThen
                            (\newEnv ->
                                verifyBindingsWithIds W.Pattern andThenings (canonicalizeWithIds newEnv stateAfterPattern expr)
                                    |> ReportingResult.map
                                        (\( ( cexpr, finalState ), freeLocals ) ->
                                            ( ( Can.CaseBranch cpattern cexpr, finalState ), freeLocals )
                                        )
                            )
                )
        )


{-| Canonicalizes each case branch in order, threading the id state from one to
the next.
-}
traverseCaseBranchesWithIds :
    Env.Env
    -> IdState
    -> List ( Src.Pattern, Src.Expr )
    -> EResult FreeLocals (List W.Warning) ( List Can.CaseBranch, IdState )
traverseCaseBranchesWithIds env state0 branches =
    ReportingResult.loop
        (\( remaining, acc, st ) ->
            case remaining of
                [] ->
                    ReportingResult.ok (ReportingResult.Done ( List.reverse acc, st ))

                branch :: rest ->
                    canonicalizeCaseBranchWithIds env st branch
                        |> ReportingResult.map
                            (\( canBranch, stateAfter ) ->
                                ReportingResult.Loop ( rest, canBranch :: acc, stateAfter )
                            )
        )
        ( branches, [], state0 )



-- ====== CANONICALIZE BINOPS ======


{-| Canonicalizes the operator chain `ops` followed by `final` and groups it
by precedence and associativity, as the module docstring describes. Each operand
is canonicalized whole, left to right, before any operator node is made, so an
operand that is itself a parenthesised chain stays one unit. An operator that is
not in scope fails at its own region; two operators that cannot be grouped fail
with `Error.Binop` at `overallRegion`, the region of the whole chain.
-}
canonicalizeBinopsWithIds :
    A.Region
    -> Env.Env
    -> IdState
    -> List ( Src.Expr, A.Located Name.Name )
    -> Src.Expr
    -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
canonicalizeBinopsWithIds overallRegion env state ops final =
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
                    canonicalizeWithIds env st expr
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
                canonicalizeWithIds env stateAfterOps final
                    |> ReportingResult.andThen
                        (\( cfinal, stateAfterFinal ) ->
                            case cOps of
                                [] ->
                                    ReportingResult.ok ( cfinal, stateAfterFinal )

                                _ ->
                                    runBinopStepperWithIds overallRegion (MoreWithIds stateAfterFinal cOps cfinal)
                        )
            )


{-| The state of regrouping an operator chain.

`DoneWithIds` is the finished expression and the id state after it.

`MoreWithIds` is a chain still to be regrouped: its id state, the operands
paired with the operator that follows each, and the last operand. The first
operand may already be an operator node built from part of the original chain.

`ErrorWithIds` holds two operators of equal precedence that cannot be grouped,
because their associativities differ or neither associates.

-}
type StepWithIds
    = DoneWithIds Can.Expr IdState
    | MoreWithIds IdState (List ( Can.Expr, Env.Binop )) Can.Expr
    | ErrorWithIds Env.Binop Env.Binop


{-| An operator node waiting for its right operand: given the id state and that
operand, it returns the node and the state after its id.

This is a name for a function type, not a new type.

-}
type alias MakeBinopFn =
    IdState -> Can.Expr -> ( Can.Expr, IdState )


{-| Regroups the chain in `step` until it is finished, and returns the
expression, or the `Error.Binop` for the first pair that cannot be grouped, at
`overallRegion`.
-}
runBinopStepperWithIds : A.Region -> StepWithIds -> EResult FreeLocals w ( Can.Expr, IdState )
runBinopStepperWithIds overallRegion step =
    case step of
        DoneWithIds expr finalState ->
            ReportingResult.ok ( expr, finalState )

        MoreWithIds innerState [] expr ->
            ReportingResult.ok ( expr, innerState )

        MoreWithIds innerState (( expr, op ) :: rest) final ->
            toBinopStepWithIds innerState (toBinopWithIds op expr) op rest final
                |> runBinopStepperWithIds overallRegion

        ErrorWithIds (Env.Binop binopData1) (Env.Binop binopData2) ->
            ReportingResult.throw (Error.Binop overallRegion binopData1.op binopData2.op)


{-| Regroups a chain that starts with `makeBinop`, the operator `rootOp` already
applied to its left operand, followed by `middle` and `final`.

An operator of higher precedence than `rootOp` is grouped into its right
operand first. One of equal precedence groups with it to the left or to the
right by their associativity. The first operator of lower precedence ends it:
the result is `MoreWithIds`, with the node built so far as the first operand of
the rest of the chain. Reaching the end of the chain gives `DoneWithIds`.

-}
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
                let
                    ( combined, newState ) =
                        makeBinop currentState expr
                in
                MoreWithIds newState (( combined, op ) :: rest) final

            else if precedence > rootPrecedence then
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
                case ( rootAssociativity, associativity ) of
                    ( Binop.Left, Binop.Left ) ->
                        let
                            ( combined, newState ) =
                                makeBinop currentState expr
                        in
                        toBinopStepWithIds newState (toBinopWithIds op combined) op rest final

                    ( Binop.Right, Binop.Right ) ->
                        -- Not an inline lambda: see composeBinopStep.
                        toBinopStepWithIds currentState (composeBinopStep makeBinop op expr) op rest final

                    _ ->
                        ErrorWithIds rootOp op


{-| Returns the operator node for `left`, the given operator and a right operand
still to come. The node spans from the start of `left` to the end of the right
operand, and takes its id only when the right operand is supplied.
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


{-| Returns an operator node waiting for its right operand that groups to the
right: it first makes `expr op right`, then gives that to `outerMakeBinop` as
its right operand.

It is a separate function, not a lambda written inside `toBinopStepWithIds`,
because the JavaScript generated for that tail-recursive function turns it into
a loop that reassigns its parameters. A lambda written in the loop captures the
variable rather than its current value, so every such lambda would call the
last one and recurse forever on a right-associative chain. As a parameter here,
`outerMakeBinop` is fixed when the closure is made.

-}
composeBinopStep : MakeBinopFn -> Env.Binop -> Can.Expr -> MakeBinopFn
composeBinopStep outerMakeBinop op expr =
    \state right ->
        let
            ( inner, state1 ) =
                toBinopWithIds op expr state right
        in
        outerMakeBinop state1 inner


{-| Canonicalizes a `let` found at `letRegion` and returns the nested `Let`,
`LetDestruct` and `LetRec` nodes it becomes, each at `letRegion`.

The definitions are canonicalized first, in order, then the body, all with
every name the `let` binds in scope. A name bound twice is a `DuplicatePattern`
error, and a bound name nothing uses gets an unused-variable warning. Free
locals of the definitions and the body, apart from the bound names, are added
to the enclosing map with the kind of use they had there; every use inside a
definition with parameters is delayed.

-}
canonicalizeLetWithIds : A.Region -> Env.Env -> IdState -> List (A.Located Src.Def) -> Src.Expr -> EResult FreeLocals (List W.Warning) ( Can.Expr, IdState )
canonicalizeLetWithIds letRegion env state defs body =
    directUsageWithIds <|
        (Dups.detect (Error.DuplicatePattern Error.DPLetBinding)
            (List.foldl addBindings Dups.none defs)
            |> ReportingResult.andThen
                (\andThenings ->
                    Env.addLocals andThenings env
                        |> ReportingResult.andThen
                            (\newEnv ->
                                verifyBindingsWithIds W.Def andThenings <|
                                    (foldDefNodesWithIds newEnv state [] defs
                                        |> ReportingResult.andThen
                                            (\( nodes, stateAfterDefs ) ->
                                                canonicalizeWithIds newEnv stateAfterDefs body
                                                    |> ReportingResult.andThen
                                                        (\( cbody, stateAfterBody ) ->
                                                            detectCyclesWithIds letRegion stateAfterBody (Graph.stronglyConnComp nodes) cbody
                                                        )
                                            )
                                    )
                            )
                )
        )


{-| Canonicalizes each `let` definition in order, threading the id state, and
adds its graph nodes to `acc0`.
-}
foldDefNodesWithIds :
    Env.Env
    -> IdState
    -> List Node
    -> List (A.Located Src.Def)
    -> EResult FreeLocals (List W.Warning) ( List Node, IdState )
foldDefNodesWithIds env state0 acc0 defs =
    ReportingResult.loop
        (\( remaining, acc, st ) ->
            case remaining of
                [] ->
                    ReportingResult.ok (ReportingResult.Done ( acc, st ))

                def :: rest ->
                    addDefNodesWithIds env st acc def
                        |> ReportingResult.map
                            (\( newAcc, newState ) ->
                                ReportingResult.Loop ( rest, newAcc, newState )
                            )
        )
        ( defs, acc0, state0 )


{-| Adds the names a `let` definition binds, each with its region, to the
tracker of duplicates: the defined name, or every name a destructuring pattern
binds.
-}
addBindings : A.Located Src.Def -> Dups.Tracker A.Region -> Dups.Tracker A.Region
addBindings (A.At _ def) andThenings =
    case def of
        Src.Define (A.At region name) _ _ _ ->
            Dups.insert name region region andThenings

        Src.Destruct pattern _ ->
            addBindingsHelp andThenings pattern


{-| Adds every name `pattern` binds, each with its region, to the tracker of
duplicates.
-}
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


{-| A node of the `let` dependency graph: the binding, the key that names it,
and the keys of the names it depends on, which include names that are not
bindings of this `let`.
-}
type alias Node =
    ( Binding, Name.Name, List Name.Name )


{-| What a node of the `let` dependency graph stands for.

`Define` is a definition, with or without parameters.

`Destruct` is a destructuring: the pattern and the expression it matches.

`Edge` is the stand-in node for one name a destructuring binds, carrying that
name and its region. It produces no code; it lets a reference to the name reach
the destructuring that binds it.

-}
type Binding
    = Define Can.Def
    | Edge (A.Located Name.Name)
    | Destruct Can.Pattern Can.Expr


{-| Canonicalizes one `let` definition and adds its graph nodes to `nodes`.

A definition gives one `Define` node; one with more than
`HeapLimits.maxStageArity` parameters is a `TooLarge` error. A destructuring
gives a `Destruct` node, keyed by `Name.fromManyNames` of the names it binds,
and an `Edge` node for each of those names. Its pattern is checked for a name
bound twice, and the free locals of its expression are added to the enclosing
map as they are.

-}
addDefNodesWithIds : Env.Env -> IdState -> List Node -> A.Located Src.Def -> EResult FreeLocals (List W.Warning) ( List Node, IdState )
addDefNodesWithIds env state nodes (A.At _ def) =
    case def of
        Src.Define ((A.At nameRegion name) as aname) srcArgs ( _, body ) maybeType ->
            case tooManyParams nameRegion (Error.TooManyParams name) srcArgs of
                Just err ->
                    ReportingResult.throw err

                Nothing ->
                    addDefineNodesWithIds env state nodes aname srcArgs body maybeType

        Src.Destruct pattern ( _, body ) ->
            Pattern.verifyWithIds Error.DPDestruct
                (Pattern.canonicalizeWithIds env state pattern)
                |> ReportingResult.andThen
                    (\( cpattern, _, stateAfterPattern ) ->
                        ReportingResult.RResult
                            (\fs ws ->
                                case canonicalizeWithIds env stateAfterPattern body of
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
                                                        ( Destruct cpattern cbody, name, Dict.keys freeLocals )
                                                in
                                                ReportingResult.ROk
                                                    (Utils.dictUnionWith combineUses fs freeLocals)
                                                    warnings
                                                    ( List.foldl (addEdge [ name ]) (node :: nodes) names, stateAfterBody )

                                            ReportingResult.RErr freeLocals warnings errors ->
                                                ReportingResult.RErr (Utils.dictUnionWith combineUses freeLocals fs) warnings errors
                            )
                    )


{-| Canonicalizes a `let` definition whose parameter count is within
`HeapLimits.maxStageArity` and adds its `Define` node to `nodes`.

With an annotation the result is a `TypedDef` whose parameters are paired with
the annotation's argument types; without one it is a `Def`. A parameter name
the body never uses gets an unused-variable warning. The body's free locals,
less the parameters, are added to the enclosing map: as they are when there
are no parameters, all as delayed uses otherwise.

-}
addDefineNodesWithIds : Env.Env -> IdState -> List Node -> A.Located Name -> List (Src.C1 Src.Pattern) -> Src.Expr -> Maybe (Src.C1 (Src.C2 Src.Type)) -> EResult FreeLocals (List W.Warning) ( List Node, IdState )
addDefineNodesWithIds env state nodes ((A.At nameRegion name) as aname) srcArgs body maybeType =
    case maybeType of
        Nothing ->
            Pattern.verifyWithIds (Error.DPFuncArgs name)
                (Pattern.traverseWithIds env state (List.map Src.c1Value srcArgs))
                |> ReportingResult.andThen
                    (\( args, argBindings, stateAfterArgs ) ->
                        Env.addLocals argBindings env
                            |> ReportingResult.andThen
                                (\newEnv ->
                                    verifyBindingsWithIds W.Pattern argBindings (canonicalizeWithIds newEnv stateAfterArgs body)
                                        |> ReportingResult.andThen
                                            (\( ( cbody, stateAfterBody ), freeLocals ) ->
                                                let
                                                    cdef : Can.Def
                                                    cdef =
                                                        Can.Def aname args cbody

                                                    node : ( Binding, Name, List Name )
                                                    node =
                                                        ( Define cdef, name, Dict.keys freeLocals )
                                                in
                                                checkClosureSlots env nameRegion (Just name) srcArgs freeLocals ( node :: nodes, stateAfterBody )
                                                    |> ReportingResult.andThen (logLetLocalsWithIds args freeLocals)
                                            )
                                )
                    )

        Just ( _, ( _, tipe ) ) ->
            Type.toAnnotation env tipe
                |> ReportingResult.andThen
                    (\(Can.Forall freeVars ctipe) ->
                        -- Pattern.verify, not verifyWithIds: the id state is inside the value.
                        Pattern.verify (Error.DPFuncArgs name)
                            (gatherTypedArgsWithIds env name state (List.map Src.c1Value srcArgs) ctipe Index.first [])
                            |> ReportingResult.andThen
                                (\( ( ( args, resultType ), stateAfterArgs ), argBindings ) ->
                                    Env.addLocals argBindings env
                                        |> ReportingResult.andThen
                                            (\newEnv ->
                                                verifyBindingsWithIds W.Pattern argBindings (canonicalizeWithIds newEnv stateAfterArgs body)
                                                    |> ReportingResult.andThen
                                                        (\( ( cbody, stateAfterBody ), freeLocals ) ->
                                                            let
                                                                cdef : Can.Def
                                                                cdef =
                                                                    Can.TypedDef aname freeVars args cbody resultType

                                                                node : ( Binding, Name, List Name )
                                                                node =
                                                                    ( Define cdef, name, Dict.keys freeLocals )
                                                            in
                                                            checkClosureSlots env nameRegion (Just name) srcArgs freeLocals ( node :: nodes, stateAfterBody )
                                                                |> ReportingResult.andThen (logLetLocalsWithIds args freeLocals)
                                                        )
                                            )
                                )
                    )


{-| Returns the `TooLarge` error, at `region` and describing the function as
`what`, when the parameter list `srcArgs` is longer than
`HeapLimits.maxStageArity`, and `Nothing` when it is within the limit.
-}
tooManyParams : A.Region -> Error.TooLargeWhat -> List arg -> Maybe Error.Error
tooManyParams region what srcArgs =
    let
        n =
            List.length srcArgs
    in
    if n > HeapLimits.maxStageArity then
        Just (Error.TooLarge region what n HeapLimits.maxStageArity)

    else
        Nothing


{-| Returns `value` when a closure with the parameters `srcArgs` and the free
locals `freeLocals` (its own parameters already removed) fits within
`HeapLimits.maxStageArity` slots, and fails with
`TooLarge region (TooManyClosureSlots name)` otherwise.

Its slots are its parameters plus its captured variables, which are the free
locals that `env`, the scope around the closure, binds as `Env.Local`, so
top-level values do not count. A `let` function's own name is in scope as a
local, so it counts when the function refers to itself, which overcounts by one
at most. A definition with no parameters is not a closure and always passes.

-}
checkClosureSlots : Env.Env -> A.Region -> Maybe Name -> List arg -> FreeLocals -> a -> EResult i w a
checkClosureSlots env region name srcArgs freeLocals value =
    let
        nArgs =
            List.length srcArgs

        isCaptured k _ =
            case Dict.get k env.vars of
                Just (Env.Local _) ->
                    True

                _ ->
                    False

        slots =
            nArgs + Dict.size (Dict.filter isCaptured freeLocals)
    in
    if nArgs > 0 && slots > HeapLimits.maxStageArity then
        ReportingResult.throw (Error.TooLarge region (Error.TooManyClosureSlots name) slots HeapLimits.maxStageArity)

    else
        ReportingResult.ok value


{-| Returns `( value, idState )` unchanged, adding `letLocals`, the free locals
of a `let` definition's body, to the enclosing map: as they are when `args` is
empty, and all as delayed uses otherwise.
-}
logLetLocalsWithIds : List arg -> FreeLocals -> ( value, IdState ) -> EResult FreeLocals w ( value, IdState )
logLetLocalsWithIds args letLocals ( value, idState ) =
    ReportingResult.RResult
        (\freeLocals warnings ->
            ReportingResult.ROk
                (Utils.dictUnionWith
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


{-| Adds to `nodes` the `Edge` node for the name `aname`, depending on `edges`.
-}
addEdge : List Name.Name -> A.Located Name.Name -> List Node -> List Node
addEdge edges ((A.At _ name) as aname) nodes =
    ( Edge aname, name, edges ) :: nodes


{-| Returns every name the pattern binds, with its region, added to the front of
`names`.
-}
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


{-| Canonicalizes the parameter patterns `srcArgs` of the annotated definition
`name`, pairing each with the next argument type of `tipe`, and returns the
pairs after those already in `revTypedArgs` (held in reverse), the type left
once every parameter has taken its argument, and the id state.

Type aliases are seen through to find each arrow, so an annotation that
reaches a function type through an alias still supplies argument types. When
the type runs out of arrows before the parameters run out, the result is an
`AnnotationTooShort` error covering the parameters left over, with `index`
counting the parameters already paired. The names the patterns bind are
gathered in the info slot, for the caller to check for duplicates.

-}
gatherTypedArgsWithIds :
    Env.Env
    -> Name.Name
    -> IdState
    -> List Src.Pattern
    -> Can.Type Name
    -> Index.ZeroBased
    -> List ( Can.Pattern, Can.Type Name )
    -> EResult Pattern.DupsDict w ( ( List ( Can.Pattern, Can.Type Name ), Can.Type Name ), IdState )
gatherTypedArgsWithIds env name state srcArgs tipe index revTypedArgs =
    case srcArgs of
        [] ->
            ReportingResult.ok ( ( List.reverse revTypedArgs, tipe ), state )

        srcArg :: otherSrcArgs ->
            case Type.iteratedDealias tipe of
                Can.TLambda _ argType resultType ->
                    Pattern.canonicalizeWithIds env state srcArg
                        |> ReportingResult.andThen
                            (\( arg, stateAfterArg ) ->
                                gatherTypedArgsWithIds env name stateAfterArg otherSrcArgs resultType (Index.next index) (( arg, argType ) :: revTypedArgs)
                            )

                _ ->
                    let
                        ( A.At start _, A.At end _ ) =
                            ( Prelude.head srcArgs, Prelude.last srcArgs )
                    in
                    ReportingResult.throw (Error.AnnotationTooShort (A.mergeRegions start end) name index (List.length srcArgs))


{-| Returns the definitions of a recursive group of `let` bindings, in reverse
order in front of those already in `defs`, when every member is a definition
with parameters.

The first member without parameters, or the first `Edge`, makes the group a
`RecursiveLet` error naming that member and the other members.

-}
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
                    -- A cycle through a destructuring passes through one of its
                    -- Edge nodes, which reports it.
                    checkCycle otherBindings defs


{-| Returns the names of the bindings in `andThenings`, skipping destructurings,
followed by the names of `revDefs` in reverse.
-}
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


{-| Returns the name a definition defines.
-}
getDefName : Can.Def -> Name.Name
getDefName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


{-| Wraps `body` in one node per component of a `let` dependency graph, the
first component outermost, and gives each node its id after those inside it.

A definition becomes `Let`, a destructuring `LetDestruct`, and a recursive
group `LetRec` once `checkCycle` accepts it. An `Edge` alone produces no node.
Every node is at `letRegion`.

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


{-| Returns `value`, recording one direct use of `name` in the free locals.
-}
logVar : Name.Name -> a -> EResult FreeLocals w a
logVar name value =
    ReportingResult.RResult <|
        \freeLocals warnings ->
            ReportingResult.ROk (Utils.dictInsertWith combineUses name oneDirectUse freeLocals) warnings value


{-| A single direct use.
-}
oneDirectUse : Uses
oneDirectUse =
    Uses
        { direct = 1
        , delayed = 0
        }


{-| Returns the uses of both arguments added together, direct to direct and
delayed to delayed.
-}
combineUses : Uses -> Uses -> Uses
combineUses (Uses ab) (Uses xy) =
    Uses
        { direct = ab.direct + xy.direct
        , delayed = ab.delayed + xy.delayed
        }


{-| Returns the same total number of uses, all counted as delayed.
-}
delayUse : Uses -> Uses
delayUse (Uses { direct, delayed }) =
    Uses
        { direct = 0
        , delayed = direct + delayed
        }



-- ====== MANAGING BINDINGS ======


{-| Adds an unused-variable warning for `name`, bound at `region` in `context`,
to the front of `warnings`.
-}
addUnusedWarning : W.Context -> Name.Name -> A.Region -> List W.Warning -> List W.Warning
addUnusedWarning context name region warnings =
    W.UnusedVariable region context name :: warnings


{-| Runs a computation that reports its own free locals in its value, and adds
them to the enclosing map as they are. On failure, the enclosing map is kept
unchanged.
-}
directUsageWithIds : EResult () w ( ( expr, IdState ), FreeLocals ) -> EResult FreeLocals w ( expr, IdState )
directUsageWithIds (ReportingResult.RResult k) =
    ReportingResult.RResult
        (\freeLocals warnings ->
            case k () warnings of
                ReportingResult.ROk () ws ( ( value, idState ), newFreeLocals ) ->
                    ReportingResult.ROk (Utils.dictUnionWith combineUses freeLocals newFreeLocals) ws ( value, idState )

                ReportingResult.RErr () ws es ->
                    ReportingResult.RErr freeLocals ws es
        )


{-| Runs a computation that reports its own free locals in its value, and adds
them to the enclosing map as delayed uses, as a lambda's body does. On failure,
the enclosing map is kept unchanged.
-}
delayedUsageWithIds : EResult () w ( ( expr, IdState ), FreeLocals ) -> EResult FreeLocals w ( expr, IdState )
delayedUsageWithIds (ReportingResult.RResult k) =
    ReportingResult.RResult
        (\freeLocals warnings ->
            case k () warnings of
                ReportingResult.ROk () ws ( ( value, idState ), newFreeLocals ) ->
                    let
                        delayedLocals : Dict Name Uses
                        delayedLocals =
                            Dict.map (\_ -> delayUse) newFreeLocals
                    in
                    ReportingResult.ROk (Utils.dictUnionWith combineUses freeLocals delayedLocals) ws ( value, idState )

                ReportingResult.RErr () ws es ->
                    ReportingResult.RErr freeLocals ws es
        )


{-| Runs the canonicalization of a body in which the names
`andThenings` are bound, from an empty map of free locals, and returns its
value together with its free locals less those names.

Each bound name the body never uses gets an unused-variable warning in
`context`. The caller's info slot is passed through unchanged, so the returned
free locals reach the enclosing map only through what the caller does with
them. If the body fails, its errors and warnings are returned with the caller's
info and no unused-variable warnings.

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
                        outerFreeLocals : Dict Name Uses
                        outerFreeLocals =
                            Dict.diff freeLocals andThenings

                        warnings2 : List W.Warning
                        warnings2 =
                            if Dict.size andThenings + Dict.size outerFreeLocals == Dict.size freeLocals then
                                warnings1

                            else
                                Dict.diff andThenings freeLocals |> Dict.foldl (addUnusedWarning context) warnings1
                    in
                    ReportingResult.ROk info warnings2 ( ( value, idState ), outerFreeLocals )



-- ====== FIND VARIABLE ======


{-| Resolves an unqualified lowercase name found at `region`.

A local or top-level name is recorded as one direct use. A name imported from
`Debug` becomes `VarDebug` carrying the home of the module being
canonicalized, and any other imported name `VarForeign`. A name more than one
import provides is an `AmbiguousVar` error, and an unknown one `NotFoundVar`.

-}
findVar : A.Region -> Env.Env -> Name -> EResult FreeLocals w Can.Expr_
findVar region env name =
    case Dict.get name env.vars of
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


{-| Resolves the lowercase name `name` qualified by `prefix`, found at `region`.

When `prefix` is an import, the name resolves as an imported name does in
`findVar`. When it is not, and it is the name of a kernel module (`Elm.Kernel.X`
or `Eco.Kernel.X`) while the module being canonicalized belongs to a kernel
package, the result is `VarKernel` for the name, whatever it is. Otherwise the
name is not found. A qualified name is never recorded as a use.

-}
findVarQual : A.Region -> Env.Env -> Name -> Name -> EResult FreeLocals w Can.Expr_
findVarQual region env prefix name =
    case Dict.get prefix env.q_vars of
        Just qualified ->
            case Dict.get name qualified of
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
                (ModuleName.Canonical pkg _) =
                    env.home
            in
            if Name.isKernel prefix && Pkg.isKernel pkg then
                let
                    ( kernelPrefix, kernelHome ) =
                        Name.getKernel prefix
                in
                Can.VarKernel kernelPrefix kernelHome name |> ReportingResult.ok

            else
                ReportingResult.throw (Error.NotFoundVar region (Just prefix) name (toPossibleNames env.vars env.q_vars))


{-| Returns the names in scope, unqualified and by qualifier, that a
`NotFoundVar` error offers as suggestions.
-}
toPossibleNames : Dict Name Env.Var -> Env.Qualified (Can.Annotation Name) -> Error.PossibleNames
toPossibleNames exposed qualified =
    Error.PossibleNames (EverySet.fromList identity (Dict.keys exposed)) (Dict.map (\_ -> Dict.keys >> EverySet.fromList identity) qualified)



-- ====== FIND CTOR ======


{-| Returns the reference to the constructor `name`, with its type as a
function from its arguments to the type it builds, generalised over the type's
variables.

A record alias's constructor is given the type the environment holds for it,
and is treated as a `Normal` constructor at index zero.

-}
toVarCtor : Name -> Env.Ctor -> Can.Expr_
toVarCtor name ctor =
    case ctor of
        Env.Ctor home typeName (Can.Union unionData) index args ->
            let
                freeVars : Dict Name ()
                freeVars =
                    Dict.fromList (List.map (\v -> ( v, () )) unionData.vars)

                result : Can.Type Name
                result =
                    Can.TType home typeName (List.map Can.TVar unionData.vars)

                tipe : Can.Type Name
                tipe =
                    List.foldr Can.tLambda result args
            in
            Can.VarCtor unionData.opts home name index (Can.Forall freeVars tipe)

        Env.RecordCtor home vars tipe ->
            let
                freeVars : Dict Name ()
                freeVars =
                    Dict.fromList (List.map (\v -> ( v, () )) vars)
            in
            Can.VarCtor Can.Normal home name Index.first (Can.Forall freeVars tipe)
