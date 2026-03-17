var yargs = require("yargs");

module.exports = config =>
    yargs
        .command({
            command: "$0 [path]",
            desc: "Run tests and generate code coverage",
            builder: compose(runnerOptions, globalOptions),
            handler: config.run
        })
        .command({
            command: "generate [path]",
            desc: "Generate a report from previously capture data.",
            builder: globalOptions,
            handler: config.generateOnly
        });

function compose() {
    var fns = Array.from(arguments);
    return arg => fns.reduce((acc, f) => f(acc), arg);
}

var runnerOptions = yargs =>
    yargs
        .option("elm-test", {
            describe: "Path to the elm-test executable",
            default: "elm-test-rs",
            type: "string"
        })
        .option("force", {
            describe:
                "Continue generating coverage report even when tests fail. Use --no-force to stop on test failure.",
            alias: "f",
            default: true,
            type: "boolean"
        })
        .option("silent", {
            describe: "Suppress `elm-test` output",
            alias: "s",
            default: false,
            type: "boolean"
        })
        .option("tests", {
            describe: "Path to your tests. Will be passed along to `elm-test`.",
            alias: "t",
            default: "tests/",
            type: "string"
        })
        .epilog("Thanks <3");

var globalOptions = yargs =>
    yargs
        .positional("path", {
            describe:
                "Where are your sources located? This path will be " +
                "scanned (recursively) and files instrumented.",
            type: "string",
            default: "src/"
        })
        .option("verbose", {
            describe: "Print debug info.",
            alias: "v",
            default: false,
            type: "boolean"
        })
        .option("open", {
            describe: "Open the report",
            alias: "o",
            default: false,
            type: "boolean"
        })
        .option("report", {
            describe: "Type of report to generate (html generates files, json generates files with coverage data)",
            alias: "r",
            default: "html",
            choices: ["html", "json", "codecov", "human"],
            coerce: function(value) {
                // Backward compatibility: treat "human" as "html"
                return value === "human" ? "html" : value;
            }
        });
