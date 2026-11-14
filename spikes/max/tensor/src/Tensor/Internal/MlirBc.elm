module Tensor.Internal.MlirBc exposing
    ( Attr(..)
    , Op
    , Region(..)
    , Type(..)
    , attrText
    , encode
    , outer
    , printGeneric
    , typeText
    , unboundOperands
    )

{-| An MLIR module written from Elm, with no MLIR library: a small IR for MLIR operations and two
writers for it. `encode` writes MLIR bytecode, the binary form MLIR loads; `printGeneric` writes the
same module as text, for reading.

In MLIR a program is a tree of _operations_ (ops). An op has a name such as `mo.add`, whose part
before the first dot is its _dialect_; it has named attributes, the types of the values it
produces, the values it reads (its _operands_) and the _regions_ it holds. A region holds blocks of
further ops, and here every region is exactly one block. A block's _values_ are its arguments and
its ops' results, and an operand names one of them by its _value number_: the block's arguments
from 0, then each op's results in order.

A region is either isolated from above (`Region`), when its ops read only their own block's values,
or an _open region_ (`OpenRegion`), whose ops may also read values of the regions enclosing it, up
to the nearest isolated one, written as _negative operands_: `outer v` names what operand `v` names
in the region immediately enclosing it, so a value `d` regions out is `outer` applied `d` times to
its number there. Before writing, both writers turn every operand into the absolute numbering
bytecode uses, in which an isolated region counts from 0 and an open region carries on after the
values of the regions around it.

The IR describes structurally only a few builtin types and attributes: integer, index and function
types, and string, array, dictionary, integer, type, unit, symbol-reference and location
attributes. Any other attribute or type (`OpaqueAttr`, `OpaqueType`) is carried as its text, which
bytecode allows in place of a binary encoding; `encode` assumes the reader parses that text as it
would parse it in MLIR's text form. So this module knows no dialect but the builtin one. Every
attribute of an op goes in `attrs`, including those the op's own definition declares (MLIR's
_inherent_ attributes).

`encode` writes bytecode version 6, assuming that the MLIR that MAX 26.7.0 is built on reads it.
Bytecode refers to every dialect, op name, string, attribute and type by its index in a _table_,
and most of the bytecode half of this file is that bookkeeping: collecting the tables from the IR,
numbering them, and writing each reference as an index. A table entry is identified by its text
(`attrText`, `typeText`), so an attribute used many times is stored once.

What `encode` writes depends on the IR alone: there is no timestamp, every location is
`loc(unknown)`, and the tables are numbered in the order their entries are first used (attributes,
types and op names grouped by dialect). Equal IR therefore gives equal bytes.

`printGeneric` writes MLIR's _generic text_, the one form MLIR reads for an op of any dialect: the
op's quoted name, its operands, its regions, its attribute dictionary and its type signature, as
in `%2 = "mo.add"(%0, %1) : (...) -> ...`.

`unboundOperands` checks what neither writer checks: that every operand names a value visible
where it is read.

Neither writer supports a region of more than one block, successors, use-list orders, resources,
or a location other than `loc(unknown)`.

-}

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Dict exposing (Dict)
import Set exposing (Set)


{-| An MLIR type: one of the few builtin types the writers encode themselves, or any other type as
its text.

`IntegerType w` is the signless integer type of `w` bits (`i32`), and `SignedIntegerType w` the
signed one (`si64`). `IndexType` is MLIR's `index`. `FunctionType` takes the argument types, then
the result types.

`OpaqueType` carries the full text of any other type, such as `!mo.tensor<[2], si64>`, and is
written as that text. Its dialect is read from the text: the name after its first character (the
`!`), up to the first `.` or `<`. Text that does not start with `!` is read the same way: `f32`
gives `32`, which is no dialect, and `encode` files the type under it in its tables all the same.

-}
type Type
    = IndexType
    | IntegerType Int
    | SignedIntegerType Int
    | FunctionType (List Type) (List Type)
    | OpaqueType String


