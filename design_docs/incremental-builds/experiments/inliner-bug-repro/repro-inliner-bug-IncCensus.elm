module Compiler.GlobalOpt.IncCensus exposing (render, polyGlobals)

{-| Incremental-build blast-radius / duplication census (experiment x12,
env-gated by `ECO_INC_CENSUS=<path>`; report-only, graph-inert).

`render origins graph` returns one line per live spec of the FINAL GlobalOpt
graph (the one handed to MLIR codegen), plus `M` lines describing LSS members.

Spec line fields (tab separated):

    S specId symbol stableKey collGroup homePkg homeModule globalName nodeKind
      specsPerGlobal lssKeyed cost nodes lambdas fp fpNames fpRaw
      typeArgHomes keyMembers refs

  - stableKey: global ++ "@" ++ canonical key type (LSS member ids rendered by
    stable descriptors, MVar ids erased), plus "#i" when several specs share
    that rendering (i = rank by a local body fingerprint).
  - fp: body hash; references use stable keys, lambdas are (owner key,
    ordinal), local names alpha-normalised, regions omitted.
  - fpNames: fp mixed with the sequence of local names (names DO reach MLIR as
    block-argument names `%name`).
  - fpRaw: body hash with raw SpecIds, raw lambda uids, raw member ids, raw
    closure-kind ids and raw names: what today's MLIR identity sees.
  - refs: space-separated raw SpecIds referenced (VarGlobal,
    fastEvaluatorSpec, owner spec of fastEvaluator lambdas).

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..), MonoType(..))
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.MLIR.Names as Names
import Compiler.Monomorphize.MonoTraverse as Traverse
import Data.Map
import Dict exposing (Dict)
import Eco.Hash
import Set exposing (Set)



-- ====== POLYMORPHIC GLOBALS ======


{-| One line per annotated global: `P <pkg> <module> <name> <nFreeVars>`.
-}
polyGlobals : TOpt.GlobalGraph id -> String
polyGlobals (TOpt.GlobalGraph _ _ annotations _ _) =
    Data.Map.foldr TOpt.compareGlobal
        (\(TOpt.Global home name) (Can.Forall freeVars _) acc ->
            String.join "\t" [ "P", pkgOf home, modOf home, name, String.fromInt (Dict.size freeVars) ] :: acc
        )
        []
        annotations
        |> String.join "\n"



-- ====== HASHING ======


hp : Int
hp =
    36028797018963913


mix : Int -> Int -> Int
mix h x =
    modBy hp (h * 31 + modBy hp x)


strH : String -> Int
strH s =
    modBy hp (Eco.Hash.string64 1469598103 s)


mixS : Int -> String -> Int
mixS h s =
    mix h (strH s)


mixList : (a -> Int -> Int) -> List a -> Int -> Int
mixList f xs h =
    List.foldl f (mix h (List.length xs)) xs


pkgOf : ModuleName.Canonical -> String
pkgOf (ModuleName.Canonical ( a, p ) _) =
    a ++ "/" ++ p


modOf : ModuleName.Canonical -> String
modOf (ModuleName.Canonical _ m) =
    m


canonStr : ModuleName.Canonical -> String
canonStr c =
    pkgOf c ++ ":" ++ modOf c


globalStr : Mono.Global -> String
globalStr g =
    case g of
        Mono.Global home name ->
            canonStr home ++ "." ++ name

        Mono.Accessor f ->
            "accessor:." ++ f



-- ====== CENSUS ======


type alias LamInfo =
    { owner : Int, ord : Int }


type alias Spec =
    { sid : Int
    , global : Mono.Global
    , keyType : MonoType
    , node : Mono.MonoNode
    }


