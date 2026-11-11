module MlirBc exposing
    ( Attr(..), Type(..), Op, Region(..)
    , encode, printGeneric, typeText, attrText
    )

{-| A small generic MLIR IR, written as MLIR bytecode (`encode`) or as MLIR's generic text form
(`printGeneric`).

`encode` writes bytecode version 6, the version MLIR 24.0.0git (llvm-project `8d4fc8f1d17e`, the
commit MAX 26.7.0 pins) writes and reads; the format is `mlir/docs/BytecodeFormat.md`. Builtin
attributes and types use the builtin dialect's own encoding (`BuiltinDialectBytecode.td`, public
and stable). Every other dialect's attributes and types are stored as their text, MLIR's
assembly-format fallback, which a reader parses with the dialect's own parser: `mo` and `kgen`
encodings are private to MAX. Inherent attributes are given as ordinary attributes; for a
registered op the reader moves them into its properties.

Limits: every region is one block and isolated from above (each starts its own value numbering),
there are no successors, use-list orders, resources or locations other than `loc(unknown)`.

The bytes are a pure function of the IR: tables are numbered in first-use order. MAX's compile
cache keys on the file's bytes, so a graph that has not changed hits the cache.

-}

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Dict exposing (Dict)


type Type
    = IndexType
    | IntegerType Int
    | FunctionType (List Type) (List Type)
      -- Any other dialect's type, as its full text: "!mo.tensor<[2], si64>".
    | OpaqueType String


type Attr
    = StrAttr String
    | ArrayAttr (List Attr)
    | DictAttr (List ( String, Attr ))
    | IntAttr Int Type
    | TypeAttr Type
    | UnknownLoc
      -- Any other dialect's attribute, as its full text: "#kgen<param.decls[]>".
    | OpaqueAttr String


{-| An operation. `operands` are value numbers in the enclosing block: the block's arguments first,
then each op's results, in order.
-}
type alias Op =
    { name : String
    , attrs : List ( String, Attr )
    , results : List Type
    , operands : List Int
    , regions : List Region
    }


{-| A region of one block: the block's argument types and its ops.
-}
type Region
    = Region (List Type) (List Op)



-- TEXT


typeText : Type -> String
typeText t =
    case t of
        IndexType ->
            "index"

        IntegerType w ->
            "i" ++ String.fromInt w

        FunctionType ins outs ->
            "(" ++ String.join ", " (List.map typeText ins) ++ ") -> " ++ resultTypesText outs

        OpaqueType s ->
            s


{-| A result type list as MLIR prints it: a lone non-function type bare, anything else in parens.
-}
resultTypesText : List Type -> String
resultTypesText ts =
    case ts of
        [ t ] ->
            case t of
                FunctionType _ _ ->
                    "(" ++ typeText t ++ ")"

                _ ->
                    typeText t

        _ ->
            "(" ++ String.join ", " (List.map typeText ts) ++ ")"


attrText : Attr -> String
attrText a =
    case a of
        StrAttr s ->
            quoted s

        ArrayAttr l ->
            "[" ++ String.join ", " (List.map attrText l) ++ "]"

        DictAttr kvs ->
            "{" ++ String.join ", " (List.map (\( k, v ) -> key k ++ " = " ++ attrText v) (sortedEntries kvs)) ++ "}"

        IntAttr n t ->
            String.fromInt n ++ " : " ++ typeText t

        TypeAttr t ->
            typeText t

        UnknownLoc ->
            "loc(unknown)"

        OpaqueAttr s ->
            s


{-| MLIR keeps a dictionary sorted by name, so both writers emit it that way.
-}
sortedEntries : List ( String, Attr ) -> List ( String, Attr )
sortedEntries =
    List.sortBy Tuple.first


