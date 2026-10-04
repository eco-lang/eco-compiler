module Compiler.Reporting.Report exposing
    ( Report(..), ReportProps
    , report
    )

{-| Each error the compiler finds in a module, of whatever kind, is described as
a report, so that showing it to a person, or encoding it as JSON, does not
depend on which phase of the compiler found it. This module defines that shape.

A _report_ is one error, described by a short title naming the kind of problem,
the region of the source it concerns, a list of suggested alternatives, and the
message itself. The message is a `Doc`, the document type of
`Compiler.Reporting.Doc`, so it is laid out only when it is rendered.

@docs Report, ReportProps
@docs report

-}

import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D


{-| One error report, as the module docstring describes.
-}
type Report
    = Report ReportProps


{-| The contents of a report.

`suggestions` holds alternatives the producer of the report offers, such as
known names close to one that could not be found. It may be empty. No renderer
shows them; any suggestion the user sees is written into `doc` by the producer.
`doc` is the whole message, and nothing in this module adds the title or the
region to it.

-}
type alias ReportProps =
    { title : String
    , region : A.Region
    , suggestions : List String
    , doc : D.Doc
    }


{-| Builds a `Report` from its title, region, suggestions and message, in that
order.
-}
report : String -> A.Region -> List String -> D.Doc -> Report
report title region suggestions doc =
    Report
        { title = title
        , region = region
        , suggestions = suggestions
        , doc = doc
        }