render : Dict Int Mono.MemberOrigin -> Mono.MonoGraph -> String
render origins (Mono.MonoGraph g) =
    let
        specs : List Spec
        specs =
            Array.foldr
                (\maybeNode ( i, acc ) ->
                    case maybeNode of
                        Just mnode ->
                            case Array.get i g.registry.reverseMapping |> Maybe.andThen identity of
                                Just ( glob, kt ) ->
                                    ( i - 1, { sid = i, global = glob, keyType = kt, node = mnode } :: acc )

                                Nothing ->
                                    ( i - 1, { sid = i, global = Mono.Global (ModuleName.Canonical ( "eco", "unknown" ) "Unknown") ("spec" ++ String.fromInt i), keyType = Mono.nodeType mnode, node = mnode } :: acc )

                        Nothing ->
                            ( i - 1, acc )
                )
                ( Array.length g.nodes - 1, [] )
                g.nodes
                |> Tuple.second

        specDict : Dict Int Spec
        specDict =
            List.foldl (\s d -> Dict.insert s.sid s d) Dict.empty specs

        -- Pass 1: lambdas (bottom-up fold order) and member occurrences.
        ( lamTable, memberOcc ) =
            List.foldl
                (\s ( lt, mo ) ->
                    let
                        gs =
                            globalStr s.global
                    in
                    List.foldl
                        (\e ( lt1, mo1, ord ) ->
                            case e of
                                MonoClosure info _ _ ->
                                    let
                                        (Mono.AnonymousLambda lh uid) =
                                            info.lambdaId

                                        k =
                                            ( canonStr lh, uid )

                                        lt2 =
                                            if Dict.member k lt1 then
                                                lt1

                                            else
                                                Dict.insert k { owner = s.sid, ord = ord } lt1

                                        mo2 =
                                            case info.lssMember of
                                                Just m ->
                                                    Dict.update m
                                                        (\old ->
                                                            let
                                                                d =
                                                                    gs ++ "#" ++ String.fromInt ord
                                                            in
                                                            case old of
                                                                Just ( best, homes ) ->
                                                                    Just ( min best d, Set.insert (homeOf s.global) homes )

                                                                Nothing ->
                                                                    Just ( d, Set.singleton (homeOf s.global) )
                                                        )
                                                        mo1

                                                Nothing ->
                                                    mo1
                                    in
                                    ( lt2, mo2, ord + 1 )

                                _ ->
                                    ( lt1, mo1, ord )
                        )
                        ( lt, mo, 0 )
                        (nodeExprs s.node |> List.concatMap (\x -> Traverse.foldExpr (::) [] x |> List.reverse))
                        |> (\( a, b, _ ) -> ( a, b ))
                )
                ( Dict.empty, Dict.empty )
                specs

        memberDesc : Int -> String
        memberDesc m =
            case Dict.get m origins of
                Just o ->
                    case o of
                        Mono.OriginGlobal gl ->
                            "g:" ++ globalStr gl

                        Mono.OriginKernel a b ->
                            "k:" ++ a ++ "." ++ b

                        Mono.OriginCtor gl ->
                            "c:" ++ globalStr gl

                        Mono.OriginAccessor f ->
                            "a:" ++ f

                        Mono.OriginPap gl k ->
                            "p:" ++ globalStr gl ++ "/" ++ String.fromInt k

                Nothing ->
                    case Dict.get m memberOcc of
                        Just ( d, _ ) ->
                            "L:" ++ d

                        Nothing ->
                            "?"

        memberHomes : Int -> String
        memberHomes m =
            case Dict.get m origins of
                Just o ->
                    case o of
                        Mono.OriginGlobal gl ->
                            homeOf gl

                        Mono.OriginKernel _ _ ->
                            "kernel"

                        Mono.OriginCtor gl ->
                            homeOf gl

                        Mono.OriginAccessor _ ->
                            "accessor"

                        Mono.OriginPap gl _ ->
                            homeOf gl

                Nothing ->
                    case Dict.get m memberOcc of
                        Just ( _, homes ) ->
                            "L=" ++ String.join "+" (Set.toList homes)

                        Nothing ->
                            "unknown"

        baseKeyOf : Spec -> String
        baseKeyOf s =
            globalStr s.global ++ "@" ++ renderType memberDesc s.keyType

        baseKeys : Dict Int String
        baseKeys =
            List.foldl (\s d -> Dict.insert s.sid (baseKeyOf s) d) Dict.empty specs

        groups : Dict String (List Int)
        groups =
            List.foldl
                (\s d -> Dict.update (Dict.get s.sid baseKeys |> Maybe.withDefault "") (\o -> Just (s.sid :: Maybe.withDefault [] o)) d)
                Dict.empty
                specs

        baseKeyH : Dict Int Int
        baseKeyH =
            Dict.map (\_ k -> strH k) baseKeys

        lamHWith : Dict Int Int -> Mono.LambdaId -> Int
        lamHWith keyH (Mono.AnonymousLambda lh uid) =
            case Dict.get ( canonStr lh, uid ) lamTable of
                Just li ->
                    mix (mix 991 (Dict.get li.owner keyH |> Maybe.withDefault 0)) li.ord

                Nothing ->
                    mix 997 0

        memH : Int -> Int
        memH m =
            strH (memberDesc m)

        stableEnv : Dict Int Int -> Env
        stableEnv keyH =
            { refH = \sid -> Dict.get sid keyH |> Maybe.withDefault (mix 7 sid)
            , lamH = lamHWith keyH
            , memH = memH
            , raw = False
            }

        rawEnv : Env
        rawEnv =
            { refH = \sid -> mix 3 sid
            , lamH = \(Mono.AnonymousLambda lh uid) -> mix (strH (canonStr lh)) uid
            , memH = \m -> mix 5 m
            , raw = True
            }

        localFp : Dict Int Int
        localFp =
            Dict.foldl
                (\_ sids acc ->
                    case sids of
                        [ _ ] ->
                            acc

                        _ ->
                            List.foldl
                                (\sid a ->
                                    case Dict.get sid specDict of
                                        Just s ->
                                            Dict.insert sid (hashNode (stableEnv baseKeyH) s.node).h a

                                        Nothing ->
                                            a
                                )
                                acc
                                sids
                )
                Dict.empty
                groups

        ( finalKeys, collInfo ) =
            Dict.foldl
                (\bk sids ( acc, ci ) ->
                    case sids of
                        [ sid ] ->
                            ( Dict.insert sid bk acc, ci )

                        _ ->
                            let
                                ranked =
                                    List.sortBy (\sid -> ( Dict.get sid localFp |> Maybe.withDefault 0, sid )) sids

                                n =
                                    List.length sids
                            in
                            ( List.foldl
                                (\( i, sid ) a -> Dict.insert sid (bk ++ "#" ++ String.fromInt i) a)
                                acc
                                (List.indexedMap Tuple.pair ranked)
                            , List.foldl (\sid c -> Dict.insert sid n c) ci sids
                            )
                )
                ( Dict.empty, Dict.empty )
                groups

        finalKeyH : Dict Int Int
        finalKeyH =
            Dict.map (\_ k -> strH k) finalKeys

        countByGlobal : Dict String Int
        countByGlobal =
            List.foldl (\s d -> Dict.update (globalStr s.global) (\o -> Just (1 + Maybe.withDefault 0 o)) d) Dict.empty specs

        specLine : Spec -> String
        specLine s =
            let
                st =
                    hashNode (stableEnv finalKeyH) s.node

                rt =
                    hashNode rawEnv s.node

                ( homePkg, homeMod, gname ) =
                    case s.global of
                        Mono.Global home name ->
                            ( pkgOf home, modOf home, name )

                        Mono.Accessor f ->
                            ( "eco/accessor", "Accessor", "." ++ f )

                refs =
                    List.foldl (\e acc -> collectRefs lamTable e acc) Set.empty (nodeExprs s.node)
                        |> Set.toList

                members =
                    collectTypeMembers s.keyType Set.empty |> Set.toList
            in
            String.join "\t"
                [ "S"
                , String.fromInt s.sid
                , symbolOf s
                , Dict.get s.sid finalKeys |> Maybe.withDefault "?"
                , String.fromInt (Dict.get s.sid collInfo |> Maybe.withDefault 1)
                , homePkg
                , homeMod
                , gname
                , nodeKind s.node
                , String.fromInt (Dict.get (globalStr s.global) countByGlobal |> Maybe.withDefault 1)
                , if lssKeyed s.keyType then
                    "1"

                  else
                    "0"
                , String.fromInt st.cost
                , String.fromInt st.nodes
                , String.fromInt st.lambdas
                , String.fromInt st.h
                , String.fromInt (mix st.h st.nameH)
                , String.fromInt (mix rt.h rt.nameH)
                , collectTypeHomes s.keyType Set.empty |> Set.toList |> String.join ","
                , List.map (\m -> String.fromInt m ++ "=" ++ memberHomes m) members |> String.join ","
                , List.map String.fromInt refs |> String.join " "
                ]

        rootLine =
            String.join "\t"
                [ "R"
                , case g.main of
                    Just (Mono.StaticMain sid) ->
                        String.fromInt sid

                    Nothing ->
                        "-"
                , g.flagsDecoder |> Maybe.map String.fromInt |> Maybe.withDefault "-"
                , List.filterMap .decoderSpecId g.ports |> List.map String.fromInt |> String.join " "
                ]
    in
    String.join "\n" (rootLine :: List.map specLine specs) ++ "\n"


