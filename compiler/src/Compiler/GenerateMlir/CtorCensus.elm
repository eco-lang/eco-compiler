module Compiler.GenerateMlir.CtorCensus exposing
    ( Table, empty, build, isOn
    , idForShape, idForBytesFusionJust
    , render
    , levelOf, payloadClass
    )

{-| The constructor census (plans/constructor-representation-levels.md §3, unit
M0): every `eco.construct.custom` and `eco.make.custom` the compiler emits is
tagged with the id of its constructor class, and the runtime counts, per id,
the allocations, the SSA constructions and the minor-GC promotions.

A class is a constructor of a custom type together with the type's level and a
payload class:

  - level 1: one constructor with one field; level 2: one constructor with
    several fields; level 3: several constructors with at most one field each;
    level 4: the rest.
  - the payload class says, for a level-1 constructor, whether its field is
    `boxed` or `unboxed` (Int, Float, Char), and for a one-field constructor of
    a level-3 type, whether the field type is admissible for the nullable
    representation (`adm`, `spare` when it needs a spare null word, `inadm`; see
    `Compiler.MonoOpt.NullableMaybe.censusClass`).
    It is `-` otherwise. A `+kv` suffix marks a kernel-visible type
    (`Compiler.MonoOpt.KernelVisible`, MONO_032).
  - the tagged column is the F1 tagged-word form of a constructor of a type with
    two or more constructors (`Compiler.MonoOpt.TaggedUnions`,
    plans/constructor-representation-followups.md F1.0): `bare`, an `alloc-*`
    reason, or `excluded-<reason>`; `-` for a one-constructor type.

Ids start at 1 and are at most 32,767, the width of the header field the
runtime keeps them in; id 0 is "unattributed". The table is written by
`render` and joined with the runtime's counts by `scripts/ctor-census.py`.

@docs Table, empty, build, isOn
@docs idForShape, idForBytesFusionJust
@docs render
@docs levelOf, payloadClass

-}

import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.NullableMaybe as NullableMaybe
import Dict exposing (Dict)
import Set


{-| The census classes of one program, by the key `idForShape` looks up.
-}
type alias Table =
    { byShape : Dict String Int
    , rows : List ( Int, String )
    , on : Bool
    }


{-| The table of a program compiled without the census: every lookup gives
`Nothing`.
-}
empty : Table
empty =
    { byShape = Dict.empty, rows = [], on = False }


{-| Returns whether the census is on.
-}
isOn : Table -> Bool
isOn table =
    table.on


maxId : Int
maxId =
    32767


{-| The level of a custom type with constructors `shapes`.
-}
levelOf : List Mono.CtorShape -> Int
levelOf shapes =
    case shapes of
        [ one ] ->
            if List.length one.fieldTypes <= 1 then
                1

            else
                2

        _ ->
            if List.all (\s -> List.length s.fieldTypes <= 1) shapes then
                3

            else
                4


{-| The payload class of the constructor `shape` of a type with constructors
`shapes` (see the module docs).
-}
payloadClass : (Mono.MonoType -> Maybe (List Mono.CtorShape)) -> Mono.MonoType -> List Mono.CtorShape -> Mono.CtorShape -> String
payloadClass shapesOf customType shapes shape =
    case ( levelOf shapes, shape.fieldTypes ) of
        ( 1, [ field ] ) ->
            case field of
                Mono.MInt ->
                    "unboxed"

                Mono.MFloat ->
                    "unboxed"

                Mono.MChar ->
                    "unboxed"

                _ ->
                    "boxed"

        ( 3, [ field ] ) ->
            if NullableMaybe.isMaybeType customType then
                NullableMaybe.censusClass shapesOf True field

            else if maybeShaped shapes then
                NullableMaybe.censusClass shapesOf False field

            else
                "-"

        _ ->
            "-"


maybeShaped : List Mono.CtorShape -> Bool
maybeShaped shapes =
    case List.map (\s -> List.length s.fieldTypes) shapes |> List.sort of
        [ 0, 1 ] ->
            True

        _ ->
            False


shapeKey : String -> List Mono.MonoType -> String
shapeKey ctorName fieldTypes =
    ctorName ++ "|" ++ String.join "," (List.map Mono.toComparableLayoutType fieldTypes)


