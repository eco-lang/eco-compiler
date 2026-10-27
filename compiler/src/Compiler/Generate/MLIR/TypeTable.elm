module Compiler.Generate.MLIR.TypeTable exposing (generateTypeTable, TypeKind, PrimKind)

{-| A program's runtime can print an Elm value only if it knows the value's type,
and this module writes down every type the generated code refers to, in a form
the runtime can read.

During code generation each `MonoType` that needs describing is given a _type
id_, a small integer, in the type registry of `Compiler.Generate.MLIR.Context`.
Debug printing names a value's type by that id. The _type table_ is one
module-level `eco.type_table` op that says what each id means. `generateTypeTable`
builds it from the registry as it stands when called, so a type registered
afterwards is missing from it.

The table is five flat array attributes, and an entry refers to entries of
the other arrays by position:

  - `types` holds one descriptor per registered type, in type-id order. Each
    begins `[id, kind]`, where kind is the tag of a `TypeKind`, and the rest
    depends on the kind: a primitive adds its `PrimKind` tag; a list adds its
    element's type id; a tuple adds its arity, its first field and its field
    count; a record its first field and field count; a custom type its first
    constructor and constructor count; a function its first argument, its
    argument count and its result's type id; a type variable adds 0 for a
    `number` variable and 1 for any other.
  - `fields` holds `[name_index, type_id]` pairs, shared by tuples, records and
    constructors. A tuple field's name index is always 0 and means nothing.
  - `ctors` holds `[tag, name_index, first_field, field_count]` per constructor.
  - `func_args` holds the type ids of function arguments.
  - `strings` holds the field and constructor names, each once; a name index is
    a position here.

Record fields appear in the order of `Types.computeRecordLayout` (unboxed
fields first, each group by name), not source order. Constructor fields carry
the names `Types.computeCtorLayout` gives them, `field0`, `field1` and so on, and
a custom type's constructors are listed by tag. A type that is not in the
registry where an entry needs its id is written as type id 0.

@docs generateTypeTable, TypeKind, PrimKind

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp)



-- ====== TYPE KIND ENUMS ======


{-| The kind of a type-table descriptor, which decides how the rest of the
descriptor is read.

Each kind is written as its tag from `typeKindToTag`, `TKPrimitive` 0 through
`TKPolymorphic` 6 in declaration order. The runtime reads these numbers, so they
must agree with its own numbering of type kinds.

`TKPolymorphic` is a type variable left open by monomorphization.

-}
type TypeKind
    = TKPrimitive
    | TKList
    | TKTuple
    | TKRecord
    | TKCustom
    | TKFunction
    | TKPolymorphic


{-| The primitive type a `TKPrimitive` descriptor stands for.

Each is written as its tag from `primKindToTag`, `PKInt` 0 through `PKUnit` 5 in
declaration order, and the runtime must number them the same way. `PKUnit` is
the unit type `()`.

-}
type PrimKind
    = PKInt
    | PKFloat
    | PKChar
    | PKBool
    | PKString
    | PKUnit


{-| Returns the integer written into a descriptor for `kind`.
-}
typeKindToTag : TypeKind -> Int
typeKindToTag kind =
    case kind of
        TKPrimitive ->
            0

        TKList ->
            1

        TKTuple ->
            2

        TKRecord ->
            3

        TKCustom ->
            4

        TKFunction ->
            5

        TKPolymorphic ->
            6


{-| Returns the integer written into a primitive descriptor for `primKind`.
-}
primKindToTag : PrimKind -> Int
primKindToTag primKind =
    case primKind of
        PKInt ->
            0

        PKFloat ->
            1

        PKChar ->
            2

        PKBool ->
            3

        PKString ->
            4

        PKUnit ->
            5



-- ====== TYPE TABLE GENERATION ======


{-| The type table part-built: the arrays so far, each held newest first, and
the position the next entry of each will take.

`strings` maps each name to its index in the string array. `ctorShapes` is the
registry's constructor table, carried so that a custom type can find its
constructors.

-}
type alias TypeTableAccum =
    { strings : Dict.Dict String Int
    , nextStringIndex : Int
    , fields : List MlirAttr
    , nextFieldIndex : Int
    , ctors : List MlirAttr
    , nextCtorIndex : Int
    , funcArgs : List Int
    , nextFuncArgIndex : Int
    , typeAttrs : List MlirAttr
    , ctorShapes : Mono.LayoutMap (List Mono.CtorShape)
    }


