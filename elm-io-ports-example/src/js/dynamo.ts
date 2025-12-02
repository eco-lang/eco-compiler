import {DynamoDB} from "@aws-sdk/client-dynamodb";
import {
    BatchGetCommandInput,
    BatchWriteCommandInput,
    DeleteCommandInput,
    DynamoDBDocument,
    GetCommandInput,
    PutCommandInput,
    QueryCommandInput,
    ScanCommandInput,
    TransactWriteCommandInput,
    UpdateCommandInput
} from "@aws-sdk/lib-dynamodb";
import * as ports from "./ports" ;

const client = new DynamoDB();
const documentClient = DynamoDBDocument.from(client);

type GetArgs = {
    id: string;
    req: GetCommandInput;
}

type PutArgs = {
    id: string;
    req: PutCommandInput;
}

type UpdateArgs = {
    id: string;
    req: UpdateCommandInput;
}

type WriteTxArgs = {
    id: string;
    req: TransactWriteCommandInput;
}

type DeleteArgs = {
    id: string;
    req: DeleteCommandInput;
}

type BatchGetArgs = {
    id: string;
    req: BatchGetCommandInput;
}

type BatchWriteArgs = {
    id: string;
    req: BatchWriteCommandInput;
}

type ScanArgs = {
    id: string;
    req: ScanCommandInput;
}

type QueryArgs = {
    id: string;
    req: QueryCommandInput;
}

type Error = {
    type_: string;
    message: string;
    details: any;
}

type Ports = {
    dynamoGet: { subscribe: any };
    dynamoPut: { subscribe: any };
    dynamoUpdate: { subscribe: any };
    dynamoWriteTx: { subscribe: any };
    dynamoDelete: { subscribe: any };
    dynamoBatchGet: { subscribe: any };
    dynamoBatchWrite: { subscribe: any };
    dynamoScan: { subscribe: any };
    dynamoQuery: { subscribe: any };
    dynamoResponse: { send: any };
}

function errorResponse(error): Error {
    return {
        type_: "Error",
        message: error.message,
        details: error
    };
}

export class DynamoPorts {
    app: { ports: Ports };

    constructor(app: any) {
        console.info("DynamoPorts.constructor");
        this.app = app;

        ports.checkPortsExist(app, [
            "dynamoGet",
            "dynamoPut",
            "dynamoUpdate",
            "dynamoWriteTx",
            "dynamoDelete",
            "dynamoBatchGet",
            "dynamoBatchWrite",
            "dynamoScan",
            "dynamoQuery",
            "dynamoResponse"
        ]);

        app.ports.dynamoGet.subscribe(this.dynamoGet);
        app.ports.dynamoPut.subscribe(this.dynamoPut);
        app.ports.dynamoUpdate.subscribe(this.dynamoUpdate);
        app.ports.dynamoWriteTx.subscribe(this.dynamoWriteTx);
        app.ports.dynamoDelete.subscribe(this.dynamoDelete);
        app.ports.dynamoBatchGet.subscribe(this.dynamoBatchGet);
        app.ports.dynamoBatchWrite.subscribe(this.dynamoBatchWrite);
        app.ports.dynamoScan.subscribe(this.dynamoScan);
        app.ports.dynamoQuery.subscribe(this.dynamoQuery);
    }


    dynamoGet = async (args: GetArgs) => {
        documentClient.get(args.req, (error, result) => {
            var getResponse;

            if (error) {
                getResponse = errorResponse(error);
            } else if (Object.entries(result).length === 0) {
                getResponse = {
                    type_: "ItemNotFound"
                }
            } else {
                getResponse = {
                    type_: "Item",
                    item: result
                }
            }

            this.app.ports.dynamoResponse.send({id: args.id, res: getResponse});
        });
    }

    dynamoPut = async (args: PutArgs) => {
        console.info("dynamoPut: called");

        documentClient.put(args.req, (error, result) => {
            var putResponse;

            if (error) {
                putResponse = errorResponse(error);
            } else {
                putResponse = {
                    type_: "Ok"
                }
            }

            this.app.ports.dynamoResponse.send({id: args.id, res: putResponse});
        });
    }

