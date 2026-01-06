module Mlir.Pretty exposing (ppModule)

{-| Mlir.Pretty provides a pretty printer for the Mlir.Mlir model that will output MLIR in text format
in the standard format.

This implementation does not currently allow custom formats.

@docs ppModule

-}

import Dict exposing (Dict)
import FormatNumber as Fmt
import Mlir.Loc exposing (Loc)
import Mlir.Mlir
    exposing
        ( MlirAttr(..)
        , MlirBlock
        , MlirModule
        , MlirOp
        , MlirRegion(..)
        , MlirType(..)
        , Visibility(..)
        )
import OrderedDict



--==== Environments (symbols, SSA)


type alias SsaEnv =
    Dict String MlirType


type alias SymbolEnv =
    Dict String MlirOp


getSymName : MlirOp -> Maybe String
getSymName op =
    case Dict.get "sym_name" op.attrs of
        Just (StringAttr s) ->
            Just s

        _ ->
            Nothing


insertIfSymbol : MlirOp -> SymbolEnv -> SymbolEnv
insertIfSymbol op acc =
    case getSymName op of
        Just sym ->
            Dict.insert sym op acc

        Nothing ->
            acc


walkOp : MlirOp -> SymbolEnv -> SymbolEnv
walkOp op acc =
    let
        acc1 =
            insertIfSymbol op acc
    in
    List.foldl walkRegion acc1 op.regions


walkBlock : MlirBlock -> SymbolEnv -> SymbolEnv
walkBlock blk acc =
    let
        acc1 =
            List.foldl walkOp acc blk.body
    in
    walkOp blk.terminator acc1


walkRegion : MlirRegion -> SymbolEnv -> SymbolEnv
walkRegion (MlirRegion r) acc =
    let
        acc1 =
            walkBlock r.entry acc
    in
    OrderedDict.toList r.blocks
        |> List.foldl (\( _, b ) a -> walkBlock b a) acc1



--==== Pretty Printer (generic MLIR form)


{-| Pretty prints an MLIR module in the standard format.
-}
ppModule : MlirModule -> String
ppModule m =
    let
        header =
            "module {\n"

        bodyStr =
            m.body
                |> List.map (ppOp 1 Dict.empty)
                |> String.concat

        footer =
            "}"
                ++ " "
                ++ ppLoc m.loc
                ++ "\n"
    in
    header ++ bodyStr ++ footer


ppRegion : Int -> MlirRegion -> String
ppRegion indent (MlirRegion r) =
    let
        entryStr =
            ppBlockWithLabel indent "bb0" (Dict.fromList r.entry.args) r.entry

        labeledStrs =
            r.blocks
                |> OrderedDict.toList
                |> List.map (\( label, blk ) -> ppBlockWithLabel indent label (Dict.fromList blk.args) blk)
                |> String.concat
    in
    entryStr ++ labeledStrs


ppBlockWithLabel : Int -> String -> SsaEnv -> MlirBlock -> String
ppBlockWithLabel indent label env0 blk =
    let
        pad =
            indentPad indent

        -- Proper block header: ^label(%arg0: ty, ...):
        argsStr =
            blk.args
                |> List.map (\( n, t ) -> n ++ ": " ++ ppType t)
                |> String.join ", "

        headerLine =
            if label == "bb0" && argsStr == "" then
                ""
                -- omit label for default block with no args

            else
                String.concat
                    [ pad
                    , "^"
                    , label
                    , "("
                    , argsStr
                    , "):\n"
                    ]

        -- walk body once, threading env and collecting lines; skip terminators in body
        step op ( linesRev, envAcc ) =
            if op.isTerminator then
                ( linesRev, envAcc )

            else
                let
                    line =
                        ppOp (indent + 1) envAcc op

                    envNext =
                        List.foldl (\( n, t ) a -> Dict.insert n t a) envAcc op.results
                in
                ( line :: linesRev, envNext )

        ( bodyLinesRev, envAfterBody ) =
            List.foldl step ( [], env0 ) blk.body

        bodyStr =
            bodyLinesRev |> List.reverse |> String.concat

        termStr =
            ppOp (indent + 1) envAfterBody blk.terminator
    in
    headerLine ++ bodyStr ++ termStr


