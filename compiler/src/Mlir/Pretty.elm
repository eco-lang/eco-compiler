module Mlir.Pretty exposing (ppModule, ppModuleHeader, ppModuleFooter, ppTopLevelOp)

{-| The compiler can write its MLIR program out as text, and this module turns
the in-memory model of `Mlir.Mlir` into that text.

MLIR has two textual forms for an operation. A dialect may define a _custom
form_ for its own operations, with whatever syntax it likes. Every operation
also has the _generic form_, which spells out each part in the same order
whatever the operation:

    results = "dialect.op"(operands)[successors] (regions) {attributes} : (operand types) -> result type

This module prints only the generic form, so it needs no syntax of any
dialect's own, except that an operation with a `callee` attribute has its
attributes printed as `<{...}>` properties, before its regions, rather than as
a `{...}` dictionary after them.

One part of the generic form is not held by the operation it describes: an
`MlirOp` names its operands but does not give their types. When the operation
has an `_operand_types` attribute, a list of `TypeAttr`s, those types are
printed. Otherwise each operand is looked up among the values in scope: the
arguments of its block and of every enclosing block, and the results of the
operations printed before it in each of those blocks (for `ppModule`, also the
earlier top-level operations; `ppTopLevelOp` starts from nothing). The lookup
does not reach into another block of the same region, and an operand it does
not find is left out, so the printed operand types can be fewer than the
operands. The `_operand_types` attribute is itself printed with the other
attributes.

Locations are accepted but not printed: the location of every operation and of
the module prints as nothing.

A module can be printed whole by `ppModule`, or piece by piece as
`ppModuleHeader`, then `ppTopLevelOp` for each top-level operation, then
`ppModuleFooter`. Joined together, the pieces are the text `ppModule` gives for
a module of those operations, as long as no top-level operation names the
result of an earlier one as an operand without an `_operand_types` attribute
(`ppModule` can look such an operand's type up; `ppTopLevelOp` cannot).

A `StringAttr` holds its text with escape sequences written out, as
`Mlir.Mlir` describes, and is rewritten on the way out: a `\uXXXX` escape
becomes the character it names (a control character or a backslash as a
two-hex-digit escape), `\n`, `\t`, `\"` and `\\` are kept, and so is a `\u` not
followed by four hexadecimal digits. `\r` becomes `\0D`, any other escape
loses its backslash, and a `"` that no backslash escapes gains one.

The file also holds a walk that collects, under its `sym_name`, every operation
that has one. Nothing uses it.

@docs ppModule, ppModuleHeader, ppModuleFooter, ppTopLevelOp

-}

import Dict exposing (Dict)
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


{-| The types of the values the printer knows at a point in a block, by value
name: the arguments of the block and the results of the operations printed
before that point.

This is a name for a `Dict`, not a new type.

-}
type alias SsaEnv =
    Dict String MlirType


{-| A table of operations by symbol name, the string in their `sym_name`
attribute. Nothing in this module reads one.
-}
type alias SymbolEnv =
    Dict String MlirOp


{-| Returns the symbol name of `op`, or `Nothing` when it has no `sym_name`
attribute or that attribute is not a `StringAttr`.
-}
getSymName : MlirOp -> Maybe String
getSymName op =
    case Dict.get "sym_name" op.attrs of
        Just (StringAttr s) ->
            Just s

        _ ->
            Nothing


{-| Adds `op` to the table under its symbol name, replacing any operation
already there, or returns the table unchanged when `op` has no symbol name.
-}
insertIfSymbol : MlirOp -> SymbolEnv -> SymbolEnv
insertIfSymbol op acc =
    case getSymName op of
        Just sym ->
            Dict.insert sym op acc

        Nothing ->
            acc


{-| Adds `op`, and every operation nested in its regions, to the table under
their symbol names.
-}
walkOp : MlirOp -> SymbolEnv -> SymbolEnv
walkOp op acc =
    let
        acc1 =
            insertIfSymbol op acc
    in
    List.foldl walkRegion acc1 op.regions


{-| Adds the operations of `blk`, those in its body and then its terminator,
with the operations nested in them, to the table under their symbol names.
Unlike the printer, this does not skip body operations marked `isTerminator`.
-}
walkBlock : MlirBlock -> SymbolEnv -> SymbolEnv
walkBlock blk acc =
    let
        acc1 =
            List.foldl walkOp acc blk.body
    in
    walkOp blk.terminator acc1


{-| Adds the operations of every block of a region, the entry block first and
then the labelled blocks in order, to the table under their symbol names.
-}
walkRegion : MlirRegion -> SymbolEnv -> SymbolEnv
walkRegion (MlirRegion r) acc =
    let
        acc1 =
            walkBlock r.entry acc
    in
    OrderedDict.toList r.blocks
        |> List.foldl (\( _, b ) a -> walkBlock b a) acc1



--==== Pretty Printer (generic MLIR form)


{-| The line that opens a printed module, and the first piece of text
`ppModule` produces.
-}
ppModuleHeader : String
ppModuleHeader =
    "module {\n"


{-| Returns the line that closes a printed module, the last piece of text
`ppModule` produces. Locations are not printed, so `loc` makes no difference to
the result.
-}
ppModuleFooter : String
ppModuleFooter =
    "}"
        ++ " "
        ++ ppLoc
        ++ "\n"


{-| Returns the text of one top-level operation of a module, with any regions
nested in it, indented by two spaces and ending in a newline.

Each top-level operation is printed with no known operand types, so its
operand types are printed only when it has an `_operand_types` attribute that
is an array. Otherwise its operand type list is empty.

-}
ppTopLevelOp : MlirOp -> String
ppTopLevelOp op =
    ppOp 1 Dict.empty op


{-| Returns the text of a whole module: `ppModuleHeader`, then each operation
of its body, then `ppModuleFooter`. Each operation is printed as `ppTopLevelOp`
prints it, except that the results of the operations before it are in scope for
its operand types.
-}
ppModule : MlirModule -> String
ppModule m =
    let
        header =
            ppModuleHeader

        step op ( linesRev, env ) =
            ( ppOp 1 env op :: linesRev
            , List.foldl (\( n, t ) acc -> Dict.insert n t acc) env op.results
            )

        bodyStr =
            List.foldl step ( [], Dict.empty ) m.body
                |> Tuple.first
                |> List.reverse
                |> String.concat

        footer =
            ppModuleFooter
    in
    header ++ bodyStr ++ footer


{-| Returns the text of a region's blocks, the entry block first and then the
labelled blocks in order, each with any header at `indent` and its operations
one level deeper.

The entry block is given the label `bb0`, whose header is left out when the
block has no arguments. Each block's operand types are looked up starting from
`outerEnv`, the values in scope at the operation that holds the region, plus
the block's own arguments.

-}
ppRegion : Int -> SsaEnv -> MlirRegion -> String
ppRegion indent outerEnv (MlirRegion r) =
    let
        withArgs args =
            List.foldl (\( n, t ) acc -> Dict.insert n t acc) outerEnv args

        entryStr =
            ppBlockWithLabel indent "bb0" (withArgs r.entry.args) r.entry

        labeledStrs =
            r.blocks
                |> OrderedDict.toList
                |> List.map (\( label, blk ) -> ppBlockWithLabel indent label (withArgs blk.args) blk)
                |> String.concat
    in
    entryStr ++ labeledStrs


{-| Returns the text of one block under `label`: a header `^label(arguments):`
at `indent`, then the operations of its body, then its terminator, each one
level deeper.

The header is left out for a block labelled `bb0` with no arguments, which is
how an entry block without arguments is printed. Body operations marked
`isTerminator` are skipped, because the terminator is printed from the block's
`terminator` field. `env0` holds the types of the values known at the start of
the block, by name; the results of each operation are added to it for the
operations after it, terminator included.

-}
ppBlockWithLabel : Int -> String -> SsaEnv -> MlirBlock -> String
ppBlockWithLabel indent label env0 blk =
    let
        pad =
            indentPad indent

        argsStr =
            blk.args
                |> List.map (\( n, t ) -> n ++ ": " ++ ppType t)
                |> String.join ", "

        headerLine =
            if label == "bb0" && argsStr == "" then
                ""

            else
                String.concat
                    [ pad
                    , "^"
                    , label
                    , "("
                    , argsStr
                    , "):\n"
                    ]

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


{-| Returns the text of one operation in the generic form, starting at
`indent` and ending in a newline.

The result names and the `=` after them are left out when there are no
results, and the successors, regions and attributes are each left out when
there are none. Successors are printed as given, inside brackets. An operation
with a `callee` attribute prints its attributes as `<{...}>` properties before
its regions; any other prints them as a `{...}` dictionary after them. Each region
is wrapped in braces, its block headers two levels deeper than the operation
and their operations three, and its closing brace at the operation's own
indent, and the regions are joined by commas inside parentheses.

The operand types come from the `_operand_types` attribute when there is one
and it is an array, keeping only its `TypeAttr` elements, and otherwise from
looking each operand up in `env`, leaving out any not found. `env` also
becomes the outer scope of the operation's regions. A single result
type is printed bare; no result, or several, are printed as a parenthesised
list. The location prints as nothing, so the line ends in a space before the
newline.

-}
ppOp : Int -> SsaEnv -> MlirOp -> String
ppOp indent env op =
    let
        pad =
            indentPad indent

        lhs =
            case op.results of
                [] ->
                    ""

                _ ->
                    String.concat
                        [ op.results |> List.map Tuple.first |> String.join ", "
                        , " = "
                        ]

        nameStr =
            "\"" ++ op.name ++ "\""

        operandsStr =
            op.operands |> String.join ", "

        regionsStr =
            case op.regions of
                [] ->
                    ""

                rs ->
                    let
                        ppOneRegion r =
                            "{\n" ++ ppRegion (indent + 2) env r ++ pad ++ "}"
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

        -- `<{...}>` properties precede the regions; a `{...}` dictionary follows them.
        ( propsStr, plainAttrsStr ) =
            if Dict.member "callee" op.attrs then
                ( attrsStr, "" )

            else
                ( "", attrsStr )

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
            " " ++ ppLoc
    in
    String.concat
        [ pad
        , lhs
        , nameStr
        , "("
        , operandsStr
        , ")"
        , succStr
        , propsStr
        , regionsStr
        , plainAttrsStr
        , sigStr
        , locStr
        , "\n"
        ]



--==== Types & Attributes


{-| Returns the MLIR spelling of a type. A `NamedStruct` gets MLIR's leading
`!`, and a `FunctionType` puts its result types in parentheses even when there
is one.
-}
ppType : MlirType -> String
ppType ty =
    case ty of
        I1 ->
            "i1"

        I8 ->
            "i8"

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


{-| Returns the leading spaces for indent level `n`, two per level.
-}
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


{-| Returns the text of a location, which is always empty: locations are not
printed.
-}
ppLoc : String
ppLoc =
    ""


{-| Returns an operation's attributes as text, preceded by a space, or the
empty string when `attrs` is empty.

The attributes appear in key order, each as `key = value`, except that a
`UnitAttr` appears as its key alone. They are wrapped in `<{...}>` when one of
them is named `callee`, and in `{...}` otherwise.

-}
ppAttrs : Dict String MlirAttr -> String
ppAttrs attrs =
    let
        pairs =
            Dict.toList attrs

        render ( k, a ) =
            case a of
                UnitAttr ->
                    k

                _ ->
                    k ++ " = " ++ ppAttr a
    in
    case pairs of
        [] ->
            ""

        _ ->
            let
                rendered =
                    pairs |> List.map render |> String.join ", "

                wrapper =
                    if Dict.member "callee" attrs then
                        "<{" ++ rendered ++ "}>"

                    else
                        "{" ++ rendered ++ "}"
            in
            " " ++ wrapper


{-| Returns the contents of an MLIR string literal for the text of a
`StringAttr`, which holds its escape sequences written out.

A `\uXXXX` escape becomes the character it names. The escapes `\n`, `\t`, `\"`
and `\\` are kept, and so is a `\u` not followed by four hexadecimal digits.
`\r` becomes `\0D`, MLIR's hexadecimal escape for a carriage return. Any other
escape loses its backslash, so `\'` becomes `'`. Last, a `"` that no backslash escapes, as the text of a
multi-line string can hold, gains one.

A character that a `\uXXXX` escape names is written as itself, except a
control character or a backslash, which becomes a two-hex-digit escape (see
`escapeCodePoint`); a `"` is escaped by the last step like any other. The two
`\uXXXX` escapes of a surrogate pair are converted one at a time.

-}
escapeForMlir : String -> String
escapeForMlir s =
    convertUnicodeEscapesToUtf8 s
        |> escapeUnescapedQuotes


{-| Returns `s` with a backslash put before each `"` that is not already
escaped. A `"` counts as escaped when an odd number of backslashes come
directly before it, so the `"` after `\\` gains a backslash.
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
                        go False ('"' :: acc) rest

                    else
                        go False ('"' :: '\\' :: acc) rest

                '\\' :: rest ->
                    go (not prevWasBackslash) ('\\' :: acc) rest

                c :: rest ->
                    go False (c :: acc) rest
    in
    go False [] (String.toList s)


{-| Returns `s` with each `\uXXXX` escape replaced by the character it names
(spelled by `escapeCodePoint`), `\r` replaced by `\0D`, the escapes `\n`, `\t`,
`\"` and `\\` kept as written, and the backslash dropped from any other escape.

A `\u` not followed by four hexadecimal digits is kept as written, and so is a
backslash at the very end of `s`. Despite the name, the result is characters,
not UTF-8 bytes.

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
                                        go (List.reverse (escapeCodePoint codePoint) ++ revAcc) afterHex

                                    Nothing ->
                                        go ('u' :: '\\' :: revAcc) afterU

                            else
                                go ('u' :: '\\' :: revAcc) afterU

                        Just ( 'r', afterEscape ) ->
                            -- MLIR has no `\r` escape; `\0D` is its two-hex-digit form.
                            go ('D' :: '0' :: '\\' :: revAcc) afterEscape

                        Just ( c, afterEscape ) ->
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


{-| Returns the characters that spell code point `cp`, named by a `\uXXXX`
escape, inside an MLIR string literal: the character itself, except that a
control character (below U+0020, or U+007F) and a backslash become MLIR's
two-hex-digit escape (`\0A`, `\5C`), which its lexer requires. A `"` is left
for `escapeUnescapedQuotes`.
-}
escapeCodePoint : Int -> List Char
escapeCodePoint cp =
    if cp < 0x20 || cp == 0x7F || cp == 0x5C then
        [ '\\', hexDigitChar (cp // 16), hexDigitChar (modBy 16 cp) ]

    else
        [ Char.fromCode cp ]


{-| Returns the upper-case hexadecimal digit for `n`, which is 0 to 15.
-}
hexDigitChar : Int -> Char
hexDigitChar n =
    if n < 10 then
        Char.fromCode (48 + n)

    else
        Char.fromCode (55 + n)


{-| Returns the number `s` spells in hexadecimal, in either case, or `Nothing`
if any character of it is not a hexadecimal digit. The empty string gives
`Just 0`; the caller passes exactly four characters.
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


{-| Returns the MLIR literal for an `f64` value, one that reads back as
exactly `f`.

A finite value is `String.fromFloat`'s text, the shortest decimal that reads
back as `f`, with `.0` put in when that text has no `.` (MLIR lexes a decimal
float only when it has one): `3` becomes `3.0` and `1e-7` becomes `1.0e-7`.
Negative zero prints as `-0.0`. NaN and the infinities, which have no decimal
spelling, print as MLIR's hexadecimal bit patterns: the canonical quiet NaN
`0x7FF8000000000000`, `0x7FF0000000000000` and `0xFFF0000000000000`.

-}
ppFloatLiteral : Float -> String
ppFloatLiteral f =
    if isNaN f then
        "0x7FF8000000000000"

    else if isInfinite f then
        if f > 0 then
            "0x7FF0000000000000"

        else
            "0xFFF0000000000000"

    else if f == 0 && 1 / f < 0 then
        "-0.0"

    else
        let
            str =
                String.fromFloat f
        in
        if String.contains "." str then
            str

        else
            case String.indexes "e" str of
                i :: _ ->
                    String.left i str ++ ".0" ++ String.dropLeft i str

                [] ->
                    str ++ ".0"


{-| Returns the MLIR spelling of an attribute's value.

A `StringAttr` is quoted, its text rewritten by `escapeForMlir`. An `IntAttr`
is followed by `: type` when it has a type, and a `TypedFloatAttr` always is;
`ppFloatLiteral` spells its value. An
`ArrayAttr (Just t)` prints as `array<t: ...>` (`array<t>` when empty) and an `ArrayAttr Nothing` as
`[...]`, with each element spelled by this function. A `SymbolRefAttr` gets
MLIR's leading `@`, a `UnitAttr` prints as `unit`, and a `VisibilityAttr`
of `Private` prints as the quoted string `"private"`.

-}
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
            ppFloatLiteral f ++ " : " ++ ppType t

        TypeAttr t ->
            ppType t

        ArrayAttr maybeType xs ->
            case maybeType of
                Just t ->
                    if List.isEmpty xs then
                        "array<" ++ ppType t ++ ">"

                    else
                        "array<" ++ ppType t ++ ": " ++ (xs |> List.map ppAttr |> String.join ", ") ++ ">"

                Nothing ->
                    "[" ++ (xs |> List.map ppAttr |> String.join ", ") ++ "]"

        SymbolRefAttr s ->
            "@" ++ s

        UnitAttr ->
            "unit"

        VisibilityAttr v ->
            case v of
                Private ->
                    "\"private\""
