import {
    CacheClient,
    CredentialProvider,
    TopicClient,
    Configurations,
    TopicConfigurations,
} from "@gomomento/sdk-web";

import {MomentoFactory} from "./momento";

export class WebMomentoFactory implements MomentoFactory {
    getCacheClient(args: any) {
        return new CacheClient({
            configuration: Configurations.Browser.latest(),
            credentialProvider: CredentialProvider.fromString({apiKey: args.apiKey}),
            defaultTtlSeconds: 60,
        });
    }

    getTopicClient(args: any) {
        return new TopicClient({
            configuration: TopicConfigurations.Browser.latest(),
            credentialProvider: CredentialProvider.fromString({apiKey: args.apiKey}),
        });
    }
}