module Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries exposing
    ( LambdaKind(..)
    , RenameCtx, RenameEnv
    , normalizeLocalGraph
    )

{-| Lambda Boundary Normalization Pass

This pass rewrites TypedOptimized (TOpt) lambdas to reduce spurious staging
boundaries. By pulling lambda parameters across `let` and `case` boundaries
when semantically safe, staged currying sees flatter lambdas, resulting in
fewer intermediate closures and simpler ABIs.

Transformations:

1.  `\x -> let t = e in \y -> body` becomes `\x y -> let t = e in body`
2.  `\x -> case s of A -> \a -> e1; B -> \b -> e2` becomes
    `\x _a_hl_0 -> case s of A -> e1[a↦_a_hl_0]; B -> e2[b↦_a_hl_0]`
    (when all branches have same arity and param types; names are alpha-renamed)


# Lambda Kind

@docs LambdaKind


# Renaming Context

@docs RenameCtx, RenameEnv


# Transformation

@docs normalizeLocalGraph

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)



-- LAMBDA KIND


{-| Which variant of lambda to use when rebuilding merged lambdas.
PlainLambda = TOpt.Function
TrackedLambda = TOpt.TrackedFunction (carries region for Located names)
-}
type LambdaKind
    = PlainLambda
    | TrackedLambda A.Region


{-| Rebuild a lambda from flat (Name, Can.Type) params using the outer kind.
This ensures we always preserve the outer lambda's variant.
-}
rebuildLambda :
    LambdaKind
    -> List ( Name.Name, Can.Type )
    -> TOpt.Expr
    -> Can.Type
    -> TOpt.Expr
rebuildLambda kind params body funcType =
    case kind of
        PlainLambda ->
            TOpt.Function params body funcType

        TrackedLambda region ->
            let
                locParams : List ( A.Located Name.Name, Can.Type )
                locParams =
                    List.map
                        (\( name, tipe ) -> ( A.At region name, tipe ))
                        params
            in
            TOpt.TrackedFunction locParams body funcType



-- FRESH NAME GENERATOR


{-| Mapping from original variable name to renamed variable name.
Uses Data.Map with `identity` comparator since Name = String.
-}
type alias RenameEnv =
    Dict String Name.Name Name.Name


{-| Local state for alpha-renaming (unique suffix counter).
-}
type alias RenameCtx =
    { nextId : Int
    }


{-| Create an empty renaming context with initial ID counter.
-}
emptyRenameCtx : RenameCtx
emptyRenameCtx =
    { nextId = 0 }


{-| Generate a fresh name from a base name plus unique suffix.
Pattern: base ++ "\_hl\_" ++ id (hl = heapless lambda)
-}
freshName : Name.Name -> RenameCtx -> ( Name.Name, RenameCtx )
freshName base ctx =
    let
        suffix =
            String.fromInt ctx.nextId

        newName =
            base ++ "_hl_" ++ suffix
    in
    ( newName, { ctx | nextId = ctx.nextId + 1 } )


{-| Insert a rename mapping into the environment.
-}
insertRename : Name.Name -> Name.Name -> RenameEnv -> RenameEnv
insertRename oldName newName env =
    Dict.insert identity oldName newName env


{-| Look up a name in the rename environment, returning original if not found.
-}
lookupRename : RenameEnv -> Name.Name -> Name.Name
lookupRename env name =
    case Dict.get identity name env of
        Just newName ->
            newName

        Nothing ->
            name



-- RENAME EXPR