ppOp : Int -> SsaEnv -> MlirOp -> String
ppOp indent env op =
    let
        pad =
            indentPad indent

        -- LHS: result names
        lhs =
            case op.results of
                [] ->
                    ""

                _ ->
                    String.concat
                        [ op.results |> List.map Tuple.first |> String.join ", "
                        , " = "
                        ]

        -- op name (generic form)
        nameStr =
            "\"" ++ op.name ++ "\""

        operandsStr =
            op.operands |> String.join ", "

        -- nested regions (generic)
        -- Each region is wrapped in {...} and separated by ", "
        regionsStr =
            case op.regions of
                [] ->
                    ""

                rs ->
                    let
                        ppOneRegion r =
                            "{\n" ++ ppRegion (indent + 2) r ++ pad ++ "}"
                    in
                    String.concat
                        [ " ("
                        , rs
                            |> List.map ppOneRegion
                            |> String.join ", "
                        , ")"
                        ]

        attrsStr =
            ppAttrs op.attrs

        -- function-like type signature: (input types) -> (result types)
        -- First try to get types from _operand_types attribute (for eco dialect ops)
        -- Fall back to environment lookup if not available
        insTys =
            case Dict.get "_operand_types" op.attrs of
                Just (ArrayAttr _ typeAttrs) ->
                    typeAttrs
                        |> List.filterMap
                            (\attr ->
                                case attr of
                                    TypeAttr t ->
                                        Just (ppType t)

                                    _ ->
                                        Nothing
                            )
                        |> String.join ", "

                _ ->
                    op.operands
                        |> List.filterMap (\n -> Dict.get n env)
                        |> List.map ppType
                        |> String.join ", "

        outsTys =
            op.results
                |> List.map (\( _, t ) -> ppType t)
                |> String.join ", "

        sigStr =
            let
                outTyStr =
                    case op.results of
                        [ ( _, singleTy ) ] ->
                            ppType singleTy

                        _ ->
                            "(" ++ outsTys ++ ")"
            in
            String.concat [ " : (", insTys, ") -> ", outTyStr ]

        succStr =
            if List.isEmpty op.successors then
                ""

            else
                " [" ++ String.join ", " op.successors ++ "]"

        locStr =
            " " ++ ppLoc op.loc
    in
    String.concat
        [ pad
        , lhs
        , nameStr
        , "("
        , operandsStr
        , ")"
        , regionsStr
        , attrsStr
        , sigStr
        , succStr
        , locStr
        , "\n"
        ]



--==== Types & Attributes


ppType : MlirType -> String
ppType ty =
    case ty of
        I1 ->
            "i1"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct s ->
            "!" ++ s

        FunctionType sig ->
            let
                ins =
                    sig.inputs |> List.map ppType |> String.join ", "

                outs =
                    sig.results |> List.map ppType |> String.join ", "
            in
            "(" ++ ins ++ ") -> (" ++ outs ++ ")"


indentPad : Int -> String
indentPad n =
    String.repeat (2 * n) " "


ppLoc : Loc -> String
ppLoc _ =
    --String.concat
    --    [ "loc(\""
    --    , file
    --    , "\":"
    --    , String.fromInt line
    --    , ":"
    --    , String.fromInt col
    --    , ")"
    --    ]
    ""


ppAttrs : Dict String MlirAttr -> String
ppAttrs attrs =
    let
        keys =
            Dict.keys attrs |> List.sort

        render k =
            case Dict.get k attrs of
                Just a ->
                    k ++ " = " ++ ppAttr a

                Nothing ->
                    k ++ " = <missing>"
    in
    case keys of
        [] ->
            ""

        _ ->
            let
                rendered =
                    keys |> List.map render |> String.join ", "

                wrapper =
                    if Dict.get "callee" attrs /= Nothing then
                        "<{" ++ rendered ++ "}>"

                    else
                        "{" ++ rendered ++ "}"
            in
            " " ++ wrapper


ppAttr : MlirAttr -> String
ppAttr attr =
    case attr of
        StringAttr s ->
            "\"" ++ s ++ "\""

        BoolAttr b ->
            if b then
                "true"

            else
                "false"

        IntAttr maybeType i ->
            case maybeType of
                Just t ->
                    String.fromInt i ++ " : " ++ ppType t

                Nothing ->
                    String.fromInt i

        TypedFloatAttr f t ->
            let
                str =
                    String.fromFloat f
            in
            if String.contains "." str then
                str ++ " : " ++ ppType t

            else
                Fmt.format
                    { decimals = 1
                    , thousandSeparator = ""
                    , decimalSeparator = "."
                    , negativePrefix = "-"
                    , negativeSuffix = ""
                    , positivePrefix = ""
                    , positiveSuffix = ""
                    }
                    f
                    ++ " : "
                    ++ ppType t

        TypeAttr t ->
            ppType t

        ArrayAttr maybeType xs ->
            case maybeType of
                Just t ->
                    "array<" ++ ppType t ++ ": " ++ (xs |> List.map ppAttr |> String.join ", ") ++ ">"

                Nothing ->
                    "[" ++ (xs |> List.map ppAttr |> String.join ", ") ++ "]"

        SymbolRefAttr s ->
            "@" ++ s

        VisibilityAttr v ->
            case v of
                Private ->
                    "\"private\""