{-| An MLIR attribute: one of the builtin attributes the writers encode themselves, or any other
attribute as its text.

`StrAttr` and `ArrayAttr` are a string and a list of attributes. `DictAttr`'s entries may be given
in any order: both writers sort them by key, so, when the keys are distinct, the order makes no
difference to what is written. `TypeAttr` holds a type as an attribute value. `UnknownLoc` is the
location `loc(unknown)`, which `encode` gives every op. `UnitAttr` carries no value; its presence
under a name is its meaning. `SymbolRefAttr name` refers to the symbol `name` and is printed
`@name`.

`IntAttr n t` is the integer `n` of type `t`. It has a binary encoding when `t` is `IndexType`, a
`SignedIntegerType`, or a signless `IntegerType` of at most 64 bits; with any other type it is
written as its text, `n : t`. In the binary encoding a type of at most 8 bits holds `n` modulo 256.

`OpaqueAttr` carries the full text of any other attribute, such as `#kgen<param.decls[]>` or a
builtin attribute the IR does not model, such as `true`, and is written as that text. Its dialect
is read from the text: the name after its first character, up to the first `.` or `<`. For text
that starts with neither `#` nor `!`, such as `true`, that name is no dialect (`rue`), and `encode`
files the attribute under it in its tables all the same.

-}
type Attr
    = StrAttr String
    | ArrayAttr (List Attr)
    | DictAttr (List ( String, Attr ))
    | IntAttr Int Type
    | TypeAttr Type
    | UnknownLoc
    | UnitAttr
    | SymbolRefAttr String
    | OpaqueAttr String


{-| One MLIR operation.

`name` is the op's full name, such as `mo.add`; everything before its first dot is taken as its
dialect. `attrs` holds every attribute, inherent ones included, in any order. `operands` are value
numbers in the region holding the op, as `Region` describes.

-}
type alias Op =
    { name : String
    , attrs : List ( String, Attr )
    , results : List Type
    , operands : List Int
    , regions : List Region
    }


{-| A region of one block: the block's argument types and its ops.

The block's values are numbered from 0: its arguments first, then the results of its ops, in
order. An op's operands name values by these numbers.

A `Region` is isolated from above: its ops read only values of its own block, and a negative
operand in it is left unresolved. Its values are numbered from 0 in the absolute numbering too.
When every region of an op is a `Region`, `encode` writes them in a nested section of their own.

An `OpenRegion` may also read values of the regions enclosing it, up to the nearest isolated one,
as negative operands: `outer v` names, in the open region, what operand `v` names in the region
immediately enclosing it, `v` being that region's own value when not negative and a value further
out when negative. In the absolute numbering an open region's values come after all the values of
the regions enclosing it, up to the nearest isolated one. An op with any `OpenRegion` has all its
regions written inline, in the op's own value scope. Mixing the two in one op is not supported: its
`Region`s are still numbered from 0, though written in that scope.

-}
type Region
    = Region (List Type) (List Op)
    | OpenRegion (List Type) (List Op)



-- TEXT


{-| Returns a type's MLIR text: `index`, `i32`, `si64`, `(i32) -> si64`, or an opaque type's own
text. The text is also the type's identity in `encode`'s tables.
-}
typeText : Type -> String
typeText t =
    case t of
        IndexType ->
            "index"

        IntegerType w ->
            "i" ++ String.fromInt w

        SignedIntegerType w ->
            "si" ++ String.fromInt w

        FunctionType ins outs ->
            "(" ++ String.join ", " (List.map typeText ins) ++ ") -> " ++ resultTypesText outs

        OpaqueType s ->
            s