{-| A dictionary key: bare if it is an identifier, else quoted.
-}
key : String -> String
key k =
    let
        bare c =
            Char.isAlphaNum c || c == '_' || c == '$' || c == '.'
    in
    case String.uncons k of
        Just ( c, _ ) ->
            if (Char.isAlpha c || c == '_') && String.all bare k then
                k

            else
                quoted k

        Nothing ->
            quoted k


{-| A string literal: `"` and `\` and anything outside printable ASCII as MLIR's `\XX` escapes.
-}
quoted : String -> String
quoted s =
    let
        hex n =
            String.fromList [ hexDigit (n // 16), hexDigit (modBy 16 n) ]

        hexDigit d =
            String.toList "0123456789ABCDEF" |> List.drop d |> List.head |> Maybe.withDefault '0'

        esc c =
            let
                n =
                    Char.toCode c
            in
            if c == '"' || c == '\\' || n < 32 || n > 126 then
                -- Non-ASCII goes as its UTF-8 bytes.
                String.concat (List.map (\b -> "\\" ++ hex b) (utf8 n))

            else
                String.fromChar c
    in
    "\"" ++ String.concat (List.map esc (String.toList s)) ++ "\""


utf8 : Int -> List Int
utf8 n =
    if n < 128 then
        [ n ]

    else if n < 2048 then
        [ 192 + n // 64, 128 + modBy 64 n ]

    else if n < 65536 then
        [ 224 + n // 4096, 128 + modBy 64 (n // 64), 128 + modBy 64 n ]

    else
        [ 240 + n // 262144, 128 + modBy 64 (n // 4096), 128 + modBy 64 (n // 64), 128 + modBy 64 n ]


{-| The dialect of a dialect attribute's or type's text: `!mo.tensor<..>` and `#mosh<..>` give
`mo` and `mosh`.
-}
dialectOfText : String -> String
dialectOfText s =
    String.dropLeft 1 s
        |> String.toList
        |> takeWhile (\c -> c /= '.' && c /= '<')
        |> String.fromList


takeWhile : (a -> Bool) -> List a -> List a
takeWhile ok l =
    case l of
        x :: rest ->
            if ok x then
                x :: takeWhile ok rest

            else
                []

        [] ->
            []


attrDialect : Attr -> String
attrDialect a =
    case a of
        OpaqueAttr s ->
            dialectOfText s

        _ ->
            "builtin"


typeDialect : Type -> String
typeDialect t =
    case t of
        OpaqueType s ->
            dialectOfText s

        _ ->
            "builtin"


splitOpName : String -> ( String, String )
splitOpName name =
    case String.indexes "." name of
        i :: _ ->
            ( String.left i name, String.dropLeft (i + 1) name )

        [] ->
            ( name, "" )


module_ : List Op -> Op
module_ ops =
    { name = "builtin.module", attrs = [], results = [], operands = [], regions = [ Region [] ops ] }



-- GENERIC TEXT


{-| `ops` in a `builtin.module`, in MLIR's generic op form: what `mlir-opt --mlir-print-op-generic`
prints, give or take spacing and the names of values.
-}
printGeneric : List Op -> String
printGeneric ops =
    String.join "\n" (printOp "" [] 0 (module_ ops) |> Tuple.first) ++ "\n"