{-| Builds the `eco.type_table` op describing every type in the context's type
registry, as the module docstring lays it out.
-}
generateTypeTable : Ctx.Context -> MlirOp
generateTypeTable ctx =
    let
        sortedTypes : List ( Int, Mono.MonoType )
        sortedTypes =
            ctx.typeRegistry.typeInfos
                |> List.sortBy Tuple.first

        typeIds =
            ctx.typeRegistry.typeIds

        emptyAccum =
            { strings = Dict.empty
            , nextStringIndex = 0
            , fields = []
            , nextFieldIndex = 0
            , ctors = []
            , nextCtorIndex = 0
            , funcArgs = []
            , nextFuncArgIndex = 0
            , typeAttrs = []
            , ctorShapes = ctx.typeRegistry.ctorShapes
            }

        finalAccum =
            List.foldl (processType typeIds) emptyAccum sortedTypes

        typesAttr =
            ArrayAttr Nothing (List.reverse finalAccum.typeAttrs)

        fieldsAttr =
            ArrayAttr Nothing (List.reverse finalAccum.fields)

        ctorsAttr =
            ArrayAttr Nothing (List.reverse finalAccum.ctors)

        funcArgsAttr =
            ArrayAttr Nothing (List.reverse finalAccum.funcArgs |> List.map (\i -> IntAttr Nothing i))

        stringsAttr =
            finalAccum.strings
                |> Dict.toList
                |> List.sortBy Tuple.second
                |> List.map (\( s, _ ) -> StringAttr s)
                |> ArrayAttr Nothing
    in
    { name = "eco.type_table"
    , id = ""
    , operands = []
    , results = []
    , attrs =
        Dict.empty
            |> Dict.insert "types" typesAttr
            |> Dict.insert "fields" fieldsAttr
            |> Dict.insert "ctors" ctorsAttr
            |> Dict.insert "func_args" funcArgsAttr
            |> Dict.insert "strings" stringsAttr
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


{-| Returns the index of `str` in the string table, adding it at the next
index if it is not there yet.
-}
getOrCreateStringIndex : String -> TypeTableAccum -> ( Int, TypeTableAccum )
getOrCreateStringIndex str accum =
    case Dict.get str accum.strings of
        Just idx ->
            ( idx, accum )

        Nothing ->
            ( accum.nextStringIndex
            , { accum
                | strings = Dict.insert str accum.nextStringIndex accum.strings
                , nextStringIndex = accum.nextStringIndex + 1
              }
            )


{-| Adds the descriptor for one registered type, with any fields, constructors
and argument entries it needs, to the table.
-}
processType : Mono.LayoutMap Int -> ( Int, Mono.MonoType ) -> TypeTableAccum -> TypeTableAccum
processType typeIds ( typeId, monoType ) accum =
    case monoType of
        Mono.MInt ->
            addPrimitiveType typeId PKInt accum

        Mono.MFloat ->
            addPrimitiveType typeId PKFloat accum

        Mono.MChar ->
            addPrimitiveType typeId PKChar accum

        Mono.MBool ->
            addPrimitiveType typeId PKBool accum

        Mono.MString ->
            addPrimitiveType typeId PKString accum

        Mono.MUnit ->
            addPrimitiveType typeId PKUnit accum

        Mono.MList _ elemType ->
            addListType typeIds typeId elemType accum

        Mono.MTuple _ elementTypes ->
            addTupleType typeIds typeId (Types.computeTupleLayout elementTypes) accum

        Mono.MRecord _ fields ->
            addRecordType typeIds typeId (Types.computeRecordLayout fields) accum

        Mono.MCustom _ _ _ _ ->
            addCustomType typeIds typeId monoType accum

        Mono.MFunction _ _ argTypes resultType ->
            addFunctionType typeIds typeId argTypes resultType accum

        Mono.MVar _ constraint ->
            addPolymorphicType typeId constraint accum


{-| Adds the descriptor `[typeId, 0, primKind]`.
-}
addPrimitiveType : Int -> PrimKind -> TypeTableAccum -> TypeTableAccum
addPrimitiveType typeId primKind accum =
    let
        typeAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing typeId
                , IntAttr Nothing (typeKindToTag TKPrimitive)
                , IntAttr Nothing (primKindToTag primKind)
                ]
    in
    { accum | typeAttrs = typeAttr :: accum.typeAttrs }


