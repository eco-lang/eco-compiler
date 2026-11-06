module CompilerIssue1789RankCrashMissingJustTest exposing (..)

{-| A missing `Just` in a case branch crashes the type checker with `[rank = 1]`.

<https://github.com/elm/compiler/issues/1789>

`toForm model` should be `Just (toForm model)`. Elm 0.19.1 crashes ("You ran into a compiler
bug"); it should report a type mismatch.

-}

-- COMPILE-ERROR: missing Just in a case branch
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: compiler bug

import Html


type Form model formData
    = SimpleForm (model -> formData)
    | AdvancedForm (model -> Bool)


initForm : Form model formData -> model -> Maybe formData
initForm formHelper model =
    case formHelper of
        SimpleForm toForm ->
            toForm model

        AdvancedForm _ ->
            Nothing


type alias Model internalModel formData =
    { internalModel : internalModel
    , form : formData
    }


processAction : Form internalModel formData -> Model internalModel formData -> Model internalModel formData
processAction formHelper model =
    { model | form = initForm formHelper model.internalModel }


main =
    Html.text ""
