module Compiler.Generate.MLIR.ConstThunks exposing (build, report)

{-| Constant-thunk folding (plans/mlir-split-backend-04-constant-thunks.md
Part II T2, CGEN\_082): the arity-0 top-level values whose body codegen can
emit at every reference instead of an `eco.call` to the thunk.

A codegen-time map, like `nullConsBySpec` / `constCtorBySpec`: the graph is not
changed and the thunk's `func.func` still exists and still returns the same
value for any path not routed through the map. `Expr.generateVarGlobal` emits
the thunk's OWN body at the reference (under a fresh lexical scope), so the
ops, values, poison and guard semantics are exactly those of calling the
thunk; LLVM then folds the constants the IPSCCP prologue used to propagate,
and the call disappears.

Phase 1 (`constThunks >= 1`): literal (not String), Unit, kernel float
constant (`pi`, `e`), or an alias chain ending at one of those or at a
null-cons / `Nothing` constant.

Phase 2A (`constThunks >= 2`): additionally a CLOSED body of those plus
`let`s and saturated calls that codegen lowers to a pure arithmetic intrinsic
(both the `MonoVarKernel` and the elm/core global routes, plus kernel
`logBase`, which codegen special-cases into two logs and a divide), within
24 nodes.

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Monomorphize.Registry as Registry
import Dict
import Set


type alias Env =
    { phase : Int
    , registry : Mono.SpecializationRegistry
    , signatures : Array (Maybe Ctx.FuncSignature)
    , nodes : Array (Maybe Mono.MonoNode)
    , mainSpec : Maybe Int
    , nullCons : Dict.Dict Int Int
    , constCtor : Dict.Dict Int String
    }


{-| Why a candidate was refused (census only).
-}
type Verdict
    = Admit String -- class: literal | unit | kconst | alias | closed
    | Refuse String -- reason


maxNodes : Int
maxNodes =
    24


{-| SpecId -> the thunk body to emit at each reference.
-}
build :
    Int
    -> Mono.SpecializationRegistry
    -> Array (Maybe Ctx.FuncSignature)
    -> Array (Maybe Mono.MonoNode)
    -> Maybe Mono.MainInfo
    -> Dict.Dict Int Int
    -> Dict.Dict Int String
    -> Dict.Dict Int Mono.MonoExpr
build phase registry signatures nodes main nullCons constCtor =
    if phase <= 0 then
        Dict.empty

    else
        let
            env =
                mkEnv phase registry signatures nodes main nullCons constCtor

            verdicts =
                classifyAll env
        in
        Dict.foldl
            (\specId v acc ->
                case v of
                    Admit _ ->
                        case Array.get specId nodes of
                            Just (Just (Mono.MonoDefine body _)) ->
                                Dict.insert specId body acc

                            _ ->
                                acc

                    Refuse _ ->
                        acc
            )
            Dict.empty
            verdicts


mkEnv :
    Int
    -> Mono.SpecializationRegistry
    -> Array (Maybe Ctx.FuncSignature)
    -> Array (Maybe Mono.MonoNode)
    -> Maybe Mono.MainInfo
    -> Dict.Dict Int Int
    -> Dict.Dict Int String
    -> Env
mkEnv phase registry signatures nodes main nullCons constCtor =
    { phase = phase
    , registry = registry
    , signatures = signatures
    , nodes = nodes
    , mainSpec =
        case main of
            Just (Mono.StaticMain s) ->
                Just s

            Nothing ->
                Nothing
    , nullCons = nullCons
    , constCtor = constCtor
    }


{-| Verdict for every candidate, in SpecId order (deterministic). Memoized:
an alias or closed body consults the verdicts of the thunks it references.
-}
classifyAll : Env -> Dict.Dict Int Verdict
classifyAll env =
    Tuple.second
        (Array.foldl
            (\_ ( specId, memo ) ->
                ( specId + 1
                , if isCandidate env specId then
                    Tuple.second (verdictOf env Set.empty specId memo)

                  else
                    memo
                )
            )
            ( 0, Dict.empty )
            env.nodes
        )


isCandidate : Env -> Int -> Bool
isCandidate env specId =
    if env.mainSpec == Just specId then
        False

    else
        case ( Array.get specId env.nodes, Array.get specId env.signatures ) of
            ( Just (Just (Mono.MonoDefine _ _)), Just (Just sig) ) ->
                List.isEmpty sig.paramTypes

            _ ->
                False


verdictOf : Env -> Set.Set Int -> Int -> Dict.Dict Int Verdict -> ( Verdict, Dict.Dict Int Verdict )
verdictOf env inProgress specId memo =
    case Dict.get specId memo of
        Just v ->
            ( v, memo )