{-| Print `op` at `indent`; `scope` holds the names and types of the values numbered so far in the
enclosing block, and `next` the number its first result gets. Returns the lines and the scope after.
-}
printOp : String -> List ( String, Type ) -> Int -> Op -> ( List String, List ( String, Type ) )
printOp indent scope next op =
    let
        lookup i =
            List.drop i scope |> List.head |> Maybe.withDefault ( "%<bad " ++ String.fromInt i ++ ">", OpaqueType "none" )

        operands =
            List.map lookup op.operands

        resultNames =
            case op.results of
                [] ->
                    []

                [ _ ] ->
                    [ "%" ++ String.fromInt next ]

                _ ->
                    List.indexedMap (\i _ -> "%" ++ String.fromInt next ++ "#" ++ String.fromInt i) op.results

        lhs =
            case op.results of
                [] ->
                    ""

                [ _ ] ->
                    "%" ++ String.fromInt next ++ " = "

                _ ->
                    "%" ++ String.fromInt next ++ ":" ++ String.fromInt (List.length op.results) ++ " = "

        regionLines =
            List.concatMap (printBlock indent) op.regions

        attrs =
            if List.isEmpty op.attrs then
                ""

            else
                " " ++ attrText (DictAttr op.attrs)

        sig =
            " : (" ++ String.join ", " (List.map (Tuple.second >> typeText) operands) ++ ") -> " ++ resultTypesText op.results

        head =
            indent ++ lhs ++ quoted op.name ++ "(" ++ String.join ", " (List.map Tuple.first operands) ++ ")"

        lines =
            if List.isEmpty op.regions then
                [ head ++ attrs ++ sig ]

            else
                (head ++ " ({") :: regionLines ++ [ indent ++ "})" ++ attrs ++ sig ]
    in
    ( lines, scope ++ List.map2 Tuple.pair resultNames op.results )


printBlock : String -> Region -> List String
printBlock indent (Region argTypes ops) =
    let
        args =
            List.indexedMap (\i t -> ( "%arg" ++ String.fromInt i, t )) argTypes

        label =
            if List.isEmpty args then
                []

            else
                [ indent ++ "^bb0(" ++ String.join ", " (List.map (\( n, t ) -> n ++ ": " ++ typeText t) args) ++ "):" ]

        step op ( lines, scope, next ) =
            let
                ( opLines, scope2 ) =
                    printOp (indent ++ "  ") scope next op
            in
            ( lines ++ opLines, scope2, next + List.length op.results )

        ( body, _, _ ) =
            List.foldl step ( [], args, 0 ) ops
    in
    label ++ body



-- TABLES


{-| A table of distinct entries in first-use order, keyed by their text.
-}
type alias Table a =
    { index : Dict String Int, items : List a }


emptyTable : Table a
emptyTable =
    { index = Dict.empty, items = [] }


{-| Add an entry if new; the Bool says whether it was.
-}
insert : String -> a -> Table a -> ( Table a, Bool )
insert k v t =
    if Dict.member k t.index then
        ( t, False )

    else
        ( { index = Dict.insert k (Dict.size t.index) t.index, items = v :: t.items }, True )


entries : Table a -> List a
entries t =
    List.reverse t.items


type alias Tables =
    { dialects : Table String
    , strings : Table String
    , opNames : Table String
    , attrs : Table Attr
    , types : Table Type
    }


addString : String -> Tables -> Tables
addString s t =
    { t | strings = Tuple.first (insert s s t.strings) }


addDialect : String -> Tables -> Tables
addDialect d t =
    addString d { t | dialects = Tuple.first (insert d d t.dialects) }


addAttr : Attr -> Tables -> Tables
addAttr a t =
    let
        ( attrs, new ) =
            insert (attrText a) a t.attrs

        t1 =
            addDialect (attrDialect a) { t | attrs = attrs }
    in
    if not new then
        t

    else
        case a of
            StrAttr s ->
                addString s t1

            ArrayAttr l ->
                List.foldl addAttr t1 l

            DictAttr kvs ->
                List.foldl (\( k, v ) acc -> addAttr v (addAttr (StrAttr k) acc)) t1 (sortedEntries kvs)

            IntAttr _ ty ->
                addType ty t1

            TypeAttr ty ->
                addType ty t1

            UnknownLoc ->
                t1

            OpaqueAttr _ ->
                t1


addType : Type -> Tables -> Tables
addType ty t =
    let
        ( types, new ) =
            insert (typeText ty) ty t.types

        t1 =
            addDialect (typeDialect ty) { t | types = types }
    in
    if not new then
        t

    else
        case ty of
            FunctionType ins outs ->
                List.foldl addType t1 (ins ++ outs)

            _ ->
                t1