homeOf : Mono.Global -> String
homeOf gl =
    case gl of
        Mono.Global home _ ->
            canonStr home

        Mono.Accessor _ ->
            "accessor"


symbolOf : Spec -> String
symbolOf s =
    case s.global of
        Mono.Global home name ->
            Names.canonicalToMLIRName home ++ "_" ++ Names.sanitizeName name ++ "_$_" ++ String.fromInt s.sid

        Mono.Accessor f ->
            "accessor_" ++ Names.sanitizeName f ++ "_$_" ++ String.fromInt s.sid


nodeKind : Mono.MonoNode -> String
nodeKind node =
    case node of
        Mono.MonoDefine _ _ ->
            "define"

        Mono.MonoTailFunc _ _ _ ->
            "tail"

        Mono.MonoCtor _ _ ->
            "ctor"

        Mono.MonoEnum _ _ ->
            "enum"

        Mono.MonoExtern _ ->
            "extern"

        Mono.MonoManagerLeaf _ _ ->
            "mgr"

        Mono.MonoPortIncoming _ _ ->
            "portin"

        Mono.MonoPortOutgoing _ _ ->
            "portout"


nodeExprs : Mono.MonoNode -> List MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine e _ ->
            [ e ]

        Mono.MonoTailFunc _ e _ ->
            [ e ]

        Mono.MonoPortIncoming e _ ->
            [ e ]

        Mono.MonoPortOutgoing e _ ->
            [ e ]

        _ ->
            []