{-| Rename variable occurrences in an expression according to the given environment.
This function applies a closed rename environment: it renames occurrences of
variables but does NOT introduce new bindings or generate fresh names.
-}
renameExpr : RenameEnv -> TOpt.Expr -> TOpt.Expr
renameExpr env expr =
    let
        ren =
            renameExpr env
    in
    case expr of
        -- Literals: unchanged
        TOpt.Bool region value tipe ->
            TOpt.Bool region value tipe

        TOpt.Chr region value tipe ->
            TOpt.Chr region value tipe

        TOpt.Str region value tipe ->
            TOpt.Str region value tipe

        TOpt.Int region value tipe ->
            TOpt.Int region value tipe

        TOpt.Float region value tipe ->
            TOpt.Float region value tipe

        -- Local variables: apply rename
        TOpt.VarLocal name tipe ->
            TOpt.VarLocal (lookupRename env name) tipe

        TOpt.TrackedVarLocal region name tipe ->
            TOpt.TrackedVarLocal region (lookupRename env name) tipe

        -- Global/external variables: unchanged
        TOpt.VarGlobal region global tipe ->
            TOpt.VarGlobal region global tipe

        TOpt.VarEnum region global index tipe ->
            TOpt.VarEnum region global index tipe

        TOpt.VarBox region global tipe ->
            TOpt.VarBox region global tipe

        TOpt.VarCycle region home name tipe ->
            -- Local name refers to a binding; apply rename
            TOpt.VarCycle region home (lookupRename env name) tipe

        TOpt.VarDebug region name home maybeUnhandled tipe ->
            TOpt.VarDebug region (lookupRename env name) home maybeUnhandled tipe

        TOpt.VarKernel region home name tipe ->
            TOpt.VarKernel region home name tipe

        -- Collections: recurse
        TOpt.List region entries tipe ->
            TOpt.List region (List.map ren entries) tipe

        -- Lambdas: rename body only (params not touched here;
        -- alpha-renaming of params handled by normalization code via rebuildLambda)
        TOpt.Function args body tipe ->
            TOpt.Function args (ren body) tipe

        TOpt.TrackedFunction args body tipe ->
            TOpt.TrackedFunction args (ren body) tipe

        -- Calls
        TOpt.Call region func args tipe ->
            TOpt.Call region (ren func) (List.map ren args) tipe

        TOpt.TailCall name namedArgs tipe ->
            let
                renPair ( argName, argExpr ) =
                    ( argName, ren argExpr )
            in
            TOpt.TailCall name (List.map renPair namedArgs) tipe

        -- Control flow
        TOpt.If branches final tipe ->
            let
                renBranch ( cond, br ) =
                    ( ren cond, ren br )
            in
            TOpt.If (List.map renBranch branches) (ren final) tipe

        TOpt.Let def body tipe ->
            TOpt.Let (renameDef env def) (ren body) tipe

        TOpt.Destruct destructor body tipe ->
            TOpt.Destruct (renameDestructor env destructor) (ren body) tipe

        TOpt.Case label root decider jumps tipe ->
            let
                newLabel =
                    lookupRename env label

                newRoot =
                    lookupRename env root

                newDecider =
                    renameDecider env decider

                newJumps =
                    List.map (\( idx, e ) -> ( idx, ren e )) jumps
            in
            TOpt.Case newLabel newRoot newDecider newJumps tipe

        -- Records
        TOpt.Accessor region fieldName tipe ->
            TOpt.Accessor region fieldName tipe

        TOpt.Access record region fieldName tipe ->
            TOpt.Access (ren record) region fieldName tipe

        TOpt.Update region record fields tipe ->
            TOpt.Update region (ren record) (Dict.map (\_ e -> ren e) fields) tipe

        TOpt.Record fields tipe ->
            TOpt.Record (Dict.map (\_ e -> ren e) fields) tipe

        TOpt.TrackedRecord region fields tipe ->
            TOpt.TrackedRecord region (Dict.map (\_ e -> ren e) fields) tipe

        -- Other
        TOpt.Unit tipe ->
            TOpt.Unit tipe

        TOpt.Tuple region a b cs tipe ->
            TOpt.Tuple region (ren a) (ren b) (List.map ren cs) tipe

        TOpt.Shader src attrs uniforms tipe ->
            TOpt.Shader src attrs uniforms tipe


renameDef : RenameEnv -> TOpt.Def -> TOpt.Def
renameDef env def =
    case def of
        TOpt.Def region name bound tipe ->
            TOpt.Def region (lookupRename env name) (renameExpr env bound) tipe

        TOpt.TailDef region name args body tipe ->
            -- Do not alpha-rename TailDef params here;
            -- that should be done by a higher-level transformation.
            TOpt.TailDef region name args (renameExpr env body) tipe


renameDestructor : RenameEnv -> TOpt.Destructor -> TOpt.Destructor
renameDestructor env (TOpt.Destructor name path tipe) =
    TOpt.Destructor (lookupRename env name) (renamePath env path) tipe


