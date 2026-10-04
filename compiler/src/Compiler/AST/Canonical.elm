module Compiler.AST.Canonical exposing
    ( Module(..), ModuleData, Exports(..), Export(..), Effects(..), Manager(..), Port(..)
    , Expr, ExprInfo, Expr_(..), CaseBranch(..), FieldUpdate(..)
    , Def(..), Decls(..)
    , Pattern, PatternInfo, Pattern_(..), PatternCtorArg(..)
    , Type(..), Annotation(..), FreeVars, AliasType(..), FieldType(..), fieldsToList
    , Union(..), UnionData, Alias(..), Ctor(..), CtorData, CtorOpts(..), Binop(..)
    , annotationEncoder, annotationDecoder
    , typeEncoder, typeDecoder
    , aliasEncoder, aliasDecoder
    , unionEncoder, unionDecoder
    , ctorOptsEncoder, ctorOptsDecoder
    , fieldUpdateEncoder, fieldUpdateDecoder
    , annotationEncoderS, annotationDecoderS
    , typeEncoderS, typeDecoderS
    , arrowSlotToInt, arrowSlotFromInt, freeVarsEncoderS, freeVarsDecoderS
    , unionEncoderS, unionDecoderS
    , collectStringsFromAnnotation, collectStringsFromType
    , collectStringsFromUnion
    , noArrow, tLambda
    )

