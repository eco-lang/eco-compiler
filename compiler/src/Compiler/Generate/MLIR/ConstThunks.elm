module Compiler.Generate.MLIR.ConstThunks exposing (build, report)

{-| A top-level value with no arguments is compiled as a _thunk_: a function
of no parameters that every reference calls. A call hides the value from LLVM,
so a reference to a constant such as `pi` or `2 * 1024` is not folded. This
module decides which thunks are simple and pure enough that the back end may
emit the thunk's own body at each reference instead of the call. Such a thunk
is a _constant thunk_.

`build` returns the bodies of the admitted thunks by SpecId, for
`Compiler.Generate.MLIR.Context`'s `constThunkBySpec`. The graph is not
changed, and the thunk's own function is still emitted, as `Context` describes
for its three constant maps. Because the body emitted at a reference is the
thunk's own body, the reference computes what a call would.

A _candidate_ is a `MonoDefine` whose signature has no parameters, other than
the program's static `main`. Which candidates are admitted depends on the
_phase_, an integer that turns the analysis on in steps.

At phase 1 or above, a candidate is admitted when its body is a literal other
than a String, `()`, a kernel float constant (`pi` or `e`), or a reference to
another nullary spec that is a null-cons constant, a well-known constant such
as `Nothing` (the `nullCons` and `constCtor` maps `build` is given), or itself
an admitted thunk. A chain of such references is an _alias chain_; a chain
that leads back to a thunk already being classified is refused.

At phase 2 or above, a candidate is also admitted when its body is _closed_:
built from those phase-1 shapes, references to locals its own `let`s bind,
`let`s that bind with a plain definition, and saturated calls that lower to
pure arithmetic, with at most `maxNodes` nodes in all. A call qualifies when
its callee is a kernel function, or an elm/core global given all its
arguments, that `Compiler.GlobalOpt.KernelIntrinsics` maps to a pure
intrinsic, or kernel `Basics.logBase` with two arguments.

`report` runs the same analysis to produce a census of it.

@docs build, report

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.GlobalOpt.KernelIntrinsics as KernelIntrinsics
import Compiler.Monomorphize.Registry as Registry
import Dict
import Set


{-| What the analysis needs about the program, and the phase it runs at.

`mainSpec` is the static `main`, which is never a candidate. `nullCons` and
`constCtor` are the null-cons and well-known-constant maps, consulted only for
whether they contain a spec.

-}
type alias Env =
    { phase : Int
    , registry : Mono.SpecializationRegistry
    , signatures : Array (Maybe Ctx.FuncSignature)
    , nodes : Array (Maybe Mono.MonoNode)
    , mainSpec : Maybe Int
    , nullCons : Dict.Dict Int Int
    , constCtor : Dict.Dict Int String
    }


{-| The outcome of classifying one spec: admitted as a constant thunk or not.

`Admit` carries the shape that admitted it: `"literal"`, `"unit"`, `"kconst"`
(a kernel float constant), `"alias"` or `"closed"`.

`Refuse` carries the reason, a short word the census counts, such as `"str"`,
`"size"`, `"cycle"` or `"notThunk"`.

-}
type Verdict
    = Admit String
    | Refuse String


{-| The largest number of nodes a closed body may have and still be admitted.
-}
maxNodes : Int
maxNodes =
    24


{-| Returns the body of every admitted constant thunk, keyed by its SpecId,
given the phase, the program's specs, the static main, and the null-cons and
well-known-constant maps. At phase 0 or below the result is empty.
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


{-| Builds the analysis environment from `build`'s arguments.
-}
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


{-| Returns the verdict for every candidate, classifying them in SpecId order.

The verdicts are memoised as they are found, because an alias or a closed body
needs the verdict of each thunk it references.

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


{-| Tells whether a spec is a candidate: a `MonoDefine` with no parameters
that is not the static `main`.
-}
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


{-| Returns the verdict for a spec, and the memo extended with it.

A spec in `inProgress` is already being classified further up, so reaching it
again is a cycle and is refused. A spec that is not a candidate is refused.
Neither refusal is memoised.

-}
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


{-| Returns the verdict for a candidate's body: a phase-1 shape first, then,
at phase 2 or above, a closed body within `maxNodes`.
-}
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


{-| Returns the class of a body that is a phase-1 shape, or `Nothing`.

A reference to another spec is an alias when that spec has no parameters and
is in the null-cons or well-known-constant map, or is itself admitted.

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
            case KernelIntrinsics.kernelIntrinsic home name [] ty of
                Just (KernelIntrinsics.ConstantFloat _) ->
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


{-| Tells whether a spec's signature has no parameters.
-}
isNullaryTarget : Env -> Int -> Bool
isNullaryTarget env target =
    case Array.get target env.signatures of
        Just (Just sig) ->
            List.isEmpty sig.paramTypes

        _ ->
            False


{-| Tells whether `e` is closed, and how many nodes it has; `locals` are the
names the enclosing `let`s bind.

A `let` counts one node, and so does a call; a call's callee is not counted.
When `e` is not closed, the size is not meaningful.

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


{-| Tells whether a call to `callee` with `args` lowers to pure arithmetic.

A kernel callee qualifies through `pureIntrinsic`. A global callee qualifies
when it is an elm/core function given exactly as many arguments as it has
parameters, and its home and name select a pure intrinsic. Kernel
`Basics.logBase` qualifies with two arguments of any type.

-}
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
            pureIntrinsic (KernelIntrinsics.kernelIntrinsic home name argTypes resultType)

        Mono.MonoVarGlobal _ target _ ->
            case ( Registry.lookupSpecKey target env.registry, Array.get target env.signatures ) of
                ( Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ), Just (Just sig) ) ->
                    pkg
                        == Pkg.core
                        && List.length sig.paramTypes
                        == List.length args
                        && pureIntrinsic (KernelIntrinsics.kernelIntrinsic moduleName name argTypes resultType)

                _ ->
                    False

        _ ->
            False


{-| Tells whether an intrinsic is one of the numeric, Bool, Char, conversion
and Int, Float and Char comparison intrinsics this module treats as pure
arithmetic.

Integer power (`eco.int.pow`) is excluded because it lowers to a call to a
runtime function. Array, String and List intrinsics, generic equality, generic
`compare` and String ordering are excluded.

-}
pureIntrinsic : Maybe KernelIntrinsics.Intrinsic -> Bool
pureIntrinsic mi =
    case mi of
        Just i ->
            case i of
                KernelIntrinsics.UnaryInt _ ->
                    True

                KernelIntrinsics.BinaryInt { op } ->
                    op /= "eco.int.pow"

                KernelIntrinsics.UnaryFloat _ ->
                    True

                KernelIntrinsics.BinaryFloat _ ->
                    True

                KernelIntrinsics.UnaryBool _ ->
                    True

                KernelIntrinsics.BinaryBool _ ->
                    True

                KernelIntrinsics.IntToFloat ->
                    True

                KernelIntrinsics.FloatToInt _ ->
                    True

                KernelIntrinsics.IntComparison _ ->
                    True

                KernelIntrinsics.FloatComparison _ ->
                    True

                KernelIntrinsics.CharComparison _ ->
                    True

                KernelIntrinsics.FloatClassify _ ->
                    True

                KernelIntrinsics.ConstantFloat _ ->
                    True

                KernelIntrinsics.CharToInt ->
                    True

                KernelIntrinsics.CharFromInt ->
                    True

                _ ->
                    False

        Nothing ->
            False


{-| Returns the census's refusal reason for a body, from its outermost form.
-}
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



-- ====== CENSUS ======


{-| Returns a census of the analysis, as lines of text.

The first line gives the phase, the number of candidates and of admitted
thunks, and the count of each class and refusal reason, with the cycle and
not-a-thunk refusals counted under `other`. It ends with a count of the static
references to admitted thunks that are found in define, tail-function and port
bodies. Each further line shows a candidate whose name is one of `hashBase`,
`branchFactor`, `shiftStep`, `bitMask` or `wordSize`, with its verdict and its
body.

The verdicts are computed at phase 2 or above whatever `phase` is; below phase
2, closed thunks are left out of the admitted count and the reference sites,
but are still counted as `closed`.

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


{-| Returns the census key of a verdict: the class, or the reason after a `!`.
-}
verdictKey : Verdict -> String
verdictKey v =
    case v of
        Admit cls ->
            cls

        Refuse r ->
            "!" ++ r


{-| Returns the expressions of a node that the census searches for references.
-}
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


{-| Counts the static references to admitted thunks in `exprs`.

This approximates the references that are folded: it counts every reference,
whatever position it is in, and does not look inside every kind of expression.

-}
countRefs : Dict.Dict Int Verdict -> List Mono.MonoExpr -> Int
countRefs admitted exprs =
    List.foldl (\e n -> n + countRefsExpr admitted e) 0 exprs


{-| Counts the static references to admitted thunks in one expression.
-}
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


{-| Returns a short S-expression for an expression, down to `depth` levels,
with `…` below that.
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