collectRefs : Dict ( String, Int ) LamInfo -> MonoExpr -> Set Int -> Set Int
collectRefs lamTable expr acc0 =
    Traverse.foldExpr
        (\e acc ->
            case e of
                MonoVarGlobal _ sid _ ->
                    Set.insert sid acc

                MonoCall _ _ _ _ ci ->
                    let
                        acc1 =
                            case ci.fastEvaluatorSpec of
                                Just sid ->
                                    Set.insert sid acc

                                Nothing ->
                                    acc
                    in
                    case ci.fastEvaluator of
                        Just (Mono.AnonymousLambda lh uid) ->
                            case Dict.get ( canonStr lh, uid ) lamTable of
                                Just li ->
                                    Set.insert li.owner acc1

                                Nothing ->
                                    acc1

                        Nothing ->
                            acc1

                _ ->
                    acc
        )
        acc0
        expr



-- ====== TYPES ======


renderType : (Int -> String) -> MonoType -> String
renderType md t =
    case t of
        MInt ->
            "I"

        MFloat ->
            "F"

        MBool ->
            "B"

        MChar ->
            "C"

        MString ->
            "S"

        MUnit ->
            "U"

        MList _ e ->
            "L(" ++ renderType md e ++ ")"

        MTuple _ es ->
            "T(" ++ String.join "," (List.map (renderType md) es) ++ ")"

        MRecord _ fields ->
            "R{" ++ String.join "," (List.map (\( n, ft ) -> n ++ ":" ++ renderType md ft) (Dict.toList fields)) ++ "}"

        MCustom _ home name args ->
            canonStr home
                ++ "."
                ++ name
                ++ (if List.isEmpty args then
                        ""

                    else
                        "(" ++ String.join "," (List.map (renderType md) args) ++ ")"
                   )

        MFunction _ anno args ret ->
            "Fn" ++ renderAnno md anno ++ "(" ++ String.join "," (List.map (renderType md) args) ++ ")->" ++ renderType md ret

        MVar _ c ->
            case c of
                Mono.CEcoValue ->
                    "v"

                Mono.CNumber ->
                    "n"


