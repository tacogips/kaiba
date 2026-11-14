import type { KaibaRepository } from "@kaiba/application";
import { createYoga } from "graphql-yoga";
import { createKaibaSchema } from "./schema";

export function createKaibaGraphQLServer(repository: KaibaRepository) {
  return createYoga({
    schema: createKaibaSchema(repository),
    graphqlEndpoint: "/graphql",
    graphiql: false,
    landingPage: false,
    maskedErrors: false,
  });
}
