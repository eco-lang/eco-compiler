const urlencode = require('urlencode');
const uuid = require('uuid');

const defaultLogger = require('./logger');
const norm = require('./normalize-headers');

const encodeBody = body => (typeof body === 'string'
    ? body
    : JSON.stringify(body));

const path = params =>
    `/${params[0] || params.proxy || ''}`
        .replace(/%2f/gi, '/');

const splitHostPort = host => {
    const parts = typeof host === 'string' ? host.split(':') : [];
    return {host: parts[0], port: parts[1]};
};

module.exports = ({
                      requestPort,
                      logger = defaultLogger
                  }) => function requestHandler({
                                                    body,
                                                    headers = {},
                                                    httpMethod,
                                                    method = httpMethod,
                                                    pathParameters,
                                                    queryStringParameters = {},
                                                    requestContext = {},
                                                }, context, callback) {
    const {host, port} = splitHostPort(headers.Host || headers.host);
    const {sourceIp} = requestContext.identity || {};
    const req = {
        body: encodeBody(body),
        headers: norm(headers),
        host: requestContext.http.sourceIp,
        method: requestContext.http.method,
        path: path(pathParameters || {}),
        port: parseInt(headers['X-Forwarded-Port'] || port || 80, 10), // Assume port 80, if none given.
        queryParams: queryStringParameters,
        queryString: `?${urlencode.stringify(queryStringParameters)}`,
        remoteIp: sourceIp || '127.0.0.1',
        scheme: headers['X-Forwarded-Proto'] || 'http',
        stage: requestContext.stage || 'local',
    };

    logger.info(JSON.stringify({req}, null, 2));
    requestPort.send({session: callback, req: req});
};
