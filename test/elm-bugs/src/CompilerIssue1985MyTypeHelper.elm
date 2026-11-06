module CompilerIssue1985MyTypeHelper exposing (TheType)

{-| Helper for CompilerIssue1985ImportOrderTypeAmbiguityTest. -}

import CompilerIssue1985SomeTypeHelper


type alias TheType =
    CompilerIssue1985SomeTypeHelper.TheType Int