renderAnno : (Int -> String) -> Mono.LambdaSetAnno -> String
renderAnno md anno =
    case anno of
        Mono.LTop _ ->
            "[T]"

        Mono.LVar _ ->
            "[V]"

        Mono.LSet ms ->
            "[" ++ String.join ";" (List.sort (List.map md ms)) ++ "]"

        Mono.LPartial ms ->
            "[~" ++ String.join ";" (List.sort (List.map md ms)) ++ "]"


{-| LSS-keyed: some argument position (of any stage) holds a function type
whose lambda set is known (LSet/LPartial).
-}
lssKeyed : MonoType -> Bool
lssKeyed t =
    case t of
        MFunction _ _ args ret ->
            List.any hasKnownSet args || lssKeyed ret

        _ ->
            False


hasKnownSet : MonoType -> Bool
hasKnownSet t =
    case t of
        MFunction _ anno args ret ->
            (case anno of
                Mono.LSet _ ->
                    True

                Mono.LPartial _ ->
                    True

                _ ->
                    False
            )
                || List.any hasKnownSet args
                || hasKnownSet ret

        MList _ e ->
            hasKnownSet e

        MTuple _ es ->
            List.any hasKnownSet es

        MRecord _ fs ->
            List.any hasKnownSet (Dict.values fs)

        MCustom _ _ _ args ->
            List.any hasKnownSet args

        _ ->
            False


collectTypeHomes : MonoType -> Set String -> Set String
collectTypeHomes t acc =
    case t of
        MList _ e ->
            collectTypeHomes e acc

        MTuple _ es ->
            List.foldl collectTypeHomes acc es

        MRecord _ fs ->
            List.foldl collectTypeHomes acc (Dict.values fs)

        MCustom _ home _ args ->
            List.foldl collectTypeHomes (Set.insert (canonStr home) acc) args

        MFunction _ _ args ret ->
            List.foldl collectTypeHomes (collectTypeHomes ret acc) args

        _ ->
            acc


collectTypeMembers : MonoType -> Set Int -> Set Int
collectTypeMembers t acc =
    case t of
        MList _ e ->
            collectTypeMembers e acc

        MTuple _ es ->
            List.foldl collectTypeMembers acc es

        MRecord _ fs ->
            List.foldl collectTypeMembers acc (Dict.values fs)

        MCustom _ _ _ args ->
            List.foldl collectTypeMembers acc args

        MFunction _ anno args ret ->
            let
                acc1 =
                    case anno of
                        Mono.LSet ms ->
                            List.foldl Set.insert acc ms

                        Mono.LPartial ms ->
                            List.foldl Set.insert acc ms

                        _ ->
                            acc
            in
            List.foldl collectTypeMembers (collectTypeMembers ret acc1) args

        _ ->
            acc


{-| Type contribution to a body hash: the structural layout hash (lambda sets
ignored) mixed with a depth-limited strong hash of names.
-}
typeH : MonoType -> Int
typeH t =
    mix (Mono.layoutHashOf t) (typeHD 3 t)