        Nothing ->
            if Set.member specId inProgress then
                ( Refuse "cycle", memo )

            else if not (isCandidate env specId) then
                ( Refuse "notThunk", memo )

            else
                case Array.get specId env.nodes of
                    Just (Just (Mono.MonoDefine body _)) ->
                        let
                            ( v, memo1 ) =
                                classifyBody env (Set.insert specId inProgress) body memo
                        in
                        ( v, Dict.insert specId v memo1 )

                    _ ->
                        ( Refuse "notThunk", memo )


classifyBody : Env -> Set.Set Int -> Mono.MonoExpr -> Dict.Dict Int Verdict -> ( Verdict, Dict.Dict Int Verdict )
classifyBody env inProgress body memo =
    case phase1Class env inProgress body memo of
        ( Just cls, memo1 ) ->
            ( Admit cls, memo1 )

        ( Nothing, memo1 ) ->
            if env.phase < 2 then
                ( Refuse (refuseReason body), memo1 )

            else
                let
                    ( ok, size, memo2 ) =
                        closed env inProgress Set.empty body memo1
                in
                if ok && size <= maxNodes then
                    ( Admit "closed", memo2 )

                else if ok then
                    ( Refuse "size", memo2 )

                else
                    ( Refuse (refuseReason body), memo2 )


{-| Phase-1 shapes; `Just class` when the body is one.
-}
phase1Class : Env -> Set.Set Int -> Mono.MonoExpr -> Dict.Dict Int Verdict -> ( Maybe String, Dict.Dict Int Verdict )
phase1Class env inProgress body memo =
    case body of
        Mono.MonoLiteral lit _ ->
            case lit of
                Mono.LStr _ ->
                    ( Nothing, memo )

                _ ->
                    ( Just "literal", memo )

        Mono.MonoUnit ->
            ( Just "unit", memo )

        Mono.MonoVarKernel _ _ home name ty ->
            case Intrinsics.kernelIntrinsic home name [] ty of
                Just (Intrinsics.ConstantFloat _) ->
                    ( Just "kconst", memo )

                _ ->
                    ( Nothing, memo )

        Mono.MonoVarGlobal _ target _ ->
            if not (isNullaryTarget env target) then
                ( Nothing, memo )

            else if Dict.member target env.nullCons || Dict.member target env.constCtor then
                ( Just "alias", memo )

            else
                case verdictOf env inProgress target memo of
                    ( Admit _, memo1 ) ->
                        ( Just "alias", memo1 )

                    ( Refuse _, memo1 ) ->
                        ( Nothing, memo1 )

        _ ->
            ( Nothing, memo )


isNullaryTarget : Env -> Int -> Bool
isNullaryTarget env target =
    case Array.get target env.signatures of
        Just (Just sig) ->
            List.isEmpty sig.paramTypes

        _ ->
            False


{-| Phase 2A: is `e` closed (built only from admissible pieces), and how
many nodes does it have? `locals` are the let names bound so far.
-}
closed : Env -> Set.Set Int -> Set.Set String -> Mono.MonoExpr -> Dict.Dict Int Verdict -> ( Bool, Int, Dict.Dict Int Verdict )
closed env inProgress locals e memo =
    case e of
        Mono.MonoVarLocal name _ ->
            ( Set.member name locals, 1, memo )

        Mono.MonoLet (Mono.MonoDef name rhs) inner _ ->
            let
                ( okR, sR, memo1 ) =
                    closed env inProgress locals rhs memo
            in
            if not okR then
                ( False, 0, memo1 )

            else
                let
                    ( okB, sB, memo2 ) =
                        closed env inProgress (Set.insert name locals) inner memo1
                in
                ( okB, 1 + sR + sB, memo2 )

        Mono.MonoCall _ callee args resultType _ ->
            if not (pureCallee env callee args resultType) then
                ( False, 0, memo )

            else
                List.foldl
                    (\a ( ok, s, m ) ->
                        if not ok then
                            ( False, s, m )

                        else
                            let
                                ( okA, sA, m1 ) =
                                    closed env inProgress locals a m
                            in
                            ( okA, s + sA, m1 )
                    )
                    ( True, 1, memo )
                    args

        _ ->
            case phase1Class env inProgress e memo of
                ( Just _, memo1 ) ->
                    ( True, 1, memo1 )

                ( Nothing, memo1 ) ->
                    ( False, 0, memo1 )


pureCallee : Env -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Bool
pureCallee env callee args resultType =
    let
        argTypes =
            List.map Mono.typeOf args
    in
    case callee of
        Mono.MonoVarKernel _ _ "Basics" "logBase" _ ->
            List.length args == 2