{-| The canonical AST is a module after name resolution. It exists so that
later phases can read the facts below about a name from the node that uses
it, instead of looking them up again.

Canonicalization finds, for most references to a top-level value, type,
constructor or operator, its _home_: the module it resolves to, as a
`ModuleName.Canonical` (a package and a module name). In a module that
imports `List as L`, `L.map` becomes a reference to `map` in `elm/core`'s
`List`. At the same time canonicalization copies onto
the node the facts that later phases would otherwise have to find in other
declarations: the annotation of an imported value or operator and of any
constructor, the function an operator stands for, a constructor's index and,
in a constructor pattern, the whole declaration of its custom type. These
copies are why several constructors of `Expr_` and `Pattern_` carry more than
their syntax needs.

Every expression and pattern is wrapped twice: in `A.Located`, which gives its
source region, and in a record (`ExprInfo`, `PatternInfo`) that adds its _node
id_, an integer that tables of per-node types are indexed by. Canonicalization
gives ids that are distinct within one module, not across modules;
`Compiler.Canonicalize.Ids` describes how they are handed out.

`Type` is parameterised by how a type variable is identified. A `Type Name`
identifies it by its name, as written in source or as the type checker
generates it, and is what canonicalization and type checking produce. A
`Type MVarId` identifies it by a program-wide `Compiler.AST.TypeIds.MVarId`,
and is what monomorphization works on. Every function arrow carries an _arrow
slot_, whose possible values at each phase `Compiler.AST.TypeIds.ArrowSlot`
describes.

Most of the file is binary codecs. Types, annotations, aliases and unions each
have a codec with an `S` suffix, which writes every string through a
`StringTable` as `Compiler.AST.StringTable` describes, and a plain codec, which
is the `S` codec with `StringTable.disabled` and so writes every string inline.
For annotations, types and unions, a `collectStringsFrom*` function gives a
`StringTable.Collector` every string the `S` encoder will write, so that the
table can be built first. Expressions, patterns and definitions have only a
plain codec, reached through `fieldUpdateEncoder`.


# Modules

@docs Module, ModuleData, Exports, Export, Effects, Manager, Port


# Expressions

@docs Expr, ExprInfo, Expr_, CaseBranch, FieldUpdate


# Definitions

@docs Def, Decls


# Patterns

@docs Pattern, PatternInfo, Pattern_, PatternCtorArg


# Types

@docs Type, Annotation, FreeVars, AliasType, FieldType, fieldsToList


# Type Declarations

@docs Union, UnionData, Alias, Ctor, CtorData, CtorOpts, Binop


# Serialization

@docs annotationEncoder, annotationDecoder
@docs typeEncoder, typeDecoder
@docs aliasEncoder, aliasDecoder
@docs unionEncoder, unionDecoder
@docs ctorOptsEncoder, ctorOptsDecoder
@docs fieldUpdateEncoder, fieldUpdateDecoder


# String-Interned Serialization

@docs annotationEncoderS, annotationDecoderS
@docs typeEncoderS, typeDecoderS
@docs arrowSlotToInt, arrowSlotFromInt, freeVarsEncoderS, freeVarsDecoderS
@docs unionEncoderS, unionDecoderS
@docs collectStringsFromAnnotation, collectStringsFromType
@docs collectStringsFromUnion

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Source as Src
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.Utils.Binop as Binop
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Data.Map
import Dict exposing (Dict)
import Set exposing (Set)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== Expressions ======


{-| An expression with its source region and its node id.
-}
type alias Expr =
    A.Located ExprInfo


{-| An expression's node id together with the expression itself.
-}
type alias ExprInfo =
    { id : Int
    , node : Expr_
    }


{-| One node of a canonical expression: which kind of expression it is, with
its parts.

The variable references differ in where the name was found, and each carries
what later phases need to know about it. `VarLocal` is a name bound inside the
definition being canonicalized, by an argument, a pattern or a `let`.
`VarTopLevel` is a top-level value of the module being canonicalized, with
that module's home. `VarKernel` is a function of a kernel module, given as the
kernel prefix (`Elm` or `Eco`), the rest of the module name (`List` for
`Elm.Kernel.List`) and the function name; the canonicalizer produces it only in
a module of a kernel package. `VarForeign` is a value imported from another
module, other than a `Debug` value, with its annotation. `VarCtor` is a
constructor reference, local or imported, with its custom type's `CtorOpts`,
its home, its name, its zero-based index among its type's constructors, and
its annotation. A record alias's constructor is a `VarCtor` too, with
`Normal` and index 0. `VarDebug` is a reference to a value of `Debug`, with its
annotation; the home it carries is the module the reference appears in, not
`Debug`.

`VarOperator` is an operator used as a value, as in `(+)`, and `Binop` is an
operator applied to a left and a right operand. Both carry the operator as
written, then the home and name of the function it stands for, and its
annotation.

`Chr` and `Str` hold the literal in escaped form, not the value it denotes;
`Compiler.Parse.String` produces that form. `Negate` is a unary
minus.

`If` holds the `if` and `else if` conditions, each paired with its branch, in
order, and then the final `else` branch. `Let` binds one definition, `LetRec`
a group of definitions that may refer to one another, and `LetDestruct` a
pattern to the value of an expression, before the body that follows.

`Accessor` is a field-access function such as `.name`. `Access` reads one
field of a record expression. `Update` holds the record being updated and the
new value of each named field, and `Record` the fields of a record literal;
both are keyed by field name, and each key keeps the region of the name.

`Tuple` holds the first and second elements and a list of any further ones.
`Shader` holds the source text of a GLSL shader and the types of its
attributes, uniforms and varyings, in the forms `Compiler.AST.Utils.Shader`
describes.

-}
type Expr_
    = VarLocal Name
    | VarTopLevel ModuleName.Canonical Name
    | VarKernel Name Name Name
    | VarForeign ModuleName.Canonical Name (Annotation Name)
    | VarCtor CtorOpts ModuleName.Canonical Name Index.ZeroBased (Annotation Name)
    | VarDebug ModuleName.Canonical Name (Annotation Name)
    | VarOperator Name ModuleName.Canonical Name (Annotation Name)
    | Chr String
    | Str String
    | Int Int
    | Float Float
    | List (List Expr)
    | Negate Expr
    | Binop Name ModuleName.Canonical Name (Annotation Name) Expr Expr
    | Lambda (List Pattern) Expr
    | Call Expr (List Expr)
    | If (List ( Expr, Expr )) Expr
    | Let Def Expr
    | LetRec (List Def) Expr
    | LetDestruct Pattern Expr Expr
    | Case Expr (List CaseBranch)
    | Accessor Name
    | Access Expr (A.Located Name)
    | Update Expr (Data.Map.Dict String (A.Located Name) FieldUpdate)
    | Record (Data.Map.Dict String (A.Located Name) Expr)
    | Unit
    | Tuple Expr Expr (List Expr)
    | Shader Shader.Source Shader.Types


{-| One branch of a `case` expression: its pattern and the expression it
evaluates to.
-}
type CaseBranch
    = CaseBranch Pattern Expr


{-| The new value of one field in a record update, with the region of the
field's name.
-}
type FieldUpdate
    = FieldUpdate A.Region Expr



-- ====== Definitions ======


{-| A definition of a value or function, top-level or in a `let`.

A `Def` has no type annotation, and holds the name, the argument patterns and
the body.

A `TypedDef` has an annotation, and the annotation's type is split across it.
It holds the name, the type variables the annotation quantifies over, each
argument pattern paired with the type the annotation gives that argument, the
body, and the result type: what remains of the annotated type once the
arguments' types are taken off.

-}
type Def
    = Def (A.Located Name) (List Pattern) Expr
    | TypedDef (A.Located Name) FreeVars (List ( Pattern, Type Name )) Expr (Type Name)


{-| The top-level definitions of a module, as a linked list of groups.

`Declare` holds a definition that is not part of a recursive group.
`DeclareRec` holds a group of definitions that refer to one another, as its
first definition and the rest. A single definition that refers to itself is
a `DeclareRec` with no further definitions. `Compiler.Canonicalize.Module`
forms the groups.

`SaveTheEnvironment` ends the list and carries nothing.

-}
type Decls
    = Declare Def Decls
    | DeclareRec Def (List Def) Decls
    | SaveTheEnvironment



-- ====== Patterns ======


{-| A pattern with its source region and its node id.
-}
type alias Pattern =
    A.Located PatternInfo


{-| A pattern's node id together with the pattern itself.
-}
type alias PatternInfo =
    { id : Int
    , node : Pattern_
    }


{-| One node of a canonical pattern: which kind of pattern it is, with its
parts.

`PAnything` is `_`. `PRecord` holds the names of the fields a record pattern
such as `{ x, y }` binds. `PAlias` is a pattern followed by `as` and a name.
`PTuple` holds the first and second elements and a list of any further ones,
and `PCons` the head and tail patterns of `::`.

`PChr` and `PStr` hold the literal in escaped form, as `Chr` and `Str` do.
The `Bool` of `PStr` is `True` for a triple-quoted string.

`PBool` is a `True` or `False` pattern: a constructor pattern for
`Basics.Bool`, with the declaration of `Bool` and which of the two it is.

`PCtor` is a pattern for any other constructor. `home` and `type_` are the
module and name of the custom type, and `union` is that type's whole
declaration, which gives its constructors, how many there are and its
`CtorOpts` without a lookup. `name` is the constructor's name and `index` its
zero-based position among the type's constructors. `args` holds a pattern for
each of the constructor's arguments.

-}
type Pattern_
    = PAnything
    | PVar Name
    | PRecord (List Name)
    | PAlias Pattern Name
    | PUnit
    | PTuple Pattern Pattern (List Pattern)
    | PList (List Pattern)
    | PCons Pattern Pattern
    | PBool Union Bool
    | PChr String
    | PStr String Bool
    | PInt Int
    | PCtor
        { home : ModuleName.Canonical
        , type_ : Name
        , union : Union
        , name : Name
        , index : Index.ZeroBased
        , args : List PatternCtorArg
        }


{-| One argument of a constructor pattern: its zero-based position among the
constructor's arguments, the type the constructor declares for it, in terms of
its custom type's own type variables, and the pattern it is matched against.
-}
type PatternCtorArg
    = PatternCtorArg
        Index.ZeroBased
        (Type Name)
        Pattern



-- ====== Types ======


{-| A type together with the names of the type variables it is polymorphic in.
-}
type Annotation id
    = Forall FreeVars (Type id)


{-| The names of the type variables an annotation quantifies over. Only the
keys mean anything.

This is a name for a `Dict`, not a new type, so the compiler does not check
that its names are the variables of any particular type.

-}
type alias FreeVars =
    Dict Name ()


{-| A canonical type, in which every named type carries its home and a type
variable is identified by an `id`, as the module documentation describes.

`TLambda` is a function type from its first type to its second, so a function
of several arguments is a chain of them. Its first field is the arrow slot,
whose meaning `Compiler.AST.TypeIds.ArrowSlot` describes; `tLambda` builds an
arrow with no identity.

`TType` is a named type other than an alias, by home and name, applied to its
arguments.

`TRecord` holds each field's type by field name, and the extension variable of
an extensible record type such as `{ r | x : Int }`, or `Nothing`.

`TTuple` holds the first and second element types and a list of any further
ones.

`TAlias` is a use of a type alias: its home and name, each of the alias's
parameter names paired with the type given for it at this use, and the
aliased type as an `AliasType`.

-}
type Type id
    = TLambda TypeIds.ArrowSlot (Type id) (Type id)
    | TVar id
    | TType ModuleName.Canonical Name (List (Type id))
    | TRecord (Dict Name (FieldType id)) (Maybe id)
    | TUnit
    | TTuple (Type id) (Type id) (List (Type id))
    | TAlias ModuleName.Canonical Name (List ( id, Type id )) (AliasType id)


{-| Returns the integer an arrow slot is serialized as: `idx + 1` for
`SolverRoot idx`, and 0 for `NoArrow` and for `Arrow`.

A `NoArrow`, and a `SolverRoot` whose index is not negative, come back
unchanged from `arrowSlotFromInt`. An `Arrow`, or a `SolverRoot` with a
negative index, comes back as `NoArrow`, an arrow with no identity.

-}
arrowSlotToInt : TypeIds.ArrowSlot -> Int
arrowSlotToInt slot =
    case slot of
        TypeIds.SolverRoot idx ->
            idx + 1

        _ ->
            0


{-| Returns the arrow slot that `arrowSlotToInt` serializes as `raw`: `NoArrow`
for 0 or any negative number, and otherwise `SolverRoot (raw - 1)`.
-}
arrowSlotFromInt : Int -> TypeIds.ArrowSlot
arrowSlotFromInt raw =
    if raw <= 0 then
        TypeIds.NoArrow

    else
        TypeIds.SolverRoot (raw - 1)


{-| Builds the function type from `a` to `b` whose arrow has no identity, the
`NoArrow` slot.

This is the constructor to use for a function type wherever no arrow identity
is known. Which phases put another slot on an arrow, and which slot values
occur in a `Type Name` and in a `Type MVarId`, is described by
`Compiler.AST.TypeIds.ArrowSlot`.

Because `==` on types compares arrow slots too, a function type built here is
not equal to the same type carrying a `SolverRoot`.

-}
tLambda : Type id -> Type id -> Type id
tLambda =
    TLambda TypeIds.NoArrow


{-| The arrow slot of an arrow with no identity, `TypeIds.NoArrow`, available
here so that a module working with canonical types needs no import of
`Compiler.AST.TypeIds` to name it.
-}
noArrow : TypeIds.ArrowSlot
noArrow =
    TypeIds.NoArrow


{-| The aliased type at one use of a type alias, in one of two forms.

A `Holey` body is written in terms of the alias's own parameter names, which
the use's argument list in `TAlias` gives types to. Those names are bound by
the alias, not free in the type, and the body mentions only the parameters it
uses, so a phantom parameter does not appear in it. `Compiler.Canonicalize.Type`
builds every alias named in a type this way.

A `Filled` body has the use's argument types already put in place of the
parameters. It is the form of the result type of a record alias's
constructor, and of an alias in a type converted back from the type checker's
solution.

-}
type AliasType id
    = Holey (Type id)
    | Filled (Type id)


{-| One field of a record type: its position and its type.

The position is the field's zero-based index in source order in a record type
written in source. In a type converted from the type checker's solution every
field's position is 0, so there it orders nothing.

-}
type FieldType id
    = FieldType Int (Type id)


{-| Returns the fields of a record type as a list of names and types, sorted by
their `FieldType` positions.

That is source order only where the positions are meaningful, as `FieldType`
describes. Where they are all 0, as in a type from the solver, the result is
in order of field name.

-}
fieldsToList : Dict Name (FieldType id) -> List ( Name, Type id )
fieldsToList fields =
    let
        getIndex : ( a, FieldType id ) -> Int
        getIndex ( _, FieldType index _ ) =
            index

        dropIndex : ( a, FieldType id ) -> ( a, Type id )
        dropIndex ( name, FieldType _ tipe ) =
            ( name, tipe )
    in
    Dict.toList fields
        |> List.sortBy getIndex
        |> List.map dropIndex



-- ====== Modules ======


{-| Everything canonicalization produces for one module.

`name` is the module's own home. `docs` holds its documentation comments as
the parser read them. `decls` holds its top-level definitions, and `unions`,
`aliases` and `binops` the custom types, type aliases and infix operators it
declares, each by name.

-}
type alias ModuleData =
    { name : ModuleName.Canonical
    , exports : Exports
    , docs : Src.Docs
    , decls : Decls
    , unions : Dict Name Union
    , aliases : Dict Name Alias
    , binops : Dict Name Binop
    , effects : Effects
    }


{-| A canonicalized module.
-}
type Module
    = Module ModuleData


{-| A type alias declaration: its parameter names, in order, and the aliased
type, written in terms of those names.
-}
type Alias
    = Alias (List Name) (Type Name)


{-| An infix operator declaration: the operator's associativity and
precedence, and the name of the function it stands for.
-}
type Binop
    = Binop_ Binop.Associativity Binop.Precedence Name


{-| The declaration of a custom type: its parameter names, its constructors,
the number of constructors, and the `CtorOpts` chosen for it.

`numAlts` is the length of `alts`, kept so that it need not be counted; the
decoder does not check that the two agree. A type that another module exposes
without its constructors reaches an importing module, through
`Compiler.Elm.Interface`, with no constructors and `numAlts` 0, but with its
`opts`.

-}
type alias UnionData =
    { vars : List Name
    , alts : List Ctor
    , numAlts : Int
    , opts : CtorOpts
    }


{-| The declaration of a custom type.
-}
type Union
    = Union UnionData


{-| The shape of a custom type's constructors, from which later phases choose
a cheaper representation for its values where one is allowed.

`Enum` is a type whose constructors all take no arguments. `Unbox` is a type
with exactly one constructor taking exactly one argument, whose values can be
represented by that argument alone. `Normal` is every other type, including
one with a single constructor of two or more arguments.
`Compiler.Canonicalize.Environment.Local` makes the choice for a custom type.
A reference to a record alias's constructor carries `Normal`, which
`Compiler.Canonicalize.Expression` gives it.

-}
type CtorOpts
    = Normal
    | Enum
    | Unbox


{-| One constructor of a custom type: its name, its zero-based position among
the type's constructors, its number of arguments, and the argument types, in
terms of the type's parameter names. `numArgs` is the length of `args` when
canonicalized; the decoder does not check that the two agree.
-}
type alias CtorData =
    { name : Name
    , index : Index.ZeroBased
    , numArgs : Int
    , args : List (Type Name)
    }


{-| One constructor of a custom type.
-}
type Ctor
    = Ctor CtorData



-- ====== Exports ======


{-| What a module's `exposing` list exposes.

`ExportEverything` is `exposing (..)`, with the region of the list. `Export`
is an explicit list: each name it exposes, with what kind of thing that name
is and the region where the list names it.

-}
type Exports
    = ExportEverything A.Region
    | Export (Dict Name (A.Located Export))


{-| The kind of thing a name in an explicit `exposing` list is.

`ExportUnionOpen` is a custom type exposed with its constructors, as
`Type(..)`, and `ExportUnionClosed` one exposed without them.

-}
type Export
    = ExportValue
    | ExportBinop
    | ExportAlias
    | ExportUnionOpen
    | ExportUnionClosed
    | ExportPort


{-| The kind of effects a module declares.

`NoEffects` is an ordinary module. `Ports` is a port module, with its ports by
name.

`Manager` is an effect module. Its three regions are those of the names of its
`init`, `onEffects` and `onSelfMsg` definitions, in that order, and its
`Manager` says which effects it manages.

-}
type Effects
    = NoEffects
    | Ports (Dict Name Port)
    | Manager A.Region A.Region A.Region Manager


{-| The types of a port declaration.

An `Incoming` port's annotated type ends in `Sub msg` and it receives values;
an `Outgoing` port's ends in `Cmd msg` and it sends them. In both, `func` is
the port's whole annotated type, `payload` the type of the value it carries,
taken from that type with every alias expanded, and `freeVars` the type
variables of the annotation.

-}
type Port
    = Incoming
        { freeVars : FreeVars
        , payload : Type Name
        , func : Type Name
        }
    | Outgoing
        { freeVars : FreeVars
        , payload : Type Name
        , func : Type Name
        }


{-| The effects an effect module manages, each named by the custom type of the
module that represents it: `Cmd` commands only, `Sub` subscriptions only, and
`Fx` both, the command type first.
-}
type Manager
    = Cmd Name
    | Sub Name
    | Fx Name Name



-- ====== Serialization ======


{-| Encodes an annotation with every string written inline, as
`annotationEncoderS` does with `StringTable.disabled`.
-}
annotationEncoder : Annotation Name -> Bytes.Encode.Encoder
annotationEncoder =
    annotationEncoderS StringTable.disabled


{-| A decoder for an annotation written by `annotationEncoder`.
-}
annotationDecoder : Bytes.Decode.Decoder (Annotation Name)
annotationDecoder =
    annotationDecoderS StringTable.disabled


{-| Encodes an annotation with the strings written through `st`: the names of
its type variables, as `freeVarsEncoderS` writes them, then its type, as
`typeEncoderS` writes it.
-}
annotationEncoderS : StringTable -> Annotation Name -> Bytes.Encode.Encoder
annotationEncoderS st (Forall freeVars tipe) =
    Bytes.Encode.sequence
        [ freeVarsEncoderS st freeVars
        , typeEncoderS st tipe
        ]


{-| Produces a decoder for an annotation written by `annotationEncoderS` with a
table equal to `st`.
-}
annotationDecoderS : StringTable -> Bytes.Decode.Decoder (Annotation Name)
annotationDecoderS st =
    Bytes.Decode.map2 Forall
        (freeVarsDecoderS st)
        (typeDecoderS st)


{-| Encodes the names of an annotation's type variables as a list, in ascending
order, each written through `st`.
-}
freeVarsEncoderS : StringTable -> FreeVars -> Bytes.Encode.Encoder
freeVarsEncoderS st freeVars =
    BE.list (StringTable.string st) (Dict.keys freeVars)


{-| Produces a decoder for the type-variable names written by `freeVarsEncoderS`
with a table equal to `st`.
-}
freeVarsDecoderS : StringTable -> Bytes.Decode.Decoder FreeVars
freeVarsDecoderS st =
    BD.list (StringTable.stringDec st)
        |> Bytes.Decode.map (List.map (\key -> ( key, () )) >> Dict.fromList)


{-| Encodes type-variable names as `freeVarsEncoderS` does, with each name
written inline.
-}
freeVarsEncoder : FreeVars -> Bytes.Encode.Encoder
freeVarsEncoder =
    freeVarsEncoderS StringTable.disabled


{-| A decoder for type-variable names written by `freeVarsEncoder`.
-}
freeVarsDecoder : Bytes.Decode.Decoder FreeVars
freeVarsDecoder =
    freeVarsDecoderS StringTable.disabled


{-| Encodes a type alias declaration with every string written inline: its
parameter names, then the aliased type as `typeEncoder` writes it.
-}
aliasEncoder : Alias -> Bytes.Encode.Encoder
aliasEncoder =
    aliasEncoderS StringTable.disabled


{-| A decoder for a type alias declaration written by `aliasEncoder`.
-}
aliasDecoder : Bytes.Decode.Decoder Alias
aliasDecoder =
    aliasDecoderS StringTable.disabled


{-| Encodes a type alias declaration as `aliasEncoder` does, with the strings
written through `st`.
-}
aliasEncoderS : StringTable -> Alias -> Bytes.Encode.Encoder
aliasEncoderS st (Alias vars tipe) =
    Bytes.Encode.sequence
        [ BE.list (StringTable.string st) vars
        , typeEncoderS st tipe
        ]


{-| Produces a decoder for a type alias declaration written by `aliasEncoderS`
with a table equal to `st`.
-}
aliasDecoderS : StringTable -> Bytes.Decode.Decoder Alias
aliasDecoderS st =
    Bytes.Decode.map2 Alias
        (BD.list (StringTable.stringDec st))
        (typeDecoderS st)


{-| Encodes a type as `typeEncoderS` does, with every string written inline.
-}
typeEncoder : Type Name -> Bytes.Encode.Encoder
typeEncoder =
    typeEncoderS StringTable.disabled


{-| A decoder for a type written by `typeEncoder`.
-}
typeDecoder : Bytes.Decode.Decoder (Type Name)
typeDecoder =
    typeDecoderS StringTable.disabled


{-| Encodes a type with the strings written through `st`.

Each constructor is written as a one-byte tag, then its fields in order: 0 for
`TLambda`, 1 `TVar`, 2 `TType`, 3 `TRecord`, 4 `TUnit`, 5 `TTuple` and 6
`TAlias`. A record's fields are written in ascending order of name, each with
its position. An alias's body is written after a byte that is 0 for `Holey`
and 1 for `Filled`.

A `TLambda`'s arrow slot is written as `arrowSlotToInt` gives it, as an
8-byte float like every `Int` written with `BE.int`. So a `SolverRoot` with a
non-negative index is kept, and an `Arrow` is written, like `NoArrow`, as no
identity.

-}
typeEncoderS : StringTable -> Type Name -> Bytes.Encode.Encoder
typeEncoderS st type_ =
    case type_ of
        TLambda slot a b ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.int (arrowSlotToInt slot)
                , typeEncoderS st a
                , typeEncoderS st b
                ]

        TVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , StringTable.string st name
                ]

        TType home name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , ModuleName.canonicalEncoderS st home
                , StringTable.string st name
                , BE.list (typeEncoderS st) args
                ]

        TRecord fields ext ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.stdDict (StringTable.string st) (fieldTypeEncoderS st) fields
                , BE.maybe (StringTable.string st) ext
                ]

        TUnit ->
            Bytes.Encode.unsignedInt8 4

        TTuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , typeEncoderS st a
                , typeEncoderS st b
                , BE.list (typeEncoderS st) cs
                ]

        TAlias home name args tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , ModuleName.canonicalEncoderS st home
                , StringTable.string st name
                , BE.list (BE.jsonPair (StringTable.string st) (typeEncoderS st)) args
                , aliasTypeEncoderS st tipe
                ]


