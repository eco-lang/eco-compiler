import * as ports from "./ports" ;
import {
    CacheListPopFrontResponse,
    CacheListPushBackResponse,
    CreateCacheResponse,
    PutWebhookResponse,
    TopicPublishResponse,
    TopicSubscribeResponse
} from "@gomomento/sdk-core";

type CacheClient = any;
type TopicClient = any;

type Session = {
    apiKey: string;
    cache: string;
    cacheClient: CacheClient;
    topicClient: TopicClient
}

type OpenArgs = {
    id: string;
    apiKey: string;
    cache: string;
    topic: string
}

type SubscribeArgs = {
    id: string;
    session: Session;
    topic: string;
}

type SendArgs = {
    id: string;
    session: Session;
    topic: string;
    payload: any
}

type PushListArgs = {
    id: string;
    session: Session;
    list: string;
    payload: any;
}

type PopListArgs = {
    id: string;
    session: Session;
    list: string;
}

type CreateWebhookArgs = {
    id: string;
    session: Session;
    name: string;
    topic: string;
    url: string;
}

type Ports = {
    mmOpen: { subscribe: any };
    mmClose: { subscribe: any };
    mmSubscribe: { subscribe: any };
    mmPublish: { subscribe: any };
    mmOnMessage: { send: any };
    mmPushList: { subscribe: any };
    mmPopList: { subscribe: any };
    mmCreateWebhook: { subscribe: any };
    mmResponse: { send: any };
    mmAsyncError: { send: any };
}


export interface MomentoFactory {
    getCacheClient(args: OpenArgs): CacheClient;

    getTopicClient(args: OpenArgs): TopicClient;
}

export class MomentoPorts {
    app: { ports: Ports };
    factory: MomentoFactory;

    constructor(app: any, factory: MomentoFactory) {
        //console.info("Momento.constructor");
        this.app = app;
        this.factory = factory;

        ports.checkPortsExist(app, [
            "mmOpen",
            "mmClose",
            "mmSubscribe",
            "mmPublish",
            "mmOnMessage",
            "mmPushList",
            "mmPopList",
            "mmCreateWebhook",
            "mmResponse",
            "mmAsyncError"
        ]);

        app.ports.mmOpen.subscribe(this.open);
        app.ports.mmClose.subscribe(this.close);
        app.ports.mmSubscribe.subscribe(this.subscribe);
        app.ports.mmPublish.subscribe(this.publish);
        app.ports.mmPushList.subscribe(this.pushList);
        app.ports.mmPopList.subscribe(this.popList);
        app.ports.mmCreateWebhook.subscribe(this.createWebhook);
    }

    // === Cache session lifecycle.
    open = async (args: OpenArgs) => {
        //console.info("Momento.open");
        //console.info(args);

        // Connect to the Momento Cache.
        const cacheClient = this.factory.getCacheClient(args);

        const createCacheResponse = await cacheClient.createCache(args.cache);

        switch (createCacheResponse.type) {
            case CreateCacheResponse.AlreadyExists:
                //console.info('cache already exists');
                break;
            case CreateCacheResponse.Success:
                //console.info('cache created');
                break;
            case CreateCacheResponse.Error:
                //console.info("Momento.open.onError");

                this.app.ports.mmResponse.send({
                    id: args.id,
                    type_: "Error",
                    response: createCacheResponse.innerException()
                });
        }

        // Set up the topic client.
        const topicClient = this.factory.getTopicClient(args);

        // Provide of a reference to the topic client and let the application know it is open.
        const session = {
            apiKey: args.apiKey,
            cache: args.cache,
            cacheClient: cacheClient,
            topicClient: topicClient
        };

        this.app.ports.mmResponse.send({
            id: args.id,
            type_: "Ok",
            response: session
        });
    }

    close = async (args: any) => {
        //console.info("Momento.close");
        //console.info(args.id);

        args.session.cacheClient.close();

        this.app.ports.mmResponse.send({
            id: args.id,
            type_: "Ok",
            response: args.session
        });
    }