{-| Adds the descriptor of a type variable: `[typeId, 6, c]`, where `c` is 0 for
a `number` variable and 1 for any other.
-}
addPolymorphicType : Int -> Mono.Constraint -> TypeTableAccum -> TypeTableAccum
addPolymorphicType typeId constraint accum =
    let
        constraintValue =
            case constraint of
                Mono.CNumber ->
                    0

                Mono.CEcoValue ->
                    1

        typeAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing typeId
                , IntAttr Nothing (typeKindToTag TKPolymorphic)
                , IntAttr Nothing constraintValue
                ]
    in
    { accum | typeAttrs = typeAttr :: accum.typeAttrs }


{-| Returns the type id registered for `monoType`, or 0 if it has none.

The lookup uses the layout key (see `Mono.LayoutMap`), under which types that
differ only in lambda sets, a `number` variable and `Int`, or any two
unconstrained variables share an id. The 0 is indistinguishable from the real id 0.

-}
lookupTypeId : Mono.LayoutMap Int -> Mono.MonoType -> Int
lookupTypeId typeIds monoType =
    Mono.layoutMapGet monoType typeIds |> Maybe.withDefault 0


{-| Adds the descriptor `[typeId, 1, element type id]`.
-}
addListType : Mono.LayoutMap Int -> Int -> Mono.MonoType -> TypeTableAccum -> TypeTableAccum
addListType typeIds typeId elemType accum =
    let
        elemTypeId =
            lookupTypeId typeIds elemType

        typeAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing typeId
                , IntAttr Nothing (typeKindToTag TKList)
                , IntAttr Nothing elemTypeId
                ]
    in
    { accum | typeAttrs = typeAttr :: accum.typeAttrs }


{-| Adds a tuple's descriptor and one field entry per element, in element
order, each with name index 0.

Arity and field count are written as two separate numbers and are always equal.

-}
addTupleType : Mono.LayoutMap Int -> Int -> Types.TupleLayout -> TypeTableAccum -> TypeTableAccum
addTupleType typeIds typeId layout accum =
    let
        firstField =
            accum.nextFieldIndex

        fieldCount =
            layout.arity

        accumWithFields =
            List.foldl
                (\( elemType, _ ) acc ->
                    let
                        elemTypeId =
                            lookupTypeId typeIds elemType

                        fieldAttr =
                            ArrayAttr Nothing
                                [ IntAttr Nothing 0
                                , IntAttr Nothing elemTypeId
                                ]
                    in
                    { acc
                        | fields = fieldAttr :: acc.fields
                        , nextFieldIndex = acc.nextFieldIndex + 1
                    }
                )
                accum
                layout.elements

        typeAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing typeId
                , IntAttr Nothing (typeKindToTag TKTuple)
                , IntAttr Nothing layout.arity
                , IntAttr Nothing firstField
                , IntAttr Nothing fieldCount
                ]
    in
    { accumWithFields | typeAttrs = typeAttr :: accumWithFields.typeAttrs }


{-| Adds a record's descriptor and one named field entry per field, in the
order of `layout`.
-}
addRecordType : Mono.LayoutMap Int -> Int -> Types.RecordLayout -> TypeTableAccum -> TypeTableAccum
addRecordType typeIds typeId layout accum =
    let
        firstField =
            accum.nextFieldIndex

        fieldCount =
            layout.fieldCount

        accumWithFields =
            List.foldl
                (\fieldInfo acc ->
                    let
                        ( nameIndex, accWithString ) =
                            getOrCreateStringIndex (Name.toElmString fieldInfo.name) acc

                        fieldTypeId =
                            lookupTypeId typeIds fieldInfo.monoType

                        fieldAttr =
                            ArrayAttr Nothing
                                [ IntAttr Nothing nameIndex
                                , IntAttr Nothing fieldTypeId
                                ]
                    in
                    { accWithString
                        | fields = fieldAttr :: accWithString.fields
                        , nextFieldIndex = accWithString.nextFieldIndex + 1
                    }
                )
                accum
                layout.fields

        typeAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing typeId
                , IntAttr Nothing (typeKindToTag TKRecord)
                , IntAttr Nothing firstField
                , IntAttr Nothing fieldCount
                ]
    in
    { accumWithFields | typeAttrs = typeAttr :: accumWithFields.typeAttrs }


