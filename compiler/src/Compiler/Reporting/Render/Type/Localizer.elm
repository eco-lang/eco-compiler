module Compiler.Reporting.Render.Type.Localizer exposing
    ( Localizer
    , empty, fromModule, fromNames
    , toDoc, toChars
    , localizerEncoder, localizerDecoder
    )

{-| An error message that mentions a type should name it the way the module being
reported on would write it, and this module works out that name from the
module's imports.

A type is identified by its _home_, the canonical name of the module that
defines it, together with its own name. Whether a module writes the type bare
(`Maybe`), under an alias (`D.Dict`, after `import Dict as D`) or with the home
module's name (`Dict.Dict`) depends on how that module imports the home
module. A _localizer_ records, for each module name, how the module being
reported on imports it, and `toChars` prints a type name by looking up its home
there.

The import table is followed as it stands. Nothing here checks that the printed
name is unambiguous: a type is printed bare whenever its home's import exposes
it, even if another import exposes a type of the same name. The lookup uses only
the module part of the home, not its package.

`fromModule` builds a localizer from a parsed module, `fromNames` from a set of
module names, and `empty` has no entries, so every type is printed with its home
module's name. A localizer can be written to bytes and read back.


# Localizer

@docs Localizer


# Construction

@docs empty, fromModule, fromNames


# Rendering

@docs toDoc, toChars


# Serialization

@docs localizerEncoder, localizerDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== LOCALIZER ======


{-| How a module writes the modules it imports, as far as printing a type name
from one of them needs it: under which alias, and which of its types are in
scope bare. A module with no entry counts as not imported.

A value is obtained from `fromModule`, `fromNames`, `empty` or
`localizerDecoder`, and is used through `toChars` and `toDoc`.

-}
type Localizer
    = Localizer (Dict Name Import)


{-| How one module is imported: the alias given by `as`, `Nothing` if there is
none, and which of its types the import brings into scope bare.
-}
type alias Import =
    { alias : Maybe Name
    , exposing_ : Exposing
    }


{-| Which of an imported module's types an import brings into scope bare.

`All` is `exposing (..)`. It is also how `fromModule` records the module's own
name and how `fromNames` records every name it is given.

`Only` holds the names of the types an explicit `exposing` list names, with or
without `(..)`. Values and operators in the list are not kept, and an import
with no `exposing` list holds an empty set.

-}
type Exposing
    = All
    | Only (EverySet String Name)


{-| The localizer with no entries, under which every type is printed with its
home module's name, as in `Maybe.Maybe`.
-}
empty : Localizer
empty =
    Localizer Dict.empty



-- ====== LOCALIZE ======


{-| Returns `name`, a type defined in the module `home`, as a document holding the
text `toChars` gives for it.
-}
toDoc : Localizer -> ModuleName.Canonical -> Name -> D.Doc
toDoc localizer home name =
    D.fromChars (toChars localizer home name)


{-| Returns `name`, a type defined in the module `home`, as the module the
localizer describes would write it. With `Home` standing for the module part of
`home`:

  - If the localizer has no entry for `Home`, the result is `Home.name`.
  - If `Home` is imported with `exposing (..)`, the result is `name`.
  - If `Home` is imported with an explicit `exposing` list that names the type,
    the result is `name`.
  - If `Home` is imported with an explicit `exposing` list that does not name
    the type, and the type is `List` from `elm/core`'s `List` module, the result
    is still `List`. The default import of `List` exposes only `(::)`, as
    `Compiler.Elm.Compiler.Imports` describes, so under that import it is this
    rule that prints `List` bare.
  - Otherwise the result is `Alias.name` when the import has an alias, and
    `Home.name` when it does not.

The package part of `home` is used only by the `List` rule; the lookup itself is
by the module name alone.

-}
toChars : Localizer -> ModuleName.Canonical -> Name -> String
toChars (Localizer localizer) ((ModuleName.Canonical _ home) as moduleName) name =
    case Dict.get home localizer of
        Nothing ->
            home ++ "." ++ name

        Just import_ ->
            case import_.exposing_ of
                All ->
                    name

                Only set ->
                    if EverySet.member identity name set then
                        name

                    else if name == Name.list && moduleName == ModuleName.list then
                        "List"

                    else
                        Maybe.withDefault home import_.alias ++ "." ++ name



-- ====== FROM NAMES ======


{-| Creates a localizer under which every module named by a key of `names` counts
as imported with `exposing (..)`, so its types are printed bare. Types from any
other module are printed with their module's name. The values in `names` are
ignored.
-}
fromNames : Dict Name a -> Localizer
fromNames names =
    Localizer (Dict.map (\_ _ -> { alias = Nothing, exposing_ = All }) names)



-- ====== FROM MODULE ======


{-| Creates the localizer for a parsed module from its imports.

The module's own name counts as imported with `exposing (..)`, so its own types
are printed bare. The imports are those in `Src.ModuleData.imports`, which
begin with the default imports except in `elm/core`, as `Compiler.AST.Source`
describes.

When one module is imported more than once, only the last import of it counts.
So an explicit import of a module that is also imported by default, such as
`import Maybe exposing (withDefault)`, replaces the default import rather than
adding to it, and `Maybe` is then printed as `Maybe.Maybe`.

-}
fromModule : Src.Module -> Localizer
fromModule ((Src.Module srcData) as modul) =
    (( Src.getName modul, { alias = Nothing, exposing_ = All } ) :: List.map toPair srcData.imports) |> Dict.fromList |> Localizer


{-| Returns the name of the module an import brings in, paired with its alias
and the types it exposes. Comments and regions are dropped.
-}
toPair : Src.Import -> ( Name, Import )
toPair (Src.Import ( _, A.At _ name ) alias_ ( _, exposing_ )) =
    ( name
    , Import (Maybe.map Src.c2Value alias_) (toExposing exposing_)
    )


{-| Returns the types a source `exposing` list brings into scope bare: all of
them for `exposing (..)`, otherwise the types it names.
-}
toExposing : Src.Exposing -> Exposing
toExposing exposing_ =
    case exposing_ of
        Src.Open _ _ ->
            All

        Src.Explicit (A.At _ exposedList) ->
            Only (List.foldr addType EverySet.empty (List.map Src.c2Value exposedList))


{-| Adds `exposed` to `types` when it is a type, with or without `(..)`, and
returns `types` unchanged when it is a value or an operator.
-}
addType : Src.Exposed -> EverySet String Name -> EverySet String Name
addType exposed types =
    case exposed of
        Src.Lower _ ->
            types

        Src.Upper (A.At _ name) _ ->
            EverySet.insert identity name types

        Src.Operator _ _ ->
            types



-- ====== ENCODERS and DECODERS ======


{-| Encodes a localizer as its entries in ascending order of module name, each
an alias followed by an exposing list, in the form `localizerDecoder` reads.
-}
localizerEncoder : Localizer -> Bytes.Encode.Encoder
localizerEncoder (Localizer localizer) =
    BE.stdDict BE.string importEncoder localizer


{-| A decoder for a localizer written by `localizerEncoder`. It fails when an
entry's exposing list starts with a tag byte other than 0 or 1.
-}
localizerDecoder : Bytes.Decode.Decoder Localizer
localizerDecoder =
    Bytes.Decode.map Localizer (BD.stdDict BD.string importDecoder)


{-| Encodes an import as its alias, written as `Utils.Bytes.Encode.maybe` writes
it, followed by its exposing list.
-}
importEncoder : Import -> Bytes.Encode.Encoder
importEncoder import_ =
    Bytes.Encode.sequence
        [ BE.maybe BE.string import_.alias
        , exposingEncoder import_.exposing_
        ]


{-| A decoder for an import written by `importEncoder`. Any non-zero alias tag is
read as `Just`, as `Utils.Bytes.Decode.maybe` describes.
-}
importDecoder : Bytes.Decode.Decoder Import
importDecoder =
    Bytes.Decode.map2 Import
        (BD.maybe BD.string)
        exposingDecoder


{-| Encodes `All` as the tag byte 0, and `Only` as the tag byte 1 followed by
its type names, which are written in descending order, as
`Utils.Bytes.Encode.everySet` describes.
-}
exposingEncoder : Exposing -> Bytes.Encode.Encoder
exposingEncoder exposing_ =
    case exposing_ of
        All ->
            Bytes.Encode.unsignedInt8 0

        Only set ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.everySet compare BE.string set
                ]


{-| A decoder for an exposing list written by `exposingEncoder`. It fails on a
tag byte other than 0 or 1.
-}
exposingDecoder : Bytes.Decode.Decoder Exposing
exposingDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\type_ ->
                case type_ of
                    0 ->
                        Bytes.Decode.succeed All

                    1 ->
                        Bytes.Decode.map Only (BD.everySet identity BD.string)

                    _ ->
                        Bytes.Decode.fail
            )
