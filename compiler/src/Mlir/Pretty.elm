module Mlir.Pretty exposing (ppModule, ppModuleHeader, ppModuleFooter, ppTopLevelOp)

{-| Mlir.Pretty provides a pretty printer for the Mlir.Mlir model that will output MLIR in text format
in the standard format.

This implementation does not currently allow custom formats.

@docs ppModule, ppModuleHeader, ppModuleFooter, ppTopLevelOp

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


{-| Pretty-prints the opening line of an MLIR module.
-}
ppModuleHeader : String
ppModuleHeader =
    "module {\n"


{-| Pretty-prints the closing brace of an MLIR module with its location attribute.
-}
ppModuleFooter : Loc -> String
ppModuleFooter loc =
    "}"
        ++ " "
        ++ ppLoc loc
        ++ "\n"


{-| Pretty-prints a single top-level MLIR operation at indent level 1.
-}
ppTopLevelOp : MlirOp -> String
ppTopLevelOp op =
    ppOp 1 Dict.empty op


{-| Pretty-prints an entire MLIR module including header, all operations, and footer.
-}
ppModule : MlirModule -> String
ppModule m =
    let
        header =
            ppModuleHeader

        bodyStr =
            m.body
                |> List.map ppTopLevelOp
                |> String.concat

        footer =
            ppModuleFooter m.loc
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
                "[" ++ String.join ", " op.successors ++ "]"

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
        , succStr
        , regionsStr
        , attrsStr
        , sigStr
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
    case n of
        0 ->
            ""

        1 ->
            "  "

        2 ->
            "    "

        3 ->
            "      "

        _ ->
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


{-| Escape a string for MLIR output.
Converts JavaScript-style \\uXXXX escapes to MLIR-compatible \\xNN UTF-8 byte escapes.
Also escapes any non-ASCII characters that may be in the string.
-}
escapeForMlir : String -> String
escapeForMlir s =
    -- Strings in the AST are pre-escaped (from Compiler.Elm.String.fromChunks):
    -- \n, \", \\, etc. are stored as two-character escape sequences.
    -- This matches MLIR string literal syntax. However, multi-line strings
    -- (triple-quoted in Elm) may contain raw " characters that need escaping.
    -- We escape unescaped " (those not preceded by \) for MLIR compatibility.
    convertUnicodeEscapesToUtf8 s
        |> escapeUnescapedQuotes


{-| Escape double-quote characters that are not already preceded by a backslash.
Pre-escaped sequences like \" are left unchanged.
-}
escapeUnescapedQuotes : String -> String
escapeUnescapedQuotes s =
    let
        go : Bool -> List Char -> List Char -> String
        go prevWasBackslash acc chars =
            case chars of
                [] ->
                    String.fromList (List.reverse acc)

                '"' :: rest ->
                    if prevWasBackslash then
                        -- Already escaped: \", keep as-is
                        go False ('"' :: acc) rest

                    else
                        -- Unescaped " — escape it
                        go False ('"' :: '\\' :: acc) rest

                '\\' :: rest ->
                    go (not prevWasBackslash) ('\\' :: acc) rest

                c :: rest ->
                    go False (c :: acc) rest
    in
    go False [] (String.toList s)


{-| Convert \\uXXXX escapes to raw UTF-8 characters.
MLIR accepts raw UTF-8 in string literals.
-}
convertUnicodeEscapesToUtf8 : String -> String
convertUnicodeEscapesToUtf8 s =
    let
        go : List Char -> String -> String
        go revAcc remaining =
            case String.uncons remaining of
                Nothing ->
                    String.fromList (List.reverse revAcc)

                Just ( '\\', rest ) ->
                    case String.uncons rest of
                        Just ( 'u', afterU ) ->
                            -- Try to parse 4 hex digits
                            let
                                hex4 =
                                    String.left 4 afterU
                            in
                            if String.length hex4 == 4 then
                                case parseHex hex4 of
                                    Just codePoint ->
                                        let
                                            afterHex =
                                                String.dropLeft 4 afterU
                                        in
                                        go (Char.fromCode codePoint :: revAcc) afterHex

                                    Nothing ->
                                        -- Not valid hex, keep as-is
                                        go ('u' :: '\\' :: revAcc) afterU

                            else
                                -- Not enough chars, keep as-is
                                go ('u' :: '\\' :: revAcc) afterU

                        Just ( c, afterEscape ) ->
                            -- Keep only MLIR-recognized escapes: \n \t \" \\
                            -- For unrecognized escapes like \', drop the backslash
                            if c == 'n' || c == 't' || c == '"' || c == '\\' then
                                go (c :: '\\' :: revAcc) afterEscape

                            else
                                go (c :: revAcc) afterEscape

                        Nothing ->
                            String.fromList (List.reverse ('\\' :: revAcc))

                Just ( c, rest ) ->
                    go (c :: revAcc) rest
    in
    go [] s


{-| Parse a 4-character hex string to an integer.
-}
parseHex : String -> Maybe Int
parseHex s =
    String.foldl
        (\c acc ->
            case acc of
                Nothing ->
                    Nothing

                Just n ->
                    let
                        code =
                            Char.toCode c
                    in
                    if code >= 48 && code <= 57 then
                        -- 0-9
                        Just (n * 16 + (code - 48))

                    else if code >= 65 && code <= 70 then
                        -- A-F
                        Just (n * 16 + (code - 55))

                    else if code >= 97 && code <= 102 then
                        -- a-f
                        Just (n * 16 + (code - 87))

                    else
                        Nothing
        )
        (Just 0)
        s


ppAttr : MlirAttr -> String
ppAttr attr =
    case attr of
        StringAttr s ->
            "\"" ++ escapeForMlir s ++ "\""

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
