module Compiler.AST.LayoutShapes exposing
    ( MRecordShape
    , MTupleShape
    , CtorShape
    , toComparableRecordShape
    , toComparableTupleShape
    , toComparableCtorShape
    )

{-| Backend-agnostic shape types for monomorphization.

These types capture the semantic structure of types without backend-specific
layout decisions (field ordering, unboxing bitmaps, indices, etc.).

The monomorphization phase produces these shapes, and a separate layout phase
converts them to backend-specific layouts with field indices and unboxing info.


# Types

@docs MRecordShape, MTupleShape, CtorShape


# Comparable Conversions

@docs toComparableRecordShape, toComparableTupleShape, toComparableCtorShape

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Data.Map as Dict exposing (Dict)


{-| Backend-agnostic record shape: field names and types without layout info.

Unlike RecordLayout, this does not include:

  - Field indices (ordering is backend-specific)
  - Unboxed bitmap (unboxing decisions are backend-specific)
  - Field count (derivable from fields dict)

-}
type alias MRecordShape =
    { fields : Dict String Name Mono.MonoType
    }


{-| Backend-agnostic tuple shape: element types without unboxing info.

Unlike TupleLayout, this does not include:

  - Unboxed bitmap (unboxing decisions are backend-specific)
  - isUnboxed flags per element

-}
type alias MTupleShape =
    { elements : List Mono.MonoType
    }


{-| Backend-agnostic constructor shape: name, tag, field types without layout.

Unlike CtorLayout, this does not include:

  - Field indices
  - Unboxed bitmap
  - FieldInfo records (just raw types)

-}
type alias CtorShape =
    { name : Name
    , tag : Int
    , fieldTypes : List Mono.MonoType
    }



-- ========== COMPARABLE CONVERSIONS ==========


{-| Convert a record shape to a comparable representation for use in Dict/Set.
-}
toComparableRecordShape : MRecordShape -> List ( String, List String )
toComparableRecordShape shape =
    Dict.toList compare shape.fields
        |> List.map (\( name, monoType ) -> ( name, Mono.toComparableMonoType monoType ))


{-| Convert a tuple shape to a comparable representation for use in Dict/Set.
-}
toComparableTupleShape : MTupleShape -> List (List String)
toComparableTupleShape shape =
    List.map Mono.toComparableMonoType shape.elements


{-| Convert a constructor shape to a comparable representation for use in Dict/Set.
-}
toComparableCtorShape : CtorShape -> ( String, Int, List (List String) )
toComparableCtorShape shape =
    ( shape.name
    , shape.tag
    , List.map Mono.toComparableMonoType shape.fieldTypes
    )
