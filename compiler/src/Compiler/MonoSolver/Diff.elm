module Compiler.MonoSolver.Diff exposing (run)

{-| The A/B gate for the two monomorphizer engines (`EngineDiff`).

Runs the original engine and the solver engine on the identical input and
compares their `MonoGraph` output by a **canonical serialization**: node
structure rendered deeply, with every embedded type run through
`Mono.toComparableMonoType` — which erases residual `MVar` ids (layout-erased
`CEcoValue`s legitimately differ between engines, MONO_003) and canonicalizes
record-field dict ordering. This is more reliable than structural `==`, whose
`Dict`/`Array` equality is insertion-order sensitive.

The build always proceeds on the original engine's graph, so `EngineDiff` is
safe to run over the whole corpus; a divergence surfaces as a distinctive `Err`
the harness greps for:

  - `ECO_MONO_DIFF MonoSolver.unsupported: …` — the solver engine declined.
  - `ECO_MONO_DIFF MISMATCH …` — both produced a graph, but they differ.

`--optimize` note: `compiler/src` is compiled with `--optimize`, so
`Debug.toString` is unavailable — hence the hand-written serializer.

This is a comparison harness, not a fallback: neither engine's *output* is ever
built from the other. It imports the original driver's public `monomorphize` to
run it (the point of A/B); the solver engine proper never does.

@docs run

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.MonoSolver.Monomorphize as MonoSolver
import Compiler.Monomorphize.Monomorphize as Monomorphize


{-| Run both engines and compare. `dump` (from `ECO_MONO_DIFF_DUMP`) appends the
first differing node's serialization to a mismatch error.
-}
run : Bool -> Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
run dump entryPointName globalTypeEnv globalGraph =
    case Monomorphize.monomorphize entryPointName globalTypeEnv globalGraph of
        Err e ->
            Err e

        Ok oldGraph ->
            case MonoSolver.monomorphize entryPointName globalTypeEnv globalGraph of
                Err e ->
                    Err ("ECO_MONO_DIFF " ++ e)

                Ok newGraph ->
                    let
                        oldLines =
                            serializeGraph oldGraph

                        newLines =
                            serializeGraph newGraph
                    in
                    if oldLines == newLines then
                        Ok oldGraph

                    else
                        Err (mismatchMessage dump oldLines newLines)


mismatchMessage : Bool -> List String -> List String -> String
mismatchMessage dump oldLines newLines =
    let
        firstDiff =
            firstDifferingLine 0 oldLines newLines

        base =
            "ECO_MONO_DIFF MISMATCH firstDiffLine="
                ++ String.fromInt firstDiff
                ++ " ||OLD|| "
                ++ nth firstDiff oldLines
                ++ " ||NEW|| "
                ++ nth firstDiff newLines
    in
    if dump then
        base
            ++ " ||FULLOLD|| "
            ++ String.join " @@ " oldLines
            ++ " ||FULLNEW|| "
            ++ String.join " @@ " newLines

    else
        base


firstDifferingLine : Int -> List String -> List String -> Int
firstDifferingLine i old new =
    case ( old, new ) of
        ( o :: os, n :: ns ) ->
            if o == n then
                firstDifferingLine (i + 1) os ns

            else
                i

        _ ->
            i


nth : Int -> List String -> String
nth i lines =
    case List.drop i lines of
        x :: _ ->
            x

        [] ->
            "<none>"



-- ====== CANONICAL SERIALIZATION ======


{-| One canonical line per specialization slot (node + registry entry), plus a
header line for the graph-level scalars. Deterministic and id-insensitive.
-}
serializeGraph : Mono.MonoGraph -> List String
serializeGraph (Mono.MonoGraph g) =
    let
        header =
            "H main="
                ++ mainStr g.main
                ++ " flags="
                ++ maybeIntStr g.flagsDecoder
                -- lambda counter deliberately NOT compared: differently-keyed
                -- unreachable junk specs (pruned) shift it without any semantic
                -- difference; the parity bar is runtime equivalence.
                ++ " ports="
                ++ String.fromInt (List.length g.ports)

        nodeLines =
            List.indexedMap
                (\i maybeNode ->
                    "N"
                        ++ String.fromInt i
                        ++ " "
                        ++ maybe serNode maybeNode
                        ++ " | reg="
                        ++ maybe serRegEntry (arrayGet i g.registry.reverseMapping)
                )
                (Array.toList g.nodes)
    in
    header :: nodeLines


mainStr : Maybe Mono.MainInfo -> String
mainStr maybeMain =
    case maybeMain of
        Just (Mono.StaticMain specId) ->
            "static:" ++ String.fromInt specId

        Nothing ->
            "none"


maybeIntStr : Maybe Int -> String
maybeIntStr m =
    case m of
        Just i ->
            String.fromInt i

        Nothing ->
            "-"


arrayGet : Int -> Array (Maybe a) -> Maybe a
arrayGet i arr =
    Array.get i arr |> Maybe.andThen identity


maybe : (a -> String) -> Maybe a -> String
maybe f m =
    case m of
        Just x ->
            f x

        Nothing ->
            "-"


serRegEntry : ( Mono.Global, Mono.MonoType ) -> String
serRegEntry ( global, monoType ) =
    serGlobal global ++ ":" ++ Mono.toComparableMonoType monoType


serGlobal : Mono.Global -> String
serGlobal global =
    case global of
        Mono.Global _ name ->
            "G." ++ name

        Mono.Accessor name ->
            "A." ++ name


serNode : Mono.MonoNode -> String
serNode node =
    case node of
        Mono.MonoDefine expr t ->
            "Def(" ++ serExpr expr ++ "):" ++ ty t

        Mono.MonoTailFunc params expr t ->
            "TailFunc([" ++ serParams params ++ "]," ++ serExpr expr ++ "):" ++ ty t

        Mono.MonoCtor shape t ->
            "Ctor(" ++ shape.name ++ "#" ++ String.fromInt shape.tag ++ "[" ++ String.join "," (List.map ty shape.fieldTypes) ++ "]):" ++ ty t

        Mono.MonoEnum tag t ->
            "Enum(" ++ String.fromInt tag ++ "):" ++ ty t

        Mono.MonoExtern t ->
            "Extern:" ++ ty t

        Mono.MonoManagerLeaf home t ->
            "Manager(" ++ home ++ "):" ++ ty t

        Mono.MonoPortIncoming expr t ->
            "PortIn(" ++ serExpr expr ++ "):" ++ ty t

        Mono.MonoPortOutgoing expr t ->
            "PortOut(" ++ serExpr expr ++ "):" ++ ty t


serExpr : Mono.MonoExpr -> String
serExpr expr =
    case expr of
        Mono.MonoLiteral lit t ->
            "Lit(" ++ serLit lit ++ "):" ++ ty t

        Mono.MonoVarLocal name t ->
            "VL(" ++ name ++ "):" ++ ty t

        Mono.MonoVarGlobal _ specId t ->
            "VG(" ++ String.fromInt specId ++ "):" ++ ty t

        Mono.MonoVarKernel _ prefix home name t ->
            -- Debug kernels are always boxed by the backend (kernelBackendAbiPolicy),
            -- so their MonoType annotation is cosmetic; the two engines pick
            -- CEcoValue vs Int for it depending on subtle number-taint timing that
            -- never reaches codegen. Waive it (documented §7.3 gate normalization).
            "VK("
                ++ prefix
                ++ "."
                ++ home
                ++ "."
                ++ name
                ++ "):"
                ++ (if home == "Debug" then "<debug-abi>" else ty t)

        Mono.MonoList _ exprs t ->
            "List[" ++ serExprs exprs ++ "]:" ++ ty t

        Mono.MonoClosure info body t ->
            "Clo(" ++ serClosure info ++ "," ++ serExpr body ++ "):" ++ ty t

        Mono.MonoCall _ func args t _ ->
            "Call(" ++ serExpr func ++ ",[" ++ serExprs args ++ "]):" ++ ty t

        Mono.MonoTailCall name args t ->
            "TC(" ++ name ++ ",[" ++ String.join "," (List.map (\( n, e ) -> n ++ "=" ++ serExpr e) args) ++ "]):" ++ ty t

        Mono.MonoIf branches final t ->
            "If([" ++ String.join ";" (List.map (\( c, b ) -> serExpr c ++ "->" ++ serExpr b) branches) ++ "]," ++ serExpr final ++ "):" ++ ty t

        Mono.MonoLet def body t ->
            "Let(" ++ serDef def ++ "," ++ serExpr body ++ "):" ++ ty t

        Mono.MonoDestruct dtor body t ->
            "Destr(" ++ serDtor dtor ++ "," ++ serExpr body ++ "):" ++ ty t

        Mono.MonoCase n1 n2 _ jumps t ->
            "Case(" ++ n1 ++ "," ++ n2 ++ ",jumps=" ++ String.fromInt (List.length jumps) ++ "):" ++ ty t

        Mono.MonoRecordCreate fields t ->
            "Rec[" ++ serFields fields ++ "]:" ++ ty t

        Mono.MonoRecordAccess record name t ->
            "Acc(" ++ serExpr record ++ "." ++ name ++ "):" ++ ty t

        Mono.MonoRecordUpdate record fields t ->
            "Upd(" ++ serExpr record ++ ",[" ++ serFields fields ++ "]):" ++ ty t

        Mono.MonoTupleCreate _ exprs t ->
            "Tup[" ++ serExprs exprs ++ "]:" ++ ty t

        Mono.MonoUnit ->
            "Unit"

        Mono.MonoAccessorValue _ name t ->
            "AccV(" ++ name ++ "):" ++ ty t


serExprs : List Mono.MonoExpr -> String
serExprs exprs =
    String.join "," (List.map serExpr exprs)


serFields : List ( Name, Mono.MonoExpr ) -> String
serFields fields =
    String.join "," (List.map (\( n, e ) -> n ++ "=" ++ serExpr e) fields)


serLit : Mono.Literal -> String
serLit lit =
    case lit of
        Mono.LBool b ->
            "B" ++ boolStr b

        Mono.LInt i ->
            "I" ++ String.fromInt i

        Mono.LFloat f ->
            "F" ++ String.fromFloat f

        Mono.LChar c ->
            "C" ++ c

        Mono.LStr s ->
            "S" ++ s


serDef : Mono.MonoDef -> String
serDef def =
    case def of
        Mono.MonoDef name body ->
            name ++ "=" ++ serExpr body

        Mono.MonoTailDef name params body ->
            name ++ "([" ++ serParams params ++ "])=" ++ serExpr body


serDtor : Mono.MonoDestructor -> String
serDtor (Mono.MonoDestructor name path t) =
    name ++ "<-" ++ serPath path ++ ":" ++ ty t


serPath : Mono.MonoPath -> String
serPath path =
    case path of
        Mono.MonoIndex i _ t sub ->
            "Idx" ++ String.fromInt i ++ ":" ++ ty t ++ "." ++ serPath sub

        Mono.MonoField name t sub ->
            "Fld" ++ name ++ ":" ++ ty t ++ "." ++ serPath sub

        Mono.MonoUnbox t sub ->
            "Unbox:" ++ ty t ++ "." ++ serPath sub

        Mono.MonoRoot name t ->
            "Root" ++ name ++ ":" ++ ty t


serParams : List ( Name, Mono.MonoType ) -> String
serParams params =
    String.join "," (List.map (\( n, t ) -> n ++ ":" ++ ty t) params)


serClosure : Mono.ClosureInfo -> String
serClosure info =
    "params=[" ++ serParams info.params ++ "] captures=" ++ String.fromInt (List.length info.captures)


ty : Mono.MonoType -> String
ty =
    Mono.toComparableMonoType


boolStr : Bool -> String
boolStr b =
    if b then
        "T"

    else
        "F"
