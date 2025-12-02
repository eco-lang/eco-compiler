import {
    CacheClient,
    CredentialProvider,
    TopicClient,
    Configurations,
    TopicConfigurations,
} from "@gomomento/sdk";

import {MomentoFactory} from "./momento";

export class NodeMomentoFactory implements MomentoFactory {
    getCacheClient(args) {
        return new CacheClient({
            configuration: Configurations.Lambda.latest(),
            credentialProvider: CredentialProvider.fromString({apiKey: args.apiKey}),
            defaultTtlSeconds: 60,
        });
    }

    getTopicClient(args) {
        return new TopicClient({
            configuration: TopicConfigurations.Lambda.latest(),
            credentialProvider: CredentialProvider.fromString({apiKey: args.apiKey}),
        });
    }
}