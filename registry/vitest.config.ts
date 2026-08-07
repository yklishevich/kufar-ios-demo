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

                // Изоляция хранилища выключена намеренно.
                //
                // По умолчанию пул откатывает записи в R2 и D1 после каждого
                // теста. Здесь это не подходит: блок публикации проверяет
                // последовательность, а она и есть контракт — версия
                // опубликована, повторная публикация той же версии даёт 409,
                // гит-URL после неё ищется. Разложи это на независимые тесты,
                // и проверяться начнёт «409, если строка уже есть», то есть
                // предусловие, а не поведение реестра.
                //
                // Цена названа честно: порядок тестов внутри файла значим,
                // и падение раннего теста тянет за собой поздние. Чтобы
                // это не расползалось, состояние заводится один раз в
                // beforeAll через INSERT OR REPLACE, а блок публикации
                // работает со своим пакетом (kufar.Published) и не пересекается
                // с тем, что читают остальные (kufar.Toolbox).
                isolatedStorage: false,
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