{-| Produces a decoder for a type written by `typeEncoderS` with a table equal
to `st`.
-}
typeDecoderS : StringTable -> Bytes.Decode.Decoder (Type Name)
typeDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 (\raw a b -> TLambda (arrowSlotFromInt raw) a b)
                            BD.int
                            (typeDecoderS st)
                            (typeDecoderS st)

                    1 ->
                        Bytes.Decode.map TVar (StringTable.stringDec st)

                    2 ->
                        Bytes.Decode.map3 TType
                            (ModuleName.canonicalDecoderS st)
                            (StringTable.stringDec st)
                            (BD.list (typeDecoderS st))

                    3 ->
                        Bytes.Decode.map2 TRecord
                            (BD.stdDict (StringTable.stringDec st) (fieldTypeDecoderS st))
                            (BD.maybe (StringTable.stringDec st))

                    4 ->
                        Bytes.Decode.succeed TUnit

                    5 ->
                        Bytes.Decode.map3 TTuple
                            (typeDecoderS st)
                            (typeDecoderS st)
                            (BD.list (typeDecoderS st))

                    6 ->
                        Bytes.Decode.map4 TAlias
                            (ModuleName.canonicalDecoderS st)
                            (StringTable.stringDec st)
                            (BD.list (BD.jsonPair (StringTable.stringDec st) (typeDecoderS st)))
                            (aliasTypeDecoderS st)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes one record field's position, then its type as `typeEncoderS`