        Mono.MonoVarKernel _ _ home name _ ->
            pureIntrinsic (Intrinsics.kernelIntrinsic home name argTypes resultType)

        Mono.MonoVarGlobal _ target _ ->
            case ( Registry.lookupSpecKey target env.registry, Array.get target env.signatures ) of
                ( Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ), Just (Just sig) ) ->
                    pkg
                        == Pkg.core
                        && List.length sig.paramTypes
                        == List.length args
                        && pureIntrinsic (Intrinsics.kernelIntrinsic moduleName name argTypes resultType)

                _ ->
                    False

        _ ->
            False


{-| Intrinsics that lower to pure, non-allocating, LLVM-foldable arithmetic
(no runtime call: `eco.int.pow` is `getOrCreateIntPow`).
-}
pureIntrinsic : Maybe Intrinsics.Intrinsic -> Bool
pureIntrinsic mi =
    case mi of
        Just i ->
            case i of
                Intrinsics.UnaryInt _ ->
                    True

                Intrinsics.BinaryInt { op } ->
                    op /= "eco.int.pow"

                Intrinsics.UnaryFloat _ ->
                    True

                Intrinsics.BinaryFloat _ ->
                    True

                Intrinsics.UnaryBool _ ->
                    True

                Intrinsics.BinaryBool _ ->
                    True

                Intrinsics.IntToFloat ->
                    True

                Intrinsics.FloatToInt _ ->
                    True

                Intrinsics.IntComparison _ ->
                    True

                Intrinsics.FloatComparison _ ->
                    True

                Intrinsics.CharComparison _ ->
                    True

                Intrinsics.FloatClassify _ ->
                    True

                Intrinsics.ConstantFloat _ ->
                    True

                Intrinsics.CharToInt ->
                    True

                Intrinsics.CharFromInt ->
                    True

                _ ->
                    False

        Nothing ->
            False


refuseReason : Mono.MonoExpr -> String
refuseReason body =
    case body of
        Mono.MonoLiteral (Mono.LStr _) _ ->
            "str"

        Mono.MonoCall _ _ _ _ _ ->
            "call"

        Mono.MonoLet _ _ _ ->
            "let"

        Mono.MonoIf _ _ _ ->
            "if"

        Mono.MonoVarGlobal _ _ _ ->
            "aliasTarget"

        _ ->
            "other"



-- ====== CENSUS (ECO_CONST_THUNK_REPORT=1) ======


{-| One stderr report: class and refusal counts, static reference sites of
the admitted thunks, and the bodies of the four hot elm/core / compiler
thunks the plan names.
-}
report :
    Int
    -> Mono.SpecializationRegistry
    -> Array (Maybe Ctx.FuncSignature)
    -> Array (Maybe Mono.MonoNode)
    -> Maybe Mono.MainInfo
    -> Dict.Dict Int Int
    -> Dict.Dict Int String
    -> String
report phase registry signatures nodes main nullCons constCtor =
    let
        env =
            mkEnv (max phase 2) registry signatures nodes main nullCons constCtor

        verdicts =
            classifyAll env

        count key =
            Dict.foldl
                (\_ v n ->
                    if verdictKey v == key then
                        n + 1

                    else
                        n
                )
                0
                verdicts

        admitted =
            Dict.filter
                (\_ v ->
                    case v of
                        Admit cls ->
                            phase >= 2 || cls /= "closed"

                        Refuse _ ->
                            False
                )
                verdicts

        sites =
            Array.foldl
                (\maybeNode n ->
                    case maybeNode of
                        Just node ->
                            n + countRefs admitted (nodeExprs node)

                        Nothing ->
                            n
                )
                0
                nodes

        hot =
            [ "hashBase", "branchFactor", "shiftStep", "bitMask", "wordSize" ]

        hotLines =
            Dict.foldl
                (\specId v acc ->
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global _ name, _ ) ->
                            if List.member name hot then
                                case Array.get specId nodes of
                                    Just (Just (Mono.MonoDefine body _)) ->
                                        ("[const-thunks]   " ++ name ++ " (spec " ++ String.fromInt specId ++ ") " ++ verdictKey v ++ ": " ++ showExpr registry 4 body)
                                            :: acc

                                    _ ->
                                        acc

                            else
                                acc

                        _ ->
                            acc
                )
                []
                verdicts
    in
    String.join "\n"
        (("[const-thunks] phase="
            ++ String.fromInt phase
            ++ " candidates="
            ++ String.fromInt (Dict.size verdicts)
            ++ " admitted="
            ++ String.fromInt (Dict.size admitted)
            ++ " literal="
            ++ String.fromInt (count "literal")
            ++ " unit="
            ++ String.fromInt (count "unit")
            ++ " kconst="
            ++ String.fromInt (count "kconst")
            ++ " alias="
            ++ String.fromInt (count "alias")
            ++ " closed="
            ++ String.fromInt (count "closed")
            ++ " refused: str="
            ++ String.fromInt (count "!str")
            ++ " call="
            ++ String.fromInt (count "!call")
            ++ " let="
            ++ String.fromInt (count "!let")
            ++ " if="
            ++ String.fromInt (count "!if")
            ++ " size="
            ++ String.fromInt (count "!size")
            ++ " aliasTarget="
            ++ String.fromInt (count "!aliasTarget")
            ++ " other="
            ++ String.fromInt (count "!other" + count "!cycle" + count "!notThunk")
            ++ " sites="
            ++ String.fromInt sites
         )
            :: List.reverse hotLines
        )