addOp : Op -> Tables -> Tables
addOp op t =
    let
        ( dialect, short ) =
            splitOpName op.name

        t1 =
            addString short (addDialect dialect { t | opNames = Tuple.first (insert op.name op.name t.opNames) })

        t2 =
            addAttr UnknownLoc t1

        t3 =
            if List.isEmpty op.attrs then
                t2

            else
                addAttr (DictAttr op.attrs) t2

        t4 =
            List.foldl addType t3 op.results
    in
    List.foldl (\(Region args ops) acc -> List.foldl addOp (List.foldl addType acc args) ops) t4 op.regions


{-| The final numbering: attributes, types and op names grouped by dialect (in dialect order), first
use first within a group, as the offset and dialect sections require.
-}
type alias Numbering =
    { dialects : List String
    , dialectIdx : Dict String Int
    , stringIdx : Dict String Int
    , strings : List String
    , opNames : List ( String, List String ) -- by dialect
    , opIdx : Dict String Int
    , attrs : List ( String, List Attr )
    , attrIdx : Dict String Int
    , types : List ( String, List Type )
    , typeIdx : Dict String Int
    }


grouped : List String -> (a -> String) -> (a -> String) -> List a -> ( List ( String, List a ), Dict String Int )
grouped dialects dialectOf keyOf items =
    let
        groups =
            List.filterMap
                (\d ->
                    case List.filter (\x -> dialectOf x == d) items of
                        [] ->
                            Nothing

                        xs ->
                            Just ( d, xs )
                )
                dialects

        index =
            List.indexedMap (\i x -> ( keyOf x, i )) (List.concatMap Tuple.second groups) |> Dict.fromList
    in
    ( groups, index )


number : Tables -> Numbering
number t =
    let
        dialects =
            entries t.dialects

        ( opNames, opIdx ) =
            grouped dialects (splitOpName >> Tuple.first) identity (entries t.opNames)

        ( attrs, attrIdx ) =
            grouped dialects attrDialect attrText (entries t.attrs)

        ( types, typeIdx ) =
            grouped dialects typeDialect typeText (entries t.types)
    in
    { dialects = dialects
    , dialectIdx = t.dialects.index
    , stringIdx = t.strings.index
    , strings = entries t.strings
    , opNames = opNames
    , opIdx = opIdx
    , attrs = attrs
    , attrIdx = attrIdx
    , types = types
    , typeIdx = typeIdx
    }



-- PRIMITIVES


u8 : Int -> E.Encoder
u8 =
    E.unsignedInt8