writes it with `st`.
-}
fieldTypeEncoderS : StringTable -> FieldType Name -> Bytes.Encode.Encoder
fieldTypeEncoderS st (FieldType index tipe) =
    Bytes.Encode.sequence
        [ BE.int index
        , typeEncoderS st tipe
        ]


{-| Encodes an alias body as a byte, 0 for `Holey` and 1 for `Filled`, then
the body's type as `typeEncoderS` writes it with `st`.
-}
aliasTypeEncoderS : StringTable -> AliasType Name -> Bytes.Encode.Encoder
aliasTypeEncoderS st aliasType =
    case aliasType of
        Holey tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , typeEncoderS st tipe
                ]

        Filled tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , typeEncoderS st tipe
                ]


{-| Produces a decoder for one record field written by `fieldTypeEncoderS`
with a table equal to `st`.
-}
fieldTypeDecoderS : StringTable -> Bytes.Decode.Decoder (FieldType Name)
fieldTypeDecoderS st =
    Bytes.Decode.map2 FieldType
        BD.int
        (typeDecoderS st)


{-| Produces a decoder for an alias body written by `aliasTypeEncoderS` with a
table equal to `st`.
-}
aliasTypeDecoderS : StringTable -> Bytes.Decode.Decoder (AliasType Name)
aliasTypeDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Holey (typeDecoderS st)

                    1 ->
                        Bytes.Decode.map Filled (typeDecoderS st)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a custom type's declaration as `unionEncoderS` does, with every