renamePath : RenameEnv -> TOpt.Path -> TOpt.Path
renamePath env path =
    case path of
        TOpt.Index idx hint sub ->
            TOpt.Index idx hint (renamePath env sub)

        TOpt.ArrayIndex i sub ->
            TOpt.ArrayIndex i (renamePath env sub)

        TOpt.Field fieldName sub ->
            TOpt.Field fieldName (renamePath env sub)

        TOpt.Unbox sub ->
            TOpt.Unbox (renamePath env sub)

        TOpt.Root name ->
            TOpt.Root (lookupRename env name)


{-| Apply renaming to a pattern match decider tree.
-}
renameDecider : RenameEnv -> TOpt.Decider TOpt.Choice -> TOpt.Decider TOpt.Choice
renameDecider env decider =
    case decider of
        TOpt.Leaf choice ->
            TOpt.Leaf (renameChoice env choice)

        TOpt.Chain tests success failure ->
            TOpt.Chain tests
                (renameDecider env success)
                (renameDecider env failure)

        TOpt.FanOut path edges fallback ->
            let
                renEdge ( test, subDecider ) =
                    ( test, renameDecider env subDecider )
            in
            TOpt.FanOut path (List.map renEdge edges) (renameDecider env fallback)


renameChoice : RenameEnv -> TOpt.Choice -> TOpt.Choice
renameChoice env choice =
    case choice of
        TOpt.Inline expr ->
            TOpt.Inline (renameExpr env expr)

        TOpt.Jump idx ->
            TOpt.Jump idx



-- NORMALIZE LOCAL GRAPH


{-| Normalize a LocalGraph by applying lambda boundary normalization to all nodes.
-}
normalizeLocalGraph : TOpt.LocalGraph -> TOpt.LocalGraph
normalizeLocalGraph (TOpt.LocalGraph data) =
    TOpt.LocalGraph
        { data
            | nodes = Dict.map (\_ node -> normalizeNode node) data.nodes
        }


normalizeNode : TOpt.Node -> TOpt.Node
normalizeNode node =
    case node of
        TOpt.Define expr deps tipe ->
            TOpt.Define (normalizeExpr expr) deps tipe

        TOpt.TrackedDefine region expr deps tipe ->
            TOpt.TrackedDefine region (normalizeExpr expr) deps tipe

        TOpt.Cycle names values functions deps ->
            TOpt.Cycle names
                (List.map (\( n, e ) -> ( n, normalizeExpr e )) values)
                (List.map normalizeDef functions)
                deps

        TOpt.PortIncoming expr deps tipe ->
            TOpt.PortIncoming (normalizeExpr expr) deps tipe

        TOpt.PortOutgoing expr deps tipe ->
            TOpt.PortOutgoing (normalizeExpr expr) deps tipe

        -- Ctor, Enum, Box, Link, Kernel, Manager: no expressions to normalize
        _ ->
            node


normalizeDef : TOpt.Def -> TOpt.Def
normalizeDef def =
    case def of
        TOpt.Def region name expr tipe ->
            TOpt.Def region name (normalizeExpr expr) tipe

        TOpt.TailDef region name params expr tipe ->
            TOpt.TailDef region name params (normalizeExpr expr) tipe



-- NORMALIZE EXPR


normalizeExpr : TOpt.Expr -> TOpt.Expr
normalizeExpr expr =
    case expr of
        TOpt.Function params body lambdaType ->
            let
                normalizedBody =
                    normalizeExpr body

                ( finalParams, finalBody ) =
                    normalizeLambdaBodyFixpoint params normalizedBody lambdaType
            in
            rebuildLambda PlainLambda finalParams finalBody lambdaType

        TOpt.TrackedFunction params body lambdaType ->
            let
                normalizedBody =
                    normalizeExpr body

                -- Extract kind from first param's region
                kind =
                    case params of
                        ( A.At region _, _ ) :: _ ->
                            TrackedLambda region

                        [] ->
                            PlainLambda

                -- Convert to flat params for normalization
                flatParams =
                    List.map (\( A.At _ n, t ) -> ( n, t )) params

                ( finalParams, finalBody ) =
                    normalizeLambdaBodyFixpoint flatParams normalizedBody lambdaType
            in
            rebuildLambda kind finalParams finalBody lambdaType

        -- Other cases: recurse on children
        TOpt.Let def body letType ->
            TOpt.Let (normalizeDef def) (normalizeExpr body) letType

        TOpt.Case label root decider jumps caseType ->
            TOpt.Case label
                root
                (normalizeDeciderExpr decider)
                (List.map (\( i, e ) -> ( i, normalizeExpr e )) jumps)
                caseType

        TOpt.Call region func args callType ->
            TOpt.Call region (normalizeExpr func) (List.map normalizeExpr args) callType

        TOpt.If branches final ifType ->
            TOpt.If
                (List.map (\( c, b ) -> ( normalizeExpr c, normalizeExpr b )) branches)
                (normalizeExpr final)
                ifType

        TOpt.List region items listType ->
            TOpt.List region (List.map normalizeExpr items) listType

        TOpt.Tuple region a b rest tupleType ->
            TOpt.Tuple region
                (normalizeExpr a)
                (normalizeExpr b)
                (List.map normalizeExpr rest)
                tupleType

        TOpt.Record fields recType ->
            TOpt.Record (Dict.map (\_ e -> normalizeExpr e) fields) recType

        TOpt.TrackedRecord region fields recType ->
            TOpt.TrackedRecord region (Dict.map (\_ e -> normalizeExpr e) fields) recType

        TOpt.Update region base updates updateType ->
            TOpt.Update region
                (normalizeExpr base)
                (Dict.map (\_ e -> normalizeExpr e) updates)
                updateType

        TOpt.Access inner region name accessType ->
            TOpt.Access (normalizeExpr inner) region name accessType

        TOpt.Destruct destructor body destType ->
            TOpt.Destruct destructor (normalizeExpr body) destType

        -- Leaf expressions: no recursion needed
        _ ->
            expr


