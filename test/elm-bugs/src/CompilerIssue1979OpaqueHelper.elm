module CompilerIssue1979OpaqueHelper exposing (Opaque, make)

{-| Helper for CompilerIssue1979ImportOpaqueConstructorsTest: an opaque type. -}


type Opaque
    = Opaque


make : Opaque
make =
    Opaque
