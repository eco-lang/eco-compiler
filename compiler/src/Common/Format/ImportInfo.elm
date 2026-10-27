module Common.Format.ImportInfo exposing
    ( ImportInfo
    , fromModule
    )

{-| A placeholder for the import information the formatter could consult.

An `ImportInfo` value records nothing about a module's imports: the type has a
single constructor with no fields, and `fromModule` is that constructor. The type
exists so that formatting functions can take an import-information argument
without depending on any import data.


# Types

@docs ImportInfo


# Building Import Information

@docs fromModule

-}


{-| Import information for a module, which currently carries no data. Every value
of this type is the same.
-}
type ImportInfo
    = ImportInfo


{-| The one `ImportInfo` value. It takes no module and reads no imports.
-}
fromModule : ImportInfo
fromModule =
    fromImports


{-| The one `ImportInfo` value; `fromModule` is defined as this.
-}
fromImports : ImportInfo
fromImports =
    ImportInfo
