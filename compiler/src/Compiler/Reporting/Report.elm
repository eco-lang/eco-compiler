module Compiler.Reporting.Report exposing (Report(..), ReportProps, report)

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