{-| Returns the text of a list of result types: a single type other than a function type bare,
anything else in parentheses.
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


{-| Returns an attribute's MLIR text, which is also its identity in `encode`'s tables.

A dictionary's entries are sorted by key, and a key is quoted unless it is an identifier. A string
is quoted, with MLIR's escapes. A symbol reference is `@name`, with the name never quoted.

-}
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

        UnitAttr ->
            "unit"

        SymbolRefAttr name ->
            "@" ++ name

        OpaqueAttr s ->
            s


{-| Returns a dictionary's entries sorted by key, the order MLIR keeps a dictionary attribute in.
Both writers use it, so entries with distinct keys give the same text and bytes in any order.
-}
sortedEntries : List ( String, Attr ) -> List ( String, Attr )
sortedEntries =
    List.sortBy Tuple.first


{-| Returns a dictionary key as MLIR text: bare when it is an identifier (an ASCII letter or `_`,
then letters, digits, `_`, `$` or `.`), quoted otherwise.
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


{-| Returns `s` as an MLIR string literal: in double quotes, with `"`, `\` and every character
outside printable ASCII written as the `\XX` escapes of its UTF-8 bytes.
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
                String.concat (List.map (\b -> "\\" ++ hex b) (utf8 n))

            else
                String.fromChar c
    in
    "\"" ++ String.concat (List.map esc (String.toList s)) ++ "\""


{-| Returns the UTF-8 bytes of the character whose code point is `n`.
-}
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


{-| Returns the dialect named by an attribute's or type's text: what follows its first character, up
to the first `.` or `<`. `!mo.tensor<..>` and `#mosh<..>` give `mo` and `mosh`. Text that does not
start with `#` or `!` gives a name that is no dialect: `true` gives `rue`.
-}
dialectOfText : String -> String
dialectOfText s =
    String.dropLeft 1 s
        |> String.toList
        |> takeWhile (\c -> c /= '.' && c /= '<')
        |> String.fromList


{-| Returns the longest prefix of `l` whose elements all satisfy `ok`.
-}
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


{-| Returns the dialect an attribute is filed under in the tables: read from the text of an opaque
attribute, `builtin` for every other.
-}
attrDialect : Attr -> String
attrDialect a =
    case a of
        OpaqueAttr s ->
            dialectOfText s

        _ ->
            "builtin"


{-| Returns the dialect a type is filed under in the tables: read from the text of an opaque type,
`builtin` for every other.
-}
typeDialect : Type -> String
typeDialect t =
    case t of
        OpaqueType s ->
            dialectOfText s

        _ ->
            "builtin"


{-| Splits an op's full name at its first dot into its dialect and its name within the dialect:
`rmo.mo.reduce.max` gives `rmo` and `mo.reduce.max`. A name without a dot is all dialect.
-}
splitOpName : String -> ( String, String )
splitOpName name =
    case String.indexes "." name of
        i :: _ ->
            ( String.left i name, String.dropLeft (i + 1) name )

        [] ->
            ( name, "" )


{-| Wraps `ops` in a `builtin.module` op, whose one region is isolated and has no arguments.
-}
module_ : List Op -> Op
module_ ops =
    { name = "builtin.module", attrs = [], results = [], operands = [], regions = [ Region [] ops ] }



-- GENERIC TEXT


{-| Writes `ops`, wrapped in a `builtin.module`, as MLIR generic text.

A value is named by its absolute number: `%N` for the single result of an op, `%N#i` for result `i`
of an op with several (declared together as `%N:k`), and `%argN` for a block argument. An isolated
region numbers its values from 0, so names repeat from one isolated region to the next. An operand
that names no value visible where it is used is printed as `%<bad N>`, with type `none`. Locations
are not printed.

-}
printGeneric : List Op -> String
printGeneric ops =
    String.join "\n" (printOp "" Dict.empty 0 ( 0, 0 ) (absolutize (module_ ops)) |> Tuple.first) ++ "\n"


{-| Prints `op` at `indent`, its operands already absolute, and returns its lines together with
`scope` extended by its results.

`scope` maps the absolute number of each value visible to the op to its name and type. `next` is
the number of the op's first result. `( homeBase, homeCount )` are the first number and the value
count of the region holding the op; an open region of the op numbers its values after them.

-}
printOp : String -> Dict Int ( String, Type ) -> Int -> ( Int, Int ) -> Op -> ( List String, Dict Int ( String, Type ) )
printOp indent scope next ( homeBase, homeCount ) op =
    let
        lookup i =
            Dict.get i scope |> Maybe.withDefault ( "%<bad " ++ String.fromInt i ++ ">", OpaqueType "none" )

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

        nested r =
            case r of
                Region _ _ ->
                    printBlock indent Dict.empty 0 r

                OpenRegion _ _ ->
                    printBlock indent scope (homeBase + homeCount) r

        regionLines =
            List.concat (List.intersperse [ indent ++ "}, {" ] (List.map nested op.regions))

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

        newScope =
            List.foldl (\( i, nt ) acc -> Dict.insert (next + i) nt acc) scope (List.indexedMap Tuple.pair (List.map2 Tuple.pair resultNames op.results))
    in
    ( lines, newScope )


{-| Prints a region's block, numbering its values from `base`, where `visible` holds the values of
enclosing regions that its ops may read. The arguments are declared in a `^bb0(...)` label, which is
left out when there are none.
-}
printBlock : String -> Dict Int ( String, Type ) -> Int -> Region -> List String
printBlock indent visible base region =
    let
        count =
            localCount (regionArgs region) (regionOps region)

        args =
            List.indexedMap (\i t -> ( base + i, ( "%arg" ++ String.fromInt (base + i), t ) )) (regionArgs region)

        label =
            if List.isEmpty args then
                []

            else
                [ indent ++ "^bb0(" ++ String.join ", " (List.map (\( _, ( n, t ) ) -> n ++ ": " ++ typeText t) args) ++ "):" ]

        step op ( lines, scope, next ) =
            let
                ( opLines, scope2 ) =
                    printOp (indent ++ "  ") scope next ( base, count ) op
            in
            ( lines ++ opLines, scope2, next + List.length op.results )

        ( body, _, _ ) =
            List.foldl step ( [], List.foldl (\( i, nt ) acc -> Dict.insert i nt acc) visible args, base + List.length args ) (regionOps region)
    in
    label ++ body


{-| Returns the argument types of a region's block.
-}
regionArgs : Region -> List Type
regionArgs r =
    case r of
        Region a _ ->
            a

        OpenRegion a _ ->
            a


{-| Returns the ops of a region's block.
-}
regionOps : Region -> List Op
regionOps r =
    case r of
        Region _ o ->
            o

        OpenRegion _ o ->
            o


{-| Tells whether a region is isolated from above (a `Region`) rather than open.
-}
isIsolated : Region -> Bool
isIsolated r =
    case r of
        Region _ _ ->
            True

        OpenRegion _ _ ->
            False


{-| Returns how many values a block with these arguments and ops defines: one per argument and one
per op result. Values defined inside the ops' own regions are not counted.
-}
localCount : List Type -> List Op -> Int
localCount args ops =
    List.length args + List.sum (List.map (.results >> List.length) ops)


{-| Returns `root` with every operand, at every depth, rewritten from the numbering `Region`
describes into the absolute numbering bytecode uses. An isolated region numbers its values from 0.
An open region numbers its values after all the values of the regions enclosing it, up to the
nearest isolated one; the open regions of one op all start at the same number.
-}
absolutize : Op -> Op
absolutize root =
    absOp (Ctx 0 Nothing) 0 root


{-| Where a region's values start in the absolute numbering, for resolving its operands.

`Ctx base parent` holds the absolute number of the region's first value and, for an open region,
the context of the region enclosing it. An isolated region has no parent.

-}
type Ctx
    = Ctx Int (Maybe Ctx)


{-| Returns the operand by which an open region names what operand `v` names in the region
immediately enclosing it (`Region`). The result is always negative: `-(1 + 2 * v)` for a
non-negative `v`, a value of the enclosing region itself, and `2 * v` for a negative `v`, a value
further out. So `outer` gives every operand of the enclosing region its own negative operand, and
applied `d` times it reaches `d` regions out.
-}
outer : Int -> Int
outer v =
    if v >= 0 then
        -(1 + 2 * v)

    else
        2 * v


{-| Returns the operand `v` that `outer` turns into the negative operand `o`.
-}
fromOuter : Int -> Int
fromOuter o =
    if modBy 2 o == 1 then
        (-o - 1) // 2

    else
        o // 2


{-| Returns the absolute number of operand `v` of a region with context `ctx`.

A non-negative `v` is the region's own value `v`. A negative `v` is resolved, as the operand
`outer` turned into `v`, in the context of the enclosing region, and so on outwards. With no
enclosing region, a negative `v` is returned unchanged.

-}
resolve : Ctx -> Int -> Int
resolve (Ctx base parent) v =
    if v >= 0 then
        base + v

    else
        case parent of
            Just p ->
                resolve p (fromOuter v)

            Nothing ->
                v


{-| Rewrites the operands of `op`, and of every op in its regions, to absolute numbers. `ctx` is the
context of the region holding `op`, and `homeCount` the number of values that region defines, after
which the op's open regions number their values.
-}
absOp : Ctx -> Int -> Op -> Op
absOp ((Ctx base _) as ctx) homeCount op =
    { op | operands = List.map (resolve ctx) op.operands, regions = List.map (absRegion ctx (base + homeCount)) op.regions }


{-| Rewrites the operands of a region's ops to absolute numbers. An isolated region numbers its
values from 0; an open one numbers them from `innerBase` and resolves its negative operands in
`parentCtx`, the context of the region enclosing it.
-}
absRegion : Ctx -> Int -> Region -> Region
absRegion parentCtx innerBase region =
    case region of
        Region args ops ->
            Region args (List.map (absOp (Ctx 0 Nothing) (localCount args ops)) ops)

        OpenRegion args ops ->
            OpenRegion args (List.map (absOp (Ctx innerBase (Just parentCtx)) (localCount args ops)) ops)



-- CHECKING


{-| Returns each operand in `ops`, at any depth of regions, that names no value visible where it is
read, as the name of the op that reads it and the operand in the absolute numbering; `[]` when
every operand names one. The ops are wrapped in a `builtin.module` and their operands made absolute
as both writers do.

A value is visible to an op when it is an argument of the op's block or a result of an op before it
in that block, or, when the block is an open region's, when it is visible to the op holding that
region. Such an operand is what `printGeneric` writes as `%<bad N>`, and what `encode` writes as a
value number that names another value or none.

-}
unboundOperands : List Op -> List ( String, Int )
unboundOperands ops =
    List.concat (List.reverse (opUnbound Set.empty 0 (absolutize (module_ ops)) []))


{-| Adds to `found` the unbound operands of `op` and of the ops in its regions, each group in front.
`visible` holds the absolute numbers of the values visible to `op`, and `innerBase` is the number of
the first value of its open regions.
-}
opUnbound : Set Int -> Int -> Op -> List (List ( String, Int )) -> List (List ( String, Int ))
opUnbound visible innerBase op found =
    List.foldl (regionUnbound visible innerBase)
        (List.filterMap
            (\v ->
                if Set.member v visible then
                    Nothing

                else
                    Just ( op.name, v )
            )
            op.operands
            :: found
        )
        op.regions


{-| Adds to `found` the unbound operands of the ops of `region`, held by an op to which the values
in `visible` are visible. An isolated region numbers its values from 0 and sees nothing outside it;
an open one numbers them from `innerBase` and also sees `visible`.
-}
regionUnbound : Set Int -> Int -> Region -> List (List ( String, Int )) -> List (List ( String, Int ))
regionUnbound visible innerBase region found =
    let
        ( base, outside ) =
            if isIsolated region then
                ( 0, Set.empty )

            else
                ( innerBase, visible )

        args =
            regionArgs region

        ops =
            regionOps region

        nested =
            base + localCount args ops

        withRange first n set =
            List.foldl Set.insert set (List.range first (first + n - 1))

        step op ( seen, next, acc ) =
            ( withRange next (List.length op.results) seen
            , next + List.length op.results
            , opUnbound seen nested op acc
            )

        ( _, _, result ) =
            List.foldl step ( withRange base (List.length args) outside, base + List.length args, found ) ops
    in
    result



-- TABLES


{-| A table of distinct entries in first-use order, each identified by its text.

`index` maps an entry's text to its position in first-use order. `items` holds the entries newest
first; `entries` gives them in first-use order.

-}
type alias Table a =
    { index : Dict String Int, items : List a }


{-| A table with no entries.
-}
emptyTable : Table a
emptyTable =
    { index = Dict.empty, items = [] }


{-| Adds `v` under the text `k`, unless the table already has an entry with that text, which is then
kept. Returns the table and whether `v` was added.
-}
insert : String -> a -> Table a -> ( Table a, Bool )
insert k v t =
    if Dict.member k t.index then
        ( t, False )

    else
        ( { index = Dict.insert k (Dict.size t.index) t.index, items = v :: t.items }, True )


{-| Returns a table's entries in first-use order.
-}
entries : Table a -> List a
entries t =
    List.reverse t.items


{-| The tables `encode` collects from the IR before numbering them. `strings` holds every string the
bytecode refers to: dialect names and op names within their dialects, as well as string attributes,
dictionary keys and symbol names. `opNames` holds full op names.
-}
type alias Tables =
    { dialects : Table String
    , strings : Table String
    , opNames : Table String
    , attrs : Table Attr
    , types : Table Type
    }


{-| Adds a string to the string table.
-}
addString : String -> Tables -> Tables
addString s t =
    { t | strings = Tuple.first (insert s s t.strings) }


{-| Adds a dialect to the dialect table, and its name to the string table.
-}
addDialect : String -> Tables -> Tables
addDialect d t =
    addString d { t | dialects = Tuple.first (insert d d t.dialects) }


{-| Adds an attribute to the tables. The first time its text is seen, its dialect and everything its
binary encoding refers to are added too: the strings, attributes and types inside it. The text of
an opaque attribute is not looked into.
-}
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

            UnitAttr ->
                t1

            SymbolRefAttr name ->
                addAttr (StrAttr name) t1

            OpaqueAttr _ ->
                t1


{-| Adds a type to the tables. The first time its text is seen, its dialect is added too, and for a
function type its argument and result types.
-}
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


{-| Adds everything `op` and the ops in its regions refer to, in the order first use is counted in:
the op's name, with its dialect and its name within the dialect; the location `loc(unknown)`; its
attribute dictionary, when it has attributes; its result types; then, region by region, the block's
argument types and its ops.
-}
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
    List.foldl (\r acc -> List.foldl addOp (List.foldl addType acc (regionArgs r)) (regionOps r)) t4 op.regions


{-| The tables in their final order, with the index of each entry, which is how the bytecode refers
to it.

Dialects and strings are in first-use order. `opNames`, `attrs` and `types` are lists of groups, one
per dialect that has entries, each with the dialect's name; the groups follow the dialects' order,
and entries within a group are in first-use order. They are grouped because the dialect and offset
sections list entries one dialect at a time, and an entry's index is its position in that listing.
Each `...Idx` dictionary is keyed by an entry's text.

-}
type alias Numbering =
    { dialects : List String
    , dialectIdx : Dict String Int
    , stringIdx : Dict String Int
    , strings : List String
    , opNames : List ( String, List String )
    , opIdx : Dict String Int
    , attrs : List ( String, List Attr )
    , attrIdx : Dict String Int
    , types : List ( String, List Type )
    , typeIdx : Dict String Int
    }


{-| Groups `items` by dialect, the groups in the order of `dialects` and the items of each group in
their order in `items`, and numbers the items through the groups in that order, keyed by `keyOf`.
A dialect with no items gets no group.
-}
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


{-| Gives the collected tables their final order and indices, as `Numbering` describes.
-}
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


{-| Writes an `Int` as one unsigned byte.
-}
u8 : Int -> E.Encoder
u8 =
    E.unsignedInt8


{-| Writes a non-negative integer in MLIR's PrefixVarInt form: the number of trailing zero bits in
the first byte is the number of bytes that follow, then comes a 1 bit, and the value fills the bits
above that, low bits first.

Table indices, value numbers, counts, sizes and zigzagged integers (`signedVarint`) are all written
this way. At most 8 bytes are written, so a value is exact only below 2⁵⁶, and a negative value is
written wrongly. The arithmetic avoids `Bitwise`, which is 32-bit under JavaScript, but `//`
truncates to 32 bits there too, so under JavaScript a value is exact below 2³⁴, where the first
quotient (`v // low`) still fits, and not dependably above it.

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


{-| Returns how many bytes `varint` uses for `v`, counting up from `n`: the fewest whose 7 value
bits per byte hold `v`, but never more than 8.
-}
byteCount : Int -> Int -> Int
byteCount v n =
    if n < 8 && v >= 2 ^ (7 * n) then
        byteCount v (n + 1)

    else
        n


{-| Writes `v` with a one-bit flag below it, as the varint `2 * v`, plus 1 when `flag` is set.
-}
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


{-| Writes a signed integer as a varint after zigzag encoding, which maps 0, -1, 1, -2 ... to 0, 1,
2, 3 ... so that small values of either sign stay short.
-}
signedVarint : Int -> E.Encoder
signedVarint v =
    if v >= 0 then
        varint (2 * v)

    else
        varint (-2 * v - 1)


{-| Writes `s` as UTF-8 followed by a zero byte.
-}
cstring : String -> E.Encoder
cstring s =
    E.sequence [ E.string s, u8 0 ]


{-| Writes a section: the byte `id`, the size of the contents, then the contents, which are encoded
to bytes first to learn their size. No alignment is asked for: the high bit of the id byte, which
would ask for one, is clear for every id this module writes.
-}
section : Int -> E.Encoder -> E.Encoder
section id body =
    let
        bytes =
            E.encode body
    in
    E.sequence [ u8 id, varint (Bytes.width bytes), E.bytes bytes ]


{-| Returns the number of bytes an encoder writes.
-}
width : E.Encoder -> Int
width e =
    Bytes.width (E.encode e)


{-| Writes a list as its length, then each element as `f` writes it.
-}
list : (a -> E.Encoder) -> List a -> E.Encoder
list f xs =
    E.sequence (varint (List.length xs) :: List.map f xs)


{-| Returns the index of `k` in `d`, or 0 when `d` has no entry for it.
-}
idx : Dict String Int -> String -> Int
idx d k =
    Maybe.withDefault 0 (Dict.get k d)



-- BYTECODE


{-| Writes `ops`, wrapped in a `builtin.module`, as an MLIR bytecode file of version 6.

The file is the magic number, the version, the producer name `eco MlirBc`, then the dialect
section, the attribute and type offset and data sections, the IR section, the string section and
an empty properties section. An attribute or type is written in the builtin binary encoding when
`Attr` or `Type` says it has one, and as its text otherwise. Operands are written in the absolute
numbering `Region` describes, and every op's location is `loc(unknown)`. The bytes depend on `ops`
alone, so equal `ops` give equal bytes.

-}
encode : List Op -> Bytes
encode ops =
    let
        root =
            absolutize (module_ ops)

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

            -- Empty, since no op here has properties, but version 6 requires the section.
            , section 8 (varint 0)
            ]
        )


{-| Writes the string section: the number of strings, each string's size including its zero byte
with the sizes in reverse order, then the strings themselves in order.
-}
stringSection : Numbering -> E.Encoder
stringSection nb =
    E.sequence
        [ varint (List.length nb.strings)
        , E.sequence (List.map (\s -> varint (E.getStringWidth s + 1)) (List.reverse nb.strings))
        , E.sequence (List.map cstring nb.strings)
        ]


{-| Writes the dialect section: the dialects' names, then the number of op names and the op names
grouped by dialect, each group led by its dialect's index. Every name is written as its index in
the string table with a clear flag below it (`varintFlag`), an op name as its name within its
dialect.
-}
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


{-| Returns the contents of the attribute and type data section and of its offset section.

The data section holds every attribute, then every type, in `Numbering`'s order, each in the builtin
binary encoding when it has one and as zero-terminated text otherwise. The offset section gives the
number of attributes and of types, then, group by group, the dialect's index and each entry's size
in bytes, flagged when the entry uses the binary encoding.

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


{-| Returns an attribute's builtin binary encoding, or `Nothing` when it is to be written as text:
an opaque attribute, or an integer attribute of a type `Attr` does not list for the binary encoding.

The encoding is the kind code MLIR's builtin dialect gives the attribute, then its fields, with
attributes, types and strings referred to by table index. An integer's value is one raw byte when
its type has at most 8 bits, and a zigzagged varint otherwise.

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
            case t of
                IntegerType w ->
                    if w <= 8 then
                        Just (E.sequence [ varint 8, typeRef t, u8 (modBy 256 n) ])

                    else if w <= 64 then
                        Just (E.sequence [ varint 8, typeRef t, signedVarint n ])

                    else
                        Nothing

                SignedIntegerType w ->
                    if w <= 8 then
                        Just (E.sequence [ varint 8, typeRef t, u8 (modBy 256 n) ])

                    else
                        Just (E.sequence [ varint 8, typeRef t, signedVarint n ])

                IndexType ->
                    Just (E.sequence [ varint 8, typeRef t, signedVarint n ])

                _ ->
                    Nothing

        UnknownLoc ->
            Just (varint 15)

        UnitAttr ->
            Just (varint 7)

        SymbolRefAttr name ->
            Just (E.sequence [ varint 4, attrRef (StrAttr name) ])

        OpaqueAttr _ ->
            Nothing


{-| Returns a type's builtin binary encoding, the kind code MLIR's builtin dialect gives it and then
its fields, or `Nothing` for an opaque type, which is written as text.
-}
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

        SignedIntegerType w ->
            Just (E.sequence [ varint 0, varint (w * 4 + 1) ])

        IndexType ->
            Just (varint 1)

        FunctionType ins outs ->
            Just (E.sequence [ varint 2, list typeRef ins, list typeRef outs ])

        OpaqueType _ ->
            Nothing


{-| Writes one op: its name's index, a mask byte saying which optional parts follow, its location
(always `loc(unknown)`), then its attribute dictionary, result types, operands and regions, each
only when it has any.

When every region of the op is a `Region`, the regions are written in a nested IR section and
flagged as isolated. Otherwise all of them are written inline, in the op's value scope.

-}
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
            (if List.all isIsolated op.regions then
                E.sequence
                    [ varintFlag (List.length op.regions) True
                    , section 4 (E.sequence (List.map (encodeRegion nb) op.regions))
                    ]

             else
                E.sequence (varintFlag (List.length op.regions) False :: List.map (encodeRegion nb) op.regions)
            )
        ]


{-| Writes a region as one block: the block count, the number of values the block defines (as
`localCount` counts them), the op count flagged when the block has arguments, the argument types,
then the ops.
-}
encodeRegion : Numbering -> Region -> E.Encoder
encodeRegion nb region =
    let
        args =
            regionArgs region

        ops =
            regionOps region

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
