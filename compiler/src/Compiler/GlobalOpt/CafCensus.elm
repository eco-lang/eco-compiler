module Compiler.GlobalOpt.CafCensus exposing (report)

{-| Inner-CAF opportunity census (`ECO_CAF_CENSUS=1`,
design_docs/caf-memoization-design.md §12 "Inner CAFs",
plans/caf-hoist-closed-expressions.md H0).

Walks the MonoGraph handed to it — pre-hoist for the opportunity
baseline, post-hoist (prefix "caf-census(post-hoist)") for the H2
collapse gate — and counts every MAXIMAL closed non-trivial
subexpression inside function bodies, plus the H0 breakdowns the hoist
pass's defaults depend on: closure-containing, pkg-bytes-excluded,
Debug-containing, scalar-ABI, below-minNodes, the v1-eligible subset,
the DISTINCT-shape count (dedupe upper bound, via CafHoist's
region-zeroed structural equality), and the LAYERED count (all closed
candidate nodes including nested — the hoist pass's site upper bound
under plan DQ7 layering).

This walk is deliberately SEPARATE from CafHoist's rewrite walk: H3
compares their outputs as a cross-check (divergence beyond tolerance is
a bug in one of them, not a shrug).

Output-only (stderr); never affects artifacts.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.GlobalOpt.CafHoist as CafHoist
import Dict exposing (Dict)
import Set exposing (Set)
import System.TypeCheck.IO as IO


type alias Cand =
    { kind : String
    , head : String -- "G:<specId>" | "K:<name>" | "" — resolved at render
    , size : Int
    , valueAbi : Bool
    , hasClosure : Bool
    , hasDebug : Bool
    , bytesEx : Bool
    , fnType : Bool
    , dedupeKey : Maybe ( String, Mono.MonoExpr ) -- (fingerprint, zeroed); closure-free only
    }


type alias Walk =
    { free : Set Name.Name
    , cands : List Cand
    , size : Int
    , hasClosure : Bool
    , hasDebug : Bool
    , layered : Int
    }


emptyWalk : Walk
emptyWalk =
    { free = Set.empty, cands = [], size = 0, hasClosure = False, hasDebug = False, layered = 0 }


merge : Walk -> Walk -> Walk
merge a b =
    { free = Set.union a.free b.free
    , cands = a.cands ++ b.cands
    , size = a.size + b.size
    , hasClosure = a.hasClosure || b.hasClosure
    , hasDebug = a.hasDebug || b.hasDebug
    , layered = a.layered + b.layered
    }


mergeAll : List Walk -> Walk
mergeAll =
    List.foldl merge emptyWalk


{-| Would this node, if closed, be a hoisting candidate? Trivial leaves,
already-interned forms (zero-capture closures, literals, empty lists), and
pure references are not.
-}
candKind : Mono.MonoExpr -> Maybe ( String, String )
candKind expr =
    case expr of
        Mono.MonoCall _ func _ _ _ ->
            Just ( "call", headOf func )

        Mono.MonoRecordCreate _ _ ->
            Just ( "record", "" )

        Mono.MonoTupleCreate _ _ _ ->
            Just ( "tuple", "" )

        Mono.MonoList _ items _ ->
            if List.isEmpty items then
                Nothing

            else
                Just ( "list", "" )

        Mono.MonoLet _ _ _ ->
            Just ( "let", "" )

        Mono.MonoIf _ _ _ ->
            Just ( "if", "" )

        Mono.MonoCase _ _ _ _ _ ->
            Just ( "case", "" )

        Mono.MonoDestruct _ _ _ ->
            Just ( "destruct", "" )

        Mono.MonoRecordUpdate _ _ _ ->
            Just ( "recordUpdate", "" )

        _ ->
            Nothing


headOf : Mono.MonoExpr -> String
headOf func =
    case func of
        Mono.MonoVarGlobal _ specId _ ->
            "G:" ++ String.fromInt specId

        Mono.MonoVarKernel _ _ home name _ ->
            "K:" ++ Name.toElmString home ++ "." ++ Name.toElmString name

        _ ->
            "dyn"


{-| Mirror of Types.monoTypeToAbi's scalar cases (HEAP\_035 slot scope)
without a Generate-layer import.
-}
valueAbi : Mono.MonoType -> Bool
valueAbi t =
    case t of
        Mono.MInt ->
            False

        Mono.MFloat ->
            False

        Mono.MChar ->
            False

        Mono.MVar _ Mono.CNumber ->
            False

        _ ->
            True


pathRoot : Mono.MonoPath -> Name.Name
pathRoot path =
    case path of
        Mono.MonoRoot n _ ->
            n

        Mono.MonoIndex _ _ _ rest ->
            pathRoot rest

        Mono.MonoField _ _ rest ->
            pathRoot rest

        Mono.MonoUnbox _ rest ->
            pathRoot rest


dtRoot : Mono.MonoDtPath -> Name.Name
dtRoot path =
    case path of
        Mono.DtRoot n _ ->
            n

        Mono.DtIndex _ _ _ rest ->
            dtRoot rest

        Mono.DtUnbox _ rest ->
            dtRoot rest


walkDecider : Mono.Decider Mono.MonoChoice -> Walk
walkDecider decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            walkExpr e

        Mono.Leaf (Mono.Jump _) ->
            emptyWalk

        Mono.Chain tests succ fail ->
            List.foldl
                (\( dtPath, _ ) acc ->
                    { acc | free = Set.insert (dtRoot dtPath) acc.free }
                )
                (merge (walkDecider succ) (walkDecider fail))
                tests

        Mono.FanOut dtPath edges fallback ->
            List.foldl (\( _, d ) acc -> merge (walkDecider d) acc)
                (walkDecider fallback)
                edges
                |> (\acc -> { acc | free = Set.insert (dtRoot dtPath) acc.free })


{-| Bottom-up walk. Maximality: a closed candidate node swallows its
children's candidates (but `layered` keeps counting them).
-}
walkExpr : Mono.MonoExpr -> Walk
walkExpr expr =
    let
        inner : Walk
        inner =
            case expr of
                Mono.MonoLiteral _ _ ->
                    emptyWalk

                Mono.MonoVarLocal n _ ->
                    { emptyWalk | free = Set.singleton n }

                Mono.MonoVarGlobal _ _ _ ->
                    emptyWalk

                Mono.MonoVarKernel _ _ home _ _ ->
                    { emptyWalk | hasDebug = home == "Debug" }

                Mono.MonoUnit ->
                    emptyWalk

                Mono.MonoAccessorValue _ _ _ ->
                    emptyWalk

                Mono.MonoList _ items _ ->
                    mergeAll (List.map walkExpr items)

                Mono.MonoClosure info body _ ->
                    let
                        captureWalks =
                            mergeAll
                                (List.map (\( _, ce, _ ) -> walkExpr ce) info.captures)

                        bound =
                            Set.fromList
                                (List.map (\( n, _ ) -> n) info.params
                                    ++ List.map (\( n, _, _ ) -> n) info.captures
                                )

                        bodyWalk =
                            walkExpr body

                        merged =
                            merge captureWalks
                                { bodyWalk | free = Set.diff bodyWalk.free bound }
                    in
                    { merged | hasClosure = True }

                Mono.MonoCall _ func args _ _ ->
                    mergeAll (walkExpr func :: List.map walkExpr args)

                Mono.MonoTailCall n args _ ->
                    let
                        argWalks =
                            mergeAll (List.map (\( _, e ) -> walkExpr e) args)
                    in
                    { argWalks | free = Set.insert n argWalks.free }

                Mono.MonoIf branches final _ ->
                    mergeAll
                        (walkExpr final
                            :: List.map
                                (\( c, t ) -> merge (walkExpr c) (walkExpr t))
                                branches
                        )

                Mono.MonoLet def body _ ->
                    case def of
                        Mono.MonoDef n bound ->
                            let
                                bodyWalk =
                                    walkExpr body
                            in
                            merge (walkExpr bound)
                                { bodyWalk | free = Set.remove n bodyWalk.free }

                        Mono.MonoTailDef n params bound ->
                            let
                                boundWalk =
                                    walkExpr bound

                                paramSet =
                                    Set.insert n
                                        (Set.fromList (List.map (\( pn, _ ) -> pn) params))

                                bodyWalk =
                                    walkExpr body
                            in
                            merge
                                { boundWalk | free = Set.diff boundWalk.free paramSet }
                                { bodyWalk | free = Set.remove n bodyWalk.free }

                Mono.MonoDestruct (Mono.MonoDestructor n path _) body _ ->
                    let
                        bodyWalk =
                            walkExpr body
                    in
                    { bodyWalk
                        | free =
                            Set.insert (pathRoot path)
                                (Set.remove n bodyWalk.free)
                    }

                Mono.MonoCase s1 s2 decider branches _ ->
                    let
                        branchWalks =
                            mergeAll (List.map (\( _, e ) -> walkExpr e) branches)

                        all =
                            merge (walkDecider decider) branchWalks
                    in
                    { all | free = Set.insert s1 (Set.insert s2 all.free) }

                Mono.MonoRecordCreate fields _ ->
                    mergeAll (List.map (\( _, e ) -> walkExpr e) fields)

                Mono.MonoRecordAccess rec _ _ ->
                    walkExpr rec

                Mono.MonoRecordUpdate rec updates _ ->
                    mergeAll
                        (walkExpr rec
                            :: List.map (\( _, e ) -> walkExpr e) updates
                        )

                Mono.MonoTupleCreate _ items _ ->
                    mergeAll (List.map walkExpr items)

        sized : Walk
        sized =
            { inner | size = inner.size + 1 }
    in
    if Set.isEmpty sized.free then
        case candKind expr of
            Just ( kind, head ) ->
                let
                    ty =
                        Mono.typeOf expr

                    cand =
                        { kind = kind
                        , head = head
                        , size = sized.size
                        , valueAbi = valueAbi ty
                        , hasClosure = sized.hasClosure
                        , hasDebug = sized.hasDebug
                        , bytesEx =
                            CafHoist.typeTouchesBytes ty || bytesHeadedCensus expr
                        , fnType =
                            case ty of
                                Mono.MFunction _ _ _ ->
                                    True

                                _ ->
                                    False
                        , dedupeKey =
                            if sized.hasClosure then
                                Nothing

                            else
                                Just ( CafHoist.fingerprintOf expr ty, CafHoist.zeroRegions expr )
                        }
                in
                { sized | cands = [ cand ], layered = sized.layered + 1 }

            Nothing ->
                sized

    else
        sized


bytesHeadedCensus : Mono.MonoExpr -> Bool
bytesHeadedCensus expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarKernel _ _ "Bytes" _ _) _ _ _ ->
            True

        _ ->
            False