normalizeDeciderExpr : TOpt.Decider TOpt.Choice -> TOpt.Decider TOpt.Choice
normalizeDeciderExpr decider =
    case decider of
        TOpt.Leaf choice ->
            TOpt.Leaf (normalizeChoiceExpr choice)

        TOpt.Chain tests success failure ->
            TOpt.Chain tests
                (normalizeDeciderExpr success)
                (normalizeDeciderExpr failure)

        TOpt.FanOut path options fallback ->
            TOpt.FanOut path
                (List.map (\( t, d ) -> ( t, normalizeDeciderExpr d )) options)
                (normalizeDeciderExpr fallback)


normalizeChoiceExpr : TOpt.Choice -> TOpt.Choice
normalizeChoiceExpr choice =
    case choice of
        TOpt.Inline expr ->
            TOpt.Inline (normalizeExpr expr)

        TOpt.Jump i ->
            TOpt.Jump i



-- FIXPOINT ITERATION


{-| Iterate let/case boundary lifting until no more changes.
-}
normalizeLambdaBodyFixpoint :
    List ( Name.Name, Can.Type )
    -> TOpt.Expr
    -> Can.Type
    -> ( List ( Name.Name, Can.Type ), TOpt.Expr )
normalizeLambdaBodyFixpoint params body lambdaType =
    case tryNormalizeLetBoundary params body of
        Just ( newParams, newBody ) ->
            -- Keep iterating
            normalizeLambdaBodyFixpoint newParams newBody lambdaType

        Nothing ->
            case tryNormalizeCaseBoundary params body lambdaType of
                Just ( newParams, newBody ) ->
                    normalizeLambdaBodyFixpoint newParams newBody lambdaType

                Nothing ->
                    ( params, body )



-- LET-BOUNDARY NORMALIZATION


{-| Peel off nested Lets, collecting their defs in order.
Returns (defs in order, innermost non-Let body).
-}
peelLets : TOpt.Expr -> List TOpt.Def -> ( List TOpt.Def, TOpt.Expr )
peelLets expr acc =
    case expr of
        TOpt.Let def inner _ ->
            peelLets inner (def :: acc)

        _ ->
            ( List.reverse acc, expr )


{-| Rebuild nested Lets from a list of defs around a body.
-}
rebuildLets : List TOpt.Def -> TOpt.Expr -> TOpt.Expr
rebuildLets defs innerBody =
    List.foldr
        (\def body -> TOpt.Let def body (TOpt.typeOf body))
        innerBody
        defs


tryNormalizeLetBoundary :
    List ( Name.Name, Can.Type )
    -> TOpt.Expr
    -> Maybe ( List ( Name.Name, Can.Type ), TOpt.Expr )