string written inline.
-}
unionEncoder : Union -> Bytes.Encode.Encoder
unionEncoder =
    unionEncoderS StringTable.disabled


{-| A decoder for a custom type's declaration written by `unionEncoder`.
-}
unionDecoder : Bytes.Decode.Decoder Union
unionDecoder =
    unionDecoderS StringTable.disabled


{-| Encodes a custom type's declaration with the strings written through `st`:
its parameter names, its constructors, the number of constructors, and its
`CtorOpts` as `ctorOptsEncoder` writes them.
-}
unionEncoderS : StringTable -> Union -> Bytes.Encode.Encoder
unionEncoderS st (Union u) =
    Bytes.Encode.sequence
        [ BE.list (StringTable.string st) u.vars
        , BE.list (ctorEncoderS st) u.alts
        , BE.int u.numAlts
        , ctorOptsEncoder u.opts
        ]


{-| Produces a decoder for a custom type's declaration written by
`unionEncoderS` with a table equal to `st`.
-}
unionDecoderS : StringTable -> Bytes.Decode.Decoder Union
unionDecoderS st =
    Bytes.Decode.map4 (\vars_ alts_ numAlts_ opts_ -> Union { vars = vars_, alts = alts_, numAlts = numAlts_, opts = opts_ })
        (BD.list (StringTable.stringDec st))
        (BD.list (ctorDecoderS st))
        BD.int
        ctorOptsDecoder


{-| Encodes one constructor with the strings written through `st`: its name,
index, number of arguments and argument types.
-}
ctorEncoderS : StringTable -> Ctor -> Bytes.Encode.Encoder
ctorEncoderS st (Ctor c) =
    Bytes.Encode.sequence
        [ StringTable.string st c.name
        , Index.zeroBasedEncoder c.index
        , BE.int c.numArgs
        , BE.list (typeEncoderS st) c.args
        ]


