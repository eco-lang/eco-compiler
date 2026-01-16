module Compiler.Generate.MLIR.TypeTable exposing
    ( generateTypeTable
    , TypeKind(..)
    , PrimKind(..)
    )

{-| Type table generation for debug printing support.

This module generates the eco.type\_table op containing the global type graph
for runtime debug printing with arg\_type\_ids.

@docs generateTypeTable, TypeKind, PrimKind

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Data.Map as EveryDict
import Dict
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))



-- ====== TYPE KIND ENUMS ======


{-| Kind of type in the global type graph.
These values must match the C++ EcoTypeKind enum in TypeInfo.hpp.
-}
type TypeKind
    = TKPrimitive
    | TKList
    | TKTuple
    | TKRecord
    | TKCustom
    | TKFunction
    | TKPolymorphic


{-| Kind of primitive type.
These values must match the C++ EcoPrimKind enum in TypeInfo.hpp.
-}
type PrimKind
    = PKInt
    | PKFloat
    | PKChar
    | PKBool
    | PKString
    | PKUnit


{-| Convert a TypeKind to its integer tag for MLIR emission.
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


{-| Convert a PrimKind to its integer tag for MLIR emission.
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


{-| Accumulator for building the type graph arrays.
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
    , typeIds : Dict.Dict (List String) Int -- MonoType comparable key -> TypeId
    , ctorLayouts : EveryDict.Dict (List String) (List String) (List Mono.CtorLayout) -- type key -> ctor layouts
    }


{-| Generate the eco.type\_table op containing the global type graph.
This op holds all type descriptors for debug printing with arg\_type\_ids.
-}
generateTypeTable : Ctx.Context -> MlirOp
generateTypeTable ctx =
    let
        -- Sort typeInfos by typeId for deterministic output
        sortedTypes : List ( Int, Mono.MonoType )
        sortedTypes =
            ctx.typeRegistry.typeInfos
                |> List.sortBy Tuple.first

        -- Build accumulators for strings, fields, ctors, and func_args
        -- as we traverse the types
        emptyAccum =
            { strings = Dict.empty -- string -> index
            , nextStringIndex = 0
            , fields = [] -- List of field entries (reversed)
            , nextFieldIndex = 0
            , ctors = [] -- List of ctor entries (reversed)
            , nextCtorIndex = 0
            , funcArgs = [] -- List of arg type_ids (reversed)
            , nextFuncArgIndex = 0
            , typeAttrs = [] -- List of type descriptor attrs (reversed)
            , typeIds = ctx.typeRegistry.typeIds -- For looking up nested type IDs
            , ctorLayouts = ctx.typeRegistry.ctorLayouts -- For custom type constructors
            }

        -- Process each type and build all arrays
        finalAccum =
            List.foldl processType emptyAccum sortedTypes

        -- Build the eco.type_table op
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


{-| Get or create a string index in the string table.
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


{-| Process a single type entry and add it to the accumulator.
-}
processType : ( Int, Mono.MonoType ) -> TypeTableAccum -> TypeTableAccum
processType ( typeId, monoType ) accum =
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
            -- Unit is treated as a primitive for printing
            addPrimitiveType typeId PKUnit accum

        Mono.MList elemType ->
            addListType typeId elemType accum

        Mono.MTuple layout ->
            addTupleType typeId layout accum

        Mono.MRecord layout ->
            addRecordType typeId layout accum

        Mono.MCustom _ typeName _ ->
            addCustomType typeId typeName monoType accum

        Mono.MFunction argTypes resultType ->
            addFunctionType typeId argTypes resultType accum

        Mono.MVar _ constraint ->
            -- Polymorphic type variable - can leak through monomorphization
            -- The runtime will determine the actual type from the boxed value's tag
            addPolymorphicType typeId constraint accum


{-| Add a primitive type descriptor.
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


{-| Add a polymorphic type descriptor for a type variable with constraint.
Type kind 6 = Polymorphic
Constraint values: 0=number, 1=eco\_value (unconstrained)
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


{-| Look up a TypeId for a MonoType in the accumulator's typeIds dict.
Returns 0 if not found (should not happen for properly registered types).
-}
lookupTypeId : Mono.MonoType -> TypeTableAccum -> Int
lookupTypeId monoType accum =
    let
        key =
            Mono.toComparableMonoType monoType
    in
    Dict.get key accum.typeIds |> Maybe.withDefault 0


{-| Add a list type descriptor.
-}
addListType : Int -> Mono.MonoType -> TypeTableAccum -> TypeTableAccum
addListType typeId elemType accum =
    let
        elemTypeId =
            lookupTypeId elemType accum

        typeAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing typeId
                , IntAttr Nothing (typeKindToTag TKList)
                , IntAttr Nothing elemTypeId
                ]
    in
    { accum | typeAttrs = typeAttr :: accum.typeAttrs }


{-| Add a tuple type descriptor.
-}
addTupleType : Int -> Mono.TupleLayout -> TypeTableAccum -> TypeTableAccum
addTupleType typeId layout accum =
    let
        firstField =
            accum.nextFieldIndex

        fieldCount =
            layout.arity

        -- Add fields with actual type IDs
        accumWithFields =
            List.foldl
                (\( elemType, _ ) acc ->
                    let
                        elemTypeId =
                            lookupTypeId elemType acc

                        fieldAttr =
                            ArrayAttr Nothing
                                [ IntAttr Nothing 0 -- name_index: not used for tuples
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


{-| Add a record type descriptor.
-}
addRecordType : Int -> Mono.RecordLayout -> TypeTableAccum -> TypeTableAccum
addRecordType typeId layout accum =
    let
        firstField =
            accum.nextFieldIndex

        fieldCount =
            layout.fieldCount

        -- Add fields with names and actual type IDs
        accumWithFields =
            List.foldl
                (\fieldInfo acc ->
                    let
                        ( nameIndex, accWithString ) =
                            getOrCreateStringIndex (Name.toElmString fieldInfo.name) acc

                        fieldTypeId =
                            lookupTypeId fieldInfo.monoType accWithString

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


{-| Add a custom type descriptor with constructor information.
-}
addCustomType : Int -> Name.Name -> Mono.MonoType -> TypeTableAccum -> TypeTableAccum
addCustomType typeId typeName monoType accum =
    let
        -- Look up constructor layouts
        key =
            Mono.toComparableMonoType monoType

        ctorLayouts =
            EveryDict.get identity key accum.ctorLayouts
                |> Maybe.withDefault []
                |> List.sortBy .tag

        firstCtor =
            accum.nextCtorIndex

        ctorCount =
            List.length ctorLayouts

        -- Add each constructor and its fields
        accumWithCtors =
            List.foldl addCtorInfo accum ctorLayouts

        typeAttr =
            ArrayAttr Nothing
                [ IntAttr Nothing typeId
                , IntAttr Nothing (typeKindToTag TKCustom)
                , IntAttr Nothing firstCtor
                , IntAttr Nothing ctorCount
                ]
    in
    { accumWithCtors | typeAttrs = typeAttr :: accumWithCtors.typeAttrs }


{-| Add constructor info for a single constructor.
-}
addCtorInfo : Mono.CtorLayout -> TypeTableAccum -> TypeTableAccum
addCtorInfo ctorLayout accum =
    let
        -- Add constructor name to string table
        ( nameIndex, accWithName ) =
            getOrCreateStringIndex (Name.toElmString ctorLayout.name) accum

        firstField =
            accWithName.nextFieldIndex

        fieldCount =
            List.length ctorLayout.fields

        -- Add fields for this constructor
        accumWithFields =
            List.foldl
                (\fieldInfo acc ->
                    let
                        fieldTypeId =
                            lookupTypeId fieldInfo.monoType acc

                        -- Field attr: [name_index, type_id]
                        -- For constructor fields, name is typically not used,
                        -- but we include it for completeness
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

        -- Constructor attr: [ctor_id, name_index, first_field, field_count]
        -- Note: ctor_id comes from ctorLayout.tag (the constructor's index within its type)
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


{-| Add a function type descriptor.
-}
addFunctionType : Int -> List Mono.MonoType -> Mono.MonoType -> TypeTableAccum -> TypeTableAccum
addFunctionType typeId argTypes resultType accum =
    let
        firstArgType =
            accum.nextFuncArgIndex

        argCount =
            List.length argTypes

        -- Add arg type_ids with actual type IDs
        accumWithArgs =
            List.foldl
                (\argType acc ->
                    let
                        argTypeId =
                            lookupTypeId argType acc
                    in
                    { acc
                        | funcArgs = argTypeId :: acc.funcArgs
                        , nextFuncArgIndex = acc.nextFuncArgIndex + 1
                    }
                )
                accum
                argTypes

        resultTypeId =
            lookupTypeId resultType accumWithArgs

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