    dynamoUpdate = async (args: UpdateArgs) => {
        console.info("dynamoUpdate: called");
        console.info(args);

        documentClient.update(args.req, (error, result) => {
            var putResponse;

            if (error) {
                if (error.code === 'ConditionalCheckFailedException') {
                    putResponse = {
                        type_: "ConditionalCheckFailed",
                        message: error.message,
                        details: error
                    }
                } else {
                    putResponse = errorResponse(error);
                }

            } else {
                putResponse = {
                    type_: "Ok"
                }
            }

            this.app.ports.dynamoResponse.send({id: args.id, res: putResponse});
        });
    }

    dynamoWriteTx = async (args: WriteTxArgs) => {
        console.info("dynamoWriteTx: called");
        console.info(args);

        documentClient.transactWrite(args.req, (error, result) => {
            var putResponse;

            if (error) {
                if (error.code === 'ConditionalCheckFailedException') {
                    putResponse = {
                        type_: "ConditionalCheckFailed",
                        message: error.message,
                        details: error
                    }
                } else {
                    putResponse = errorResponse(error);
                }
            } else {
                putResponse = {
                    type_: "Ok"
                }
            }

            this.app.ports.dynamoResponse.send({id: args.id, res: putResponse});
        });
    }

    dynamoDelete = async (args: DeleteArgs) => {
        documentClient.delete(args.req, (error, result) => {
            var deleteResponse;

            if (error) {
                deleteResponse = errorResponse(error);
            } else {
                deleteResponse = {
                    type_: "Ok"
                }
            }

            this.app.ports.dynamoResponse.send({id: args.id, res: deleteResponse});
        });
    }

    dynamoBatchGet = async (args: BatchGetArgs) => {
        documentClient.batchGet(args.req, (error, result) => {
            var getResponse;

            if (error) {
                getResponse = errorResponse(error);
            } else if (Object.entries(result).length === 0) {
                getResponse = {
                    type_: "Item",
                    item: []
                }
            } else {
                getResponse = {
                    type_: "Item",
                    item: result
                }
            }

            this.app.ports.dynamoResponse.send({id: args.id, res: getResponse});
        });
    }

    dynamoBatchWrite = async (args: BatchWriteArgs) => {
        documentClient.batchWrite(args.req, (error, result) => {
            var putResponse;

            if (error) {
                putResponse = errorResponse(error);
            } else {
                putResponse = {
                    type_: "Ok"
                }
            }

            this.app.ports.dynamoResponse.send({id: args.id, res: putResponse});
        });
    }

    dynamoScan = async (args: ScanArgs) => {
        documentClient.scan(args.req, (error, result) => {
            var getResponse;

            if (error) {
                getResponse = errorResponse(error);
            } else if (Object.entries(result).length === 0) {
                getResponse = {
                    type_: "Items",
                    items: []
                }
            } else {
                getResponse = {
                    type_: "Items",
                    items: result.Items
                }
            }

            if (result.LastEvaluatedKey !== undefined) {
                getResponse.lastEvaluatedKey = result.LastEvaluatedKey;
            }

            this.app.ports.dynamoResponse.send({id: args.id, res: getResponse});
        });

    }

    dynamoQuery = async (args: QueryArgs) => {
        documentClient.query(args.req, (error, result) => {
            var getResponse;

            if (error) {
                getResponse = errorResponse(error);
            } else if (Object.entries(result).length === 0) {
                getResponse = {
                    type_: "Items",
                    items: []
                }
            } else {
                getResponse = {
                    type_: "Items",
                    items: result.Items
                }
            }

            if (result.LastEvaluatedKey !== undefined) {
                getResponse.lastEvaluatedKey = result.LastEvaluatedKey;
            }

            this.app.ports.dynamoResponse.send({id: args.id, res: getResponse});
        });
    }
}