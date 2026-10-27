module Compiler.MonoSolver.Diff exposing (runAssigned)

{-| The compiler has two monomorphizers, the original engine and the solver
engine, and this module checks that they agree on a given program.

`runAssigned` runs both engines on the same id-assigned graph and compares the
two `MonoGraph`s. The build always continues with the original engine's graph,
so a disagreement never changes the graph that is built; instead the step
fails with an `Err` whose text starts with `ECO_MONO_DIFF`, which a test
harness can search for.

The comparison is not structural `==`. Each graph is written out as a list of
lines, one header line for the graph as a whole and one line per
specialization slot, and the two lists are compared. Writing the graph out
lets the comparison ignore what is allowed to differ: every type is written by
`Mono.toComparableMonoType`, whose docstring says what that key leaves out
(among other things, the ids of residual type variables). The serializer is
written by hand because `Debug.toString` is not available to a build compiled
with `--optimize`.

The written form is deliberately partial, so a match is weaker than equality
of the graphs. Only the main entry, the flags decoder, the number of ports,
the node array and the registry's reverse mapping are written; the other
fields of the graph are not compared. Within those, not compared: the lambda
counter; the module of a global; the
source regions; a call's `CallInfo`; the container kind of a destructuring
index; the deciders and branch bodies of a `case`, which are reduced to a count of jump
targets; and the type of any kernel whose home is `Debug`. Closure captures
and ports are compared by count only.

@docs runAssigned

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.MonoSolver.Monomorphize as MonoSolver
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.Monomorphize as Monomorphize


{-| Returns the original engine's graph for `assigned` when the solver engine
produces a graph that serializes the same, and an `Err` otherwise.

Both engines are given the same `assigned` graph, so whatever ran before id
assignment is seen by both. The solver engine runs with `Config.defaultLss`
except that LSS (its set annotations on function types) is switched off,
because the original engine produces no such annotations; `defaultLss` has it
switched on, so it is turned off here explicitly.

An `Err` from the original engine is returned as it is. An `Err` from the
solver engine is returned prefixed with `ECO_MONO_DIFF` and a space. When the graphs
differ, the `Err` is `ECO_MONO_DIFF MISMATCH` followed by the index of the
first differing line and that line from each graph; when `dump` is `True`,
both full serializations are appended.

-}
runAssigned : Bool -> Name -> TypeEnv.GlobalTypeEnv -> EntryPrep.Assigned -> Result String Mono.MonoGraph
runAssigned dump entryPointName globalTypeEnv assigned =
    case Monomorphize.monomorphizeWithLimitsAssigned Config.defaultLimits entryPointName globalTypeEnv assigned of
        Err e ->
            Err e

        Ok oldGraph ->
            let
                lssOff =
                    Config.defaultLss
            in
            case MonoSolver.monomorphizeWithReportAssigned { lssOff | enabled = False } Config.defaultLimits entryPointName globalTypeEnv assigned of
                Err e ->
                    Err ("ECO_MONO_DIFF " ++ e)

                Ok ( newGraph, _ ) ->
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


{-| Builds the `ECO_MONO_DIFF MISMATCH` message for two differing
serializations, appending both in full, lines joined by `@@` between spaces, when `dump` is
`True`.
-}
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


{-| Returns the index of the first line at which `old` and `new` differ,
counting from `i`. When one list is a prefix of the other, this is `i` plus
the length of the shorter one.
-}
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


{-| Returns the line at index `i`, or `<none>` when there is none.
-}
nth : Int -> List String -> String
nth i lines =
    case List.drop i lines of
        x :: _ ->
            x

        [] ->
            "<none>"



-- ====== CANONICAL SERIALIZATION ======


{-| Returns the lines a graph is compared by: a header line with the main entry,
the flags decoder's spec id and the number of ports, then one line per slot of
the node array, holding the slot's node and its registry entry.
-}
serializeGraph : Mono.MonoGraph -> List String
serializeGraph (Mono.MonoGraph g) =
    let
        header =
            "H main="
                ++ mainStr g.main
                ++ " flags="
                ++ maybeIntStr g.flagsDecoder
                -- The lambda counter is left out: the engines may number
                -- closures differently with no difference in behaviour.
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


{-| Writes the main entry, or `none`.
-}
mainStr : Maybe Mono.MainInfo -> String
mainStr maybeMain =
    case maybeMain of
        Just (Mono.StaticMain specId) ->
            "static:" ++ String.fromInt specId

        Nothing ->
            "none"


{-| Writes an optional number, or `-` when absent.
-}
maybeIntStr : Maybe Int -> String
maybeIntStr m =
    case m of
        Just i ->
            String.fromInt i

        Nothing ->
            "-"


{-| Returns the value at index `i`, or `Nothing` when the index is out of range or the slot is empty.
-}
arrayGet : Int -> Array (Maybe a) -> Maybe a
arrayGet i arr =
    Array.get i arr |> Maybe.andThen identity


{-| Writes an optional value with `f`, or `-` when absent.
-}
maybe : (a -> String) -> Maybe a -> String
maybe f m =
    case m of
        Just x ->
            f x

        Nothing ->
            "-"


{-| Writes a registry entry: its global and its type key.
-}
serRegEntry : ( Mono.Global, Mono.MonoType ) -> String
serRegEntry ( global, monoType ) =
    serGlobal global ++ ":" ++ Mono.toComparableMonoType monoType


{-| Writes a global by name alone, leaving out its module.
-}
serGlobal : Mono.Global -> String
serGlobal global =
    case global of
        Mono.Global _ name ->
            "G." ++ name

        Mono.Accessor name ->
            "A." ++ name


{-| Writes a node.
-}
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


{-| Writes an expression and, for every form but `MonoUnit`, its type.
-}
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
            -- The engines can type a Debug kernel differently (CEcoValue or
            -- Int), so its type is not compared.
            "VK("
                ++ prefix
                ++ "."
                ++ home
                ++ "."
                ++ name
                ++ "):"
                ++ (if home == "Debug" then
                        "<debug-abi>"

                    else
                        ty t
                   )

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


{-| Writes a list of expressions, separated by commas.
-}
serExprs : List Mono.MonoExpr -> String
serExprs exprs =
    String.join "," (List.map serExpr exprs)


{-| Writes record fields as `name=expression`, separated by commas.
-}
serFields : List ( Name, Mono.MonoExpr ) -> String
serFields fields =
    String.join "," (List.map (\( n, e ) -> n ++ "=" ++ serExpr e) fields)


{-| Writes a literal, tagged by its kind.
-}
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


{-| Writes a `let` definition.
-}
serDef : Mono.MonoDef -> String
serDef def =
    case def of
        Mono.MonoDef name body ->
            name ++ "=" ++ serExpr body

        Mono.MonoTailDef name params body ->
            name ++ "([" ++ serParams params ++ "])=" ++ serExpr body


{-| Writes a destructor: the bound name, its path and its type.
-}
serDtor : Mono.MonoDestructor -> String
serDtor (Mono.MonoDestructor name path t) =
    name ++ "<-" ++ serPath path ++ ":" ++ ty t


{-| Writes a destructuring path, outermost step first.
-}
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


{-| Writes parameters as `name:type`, separated by commas.
-}
serParams : List ( Name, Mono.MonoType ) -> String
serParams params =
    String.join "," (List.map (\( n, t ) -> n ++ ":" ++ ty t) params)


{-| Writes a closure's parameters and the number of its captures.
-}
serClosure : Mono.ClosureInfo -> String
serClosure info =
    "params=[" ++ serParams info.params ++ "] captures=" ++ String.fromInt (List.length info.captures)


{-| The function that writes a type: `Mono.toComparableMonoType`.
-}
ty : Mono.MonoType -> String
ty =
    Mono.toComparableMonoType


{-| Writes a `Bool` as `T` or `F`.
-}
boolStr : Bool -> String
boolStr b =
    if b then
        "T"

    else
        "F"