{-| MLIR's PrefixVarInt: the count of trailing zero bits in the first byte is the number of extra
bytes; the value fills the bits above. Arithmetic only (no Bitwise), so it stays exact on the JS
backend; values here are table indices and section sizes, far below 2^49.
-}
varint : Int -> E.Encoder
varint v =
    let
        n =
            byteCount v 1

        low =
            2 ^ (8 - n)

        rest k w =
            if k == 0 then
                []

            else
                u8 (modBy 256 w) :: rest (k - 1) (w // 256)
    in
    E.sequence (u8 (modBy low v * 2 ^ n + 2 ^ (n - 1)) :: rest (n - 1) (v // low))


byteCount : Int -> Int -> Int
byteCount v n =
    if n < 8 && v >= 2 ^ (7 * n) then
        byteCount v (n + 1)

    else
        n


varintFlag : Int -> Bool -> E.Encoder
varintFlag v flag =
    varint
        (v
            * 2
            + (if flag then
                1

               else
                0
              )
        )


{-| Zigzag: 0, -1, 1, -2 ... become 0, 1, 2, 3 ...
-}
signedVarint : Int -> E.Encoder
signedVarint v =
    if v >= 0 then
        varint (2 * v)

    else
        varint (-2 * v - 1)


cstring : String -> E.Encoder
cstring s =
    E.sequence [ E.string s, u8 0 ]


{-| A section: its id (no alignment needed, so the high bit is clear), its size, its contents. The
contents are encoded once, to learn their size.
-}
section : Int -> E.Encoder -> E.Encoder
section id body =
    let
        bytes =
            E.encode body
    in
    E.sequence [ u8 id, varint (Bytes.width bytes), E.bytes bytes ]


width : E.Encoder -> Int
width e =
    Bytes.width (E.encode e)


list : (a -> E.Encoder) -> List a -> E.Encoder
list f xs =
    E.sequence (varint (List.length xs) :: List.map f xs)


idx : Dict String Int -> String -> Int
idx d k =
    Maybe.withDefault 0 (Dict.get k d)



-- BYTECODE


{-| `ops` in a `builtin.module`, as MLIR bytecode.
-}
encode : List Op -> Bytes
encode ops =
    let
        root =
            module_ ops

        nb =
            number (addOp root { dialects = emptyTable, strings = emptyTable, opNames = emptyTable, attrs = emptyTable, types = emptyTable })

        ( attrTypeBody, offsets ) =
            attrTypeSections nb
    in
    E.encode
        (E.sequence
            [ E.sequence (List.map u8 [ 0x4D, 0x4C, 0xEF, 0x52 ])
            , varint 6
            , cstring "eco MlirBc"
            , section 1 (dialectSection nb)
            , section 3 offsets
            , section 2 attrTypeBody
            , section 4 (E.sequence [ varintFlag 1 False, encodeOp nb root ])
            , section 0 (stringSection nb)

            -- Required from version 5 on, even when empty: no op here has native properties.
            , section 8 (varint 0)
            ]
        )


stringSection : Numbering -> E.Encoder
stringSection nb =
    E.sequence
        [ varint (List.length nb.strings)
        , E.sequence (List.map (\s -> varint (E.getStringWidth s + 1)) (List.reverse nb.strings))
        , E.sequence (List.map cstring nb.strings)
        ]


dialectSection : Numbering -> E.Encoder
dialectSection nb =
    E.sequence
        [ list (\d -> varintFlag (idx nb.stringIdx d) False) nb.dialects
        , varint (List.length (List.concatMap Tuple.second nb.opNames))
        , E.sequence
            (List.map
                (\( d, names ) ->
                    E.sequence
                        [ varint (idx nb.dialectIdx d)
                        , list (\n -> varintFlag (idx nb.stringIdx (Tuple.second (splitOpName n))) False) names
                        ]
                )
                nb.opNames
            )
        ]


{-| The attribute/type section and its offset section: each entry's size, and whether it uses a
custom (here: builtin) encoding rather than text.
-}
attrTypeSections : Numbering -> ( E.Encoder, E.Encoder )
attrTypeSections nb =
    let
        entry encodeCustom text item =
            case encodeCustom item of
                Just e ->
                    ( e, True )

                Nothing ->
                    ( cstring (text item), False )

        groups encodeCustom text gs =
            List.map
                (\( d, items ) -> ( d, List.map (entry encodeCustom text) items ))
                gs

        attrGroups =
            groups (builtinAttr nb) attrText nb.attrs

        typeGroups =
            groups (builtinType nb) typeText nb.types

        offsetGroup ( d, es ) =
            E.sequence
                [ varint (idx nb.dialectIdx d)
                , list (\( e, custom ) -> varintFlag (width e) custom) es
                ]

        body gs =
            List.concatMap (Tuple.second >> List.map Tuple.first) gs
    in
    ( E.sequence (body attrGroups ++ body typeGroups)
    , E.sequence
        [ varint (List.length (List.concatMap Tuple.second nb.attrs))
        , varint (List.length (List.concatMap Tuple.second nb.types))
        , E.sequence (List.map offsetGroup attrGroups)
        , E.sequence (List.map offsetGroup typeGroups)
        ]
    )


{-| The builtin dialect's encoding: a kind code (its position in `BuiltinDialectAttributes`), then
the fields; attributes, types and strings are table indices.
-}
builtinAttr : Numbering -> Attr -> Maybe E.Encoder
builtinAttr nb a =
    let
        attrRef x =
            varint (idx nb.attrIdx (attrText x))

        typeRef x =
            varint (idx nb.typeIdx (typeText x))
    in
    case a of
        ArrayAttr l ->
            Just (E.sequence [ varint 0, list attrRef l ])

        DictAttr kvs ->
            Just (E.sequence [ varint 1, list (\( k, v ) -> E.sequence [ attrRef (StrAttr k), attrRef v ]) (sortedEntries kvs) ])

        StrAttr s ->
            Just (E.sequence [ varint 2, varint (idx nb.stringIdx s) ])

        TypeAttr t ->
            Just (E.sequence [ varint 6, typeRef t ])

        IntAttr n t ->
            -- The value's width is the type's: index is 64 bits; up to 8 bits is one raw byte.
            case t of
                IntegerType w ->
                    if w <= 8 then
                        Just (E.sequence [ varint 8, typeRef t, u8 (modBy 256 n) ])

                    else if w <= 64 then
                        Just (E.sequence [ varint 8, typeRef t, signedVarint n ])

                    else
                        Nothing

                IndexType ->
                    Just (E.sequence [ varint 8, typeRef t, signedVarint n ])

                _ ->
                    Nothing

        UnknownLoc ->
            Just (varint 15)

        OpaqueAttr _ ->
            Nothing


builtinType : Numbering -> Type -> Maybe E.Encoder
builtinType nb t =
    let
        typeRef x =
            varint (idx nb.typeIdx (typeText x))
    in
    case t of
        IntegerType w ->
            -- width << 2 | signedness; 0 is signless.
            Just (E.sequence [ varint 0, varint (w * 4) ])

        IndexType ->
            Just (varint 1)

        FunctionType ins outs ->
            Just (E.sequence [ varint 2, list typeRef ins, list typeRef outs ])

        OpaqueType _ ->
            Nothing


encodeOp : Numbering -> Op -> E.Encoder
encodeOp nb op =
    let
        has cond bit =
            if cond then
                bit

            else
                0

        hasAttrs =
            not (List.isEmpty op.attrs)

        mask =
            has hasAttrs 1 + has (not (List.isEmpty op.results)) 2 + has (not (List.isEmpty op.operands)) 4 + has (not (List.isEmpty op.regions)) 16

        optional cond e =
            if cond then
                e

            else
                E.sequence []
    in
    E.sequence
        [ varint (idx nb.opIdx op.name)
        , u8 mask
        , varint (idx nb.attrIdx (attrText UnknownLoc))
        , optional hasAttrs (varint (idx nb.attrIdx (attrText (DictAttr op.attrs))))
        , optional (not (List.isEmpty op.results)) (list (\t -> varint (idx nb.typeIdx (typeText t))) op.results)
        , optional (not (List.isEmpty op.operands)) (list varint op.operands)
        , optional (not (List.isEmpty op.regions))
            (E.sequence
                [ varintFlag (List.length op.regions) True
                , section 4 (E.sequence (List.map (encodeRegion nb) op.regions))
                ]
            )
        ]


{-| A one-block region: block count, the number of values it defines, then the block.
-}
encodeRegion : Numbering -> Region -> E.Encoder
encodeRegion nb (Region args ops) =
    let
        hasArgs =
            not (List.isEmpty args)

        numValues =
            List.length args + List.sum (List.map (.results >> List.length) ops)
    in
    E.sequence
        [ varint 1
        , varint numValues
        , varintFlag (List.length ops) hasArgs
        , if hasArgs then
            -- Each argument: its type, flag clear (unknown location); then an empty use-list mask.
            E.sequence [ list (\t -> varintFlag (idx nb.typeIdx (typeText t)) False) args, u8 0 ]

          else
            E.sequence []
        , E.sequence (List.map (encodeOp nb) ops)
        ]
