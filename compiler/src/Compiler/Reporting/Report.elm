module Compiler.Reporting.Report exposing
    ( Report(..), ReportProps
    , report
    )

{-| Core data structure for compiler error and warning reports.

A Report packages together all the information needed to display a helpful
compiler diagnostic message: a title, source location, suggested fixes, and
formatted documentation describing the issue.


# Types

@docs Report, ReportProps


# Construction

@docs report

-}

import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D



-- BUILD REPORTS


type Report
    = Report ReportProps


type alias ReportProps =
    { title : String
    , region : A.Region
    , suggestions : List String
    , doc : D.Doc
    }


{-| Helper constructor for backward compatibility.
Allows existing code to continue using positional arguments:
`Report.report "title" region suggestions doc`
-}
report : String -> A.Region -> List String -> D.Doc -> Report
report title region suggestions doc =
    Report
        { title = title
        , region = region
        , suggestions = suggestions
        , doc = doc
        }