{-| Candidates for one spec node. Thunk bodies (nullary defines) are already
memoized whole — skipped. Ports and non-body nodes are skipped.
-}
walkNode : Mono.MonoNode -> ( List Cand, Int )
walkNode node =
    case node of
        Mono.MonoDefine (Mono.MonoClosure info body _) _ ->
            let
                bodyWalk =
                    walkExpr body

                captureWalks =
                    List.map (\( _, ce, _ ) -> walkExpr ce) info.captures
            in
            ( bodyWalk.cands ++ List.concatMap .cands captureWalks
            , bodyWalk.layered + List.sum (List.map .layered captureWalks)
            )

        Mono.MonoDefine _ _ ->
            ( [], 0 )

        Mono.MonoTailFunc _ body _ ->
            let
                w =
                    walkExpr body
            in
            ( w.cands, w.layered )

        _ ->
            ( [], 0 )


report : String -> { minNodes : Int } -> Mono.MonoGraph -> String
report prefix hoistCfg (Mono.MonoGraph g) =
    let
        ( perSpec, allCands, ( specsWalked, layeredTotal ) ) =
            Array.foldl
                (\maybeNode ( acc, cands, ( sid, lay ) ) ->
                    case maybeNode of
                        Just node ->
                            let
                                ( cs, layN ) =
                                    walkNode node
                            in
                            ( if List.isEmpty cs then
                                acc

                              else
                                Dict.insert sid (List.length cs) acc
                            , cs ++ cands
                            , ( sid + 1, lay + layN )
                            )

                        Nothing ->
                            ( acc, cands, ( sid + 1, lay ) )
                )
                ( Dict.empty, [], ( 0, 0 ) )
                g.nodes

        total =
            List.length allCands

        vAbi =
            List.length (List.filter .valueAbi allCands)

        candNodes =
            List.sum (List.map .size allCands)

        -- H0 breakdowns (plan DQ1/DQ6): attributes overlap; eligibleV1 is
        -- the conjunction the hoist pass would accept as a SITE.
        closureContaining =
            List.length (List.filter .hasClosure allCands)

        bytesExcluded =
            List.length (List.filter .bytesEx allCands)

        debugContaining =
            List.length (List.filter .hasDebug allCands)

        scalarExcluded =
            List.length (List.filter (\c -> not c.valueAbi) allCands)

        fnTypeExcluded =
            List.length (List.filter .fnType allCands)

        belowMin =
            List.length (List.filter (\c -> c.size < hoistCfg.minNodes) allCands)

        eligible c =
            c.valueAbi
                && not c.fnType
                && not c.bytesEx
                && not c.hasDebug
                && c.size >= hoistCfg.minNodes

        eligibleV1 =
            List.length (List.filter eligible allCands)

        -- Distinct shapes among eligible closure-free candidates: the
        -- dedupe upper bound (collision-impossible equality — CafHoist).
        distinctShapes =
            List.foldl
                (\c buckets ->
                    case ( eligible c, c.dedupeKey ) of
                        ( True, Just ( fp, zeroed ) ) ->
                            let
                                bucket =
                                    Maybe.withDefault [] (Dict.get fp buckets)
                            in
                            if List.any (\z -> z == zeroed) bucket then
                                buckets

                            else
                                Dict.insert fp (zeroed :: bucket) buckets

                        _ ->
                            buckets
                )
                Dict.empty
                allCands
                |> Dict.foldl (\_ bucket n -> n + List.length bucket) 0

        byKind =
            List.foldl (\c d -> bump c.kind d) Dict.empty allCands

        sizeBucket c =
            if c.size <= 2 then
                "s1_2"

            else if c.size <= 9 then
                "s3_9"

            else if c.size <= 49 then
                "s10_49"

            else
                "s50plus"

        bySize =
            List.foldl (\c d -> bump (sizeBucket c) d) Dict.empty allCands

        byHead =
            List.foldl
                (\c d ->
                    if c.head == "" then
                        d

                    else
                        bump (renderHead c.head) d
                )
                Dict.empty
                allCands

        specName sid =
            case Array.get sid g.registry.reverseMapping |> Maybe.andThen identity of
                Just ( Mono.Global (IO.Canonical _ moduleName) n, _ ) ->
                    moduleName ++ "." ++ Name.toElmString n

                Just ( Mono.Accessor f, _ ) ->
                    "accessor." ++ Name.toElmString f

                Nothing ->
                    "spec" ++ String.fromInt sid

        renderHead h =
            case String.split ":" h of
                [ "G", sid ] ->
                    String.toInt sid
                        |> Maybe.map specName
                        |> Maybe.withDefault h

                _ ->
                    String.dropLeft 2 h

        top n d =
            Dict.toList d
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.take n
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "

        topSpecs =
            Dict.toList perSpec
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.take 20
                |> List.map (\( sid, c ) -> specName sid ++ "=" ++ String.fromInt c)
                |> String.join " "

        renderDict d =
            Dict.toList d
                |> List.sortBy (\( _, c ) -> negate c)
                |> List.map (\( k, c ) -> k ++ "=" ++ String.fromInt c)
                |> String.join " "
    in
    String.join "\n"
        [ prefix
            ++ ": specs="
            ++ String.fromInt specsWalked
            ++ " candidates="
            ++ String.fromInt total
            ++ " valueAbi="
            ++ String.fromInt vAbi
            ++ " candNodes="
            ++ String.fromInt candNodes
        , prefix
            ++ " v1: eligible="
            ++ String.fromInt eligibleV1
            ++ " distinctShapes="
            ++ String.fromInt distinctShapes
            ++ " layered="
            ++ String.fromInt layeredTotal
            ++ " closureContaining="
            ++ String.fromInt closureContaining
            ++ " bytesExcluded="
            ++ String.fromInt bytesExcluded
            ++ " debugContaining="
            ++ String.fromInt debugContaining
            ++ " scalarExcluded="
            ++ String.fromInt scalarExcluded
            ++ " fnTypeExcluded="
            ++ String.fromInt fnTypeExcluded
            ++ " belowMinNodes="
            ++ String.fromInt belowMin
        , prefix ++ " kinds: " ++ renderDict byKind
        , prefix ++ " sizes: " ++ renderDict bySize
        , prefix ++ " top heads: " ++ top 25 byHead
        , prefix ++ " top specs: " ++ topSpecs
        ]


bump : String -> Dict String Int -> Dict String Int
bump k d =
    Dict.insert k (1 + Maybe.withDefault 0 (Dict.get k d)) d
