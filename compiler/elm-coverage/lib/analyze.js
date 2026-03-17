var emitter = require("./analyzer"),
    fs = require("fs-extra"),
    Promise = require("bluebird"),
    packageInfo = require("../package.json"),
    path = require("path");

/**
 * Convert module name to file path.
 * E.g., "Foo.Bar.Baz" -> "Foo/Bar/Baz.html" (or .json)
 */
function moduleToPath(moduleName, ext) {
    return moduleName.split(".").join(path.sep) + "." + ext;
}

module.exports = function(sourcePath, allData, reportFormat) {
    // Default to html for backward compatibility
    reportFormat = reportFormat || "html";
    var ext = reportFormat === "json" ? "json" : "html";

    return new Promise(function(resolve, reject) {
        return Promise.map(Object.keys(allData.moduleMap), function(
            moduleName
        ) {
            return fs
                .readFile(allData.moduleMap[moduleName])
                .then(function(data) {
                    return [moduleName, data.toString()];
                });
        }).then(function(sourceDataList) {
            var sourceData = {};
            sourceDataList.forEach(function(entry) {
                sourceData[entry[0]] = entry[1];
            });

            var app = emitter.Elm.Analyzer.init({
                flags: {
                    version: packageInfo.version,
                    format: reportFormat
                }
            });

            app.ports.receive.send({
                coverage: allData.coverageData,
                files: sourceData
            });

            app.ports.emit.subscribe(function(report) {
                if (report.type && report.type === "error") {
                    reject(report.message);
                } else {
                    var promises = [];

                    // Write CSS file for HTML reports
                    if (reportFormat === "html" && report.css) {
                        promises.push(fs.writeFile(
                            path.join(".coverage", "styles.css"),
                            report.css
                        ));
                    }

                    // Write overview page
                    promises.push(fs.writeFile(
                        path.join(".coverage", "coverage." + ext),
                        report.overview
                    ));

                    // Write individual module pages
                    var modulePromises = Object.keys(report.modules).map(function(moduleName) {
                        var filePath = path.join(".coverage", moduleToPath(moduleName, ext));
                        var dirPath = path.dirname(filePath);

                        // Ensure directory exists, then write file
                        return fs.mkdirp(dirPath).then(function() {
                            return fs.writeFile(filePath, report.modules[moduleName]);
                        });
                    });

                    // Wait for all files to be written
                    Promise.all(promises.concat(modulePromises))
                        .then(resolve)
                        .catch(reject);
                }
            });
        });
    });
};
