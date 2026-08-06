import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

// Тесты идут в настоящем workerd через miniflare, а не в ноде с моками:
// R2 и D1 подменяются локальными реализациями, а поведение Request, Headers
// и crypto.subtle остаётся тем же, что в проде. Мок на fetch проверял бы
// наши представления о рантайме, а не рантайм.
export default defineWorkersConfig({
    test: {
        poolOptions: {
            workers: {
                wrangler: { configPath: "./wrangler.toml" },
                miniflare: {
                    compatibilityDate: "2026-01-15",
                    r2Buckets: ["ARCHIVES"],
                    d1Databases: ["DB"],
                    bindings: {
                        REGISTRY_BASE_URL: "https://registry.test",
                        // В проде это секрет из `wrangler secret put`.
                        PUBLISH_TOKEN: "test-token",
                    },
                },
            },
        },
    },
});