{-| Produces a decoder for one constructor written by `ctorEncoderS` with a
table equal to `st`.
-}
ctorDecoderS : StringTable -> Bytes.Decode.Decoder Ctor
ctorDecoderS st =
    Bytes.Decode.map4 (\name_ index_ numArgs_ args_ -> Ctor { name = name_, index = index_, numArgs = numArgs_, args = args_ })
        (StringTable.stringDec st)
        Index.zeroBasedDecoder
        BD.int
        (BD.list (typeDecoderS st))


{-| Encodes a `CtorOpts` as one byte: 0 for `Normal`, 1 for `Enum` and 2 for
`Unbox`.
-}
ctorOptsEncoder : CtorOpts -> Bytes.Encode.Encoder
ctorOptsEncoder ctorOpts =
    Bytes.Encode.unsignedInt8
        (case ctorOpts of
            Normal ->
                0

            Enum ->
                1

            Unbox ->
                2
        )


{-| A decoder for a `CtorOpts` written by `ctorOptsEncoder`, which fails on any
other byte.
-}
ctorOptsDecoder : Bytes.Decode.Decoder CtorOpts
ctorOptsDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Normal

                    1 ->
                        Bytes.Decode.succeed Enum

                    2 ->
                        Bytes.Decode.succeed Unbox

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a field update: the region of the field's name in the fixed
encoding of `Compiler.Reporting.Annotation.regionEncoder`, then the new value
with the expression codec, which writes every string inline.

The expression codec does not round-trip every expression. Within a record
literal or a record update, it writes each field name without its region, but
its decoder reads a region before each name, so `fieldUpdateDecoder` misreads
a value containing either.

-}
fieldUpdateEncoder : FieldUpdate -> Bytes.Encode.Encoder
fieldUpdateEncoder (FieldUpdate fieldRegion expr) =
    Bytes.Encode.sequence
        [ A.regionEncoder fieldRegion
        , exprEncoder expr
        ]


{-| A decoder for a field update written by `fieldUpdateEncoder`.
-}
fieldUpdateDecoder : Bytes.Decode.Decoder FieldUpdate
fieldUpdateDecoder =
    Bytes.Decode.map2 FieldUpdate
        A.regionDecoder
        exprDecoder


{-| Encodes an expression: its region, then its node id and node.
-}
exprEncoder : Expr -> Bytes.Encode.Encoder
exprEncoder =
    A.locatedEncoder exprInfoEncoder


{-| A decoder for an expression written by `exprEncoder`.
-}
exprDecoder : Bytes.Decode.Decoder Expr
exprDecoder =
    A.locatedDecoder exprInfoDecoder


{-| Encodes an expression's node id, then its node.
-}
exprInfoEncoder : ExprInfo -> Bytes.Encode.Encoder
exprInfoEncoder info =
    Bytes.Encode.sequence
        [ BE.int info.id
        , expr_Encoder info.node
        ]


{-| A decoder for a node id and expression node written by `exprInfoEncoder`.
-}
exprInfoDecoder : Bytes.Decode.Decoder ExprInfo
exprInfoDecoder =
    Bytes.Decode.map2 (\id node -> { id = id, node = node })
        BD.int
        expr_Decoder


{-| Encodes an expression node as a one-byte tag, 0 to 27 in the order the
constructors are listed in the `case`, followed by its fields, with every
string written inline.

`Record` and `Update` write each field's name without the region its key
carries, although `expr_Decoder` reads a located name there.

-}
expr_Encoder : Expr_ -> Bytes.Encode.Encoder
expr_Encoder expr_ =
    case expr_ of
        VarLocal name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string name
                ]

        VarTopLevel home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , ModuleName.canonicalEncoder home
                , BE.string name
                ]

        VarKernel kernelPrefix home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string kernelPrefix
                , BE.string home
                , BE.string name
                ]

        VarForeign home name annotation ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , ModuleName.canonicalEncoder home
                , BE.string name
                , annotationEncoder annotation
                ]

        VarCtor opts home name index annotation ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , ctorOptsEncoder opts
                , ModuleName.canonicalEncoder home
                , BE.string name
                , Index.zeroBasedEncoder index
                , annotationEncoder annotation
                ]

        VarDebug home name annotation ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , ModuleName.canonicalEncoder home
                , BE.string name
                , annotationEncoder annotation
                ]

        VarOperator op home name annotation ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , BE.string op
                , ModuleName.canonicalEncoder home
                , BE.string name
                , annotationEncoder annotation
                ]

        Chr chr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.string chr
                ]

        Str str ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , BE.string str
                ]

        Int int ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , BE.int int
                ]

        Float float ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , BE.float float
                ]

        List entries ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , BE.list exprEncoder entries
                ]

        Negate expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , exprEncoder expr
                ]

        Binop op home name annotation left right ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , BE.string op
                , ModuleName.canonicalEncoder home
                , BE.string name
                , annotationEncoder annotation
                , exprEncoder left
                , exprEncoder right
                ]

        Lambda args body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , BE.list patternEncoder args
                , exprEncoder body
                ]

        Call func args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , exprEncoder func
                , BE.list exprEncoder args
                ]

        If branches finally ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , BE.list (BE.jsonPair exprEncoder exprEncoder) branches
                , exprEncoder finally
                ]

        Let def body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , defEncoder def
                , exprEncoder body
                ]

        LetRec defs body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , BE.list defEncoder defs
                , exprEncoder body
                ]

        LetDestruct pattern expr body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 19
                , patternEncoder pattern
                , exprEncoder expr
                , exprEncoder body
                ]

        Case expr branches ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , exprEncoder expr
                , BE.list caseBranchEncoder branches
                ]

        Accessor field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , BE.string field
                ]

        Access record field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , exprEncoder record
                , A.locatedEncoder BE.string field
                ]

        Update record updates ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 23
                , exprEncoder record
                , BE.assocListDict A.compareLocated (A.toValue >> BE.string) fieldUpdateEncoder updates
                ]

        Record fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 24
                , BE.assocListDict A.compareLocated (A.toValue >> BE.string) exprEncoder fields
                ]

        Unit ->
            Bytes.Encode.unsignedInt8 25

        Tuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 26
                , exprEncoder a
                , exprEncoder b
                , BE.list exprEncoder cs
                ]

        Shader src types ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 27
                , Shader.sourceEncoder src
                , Shader.typesEncoder types
                ]