{-| Builds the census table from the program's constructor shapes, or `empty`
when `on` is false.
-}
build : Bool -> List ( String, String ) -> Mono.LayoutMap (List ( String, String )) -> Mono.LayoutMap (List Mono.CtorShape) -> Table
build on kernelVisible tagCensus ctorShapes =
    if not on then
        empty

    else
        let
            shapesOf t =
                Mono.layoutMapGet t ctorShapes

            kv =
                Set.fromList kernelVisible

            -- ( class key, shape key ) for every constructor with fields.
            entries : List ( String, String )
            entries =
                Mono.layoutMapFoldl
                    (\key shapes acc ->
                        case key of
                            Mono.MCustom _ home typeName _ ->
                                List.filterMap
                                    (\shape ->
                                        if List.isEmpty shape.fieldTypes then
                                            Nothing

                                        else
                                            Just
                                                ( String.join "\t"
                                                    [ String.fromInt (levelOf shapes)
                                                    , ModuleName.toComparableCanonical home
                                                    , typeName
                                                    , shape.name
                                                    , String.fromInt (List.length shape.fieldTypes)
                                                    , payloadClass shapesOf key shapes shape
                                                        ++ (if Set.member ( ModuleName.toComparableCanonical home, typeName ) kv then
                                                                "+kv"

                                                            else
                                                                ""
                                                           )
                                                    , Mono.layoutMapGet key tagCensus
                                                        |> Maybe.andThen (List.filter (\( c, _ ) -> c == shape.name) >> List.head)
                                                        |> Maybe.map Tuple.second
                                                        |> Maybe.withDefault "-"
                                                    ]
                                                , shapeKey shape.name shape.fieldTypes
                                                )
                                    )
                                    shapes
                                    ++ acc

                            _ ->
                                acc
                    )
                    []
                    ctorShapes
                    ++ [ ( bytesFusionJustClass, bytesFusionJustKey ) ]

            classIds : Dict String Int
            classIds =
                entries
                    |> List.map Tuple.first
                    |> List.sort
                    |> List.foldl
                        (\cls acc ->
                            if Dict.member cls acc then
                                acc

                            else
                                let
                                    next =
                                        Dict.size acc + 1
                                in
                                Dict.insert cls
                                    (if next > maxId then
                                        0

                                     else
                                        next
                                    )
                                    acc
                        )
                        Dict.empty

            byShape : Dict String Int
            byShape =
                List.foldl
                    (\( cls, sk ) acc ->
                        if Dict.member sk acc then
                            acc

                        else
                            Dict.insert sk (Dict.get cls classIds |> Maybe.withDefault 0) acc
                    )
                    Dict.empty
                    (List.sortBy Tuple.first entries)
        in
        { byShape = byShape
        , rows =
            Dict.toList classIds
                |> List.filter (\( _, id ) -> id > 0)
                |> List.map (\( cls, id ) -> ( id, cls ))
                |> List.sortBy Tuple.first
        , on = True
        }


bytesFusionJustClass : String
bytesFusionJustClass =
    String.join "\t" [ "3", ModuleName.toComparableCanonical ModuleName.maybe, "Maybe", "Just", "1", "bf", "-" ]


bytesFusionJustKey : String
bytesFusionJustKey =
    "Just|<bytes-fusion>"


{-| The census id of a construction of the constructor `ctorName` with field
types `fieldTypes`, or `Nothing` when the census is off. A constructor the
table does not know gets id 0.
-}
idForShape : Table -> String -> List Mono.MonoType -> Maybe Int
idForShape table ctorName fieldTypes =
    if table.on then
        Just (Dict.get (shapeKey ctorName fieldTypes) table.byShape |> Maybe.withDefault 0)

    else
        Nothing


{-| The census id of a `Just` that bytes decoder fusion builds, whose payload
type it knows only as an MLIR type.
-}
idForBytesFusionJust : Table -> Maybe Int
idForBytesFusionJust table =
    if table.on then
        Just (Dict.get bytesFusionJustKey table.byShape |> Maybe.withDefault 0)

    else
        Nothing


{-| The table as tab-separated text, one class per line:
`id level home type ctor fields payload tagged`.
-}
render : Table -> String
render table =
    "id\tlevel\thome\ttype\tctor\tfields\tpayload\ttagged\n"
        ++ String.concat (List.map (\( id, cls ) -> String.fromInt id ++ "\t" ++ cls ++ "\n") table.rows)
