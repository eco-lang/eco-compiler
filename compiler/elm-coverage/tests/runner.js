var spawn = require("cross-spawn"),
    chai = require("chai"),
    Promise = require("bluebird"),
    assert = chai.assert,
    expect = chai.expect,
    shell = require("shelljs"),
    path = require("path"),
    fs = require("fs-extra"),
    chaiMatchPattern = require("chai-match-pattern");

chai.use(require("chai-json-schema-ajv"));
chai.use(chaiMatchPattern);
var _ = chaiMatchPattern.getLodashModule();
_.mixin({
    matchesPath: (expected, actual) => actual.replace("\\", "/") === expected
});

var elmCoverage = require.resolve( path.join("..", "bin", "elm-coverage"));

describe("Sanity test", () => {
    it("prints the usage instructions when running with `--help`", done => {
        var process = spawn.spawn(elmCoverage, ["--help"]);
        var output = "";

        process.stderr.on("data", data => {
            console.error(data.toString());
        });
        process.stdout.on("data", data => {
            output += data;
        });

        process.on("exit", exitCode => {
            assert.equal(exitCode, 0, "Expected to exit with 0 exitcode");
            assert.notEqual(output, "", "Expected to have some output");
            done();
        });
    });
});

describe("E2E tests", function() {
    this.timeout(Infinity);
    it("Should run succesfully", done => {
        var process = spawn.spawn(elmCoverage, {
            cwd: path.join("tests", "data", "simple")
        });

        process.stderr.on("data", data => {
            console.error(data.toString());
        });

        process.on("exit", exitCode => {
            assert.equal(exitCode, 0, "Expected to finish succesfully");
            done();
        });
    });

    it("Should generate schema-validated JSON", () =>
        generateJSONReport().then(() =>
            Promise.all([
                fs.readJSON(path.join("tests", "data", "simple", ".coverage", "Simple.json")),
                fs.readJSON(require.resolve("../docs/elm-coverage.json"))
            ]).spread((json, schema) => {
                expect(json).to.be.jsonSchema(schema);
            })
        ));

    it("Should generate JSON that matches the pregenerated one, modulus runcount", () =>
        generateJSONReport().then(() =>
            Promise.all([
                fs.readJSON(path.join("tests", "data", "simple", ".coverage", "Simple.json")),
                fs.readJSON(require.resolve("./data/simple/expected.json"))
            ]).spread((actual, expectedJSON) => {
                // Build expected pattern - ignore count values (just check they're integers)
                var expected = {
                    module: expectedJSON.module,
                    totalComplexity: expectedJSON.totalComplexity,
                    coverage: expectedJSON.coverage,
                    annotations: _.map(expectedJSON.annotations, annotation =>
                        Object.assign({}, annotation, {
                            count: _.isInteger
                        })
                    )
                };

                expect(actual).to.matchPattern(expected);
            })
        ));
});

function generateJSONReport() {
    return new Promise((resolve, reject) => {
        var process = spawn.spawn(
            elmCoverage,
            ["generate", "--report", "json"],
            {
                cwd: path.join("tests", "data", "simple")
            }
        );

        process.stderr.on("data", data => {
            console.error(data.toString());
        });

        process.on("exit", exitCode => {
            assert.equal(exitCode, 0, "Expected to finish succesfully");
            if (exitCode === 0) {
                resolve();
            } else {
                reject(new Error("Expected to finish successfully"));
            }
        });
    });
}