tryNormalizeLetBoundary outerParams body =
    -- Handle nested Lets: collect defs, find innermost lambda, rebuild
    case peelLets body [] of
        ( defs, TOpt.Function innerParams innerBody _ ) ->
            if List.isEmpty defs then
                Nothing

            else
                Just
                    ( outerParams ++ innerParams
                    , rebuildLets defs innerBody
                    )

        ( defs, TOpt.TrackedFunction innerParams innerBody _ ) ->
            if List.isEmpty defs then
                Nothing

            else
                let
                    converted =
                        List.map (\( A.At _ n, t ) -> ( n, t )) innerParams
                in
                Just
                    ( outerParams ++ converted
                    , rebuildLets defs innerBody
                    )

        _ ->
            Nothing



-- CASE-BOUNDARY NORMALIZATION


{-| Hoist inline lambda leaves in the Decider into the jump table.

We transform:

    Leaf (Inline (\params -> body))

into:

    Leaf (Jump idx)

and append (idx, \\params -> body) to the jumps list, choosing fresh
indices above any existing ones.

Non-lambda Inline leaves are left as Inline; they will NOT be
considered for case-boundary normalization.

-}
hoistInlineLambdaChoicesToJumps :
    TOpt.Decider TOpt.Choice
    -> List ( Int, TOpt.Expr )
    -> ( TOpt.Decider TOpt.Choice, List ( Int, TOpt.Expr ) )
hoistInlineLambdaChoicesToJumps decider jumps0 =
    let
        -- Determine the starting index for new jumps.
        maxIndex : Int
        maxIndex =
            jumps0
                |> List.map Tuple.first
                |> List.maximum
                |> Maybe.withDefault -1

        startIndex : Int
        startIndex =
            maxIndex + 1

        -- Walk the Decider, hoisting lambda Inlines.
        step :
            TOpt.Decider TOpt.Choice
            -> Int
            -> List ( Int, TOpt.Expr )
            -> ( TOpt.Decider TOpt.Choice, Int, List ( Int, TOpt.Expr ) )
        step dec nextIdx accJumps =
            case dec of
                TOpt.Leaf choice ->
                    case choice of
                        TOpt.Inline expr ->
                            case expr of
                                TOpt.Function _ _ _ ->
                                    ( TOpt.Leaf (TOpt.Jump nextIdx)
                                    , nextIdx + 1
                                    , ( nextIdx, expr ) :: accJumps
                                    )

                                TOpt.TrackedFunction _ _ _ ->
                                    ( TOpt.Leaf (TOpt.Jump nextIdx)
                                    , nextIdx + 1
                                    , ( nextIdx, expr ) :: accJumps
                                    )

                                -- Non-lambda Inline: leave as-is.
                                _ ->
                                    ( TOpt.Leaf (TOpt.Inline expr), nextIdx, accJumps )

                        TOpt.Jump idx ->
                            -- Already a jump; do nothing.
                            ( TOpt.Leaf (TOpt.Jump idx), nextIdx, accJumps )

                TOpt.Chain tests success failure ->
                    let
                        ( success1, next1, acc1 ) =
                            step success nextIdx accJumps

                        ( failure1, next2, acc2 ) =
                            step failure next1 acc1
                    in
                    ( TOpt.Chain tests success1 failure1, next2, acc2 )

                TOpt.FanOut path edges fallback ->
                    let
                        stepEdge ( test, subDecider ) ( edgeAcc, n, js ) =
                            let
                                ( subDecider1, n1, js1 ) =
                                    step subDecider n js
                            in
                            ( ( test, subDecider1 ) :: edgeAcc, n1, js1 )

                        ( edgesRev, next1, acc1 ) =
                            List.foldl stepEdge ( [], nextIdx, accJumps ) edges

                        ( fallback1, next2, acc2 ) =
                            step fallback next1 acc1
                    in
                    ( TOpt.FanOut path (List.reverse edgesRev) fallback1, next2, acc2 )

        ( newDecider, _, newJumpsRev ) =
            step decider startIndex []
    in
    ( newDecider, jumps0 ++ List.reverse newJumpsRev )


{-| Check if a decider contains any Inline choices.
If true, the decider has non-lambda branches that weren't hoisted.
-}
hasAnyInline : TOpt.Decider TOpt.Choice -> Bool
hasAnyInline decider =
    case decider of
        TOpt.Leaf choice ->
            case choice of
                TOpt.Inline _ ->
                    True

                TOpt.Jump _ ->
                    False

        TOpt.Chain _ success failure ->
            hasAnyInline success || hasAnyInline failure

        TOpt.FanOut _ edges fallback ->
            List.any (\( _, d ) -> hasAnyInline d) edges || hasAnyInline fallback


