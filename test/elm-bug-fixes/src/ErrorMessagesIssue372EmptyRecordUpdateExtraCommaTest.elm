module ErrorMessagesIssue372EmptyRecordUpdateExtraCommaTest exposing (main)

{-| A record update with no fields, `{ key | }`, is reported as an EXTRA COMMA, although the
program has no comma at all.

<https://github.com/elm/error-message-catalog/issues/372>

Elm 0.19.1 reports `-- EXTRA COMMA` and says "Try deleting the comma that appears before this
closing curly brace". The program is still wrong (a record update needs a field), but the
report must not blame a comma that does not exist.

Fixed in Elm 0.19.2.

-}

-- COMPILE-ERROR: record update without fields
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: -- EXTRA COMMA
-- CHECK-NOT: deleting the comma

import Html exposing (text)


g key =
    { key | }


main =
    text "done"
