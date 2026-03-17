var Promise = require("bluebird"),
    find = require("find"),
    analyzer = require("./analyze"),
    _ = require("lodash"),
    fs = require("fs-extra"),
    tmp = Promise.promisifyAll(require("tmp")),
    spawn = require("cross-spawn"),
    path = require("path"),
    touch = require("touch"),
    moment = require("moment"),
    opn = require("opn"),
    aggregate = require("./aggregate"),
    codeCov = require("./codeCov"),
    summarize = require("./summarize");

module.exports.run = function(args) {
    var log = createLogger(args);
    Promise.resolve()
        .then(prepare())
        .then(instrumentSources(log, args))
        .then(setupTests(log, args))
        .then(runTests(log, args))
        .then(generateReport(log, args))
        .then(finishUp(log, args))
        .catch(handleError(log));
};

module.exports.generateOnly = function(args) {
    var log = createLogger(args);
    Promise.resolve()
        .then(generateReport(log, args))
        .then(finishUp(log, args))
        .catch(handleError(log));
};

var elmInstrument = path.join(__dirname, "..", "bin", "elm-instrument");
var coverageDir = path.join(".coverage", "instrumented");
var fakeElmBinary = path.resolve(path.join(__dirname, "..", "bin", "fake-elm"));

function createLogger(args) {
    var logger = function(op) {
        return function(event, msg) {
            var now = "[" + moment().format("hh:mm:ss.SS") + "] ";
            op(now + msg);
        };
    };
    return {
        debug: args.verbose ? logger(console.log) : function() {},
        info: logger(console.log),
        warn: logger(console.error),
        error: logger(console.error)
    };
}

var setupTests = (log, args) => () => {
    var tmpElmJson = path.join(coverageDir, "elm.json");
    return fs
        .readJson("elm.json")
        .then(function(elmPackage) {
            log.debug(
                "modifyingTests",
                "Generating elm.json for coverage at " + tmpElmJson + "..."
            );
            var covSrc = path.resolve(path.join(coverageDir, args.path));
            var originalPath = path.resolve(args.path);

            elmPackage["name"] = "author/project";

            return elmPackage;
        })
        .then(function(elmPackage) {
            log.debug("writeTestElmJson", "writing elm.json");
            // Copy additional source directories (not the instrumented path)
            // so that elm make can find all modules referenced in elm.json
            var sourceDirs = elmPackage["source-directories"] || [];
            var normalizedPath = path.normalize(args.path).replace(/\/$/, "");
            var extraDirs = sourceDirs.filter(function(dir) {
                return path.normalize(dir).replace(/\/$/, "") !== normalizedPath;
            });
            return fs.writeJson(tmpElmJson, elmPackage).then(function() {
                return Promise.map(extraDirs, function(dir) {
                    var dest = path.join(coverageDir, dir);
                    log.debug(
                        "copyExtraSrc",
                        "Copying extra source dir " + dir + " to " + dest
                    );
                    return fs.copy(dir, dest);
                });
            });
        })
        .then(function() {
            var generatedTestsDir = path.join(coverageDir, "tests");
            log.debug(
                "copyTests",
                "Copying tests from " + args.tests + " to " + generatedTestsDir
            );
            return fs.copy(args.tests, generatedTestsDir);
        })
        .then(function() {
            return fs.copyFile(
                path.join(__dirname, "..", "kernel-src", "Coverage.elm"),
                path.join(coverageDir, args.path, "Coverage.elm")
            );
        })
        .then(function() {
            log.debug("testModificationComplete", "Setup complete");
        });
};

var runTests = (log, args) => () => {
    log.info("testRunInit", "Running tests...");
    return new Promise(function(resolve, reject) {
        log.debug(
            "testRun",
            "spawning " +
                args["elm-test"] +
                " --compiler " +
                fakeElmBinary
        );
        var process = spawn(
            args["elm-test"],
            ["--compiler", fakeElmBinary]
                .concat(args._),
            {
                // run elm-test in the instrumented files dir
                cwd: coverageDir,
                stdio: ["ignore", args.silent ? "ignore" : "inherit", "pipe"],
                env: Object.assign({}, require("process").env, {
                    ELM_COVERAGE_DIR: path.resolve(coverageDir)
                })
            }
        );

        var errStream = "";
        process.stderr.on("data", function(d) {
            errStream += d;
        });

        process.on("exit", function(exitCode) {
            if (exitCode === 0) {
                log.debug("testRunComplete", "Ran tests!");
                resolve();
            } else if (args.force) {
                log.warn(
                    "testFailure",
                    "Some tests failed, but continuing to generate coverage report."
                );
                resolve();
            } else {
                log.error("testFailure", "Ruh roh, tests failed.");
                reject(new Error(errStream));
            }
        });
    });
};

var prepare = () => () => {
    return new Promise(function(resolve, reject) {
        return fs
            .remove(".coverage")
            .then(function() {
                return fs.mkdirp(coverageDir);
            })
            .then(resolve);
    });
};

var allSources = args => {
    return new Promise(function(resolve, reject) {
        find.file(/\.(elm|js)$/, args.path, resolve);
    });
};

var instrumentSources = (log, args) => () => {
    return allSources(args)
        .then(function(files) {
            return Promise.map(
                files.filter(function(file) {
                    return !(
                        file.includes("elm-stuff") ||
                        file.includes(args.tests) ||
                        file.includes(".coverage")
                    );
                }),
                function(file) {
                    return fs.copy(file, path.join(coverageDir, file));
                }
            );
        })
        .then(function() {
            log.info("instrumenting", "Instrumenting sources...");

            return new Promise(function(resolve, reject) {
                var process = spawn(elmInstrument, [coverageDir]);
                var err = "";

                process.stderr.on("data", function(data) {
                    err += data;
                });
                process.on("error", function(code) {
                    log.error("instrumenting", "got error");
                    reject(err);
                });

                process.on("exit", function(code) {
                    log.debug("instrumenting", "finished instrumenting" + code);
                    if (code === 0) {
                        resolve();
                    } else {
                        reject(err);
                    }
                });
            });
        });
};

var generateReport = (log, args) => () => {
    log.debug("aggregating", "Aggregating info");
    return aggregate(args.path)
        .then(function(data) {
            if (!args.silent) {
                summarize.printSummary(data);
            }
            return data;
        })
        .then(function(data) {
            switch (args.report) {
                case "html":
                    log.info("generating", "Generating HTML report...");
                    return analyzer(args.path, data, "html");
                case "json":
                    log.info("generating", "Generating JSON report...");
                    return analyzer(args.path, data, "json");
                case "codecov":
                    log.info(
                        "generating",
                        "Writing code coverage to " +
                            path.join(".coverage", "codecov.json")
                    );
                    return codeCov(data);
            }
        });
};

var finishUp = (log, args) => () => {
    return Promise.map(allSources(args), function(file) {
        return touch(file);
    }).then(function() {
        var ext = args.report === "json" ? "json" : "html";
        var reportFile = ".coverage/coverage." + ext;

        if (args.report === "html" || args.report === "json") {
            if (args.open && args.report === "html") {
                log.info("complete", "All done! Opening " + reportFile);
                opn(reportFile, { wait: false });
            } else {
                log.info(
                    "complete",
                    "All done! Your coverage is waiting for you in " + reportFile
                );
            }
        }
        return Promise.resolve();
    });
};

var handleError = log => e => {
    log.error("handleError", "Something went wrong: \n" + e.toString());
    process.exit(1);
};