typeHD : Int -> MonoType -> Int
typeHD d t =
    if d <= 0 then
        Mono.layoutHashOf t

    else
        case t of
            MList _ e ->
                mix 101 (typeHD (d - 1) e)

            MTuple _ es ->
                mixList (\x h -> mix h (typeHD (d - 1) x)) es 102

            MRecord _ fs ->
                Dict.foldl (\n ft h -> mix (mixS h n) (typeHD (d - 1) ft)) (mix 103 (Dict.size fs)) fs

            MCustom _ home name args ->
                mixList (\x h -> mix h (typeHD (d - 1) x)) args (mixS (mixS 104 (canonStr home)) name)

            MFunction _ _ args ret ->
                mixList (\x h -> mix h (typeHD (d - 1) x)) args (mix 105 (typeHD (d - 1) ret))

            _ ->
                Mono.layoutHashOf t



-- ====== BODY HASH ======


type alias Env =
    { refH : Int -> Int
    , lamH : Mono.LambdaId -> Int
    , memH : Int -> Int
    , raw : Bool
    }


type alias St =
    { h : Int
    , nameH : Int
    , names : Dict Name Int
    , nextName : Int
    , cost : Int
    , nodes : Int
    , lambdas : Int
    }


initSt : St
initSt =
    { h = 17, nameH = 19, names = Dict.empty, nextName = 0, cost = 0, nodes = 0, lambdas = 0 }


hI : Int -> St -> St
hI x st =
    { st | h = mix st.h x }


hS : String -> St -> St
hS s st =
    { st | h = mixS st.h s }


hT : MonoType -> St -> St
hT t st =
    { st | h = mix st.h (typeH t) }


hName : Env -> Name -> St -> St
hName env n st =
    if env.raw then
        { st | h = mixS st.h n }

    else
        case Dict.get n st.names of
            Just i ->
                { st | h = mix st.h i }

            Nothing ->
                { st
                    | h = mix st.h st.nextName
                    , names = Dict.insert n st.nextName st.names
                    , nextName = st.nextName + 1
                    , nameH = mixS st.nameH n
                }


nd : Int -> Int -> St -> St
nd tag c st =
    { st | h = mix st.h tag, nodes = st.nodes + 1, cost = st.cost + c }


hList : (a -> St -> St) -> List a -> St -> St
hList f xs st =
    List.foldl f (hI (List.length xs) st) xs


hMaybe : (a -> St -> St) -> Maybe a -> St -> St
hMaybe f m st =
    case m of
        Just x ->
            f x (hI 1 st)

        Nothing ->
            hI 0 st


hashNode : Env -> Mono.MonoNode -> St
hashNode env n =
    case n of
        Mono.MonoDefine e t ->
            initSt |> hI 1 |> hT t |> hExpr env e

        Mono.MonoTailFunc params e t ->
            initSt |> hI 2 |> hT t |> hList (\( pn, pt ) -> hName env pn >> hT pt) params |> hExpr env e

        Mono.MonoCtor shape t ->
            initSt |> hI 3 |> hT t |> hS shape.name |> hI shape.tag |> hList hT shape.fieldTypes

        Mono.MonoEnum tag t ->
            initSt |> hI 4 |> hT t |> hI tag

        Mono.MonoExtern t ->
            initSt |> hI 5 |> hT t

        Mono.MonoManagerLeaf s t ->
            initSt |> hI 6 |> hT t |> hS s

        Mono.MonoPortIncoming e t ->
            initSt |> hI 7 |> hT t |> hExpr env e

        Mono.MonoPortOutgoing e t ->
            initSt |> hI 8 |> hT t |> hExpr env e


hLit : Mono.Literal -> St -> St
hLit lit st =
    case lit of
        Mono.LBool b ->
            hI
                (if b then
                    11

                 else
                    10
                )
                st

        Mono.LInt i ->
            st |> hI 12 |> hI i

        Mono.LFloat f ->
            st |> hI 13 |> hS (String.fromFloat f)

        Mono.LChar c ->
            st |> hI 14 |> hS c

        Mono.LStr s ->
            st |> hI 15 |> hS s


