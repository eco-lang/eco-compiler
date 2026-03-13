/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
import Eco.Kernel.Utils exposing (Tuple2)
import Elm.Kernel.List exposing (Nil, Cons, toArray)
import Result exposing (Ok, Err)
*/

var _Http_fetch = F3(function(method, url, headers) {
    return __Scheduler_binding(function(callback) {
        try {
            var headerArr = __List_toArray(headers);
            var headerObj = {};
            for (var i = 0; i < headerArr.length; i++) {
                headerObj[headerArr[i].a] = headerArr[i].b;
            }

            var parsedUrl = new URL(url);
            var client = parsedUrl.protocol === 'https:' ? require('https') : require('http');
            var zlib = require('zlib');

            var req = client.request(parsedUrl, { method: method, headers: headerObj }, function(res) {
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    var chunks = [];
                    res.on('data', function(chunk) { chunks.push(chunk); });
                    res.on('end', function() {
                        var buffer = Buffer.concat(chunks);
                        var encoding = res.headers['content-encoding'];
                        var decode = function(buf) {
                            callback(__Scheduler_succeed(__Result_Ok(buf.toString())));
                        };
                        if (encoding === 'gzip') {
                            zlib.gunzip(buffer, function(err, decoded) {
                                if (err) {
                                    callback(__Scheduler_succeed(__Result_Err(
                                        __Utils_Tuple2(0, err.message)
                                    )));
                                    return;
                                }
                                decode(decoded);
                            });
                        } else if (encoding === 'deflate') {
                            zlib.inflate(buffer, function(err, decoded) {
                                if (err) {
                                    callback(__Scheduler_succeed(__Result_Err(
                                        __Utils_Tuple2(0, err.message)
                                    )));
                                    return;
                                }
                                decode(decoded);
                            });
                        } else {
                            decode(buffer);
                        }
                    });
                } else {
                    res.resume();
                    res.on('end', function() {
                        callback(__Scheduler_succeed(__Result_Err(
                            __Utils_Tuple2(res.statusCode, res.statusMessage || '')
                        )));
                    });
                }
            });

            req.on('error', function(err) {
                callback(__Scheduler_succeed(__Result_Err(
                    __Utils_Tuple2(0, err.message)
                )));
            });

            req.end();
        } catch (e) {
            callback(__Scheduler_succeed(__Result_Err(
                __Utils_Tuple2(0, e.message)
            )));
        }
    });
});

var _Http_getArchive = function(url) {
    return __Scheduler_binding(function(callback) {
        var download = function(downloadUrl) {
            try {
                var parsedUrl = new URL(downloadUrl);
                var client = parsedUrl.protocol === 'https:' ? require('https') : require('http');

                var req = client.request(parsedUrl, { method: 'GET' }, function(res) {
                    if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                        download(res.headers.location);
                        return;
                    }
                    if (res.statusCode >= 200 && res.statusCode < 300) {
                        var chunks = [];
                        res.on('data', function(chunk) { chunks.push(chunk); });
                        res.on('end', function() {
                            try {
                                var AdmZip = require('adm-zip');
                                var crypto = require('crypto');

                                var buffer = Buffer.concat(chunks);
                                var zip = new AdmZip(buffer);
                                var sha = crypto.createHash('sha1').update(buffer).digest('hex');
                                var entries = zip.getEntries();
                                var archive = __List_Nil;
                                for (var i = entries.length - 1; i >= 0; i--) {
                                    archive = __List_Cons(
                                        __Utils_Tuple2(entries[i].entryName, zip.readAsText(entries[i])),
                                        archive
                                    );
                                }
                                callback(__Scheduler_succeed(__Result_Ok(
                                    __Utils_Tuple2(sha, archive)
                                )));
                            } catch (e) {
                                callback(__Scheduler_succeed(__Result_Err(e.message)));
                            }
                        });
                    } else {
                        res.resume();
                        res.on('end', function() {
                            callback(__Scheduler_succeed(__Result_Err('HTTP ' + res.statusCode)));
                        });
                    }
                });

                req.on('error', function(err) {
                    callback(__Scheduler_succeed(__Result_Err(err.message)));
                });

                req.end();
            } catch (e) {
                callback(__Scheduler_succeed(__Result_Err(e.message)));
            }
        };

        download(url);
    });
};