verdictKey : Verdict -> String
verdictKey v =
    case v of
        Admit cls ->
            cls

        Refuse r ->
            "!" ++ r


nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
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


{-| Static `MonoVarGlobal` references to admitted thunks (value position or
not; an approximation of the folded reference sites).
-}
countRefs : Dict.Dict Int Verdict -> List Mono.MonoExpr -> Int
countRefs admitted exprs =
    List.foldl (\e n -> n + countRefsExpr admitted e) 0 exprs


countRefsExpr : Dict.Dict Int Verdict -> Mono.MonoExpr -> Int
countRefsExpr admitted e =
    case e of
        Mono.MonoVarGlobal _ s _ ->
            if Dict.member s admitted then
                1

            else
                0

        Mono.MonoList _ xs _ ->
            countRefs admitted xs

        Mono.MonoClosure info body _ ->
            countRefs admitted (body :: List.map (\( _, c, _ ) -> c) info.captures)

        Mono.MonoCall _ f args _ _ ->
            countRefs admitted (f :: args)

        Mono.MonoTailCall _ args _ ->
            countRefs admitted (List.map Tuple.second args)

        Mono.MonoIf branches final _ ->
            countRefs admitted (final :: List.concatMap (\( c, b ) -> [ c, b ]) branches)

        Mono.MonoLet def body _ ->
            case def of
                Mono.MonoDef _ rhs ->
                    countRefs admitted [ rhs, body ]

                Mono.MonoTailDef _ _ rhs ->
                    countRefs admitted [ rhs, body ]

        Mono.MonoDestruct _ body _ ->
            countRefsExpr admitted body

        Mono.MonoCase _ _ _ branches _ ->
            countRefs admitted (List.map Tuple.second branches)

        Mono.MonoRecordCreate fields _ ->
            countRefs admitted (List.map Tuple.second fields)

        Mono.MonoRecordAccess r _ _ ->
            countRefsExpr admitted r

        Mono.MonoRecordUpdate r fields _ ->
            countRefs admitted (r :: List.map Tuple.second fields)

        Mono.MonoTupleCreate _ xs _ ->
            countRefs admitted xs

        _ ->
            0


{-| Compact S-expression of a (small) body, for the census.
-}
showExpr : Mono.SpecializationRegistry -> Int -> Mono.MonoExpr -> String
showExpr registry depth e =
    if depth <= 0 then
        "…"

    else
        case e of
            Mono.MonoLiteral lit _ ->
                case lit of
                    Mono.LBool b ->
                        if b then
                            "True"

                        else
                            "False"

                    Mono.LInt i ->
                        String.fromInt i

                    Mono.LFloat f ->
                        String.fromFloat f

                    Mono.LChar c ->
                        "'" ++ c ++ "'"

                    Mono.LStr s ->
                        "\"" ++ String.left 16 s ++ "\""

            Mono.MonoUnit ->
                "()"

            Mono.MonoVarLocal n _ ->
                n

            Mono.MonoVarGlobal _ s _ ->
                case Registry.lookupSpecKey s registry of
                    Just ( Mono.Global _ name, _ ) ->
                        "@" ++ name

                    _ ->
                        "@" ++ String.fromInt s

            Mono.MonoVarKernel _ _ home name _ ->
                "K." ++ home ++ "." ++ name

            Mono.MonoCall _ f args _ _ ->
                "(" ++ String.join " " (showExpr registry (depth - 1) f :: List.map (showExpr registry (depth - 1)) args) ++ ")"

            Mono.MonoLet (Mono.MonoDef n rhs) body _ ->
                "(let " ++ n ++ " " ++ showExpr registry (depth - 1) rhs ++ " " ++ showExpr registry (depth - 1) body ++ ")"

            Mono.MonoIf _ _ _ ->
                "(if …)"

            _ ->
                "<expr>"