hExpr : Env -> MonoExpr -> St -> St
hExpr env expr st =
    case expr of
        MonoLiteral lit t ->
            st |> nd 20 1 |> hLit lit |> hT t

        MonoVarLocal n t ->
            st |> nd 21 1 |> hName env n |> hT t

        MonoVarGlobal _ sid t ->
            st |> nd 22 1 |> hI (env.refH sid) |> hT t

        MonoVarKernel _ a b c t ->
            st |> nd 23 1 |> hS a |> hS b |> hS c |> hT t

        MonoList _ items t ->
            st |> nd 24 3 |> hT t |> hList (hExpr env) items

        MonoClosure info body t ->
            { st | lambdas = st.lambdas + 1 }
                |> nd 25 5
                |> hT t
                |> hI (env.lamH info.lambdaId)
                |> hMaybe (\m -> hI (env.memH m)) info.lssMember
                |> hList (\( cn, ce, ub ) -> hName env cn >> hExpr env ce >> hBool ub) info.captures
                |> hList (\( pn, pt ) -> hName env pn >> hT pt) info.params
                |> hMaybe (hKind env) info.closureKind
                |> hMaybe hAbi info.captureAbi
                |> hExpr env body

        MonoCall _ f args t ci ->
            st
                |> nd 26 5
                |> hT t
                |> hCallInfo env ci
                |> hExpr env f
                |> hList (hExpr env) args

        MonoTailCall n args t ->
            st |> nd 27 5 |> hName env n |> hT t |> hList (\( an, ae ) -> hName env an >> hExpr env ae) args

        MonoIf branches final t ->
            st |> nd 28 2 |> hT t |> hList (\( c, b ) -> hExpr env c >> hExpr env b) branches |> hExpr env final

        MonoLet def body t ->
            let
                st1 =
                    st |> nd 29 2 |> hT t
            in
            (case def of
                Mono.MonoDef n e ->
                    st1 |> hI 1 |> hName env n |> hExpr env e

                Mono.MonoTailDef n params e ->
                    st1 |> hI 2 |> hName env n |> hList (\( pn, pt ) -> hName env pn >> hT pt) params |> hExpr env e
            )
                |> hExpr env body

        MonoDestruct (Mono.MonoDestructor n path dt) body t ->
            st |> nd 30 2 |> hT t |> hName env n |> hT dt |> hPath env path |> hExpr env body

        MonoCase label scrut decider jumps t ->
            st
                |> nd 31 3
                |> hT t
                |> hName env label
                |> hName env scrut
                |> hDecider env decider
                |> hList (\( i, e ) -> hI i >> hExpr env e) jumps

        MonoRecordCreate fields t ->
            st |> nd 32 3 |> hT t |> hList (\( fname, e ) -> hS fname >> hExpr env e) fields

        MonoRecordAccess e fname t ->
            st |> nd 33 1 |> hT t |> hS fname |> hExpr env e

        MonoRecordUpdate e updates t ->
            st |> nd 34 3 |> hT t |> hExpr env e |> hList (\( fname, ue ) -> hS fname >> hExpr env ue) updates

        MonoTupleCreate _ items t ->
            st |> nd 35 3 |> hT t |> hList (hExpr env) items

        MonoUnit ->
            st |> nd 36 1

        MonoAccessorValue _ fname t ->
            st |> nd 37 1 |> hS fname |> hT t


hBool : Bool -> St -> St
hBool b =
    hI
        (if b then
            1

         else
            0
        )


hKind : Env -> Mono.ClosureKind -> St -> St
hKind env (Mono.Known (Mono.ClosureKindId k)) st =
    if env.raw then
        hI k st

    else
        hI 1 st