{-| Adds a custom type's descriptor and an entry for each of its constructors,
in tag order.

The constructors are those the registry's `ctorShapes` holds for `monoType`
under the layout key. A type with no entry there is described with no
constructors.

-}
addCustomType : Mono.LayoutMap Int -> Int -> Mono.MonoType -> TypeTableAccum -> TypeTableAccum
addCustomType typeIds typeId monoType accum =
    let
        ctorShapes =
            Mono.layoutMapGet monoType accum.ctorShapes
                |> Maybe.withDefault []
                |> List.sortBy .tag

        firstCtor =
            accum.nextCtorIndex

        ctorCount =
            List.length ctorShapes

        accumWithCtors =
            List.foldl (addCtorInfo typeIds) accum ctorShapes

        typeAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing typeId
                , IntAttr Nothing (typeKindToTag TKCustom)
                , IntAttr Nothing firstCtor
                , IntAttr Nothing ctorCount
                ]
    in
    { accumWithCtors | typeAttrs = typeAttr :: accumWithCtors.typeAttrs }


{-| Adds one constructor's entry and its field entries, named `field0`,
`field1` and so on in declaration order.
-}
addCtorInfo : Mono.LayoutMap Int -> Mono.CtorShape -> TypeTableAccum -> TypeTableAccum
addCtorInfo typeIds ctorShape accum =
    let
        ctorLayout =
            Types.computeCtorLayout ctorShape

        ( nameIndex, accWithName ) =
            getOrCreateStringIndex (Name.toElmString ctorLayout.name) accum

        firstField =
            accWithName.nextFieldIndex

        fieldCount =
            List.length ctorLayout.fields

        accumWithFields =
            List.foldl
                (\fieldInfo acc ->
                    let
                        fieldTypeId =
                            lookupTypeId typeIds fieldInfo.monoType

                        ( fieldNameIndex, accWithFieldName ) =
                            getOrCreateStringIndex (Name.toElmString fieldInfo.name) acc

                        fieldAttr =
                            ArrayAttr Nothing
                                [ IntAttr Nothing fieldNameIndex
                                , IntAttr Nothing fieldTypeId
                                ]
                    in
                    { accWithFieldName
                        | fields = fieldAttr :: accWithFieldName.fields
                        , nextFieldIndex = accWithFieldName.nextFieldIndex + 1
                    }
                )
                accWithName
                ctorLayout.fields

        ctorAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing ctorLayout.tag
                , IntAttr Nothing nameIndex
                , IntAttr Nothing firstField
                , IntAttr Nothing fieldCount
                ]
    in
    { accumWithFields
        | ctors = ctorAttr :: accumWithFields.ctors
        , nextCtorIndex = accumWithFields.nextCtorIndex + 1
    }


{-| Adds a function's descriptor and one `func_args` entry per argument.

The arguments are those of this `MFunction` node only, so a curried function
type whose result is another function is described with that function as its
result.

-}
addFunctionType : Mono.LayoutMap Int -> Int -> List Mono.MonoType -> Mono.MonoType -> TypeTableAccum -> TypeTableAccum
addFunctionType typeIds typeId argTypes resultType accum =
    let
        firstArgType =
            accum.nextFuncArgIndex

        argCount =
            List.length argTypes

        accumWithArgs =
            List.foldl
                (\argType acc ->
                    let
                        argTypeId =
                            lookupTypeId typeIds argType
                    in
                    { acc
                        | funcArgs = argTypeId :: acc.funcArgs
                        , nextFuncArgIndex = acc.nextFuncArgIndex + 1
                    }
                )
                accum
                argTypes

        resultTypeId =
            lookupTypeId typeIds resultType

        typeAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing typeId
                , IntAttr Nothing (typeKindToTag TKFunction)
                , IntAttr Nothing firstArgType
                , IntAttr Nothing argCount
                , IntAttr Nothing resultTypeId
                ]
    in
    { accumWithArgs | typeAttrs = typeAttr :: accumWithArgs.typeAttrs }