{-| A decoder for an expression node written by `expr_Encoder`.
-}
expr_Decoder : Bytes.Decode.Decoder Expr_
expr_Decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map VarLocal BD.string

                    1 ->
                        Bytes.Decode.map2 VarTopLevel
                            ModuleName.canonicalDecoder
                            BD.string

                    2 ->
                        Bytes.Decode.map3 VarKernel
                            BD.string
                            BD.string
                            BD.string

                    3 ->
                        Bytes.Decode.map3 VarForeign
                            ModuleName.canonicalDecoder
                            BD.string
                            annotationDecoder

                    4 ->
                        Bytes.Decode.map5 VarCtor
                            ctorOptsDecoder
                            ModuleName.canonicalDecoder
                            BD.string
                            Index.zeroBasedDecoder
                            annotationDecoder

                    5 ->
                        Bytes.Decode.map3 VarDebug
                            ModuleName.canonicalDecoder
                            BD.string
                            annotationDecoder

                    6 ->
                        Bytes.Decode.map4 VarOperator
                            BD.string
                            ModuleName.canonicalDecoder
                            BD.string
                            annotationDecoder

                    7 ->
                        Bytes.Decode.map Chr BD.string

                    8 ->
                        Bytes.Decode.map Str BD.string

                    9 ->
                        Bytes.Decode.map Int BD.int

                    10 ->
                        Bytes.Decode.map Float BD.float

                    11 ->
                        Bytes.Decode.map List (BD.list exprDecoder)

                    12 ->
                        Bytes.Decode.map Negate exprDecoder

                    13 ->
                        BD.map6 Binop
                            BD.string
                            ModuleName.canonicalDecoder
                            BD.string
                            annotationDecoder
                            exprDecoder
                            exprDecoder

                    14 ->
                        Bytes.Decode.map2 Lambda
                            (BD.list patternDecoder)
                            exprDecoder

                    15 ->
                        Bytes.Decode.map2 Call
                            exprDecoder
                            (BD.list exprDecoder)

                    16 ->
                        Bytes.Decode.map2 If
                            (BD.list (BD.jsonPair exprDecoder exprDecoder))
                            exprDecoder

                    17 ->
                        Bytes.Decode.map2 Let
                            defDecoder
                            exprDecoder

                    18 ->
                        Bytes.Decode.map2 LetRec
                            (BD.list defDecoder)
                            exprDecoder

                    19 ->
                        Bytes.Decode.map3 LetDestruct
                            patternDecoder
                            exprDecoder
                            exprDecoder

                    20 ->
                        Bytes.Decode.map2 Case
                            exprDecoder
                            (BD.list caseBranchDecoder)

                    21 ->
                        Bytes.Decode.map Accessor BD.string

                    22 ->
                        Bytes.Decode.map2 Access
                            exprDecoder
                            (A.locatedDecoder BD.string)

                    23 ->
                        Bytes.Decode.map2 Update
                            exprDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) fieldUpdateDecoder)

                    24 ->
                        Bytes.Decode.map Record
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)

                    25 ->
                        Bytes.Decode.succeed Unit

                    26 ->
                        Bytes.Decode.map3 Tuple
                            exprDecoder
                            exprDecoder
                            (BD.list exprDecoder)

                    27 ->
                        Bytes.Decode.map2 Shader
                            Shader.sourceDecoder
                            Shader.typesDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a pattern: its region, then its node id and node.
-}
patternEncoder : Pattern -> Bytes.Encode.Encoder
patternEncoder =
    A.locatedEncoder patternInfoEncoder


{-| A decoder for a pattern written by `patternEncoder`.
-}
patternDecoder : Bytes.Decode.Decoder Pattern
patternDecoder =
    A.locatedDecoder patternInfoDecoder


{-| Encodes a pattern's node id, then its node.
-}
patternInfoEncoder : PatternInfo -> Bytes.Encode.Encoder
patternInfoEncoder info =
    Bytes.Encode.sequence
        [ BE.int info.id
        , pattern_Encoder info.node
        ]


{-| A decoder for a node id and pattern node written by `patternInfoEncoder`.
-}
patternInfoDecoder : Bytes.Decode.Decoder PatternInfo
patternInfoDecoder =
    Bytes.Decode.map2 PatternInfo
        BD.int
        pattern_Decoder


{-| Encodes a pattern node as a one-byte tag, 0 to 12 in the order the
constructors are listed in the `case`, followed by its fields, with every
string written inline.
-}
pattern_Encoder : Pattern_ -> Bytes.Encode.Encoder
pattern_Encoder pattern_ =
    case pattern_ of
        PAnything ->
            Bytes.Encode.unsignedInt8 0

        PVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string name
                ]

        PRecord names ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.list BE.string names
                ]

        PAlias pattern name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , patternEncoder pattern
                , BE.string name
                ]

        PUnit ->
            Bytes.Encode.unsignedInt8 4

        PTuple pattern1 pattern2 otherPatterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , patternEncoder pattern1
                , patternEncoder pattern2
                , BE.list patternEncoder otherPatterns
                ]

        PList patterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , BE.list patternEncoder patterns
                ]

        PCons pattern1 pattern2 ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , patternEncoder pattern1
                , patternEncoder pattern2
                ]

        PBool union bool ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , unionEncoder union
                , BE.bool bool
                ]

        PChr chr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , BE.string chr
                ]

        PStr str multiline ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , BE.string str
                , BE.bool multiline
                ]

        PInt int ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , BE.int int
                ]

        PCtor { home, type_, union, name, index, args } ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , ModuleName.canonicalEncoder home
                , BE.string type_
                , unionEncoder union
                , BE.string name
                , Index.zeroBasedEncoder index
                , BE.list patternCtorArgEncoder args
                ]