    // === Topics
    subscribe = async (args: SubscribeArgs) => {
        // Set up the topic.
        const topicSubscribeResponse =
            await args.session.topicClient.subscribe(args.session.cache, args.topic, {
                onError: (err: any) => {
                    this.app.ports.mmAsyncError.send({
                        id: args.id,
                        error: err
                    });

                    return;
                },
                onItem: (item: any) => {
                    //console.info(`Received an item on subscription for '${args.topic}': ${item.value().toString()}`);
                    //this.onMessage(args.id, args.session, JSON.stringify(item));
                    this.onMessage(args.id, args.session, JSON.parse(item.value().toString()));

                    return;
                },
            });

        switch (topicSubscribeResponse.type) {
            case TopicSubscribeResponse.Subscription:
                //console.info(`Successfully subscribed to topic '${args.topic}'`);
                break;

            case TopicSubscribeResponse.Error:
                this.app.ports.mmResponse.send({
                    id: args.id,
                    type_: "Error",
                    response: topicSubscribeResponse.innerException()
                });
        }

        this.app.ports.mmResponse.send({
            id: args.id,
            type_: "Ok",
            response: args.session
        });
    }

    publish = async (args: SendArgs) => {
        //console.info("Momento.send");
        //console.info(args);

        const publishResponse =
            await args.session.topicClient.publish(
                args.session.cache,
                args.topic,
                JSON.stringify(args.payload));

        switch (publishResponse.type) {
            case TopicPublishResponse.Success:
                //console.info('Value published successfully!');
                break;
            case TopicPublishResponse.Error:
                //console.info(`Error publishing value: ${publishResponse.toString()}`);

                this.app.ports.mmResponse.send({
                    id: args.id,
                    type_: "Error",
                    response: publishResponse.innerException()
                });

                break;
        }

        this.app.ports.mmResponse.send({
            id: args.id,
            type_: "Ok",
            response: args.session
        });

    }

    onMessage = (id: string, session: Session, payload: any) => {
        //console.info("Momento.onMessage");
        //console.info(payload);

        this.app.ports.mmOnMessage.send({
            id: id,
            session: session,
            payload: payload
        });
    }

    // === Lists
    pushList = async (args: PushListArgs) => {
        //console.info("Momento.pushList");

        const pushResponse =
            await args.session.cacheClient.listPushBack(
                args.session.cache,
                args.list,
                JSON.stringify(args.payload));

        switch (pushResponse.type) {
            case CacheListPushBackResponse.Success:
                //console.info(`Value '${args.payload}' added successfully to back of list '${args.list}'`);
                break;
            case CacheListPushBackResponse.Error:
                //console.info("Momento.pusList.Error");

                this.app.ports.mmResponse.send({
                    id: args.id,
                    type_: "Error",
                    response: pushResponse.innerException()
                });
        }

        this.app.ports.mmResponse.send({
            id: args.id,
            type_: "Ok",
            response: args.session
        });
    }

    popList = async (args: PopListArgs) => {
        //console.info("Momento.popList");

        const popResponse =
            await args.session.cacheClient.listPopFront(
                args.session.cache,
                args.list);

        switch (popResponse.type) {
            case CacheListPopFrontResponse.Hit:
                //console.info(`Value '${popResponse.value()}' popped from list '${args.list}'`);

                this.app.ports.mmResponse.send({
                    id: args.id,
                    type_: "Item",
                    response: JSON.parse(popResponse.value())
                });

                break;

            case CacheListPopFrontResponse.Miss:
                //console.info(`No value  popped from list '${args.list}'`);

                this.app.ports.mmResponse.send({
                    id: args.id,
                    type_: "ItemNotFound",
                    response: null
                });

                break;
            case CacheListPopFrontResponse.Error:
                //console.info("Momento.popList.Error");

                this.app.ports.mmResponse.send({
                    id: args.id,
                    type_: "Error",
                    response: popResponse.innerException()
                });
        }

    }

    // == Webhooks
    createWebhook = async (args: CreateWebhookArgs) => {
        //console.info("Momento.createWebhook");
        //console.info(args);

        const webhookResponse =
            await args.session.topicClient.putWebhook(
                args.session.cache,
                args.name,
                {
                    topicName: args.topic,
                    destination: args.url
                });

        switch (webhookResponse.type) {
            case PutWebhookResponse.Success:
                //console.info('Successfully put webhook');
                break;

            case PutWebhookResponse.Error:
                //console.info("Momento.createWebhook.Error");
                // console.error(webhookResponse.innerException());

                this.app.ports.mmResponse.send({
                    id: args.id,
                    type_: "Error",
                    response: webhookResponse.innerException()
                });
        }

        this.app.ports.mmResponse.send({
            id: args.id,
            type_: "Ok",
            response: args.session
        });
    }
}