tryNormalizeCaseBoundary :
    List ( Name.Name, Can.Type )
    -> TOpt.Expr
    -> Can.Type
    -> Maybe ( List ( Name.Name, Can.Type ), TOpt.Expr )
tryNormalizeCaseBoundary outerParams body _ =
    case body of
        TOpt.Case label scrut decider jumps caseType ->
            let
                -- Step 1: expose all lambda branches in the jump table.
                ( deciderWithJumps, allJumps ) =
                    hoistInlineLambdaChoicesToJumps decider jumps
            in
            -- Guard: If any Inlines remain (non-lambda branches), abort.
            -- This prevents changing the case type while leaving Inline branches
            -- with the wrong type (would cause TOPT_004/GOPT_003 violations).
            if hasAnyInline deciderWithJumps then
                Nothing

            else
                case extractAndUnifyBranchParams allJumps of
                    Nothing ->
                        -- Either some branch is not a lambda, or arities/types mismatch;
                        -- do not normalize this case boundary.
                        Nothing

                    Just ( canonicalParams, renamedJumps, arityPeeled ) ->
                        -- Step 2: peel arityPeeled argument types off the case result type.
                        case peelLambdaTypes arityPeeled caseType of
                            Just newCaseType ->
                                -- Step 3: extend outer params and rebuild Case with:
                                --   - deciderWithJumps (now using Jump choices),
                                --   - renamed jump branch bodies,
                                --   - peeled case result type.
                                Just
                                    ( outerParams ++ canonicalParams
                                    , TOpt.Case label scrut deciderWithJumps renamedJumps newCaseType
                                    )

                            Nothing ->
                                -- Case result type is not sufficiently-curried; abort.
                                Nothing

        _ ->
            Nothing


extractAndUnifyBranchParams :
    List ( Int, TOpt.Expr )
    -> Maybe ( List ( Name.Name, Can.Type ), List ( Int, TOpt.Expr ), Int )
extractAndUnifyBranchParams jumps =
    let
        extractBranch ( idx, expr ) =
            case expr of
                TOpt.Function params body _ ->
                    Just ( idx, params, body )

                TOpt.TrackedFunction params body _ ->
                    Just ( idx, List.map (\( A.At _ n, t ) -> ( n, t )) params, body )

                _ ->
                    Nothing

        extracted =
            List.filterMap extractBranch jumps
    in
    if List.length extracted /= List.length jumps then
        Nothing

    else
        case extracted of
            [] ->
                Nothing

            ( _, firstParams, _ ) :: rest ->
                let
                    arity =
                        List.length firstParams

                    firstTypes =
                        List.map Tuple.second firstParams

                    allCompatible =
                        List.all
                            (\( _, params, _ ) ->
                                List.length params == arity && List.map Tuple.second params == firstTypes
                            )
                            rest
                in
                if not allCompatible then
                    Nothing

                else
                    let
                        -- Generate fresh canonical names
                        ( revCanonicalParams, _ ) =
                            List.foldl
                                (\( name, tipe ) ( acc, ctx ) ->
                                    let
                                        ( freshN, ctx1 ) =
                                            freshName name ctx
                                    in
                                    ( ( freshN, tipe ) :: acc, ctx1 )
                                )
                                ( [], emptyRenameCtx )
                                firstParams

                        canonicalParams =
                            List.reverse revCanonicalParams

                        canonicalNames =
                            List.map Tuple.first canonicalParams

                        -- Rename each branch body
                        renamedJumps =
                            List.map
                                (\( idx, branchParams, branchBody ) ->
                                    let
                                        oldNames =
                                            List.map Tuple.first branchParams

                                        renameEnv =
                                            List.foldl
                                                (\( old, new ) env -> insertRename old new env)
                                                Dict.empty
                                                (List.map2 Tuple.pair oldNames canonicalNames)

                                        renamedBody =
                                            renameExpr renameEnv branchBody
                                    in
                                    ( idx, renamedBody )
                                )
                                extracted
                    in
                    Just ( canonicalParams, renamedJumps, arity )


peelLambdaTypes : Int -> Can.Type -> Maybe Can.Type
peelLambdaTypes count tipe =
    if count <= 0 then
        Just tipe

    else
        case tipe of
            Can.TLambda _ result ->
                peelLambdaTypes (count - 1) result

            _ ->
                Nothing