{-| A decoder for a pattern node written by `pattern_Encoder`.
-}
pattern_Decoder : Bytes.Decode.Decoder Pattern_
pattern_Decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed PAnything

                    1 ->
                        Bytes.Decode.map PVar
                            BD.string

                    2 ->
                        Bytes.Decode.map PRecord
                            (BD.list BD.string)

                    3 ->
                        Bytes.Decode.map2 PAlias
                            patternDecoder
                            BD.string

                    4 ->
                        Bytes.Decode.succeed PUnit

                    5 ->
                        Bytes.Decode.map3 PTuple
                            patternDecoder
                            patternDecoder
                            (BD.list patternDecoder)

                    6 ->
                        Bytes.Decode.map PList
                            (BD.list patternDecoder)

                    7 ->
                        Bytes.Decode.map2 PCons
                            patternDecoder
                            patternDecoder

                    8 ->
                        Bytes.Decode.map2 PBool
                            unionDecoder
                            BD.bool

                    9 ->
                        Bytes.Decode.map PChr BD.string

                    10 ->
                        Bytes.Decode.map2 PStr
                            BD.string
                            BD.bool

                    11 ->
                        Bytes.Decode.map PInt BD.int

                    12 ->
                        BD.map6
                            (\home type_ union name index args ->
                                PCtor
                                    { home = home
                                    , type_ = type_
                                    , union = union
                                    , name = name
                                    , index = index
                                    , args = args
                                    }
                            )
                            ModuleName.canonicalDecoder
                            BD.string
                            unionDecoder
                            BD.string
                            Index.zeroBasedDecoder
                            (BD.list patternCtorArgDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes one argument of a constructor pattern: its index, its declared type
and its pattern.
-}
patternCtorArgEncoder : PatternCtorArg -> Bytes.Encode.Encoder
patternCtorArgEncoder (PatternCtorArg index srcType pattern) =
    Bytes.Encode.sequence
        [ Index.zeroBasedEncoder index
        , typeEncoder srcType
        , patternEncoder pattern
        ]


{-| A decoder for a constructor-pattern argument written by
`patternCtorArgEncoder`.
-}
patternCtorArgDecoder : Bytes.Decode.Decoder PatternCtorArg
patternCtorArgDecoder =
    Bytes.Decode.map3 PatternCtorArg
        Index.zeroBasedDecoder
        typeDecoder
        patternDecoder


{-| Encodes a definition as a tag, 0 for `Def` and 1 for `TypedDef`, followed by
its fields, with every string written inline.
-}
defEncoder : Def -> Bytes.Encode.Encoder
defEncoder def =
    case def of
        Def name args expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.locatedEncoder BE.string name
                , BE.list patternEncoder args
                , exprEncoder expr
                ]

        TypedDef name freeVars typedArgs expr srcResultType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.locatedEncoder BE.string name
                , freeVarsEncoder freeVars
                , BE.list (BE.jsonPair patternEncoder typeEncoder) typedArgs
                , exprEncoder expr
                , typeEncoder srcResultType
                ]


{-| A decoder for a definition written by `defEncoder`.
-}
defDecoder : Bytes.Decode.Decoder Def
defDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Def
                            (A.locatedDecoder BD.string)
                            (BD.list patternDecoder)
                            exprDecoder

                    1 ->
                        Bytes.Decode.map5 TypedDef
                            (A.locatedDecoder BD.string)
                            freeVarsDecoder
                            (BD.list (BD.jsonPair patternDecoder typeDecoder))
                            exprDecoder
                            typeDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a `case` branch: its pattern, then its body.
-}
caseBranchEncoder : CaseBranch -> Bytes.Encode.Encoder
caseBranchEncoder (CaseBranch pattern expr) =
    Bytes.Encode.sequence
        [ patternEncoder pattern
        , exprEncoder expr
        ]


{-| A decoder for a `case` branch written by `caseBranchEncoder`.
-}
caseBranchDecoder : Bytes.Decode.Decoder CaseBranch
caseBranchDecoder =
    Bytes.Decode.map2 CaseBranch
        patternDecoder
        exprDecoder



-- ====== STRING COLLECTORS ======


{-| Gives the collector `acc` every string `annotationEncoderS` writes for the
annotation: the names of its type variables and the strings of its type. Which
of them `acc` keeps is its own rule, as `StringTable.Collector` describes.
-}
collectStringsFromAnnotation : Annotation Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromAnnotation (Forall freeVars tipe) acc =
    acc
        |> (\a -> List.foldl StringTable.add a (Dict.keys freeVars))
        |> collectStringsFromType tipe


{-| Gives the collector `acc` every string `typeEncoderS` writes for the type:
type variable names, the homes and names of named types and aliases, record
field names and extension variables, alias parameter names, and every string
of an alias's body. Which of them `acc` keeps is its own rule.
-}
collectStringsFromType : Type Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromType type_ acc =
    case type_ of
        TLambda _ a b ->
            acc
                |> collectStringsFromType a
                |> collectStringsFromType b

        TVar name ->
            StringTable.add name acc

        TType home name args ->
            List.foldl collectStringsFromType
                (acc
                    |> ModuleName.collectStringsFromCanonical home
                    |> StringTable.add name
                )
                args

        TRecord fields ext ->
            let
                withFields : StringTable.Collector
                withFields =
                    Dict.foldl
                        (\k (FieldType _ ft) a ->
                            collectStringsFromType ft (StringTable.add k a)
                        )
                        acc
                        fields
            in
            case ext of
                Just s ->
                    StringTable.add s withFields

                Nothing ->
                    withFields

        TUnit ->
            acc

        TTuple a b cs ->
            List.foldl collectStringsFromType
                (acc
                    |> collectStringsFromType a
                    |> collectStringsFromType b
                )
                cs

        TAlias home name args tipe ->
            let
                withHead : StringTable.Collector
                withHead =
                    acc
                        |> ModuleName.collectStringsFromCanonical home
                        |> StringTable.add name

                withArgs : StringTable.Collector
                withArgs =
                    List.foldl
                        (\( argName, argType ) a ->
                            a |> StringTable.add argName |> collectStringsFromType argType
                        )
                        withHead
                        args
            in
            collectStringsFromAliasType tipe withArgs


{-| Gives the collector `acc` every string `typeEncoderS` writes for an alias's
body, whether `Holey` or `Filled`.
-}
collectStringsFromAliasType : AliasType Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromAliasType at acc =
    case at of
        Holey tipe ->
            collectStringsFromType tipe acc

        Filled tipe ->
            collectStringsFromType tipe acc


{-| Gives the collector `acc` every string `unionEncoderS` writes for the
declaration: its parameter names, and each constructor's name and the strings
of its argument types. Which of them `acc` keeps is its own rule.
-}
collectStringsFromUnion : Union -> StringTable.Collector -> StringTable.Collector
collectStringsFromUnion (Union u) acc =
    let
        withVars : StringTable.Collector
        withVars =
            List.foldl StringTable.add acc u.vars
    in
    List.foldl collectStringsFromCtor withVars u.alts


{-| Gives the collector `acc` a constructor's name and the strings of its
argument types.
-}
collectStringsFromCtor : Ctor -> StringTable.Collector -> StringTable.Collector
collectStringsFromCtor (Ctor c) acc =
    List.foldl collectStringsFromType (StringTable.add c.name acc) c.args