hAbi : Mono.CaptureABI -> St -> St
hAbi abi st =
    st |> hList hT abi.captureTypes |> hList hT abi.paramTypes |> hT abi.returnType


hCallInfo : Env -> Mono.CallInfo -> St -> St
hCallInfo env ci st =
    st
        |> hI
            (case ci.callModel of
                Mono.FlattenedExternal ->
                    1

                Mono.StageCurried ->
                    2
            )
        |> hList hI ci.stageArities
        |> hBool ci.isSingleStageSaturated
        |> hI ci.initialRemaining
        |> hList hI ci.remainingStageArities
        |> hMaybe (hKind env) ci.closureKind
        |> hMaybe hAbi ci.captureAbi
        |> hMaybe (\l -> hI (env.lamH l)) ci.fastEvaluator
        |> hMaybe (\sid -> hI (env.refH sid)) ci.fastEvaluatorSpec
        |> hMaybe hI ci.fastPapPrefix
        |> hI
            (case ci.callKind of
                Mono.CallDirectKnownSegmentation ->
                    1

                Mono.CallDirectFlat ->
                    2

                Mono.CallGenericApply ->
                    3

                Mono.CallSegmentationUnknown ->
                    4
            )
        |> hT ci.evaluatorReturnType


hContainer : Mono.ContainerKind -> St -> St
hContainer k =
    case k of
        Mono.ListContainer ->
            hI 1

        Mono.Tuple2Container ->
            hI 2

        Mono.Tuple3Container ->
            hI 3

        Mono.CustomContainer n ->
            hI 4 >> hS n


hPath : Env -> Mono.MonoPath -> St -> St
hPath env path st =
    case path of
        Mono.MonoIndex i k t inner ->
            st |> hI 41 |> hI i |> hContainer k |> hT t |> hPath env inner

        Mono.MonoField n t inner ->
            st |> hI 42 |> hS n |> hT t |> hPath env inner

        Mono.MonoUnbox t inner ->
            st |> hI 43 |> hT t |> hPath env inner

        Mono.MonoRoot n t ->
            st |> hI 44 |> hName env n |> hT t


hDtPath : Env -> Mono.MonoDtPath -> St -> St
hDtPath env path st =
    case path of
        Mono.DtRoot n t ->
            st |> hI 51 |> hName env n |> hT t

        Mono.DtIndex i k t inner ->
            st |> hI 52 |> hI i |> hContainer k |> hT t |> hDtPath env inner

        Mono.DtUnbox t inner ->
            st |> hI 53 |> hT t |> hDtPath env inner


hTest : DT.Test -> St -> St
hTest test st =
    case test of
        DT.IsCtor home name idx n opts ->
            st
                |> hI 61
                |> hS (canonStr home)
                |> hS name
                |> hI (Index.toMachine idx)
                |> hI n
                |> hI
                    (case opts of
                        Can.Normal ->
                            1

                        Can.Enum ->
                            2

                        Can.Unbox ->
                            3
                    )

        DT.IsCons ->
            hI 62 st

        DT.IsNil ->
            hI 63 st

        DT.IsTuple ->
            hI 64 st

        DT.IsInt i ->
            st |> hI 65 |> hI i

        DT.IsChr c ->
            st |> hI 66 |> hS c

        DT.IsStr s ->
            st |> hI 67 |> hS s

        DT.IsBool b ->
            st |> hI 68 |> hBool b


hDecider : Env -> Mono.Decider Mono.MonoChoice -> St -> St
hDecider env d st =
    case d of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline e ->
                    st |> hI 71 |> hExpr env e

                Mono.Jump i ->
                    st |> hI 72 |> hI i

        Mono.Chain tests yes no ->
            st
                |> hI 73
                |> hList (\( p, t ) -> hDtPath env p >> hTest t) tests
                |> hDecider env yes
                |> hDecider env no

        Mono.FanOut p edges fallback ->
            st
                |> hI 74
                |> hDtPath env p
                |> hList (\( t, sub ) -> hTest t >> hDecider env sub) edges
                |> hDecider env fallback
