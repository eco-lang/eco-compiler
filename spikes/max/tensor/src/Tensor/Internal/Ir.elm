module Tensor.Internal.Ir exposing
    ( Attr(..)
    , Op
    , Region(..)
    , Type(..)
    , encode
    , outer
    , printGeneric
    , typeText
    , unboundOperands
    )

{-| The MLIR ops a graph lowers to, in a small IR suited to building them, and the two writers that
turn them into what MAX reads: `encode` (MLIR bytecode) and `printGeneric` (MLIR's generic text).
Both convert the ops to the-sett/elm-mlir's model (`Mlir.Mlir`) and write them with that package.

In MLIR a program is a tree of _operations_ (ops). An op has a name such as `mo.add`, whose part
before the first dot is its _dialect_; it has named attributes, the types of the values it
produces, the values it reads (its _operands_) and the _regions_ it holds. A region holds blocks of
further ops, and here every region is exactly one block, whose last op is its terminator.

What this IR adds to the package's model is how operands are given. The package names every value
(`%x`); here an operand is a _value number_ in the region that reads it: the block's arguments
from 0, then each op's results in order. That suits lowering, which numbers values as it emits ops.
A region is either isolated from above (`Region`), when its ops read only their own block's values,
or an _open region_ (`OpenRegion`), whose ops may also read values of the regions enclosing it, up
to the nearest isolated one, written as _negative operands_: `outer v` names what operand `v` names
in the region immediately enclosing it, so a value `d` regions out is `outer` applied `d` times to
its number there.

Before writing, every operand is turned into the absolute numbering MLIR bytecode uses, in which an
isolated region counts from 0 and an open region carries on after the values of the regions around
it, and each value is named after its absolute number: `%argN` for a block argument and `%N` for
an op result. An operand that names no value visible where it is read is named `%<bad N>`; `unboundOperands` finds those, and `Graph` refuses a graph
that has any, so neither writer meets one in practice.

Attributes and types the IR does not model are carried as their text (`OpaqueAttr`, `OpaqueType`),
which the reader parses as it would parse MLIR's text form. Every attribute of an op goes in
`attrs`, including those the op's own definition declares (MLIR's _inherent_ attributes). Every
location is `loc(unknown)`.

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Mlir.Bytecode.StreamEncode as StreamEncode
import Mlir.Loc as Loc
import Mlir.Mlir as M
import Mlir.Pretty as Pretty
import OrderedDict
import Set exposing (Set)


{-| An MLIR type: one of the few builtin types the IR models, or any other type as its text.

`SignedIntegerType w` is the signed integer type of `w` bits (`si64`). `IndexType` is MLIR's
`index`. `FunctionType` takes the argument types, then the result types.

`OpaqueType` carries the full text of any other type, such as `!mo.tensor<[2], si64>`, starting with
its `!`, and is written as that text. Its dialect is the name after the `!`, up to the first `.`.

-}
type Type
    = IndexType
    | SignedIntegerType Int
    | FunctionType (List Type) (List Type)
    | OpaqueType String


{-| An MLIR attribute: one of the builtin attributes the IR models, or any other attribute as its
text.

`StrAttr` and `ArrayAttr` are a string and a list of attributes. `DictAttr`'s entries may be given
in any order: they are written sorted by key, and of two entries with one key only the last is
kept. `TypeAttr` holds a type as an attribute value. `UnitAttr` carries no value; its presence under
a name is its meaning. `SymbolRefAttr name` refers to the symbol `name` and is printed `@name`.
`IntAttr n t` is the integer `n` of type `t`.

`OpaqueAttr` carries the full text of any other attribute, such as `#kgen<param.decls[]>`, or a
builtin attribute the IR does not model, such as `true`, and is written as that text. Its dialect is
the name after a leading `#`, up to the first `.` or `<`; text without a `#` is builtin.

-}
type Attr
    = StrAttr String
    | ArrayAttr (List Attr)
    | DictAttr (List ( String, Attr ))
    | IntAttr Int Type
    | TypeAttr Type
    | UnitAttr
    | SymbolRefAttr String
    | OpaqueAttr String


{-| One MLIR operation.

`name` is the op's full name, such as `mo.add`; everything before its first dot is taken as its
dialect. `attrs` holds every attribute, inherent ones included, in any order; of two with one name
only the last is kept. `operands` are value numbers in the region holding the op, as `Region`
describes.

-}
type alias Op =
    { name : String
    , attrs : List ( String, Attr )
    , results : List Type
    , operands : List Int
    , regions : List Region
    }


{-| A region of one block: the block's argument types and its ops, the last of which is the block's
terminator.

The block's values are numbered from 0: its arguments first, then the results of its ops, in
order. An op's operands name values by these numbers.

A `Region` is isolated from above: its ops read only values of its own block, and a negative
operand in it is left unresolved. Its values are numbered from 0 in the absolute numbering too.

An `OpenRegion` may also read values of the regions enclosing it, up to the nearest isolated one,
as negative operands: `outer v` names, in the open region, what operand `v` names in the region
immediately enclosing it, `v` being that region's own value when not negative and a value further
out when negative. In the absolute numbering an open region's values come after all the values of
the regions enclosing it, up to the nearest isolated one.

The bytecode writer knows a region is isolated by the name of the op holding it: an op whose
regions are all `Region`s has isolated regions, and its name is given to the writer as such. So an
op name must not have `Region`s in one place and `OpenRegion`s in another, and one op must not mix
the two.

-}
type Region
    = Region (List Type) (List Op)
    | OpenRegion (List Type) (List Op)



-- TEXT


{-| Returns a type's MLIR text: `index`, `si64`, `(si64) -> si64`, or an opaque type's own text.
-}
typeText : Type -> String
typeText t =
    case t of
        IndexType ->
            "index"

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



{-| Wraps `ops` in a `builtin.module` op, whose one region is isolated and has no arguments.
-}
module_ : List Op -> Op
module_ ops =
    { name = "builtin.module", attrs = [], results = [], operands = [], regions = [ Region [] ops ] }




-- NUMBERING


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
region. Both writers name such an operand `%<bad N>`: `printGeneric` prints that name, and the
bytecode `encode` writes for it names no value, so the file is corrupt.

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



-- WRITING


{-| Writes `ops`, wrapped in a `builtin.module`, as an MLIR bytecode file (format version 4), with
the regions of each op that holds only `Region`s marked isolated.
-}
encode : List Op -> Bytes
encode ops =
    StreamEncode.assembleModule "eco-lab/tensor"
        (StreamEncode.emptyStreamTables
            |> StreamEncode.isolating (isolatedOpNames ops)
            |> StreamEncode.collectAndEncodeOps (toMlir ops)
        )
        Loc.unknown


{-| Writes `ops`, wrapped in a `builtin.module`, as MLIR generic text: each op as its quoted name,
operands, regions, attribute dictionary and type signature, as in `%2 = "mo.add"(%0, %1) : (...) ->
...`. Values are named as the module docstring describes; locations are not printed.
-}
printGeneric : List Op -> String
printGeneric ops =
    Pretty.ppModuleHeader ++ String.concat (List.map Pretty.ppTopLevelOp (toMlir ops)) ++ Pretty.ppModuleFooter


{-| Returns the names of the ops, at any depth, whose regions are all isolated (`Region`s).
-}
isolatedOpNames : List Op -> List String
isolatedOpNames ops =
    let
        go op acc =
            List.foldl (\r a -> List.foldl go a (regionOps r))
                (if not (List.isEmpty op.regions) && List.all isIsolated op.regions then
                    Set.insert op.name acc

                 else
                    acc
                )
                op.regions
    in
    Set.toList (List.foldl go Set.empty ops)


{-| Converts top-level `ops` to the package's model, each value named as the module docstring
describes.
-}
toMlir : List Op -> List M.MlirOp
toMlir ops =
    case (absolutize (module_ ops)).regions of
        [ Region _ absOps ] ->
            convertOps Dict.empty 0 (localCount [] absOps) absOps

        _ ->
            []


{-| Converts the ops of one block, whose op results are numbered from `next`. `visible` holds the
names of the values visible to its first op, by absolute number, and `nested` is where the open
regions of these ops start numbering.
-}
convertOps : Dict Int String -> Int -> Int -> List Op -> List M.MlirOp
convertOps visible next nested ops =
    let
        step op ( seen, n, acc ) =
            let
                count =
                    List.length op.results
            in
            ( List.foldl (\v d -> Dict.insert v (resultName v) d) seen (List.range n (n + count - 1))
            , n + count
            , convertOp seen nested n op :: acc
            )

        ( _, _, converted ) =
            List.foldl step ( visible, next, [] ) ops
    in
    List.reverse converted


{-| Converts one op whose results are numbered from `first`, read where the values named in
`visible` are visible. Its open regions number their values from `nested` and also see `visible`.
-}
convertOp : Dict Int String -> Int -> Int -> Op -> M.MlirOp
convertOp visible nested first op =
    { name = op.name
    , id = ""
    , operands =
        List.map
            (\v ->
                Dict.get v visible
                    |> Maybe.withDefault ("%<bad " ++ String.fromInt v ++ ">")
            )
            op.operands
    , results = List.indexedMap (\i t -> ( resultName (first + i), convertType t )) op.results
    , attrs = Dict.fromList (List.map (\( k, a ) -> ( k, convertAttr a )) op.attrs)
    , regions = List.map (convertRegion visible nested) op.regions
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| Converts a region held by an op that sees `visible`: an isolated one numbered from 0 and seeing
nothing else, an open one numbered from `nested` and seeing `visible` too. Its last op becomes the
block's terminator; a region with no ops gets a terminator with no name, which no reader accepts.
-}
convertRegion : Dict Int String -> Int -> Region -> M.MlirRegion
convertRegion visible nested region =
    let
        ( base, outside ) =
            if isIsolated region then
                ( 0, Dict.empty )

            else
                ( nested, visible )

        args =
            regionArgs region

        ops =
            regionOps region

        argCount =
            List.length args

        converted =
            convertOps (List.foldl (\v d -> Dict.insert v (argName v) d) outside (List.range base (base + argCount - 1)))
                (base + argCount)
                (base + localCount args ops)
                ops

        ( body, terminator ) =
            case List.reverse converted of
                last :: before ->
                    ( List.reverse before, { last | isTerminator = True } )

                [] ->
                    ( [], { name = "", id = "", operands = [], results = [], attrs = Dict.empty, regions = [], isTerminator = True, loc = Loc.unknown, successors = [] } )
    in
    M.MlirRegion
        { entry =
            { args = List.indexedMap (\i t -> ( argName (base + i), convertType t )) args
            , body = body
            , terminator = terminator
            }
        , blocks = OrderedDict.empty
        }


{-| The name of the op result with absolute number `v`.
-}
resultName : Int -> String
resultName v =
    "%" ++ String.fromInt v


{-| The name of the block argument with absolute number `v`.
-}
argName : Int -> String
argName v =
    "%arg" ++ String.fromInt v


{-| Converts a type to the package's model.
-}
convertType : Type -> M.MlirType
convertType t =
    case t of
        IndexType ->
            M.IndexType

        SignedIntegerType w ->
            M.SignedIntegerType w

        FunctionType ins outs ->
            M.FunctionType { inputs = List.map convertType ins, results = List.map convertType outs }

        OpaqueType s ->
            -- The package spells a dialect type without its leading `!`.
            M.NamedStruct
                (if String.startsWith "!" s then
                    String.dropLeft 1 s

                 else
                    s
                )


{-| Converts an attribute to the package's model, a string to the escaped form a `StringAttr` holds.
-}
convertAttr : Attr -> M.MlirAttr
convertAttr a =
    case a of
        StrAttr s ->
            M.StringAttr (escaped s)

        ArrayAttr l ->
            M.ArrayAttr Nothing (List.map convertAttr l)

        DictAttr kvs ->
            M.DictAttr (Dict.fromList (List.map (\( k, v ) -> ( k, convertAttr v )) kvs))

        IntAttr n t ->
            M.IntAttr (Just (convertType t)) n

        TypeAttr t ->
            M.TypeAttr (convertType t)

        UnitAttr ->
            M.UnitAttr

        SymbolRefAttr name ->
            M.SymbolRefAttr name

        OpaqueAttr s ->
            M.OpaqueAttr s


{-| Returns `s` with its backslashes, double quotes and control characters written as escapes, the
form the package's `StringAttr` holds a string in.
-}
escaped : String -> String
escaped s =
    let
        hex4 n =
            "\\u" ++ String.padLeft 4 '0' (hexDigits n)

        hexDigits n =
            if n < 16 then
                String.fromChar (hexDigit n)

            else
                hexDigits (n // 16) ++ String.fromChar (hexDigit (modBy 16 n))

        hexDigit d =
            String.toList "0123456789ABCDEF" |> List.drop d |> List.head |> Maybe.withDefault '0'

        esc c =
            case c of
                '\\' ->
                    "\\\\"

                '"' ->
                    "\\\""

                '\n' ->
                    "\\n"

                '\t' ->
                    "\\t"

                '\r' ->
                    "\\r"

                _ ->
                    if Char.toCode c < 32 || Char.toCode c == 127 then
                        hex4 (Char.toCode c)

                    else
                        String.fromChar c
    in
    String.concat (List.map esc (String.toList s))
