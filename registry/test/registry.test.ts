/**
 * Тесты контракта, а не реализации.
 *
 * Проверяется то, на что смотрит SwiftPM: коды ответов, обязательные
 * заголовки, форма JSON, поведение при незнакомой версии API. Именно эти
 * вещи ломаются молча — клиент не скажет «у вас нет Content-Version»,
 * он просто поведёт себя странно при резолве.
 */

import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import worker from "../src/index";
import { normalizeGitURL } from "../src/handlers";
import { parseVersion, isValidSegment } from "../src/types";

const ACCEPT = "application/vnd.swift.registry.v1+json";

async function call(path: string, init: RequestInit = {}): Promise<Response> {
    const request = new Request(`https://registry.test${path}`, {
        headers: { Accept: ACCEPT },
        ...init,
    });
    const ctx = createExecutionContext();
    const response = await worker.fetch(request, env, ctx);
    await waitOnExecutionContext(ctx);
    return response;
}

/** Публикует версию напрямую в хранилища — быстрее, чем через эндпоинт. */
async function seed(scope: string, name: string, version: string, manifest = "// swift-tools-version: 5.9") {
    const parsed = parseVersion(version)!;
    const archive = new TextEncoder().encode(`archive of ${name} ${version}`);
    const digest = await crypto.subtle.digest("SHA-256", archive);
    const checksum = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    const key = `${scope}/${name}/${version}.zip`;

    await env.ARCHIVES.put(key, archive);
    await env.DB.prepare(
        `INSERT OR REPLACE INTO releases
           (scope, name, version, major, minor, patch, prerelease, checksum,
            archive_size, archive_key, manifest, manifests_json, repository_url, published_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
        scope, name, version, parsed.major, parsed.minor, parsed.patch, parsed.prerelease,
        checksum, archive.length, key, manifest, "{}",
        `https://github.com/kufar/${name}`, new Date().toISOString()
    ).run();

    await env.DB.prepare(
        `INSERT OR IGNORE INTO scm_identifiers (url, scope, name) VALUES (?, ?, ?)`
    ).bind(normalizeGitURL(`https://github.com/kufar/${name}`), scope, name).run();
}

beforeAll(async () => {
    await env.DB.exec("CREATE TABLE IF NOT EXISTS releases (scope TEXT NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL, major INTEGER NOT NULL, minor INTEGER NOT NULL, patch INTEGER NOT NULL, prerelease TEXT, checksum TEXT NOT NULL, archive_size INTEGER NOT NULL, archive_key TEXT NOT NULL, manifest TEXT NOT NULL, manifests_json TEXT NOT NULL DEFAULT '{}', repository_url TEXT, published_at TEXT NOT NULL, PRIMARY KEY (scope, name, version))");
    await env.DB.exec("CREATE TABLE IF NOT EXISTS scm_identifiers (url TEXT NOT NULL, scope TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY (url, scope, name))");

    // Порядок публикации намеренно не по возрастанию: сортировку должен
    // делать сервер, а не порядок вставки.
    await seed("kufar", "Toolbox", "1.0.0");
    await seed("kufar", "Toolbox", "1.10.0");
    await seed("kufar", "Toolbox", "1.9.0");
    await seed("kufar", "Toolbox", "2.0.0-beta.1");
});

describe("согласование версии API", () => {
    it("отдаёт Content-Version в каждом ответе", async () => {
        const response = await call("/kufar/Toolbox");
        expect(response.headers.get("Content-Version")).toBe("1");
    });

    it("отказывает на незнакомую версию с внятной причиной", async () => {
        const response = await call("/kufar/Toolbox", {
            headers: { Accept: "application/vnd.swift.registry.v9+json" },
        });
        expect(response.status).toBe(400);
        expect(response.headers.get("Content-Type")).toBe("application/problem+json");
        expect((await response.json<{ detail: string }>()).detail).toContain("9");
    });

    it("работает без Accept — спецификация велит отдавать актуальную версию", async () => {
        const response = await call("/kufar/Toolbox", { headers: {} });
        expect(response.status).toBe(200);
    });
});

describe("список релизов", () => {
    it("возвращает все версии с абсолютными ссылками", async () => {
        const response = await call("/kufar/Toolbox");
        const body = await response.json<{ releases: Record<string, { url: string }> }>();

        expect(Object.keys(body.releases).sort()).toEqual(["1.0.0", "1.10.0", "1.9.0", "2.0.0-beta.1"]);
        expect(body.releases["1.10.0"]!.url).toMatch(/^https?:\/\/.+\/kufar\/Toolbox\/1\.10\.0$/);
    });

    it("сортирует по semver, а не лексикографически", async () => {
        const response = await call("/kufar/Toolbox");
        // Порядок ключей в JSON сохраняется — 1.10.0 должна идти раньше 1.9.0,
        // хотя как строка она меньше.
        const keys = Object.keys(await response.json<{ releases: Record<string, unknown> }>().then((b) => b.releases));
        expect(keys.indexOf("1.10.0")).toBeLessThan(keys.indexOf("1.9.0"));
    });

    it("не считает предрелиз последней версией", async () => {
        const response = await call("/kufar/Toolbox");
        const link = response.headers.get("Link") ?? "";
        expect(link).toContain('rel="latest-version"');
        expect(link).toContain("/1.10.0>");
        expect(link).not.toContain("2.0.0-beta.1>; rel=\"latest-version\"");
    });

    it("404 на неизвестный пакет", async () => {
        const response = await call("/kufar/Missing");
        expect(response.status).toBe(404);
        expect(response.headers.get("Content-Type")).toBe("application/problem+json");
    });
});

describe("метаданные релиза", () => {
    it("отдаёт идентификатор, версию и контрольную сумму архива", async () => {
        const response = await call("/kufar/Toolbox/1.0.0");
        const body = await response.json<{
            id: string;
            version: string;
            resources: Array<{ name: string; type: string; checksum: string }>;
        }>();

        expect(body.id).toBe("kufar.Toolbox");
        expect(body.version).toBe("1.0.0");
        const archive = body.resources.find((r) => r.name === "source-archive");
        expect(archive?.type).toBe("application/zip");
        expect(archive?.checksum).toMatch(/^[0-9a-f]{64}$/);
    });

    it("404 на неопубликованную версию", async () => {
        const response = await call("/kufar/Toolbox/9.9.9");
        expect(response.status).toBe(404);
    });

    it("400 на версию не по semver", async () => {
        const response = await call("/kufar/Toolbox/latest");
        expect(response.status).toBe(400);
    });

    // Регрессия. publishedAt отдавался как new Date().toISOString(), то есть
    // с миллисекундами — валидный ISO 8601, который SwiftPM не принимает:
    // он читает поле через ISO8601DateFormatter с настройками по умолчанию,
    // а дробные секунды требуют опции .withFractionalSeconds. Резолв падал
    // целиком, и сообщение про дату не говорило ничего:
    //
    //   failed fetching kufar.AppComposition version 1.0.2 release information:
    //   dataCorrupted(… "Expected date string to be ISO8601-formatted.")
    //
    // seed() намеренно кладёт в базу значение С миллисекундами: проверяется,
    // что чинит именно чтение, а не аккуратность записи.
    it("отдаёт publishedAt без дробных секунд", async () => {
        const response = await call("/kufar/Toolbox/1.0.0");
        const body = await response.json<{ publishedAt: string }>();

        expect(body.publishedAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
        expect(body.publishedAt).not.toContain(".");
    });
});

describe("манифест", () => {
    it("отдаётся как text/x-swift", async () => {
        const response = await call("/kufar/Toolbox/1.0.0/Package.swift");
        expect(response.status).toBe(200);
        expect(response.headers.get("Content-Type")).toBe("text/x-swift");
        expect(await response.text()).toContain("swift-tools-version");
    });

    it("на неизвестную версию Swift отдаёт основной манифест, а не 404", async () => {
        const response = await call("/kufar/Toolbox/1.0.0/Package.swift?swift-version=6.5");
        expect(response.status).toBe(200);
    });
});

describe("архив исходников", () => {
    it("отдаётся как zip с Digest и длиной", async () => {
        const response = await call("/kufar/Toolbox/1.0.0.zip");
        expect(response.status).toBe(200);
        expect(response.headers.get("Content-Type")).toBe("application/zip");
        expect(response.headers.get("Digest")).toMatch(/^sha-256=[A-Za-z0-9+/]+=*$/);
        expect(response.headers.get("Content-Length")).toBeTruthy();
    });

    it("Digest — то же значение, что checksum в метаданных, но в base64", async () => {
        const meta = await (await call("/kufar/Toolbox/1.0.0")).json<{
            resources: Array<{ checksum: string }>;
        }>();
        const hex = meta.resources[0]!.checksum;

        const archive = await call("/kufar/Toolbox/1.0.0.zip");
        const base64 = archive.headers.get("Digest")!.replace("sha-256=", "");

        const decoded = [...atob(base64)].map((c) => c.charCodeAt(0).toString(16).padStart(2, "0")).join("");
        expect(decoded).toBe(hex);
    });
});

describe("обратный поиск идентификаторов", () => {
    it("находит пакет по гит-URL", async () => {
        const response = await call("/identifiers?url=https://github.com/kufar/Toolbox.git");
        const body = await response.json<{ identifiers: string[] }>();
        expect(body.identifiers).toContain("kufar.Toolbox");
    });

    it("не зависит от формы записи URL", async () => {
        for (const url of [
            "https://github.com/kufar/Toolbox",
            "https://github.com/kufar/Toolbox.git",
            "git@github.com:kufar/Toolbox.git",
            "HTTPS://GitHub.com/kufar/Toolbox/",
        ]) {
            const response = await call(`/identifiers?url=${encodeURIComponent(url)}`);
            expect(response.status, `не распознан: ${url}`).toBe(200);
        }
    });

    it("400 без параметра url", async () => {
        expect((await call("/identifiers")).status).toBe(400);
    });
});

describe("публикация", () => {
    const TOKEN = "test-token";

    async function put(body: unknown, token = TOKEN): Promise<Response> {
        return call("/_publish", {
            method: "PUT",
            headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
            body: JSON.stringify(body),
        });
    }

    async function payload(version: string, corruptChecksum = false) {
        const bytes = new TextEncoder().encode(`archive ${version}`);
        const digest = await crypto.subtle.digest("SHA-256", bytes);
        const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
        let binary = "";
        for (const b of bytes) binary += String.fromCharCode(b);
        return {
            scope: "kufar",
            name: "Published",
            version,
            archive: btoa(binary),
            checksum: corruptChecksum ? "0".repeat(64) : hex,
            manifest: "// swift-tools-version: 5.9",
            repositoryURL: "https://github.com/kufar/Published",
        };
    }

    it("401 без токена", async () => {
        expect((await put(await payload("1.0.0"), "wrong")).status).toBe(401);
    });

    it("400, если checksum не sha256 в hex", async () => {
        const body = { ...(await payload("1.0.0")), checksum: "не-хеш" };
        const response = await put(body);
        expect(response.status).toBe(400);
        expect((await response.json<{ detail: string }>()).detail).toContain("sha256");
    });

    it("отвергает архив с несовпадающей суммой — проверяет R2, не Worker", async () => {
        // Ключевое: Worker сам ничего не хеширует, сумму сверяет хранилище
        // при записи. Поведение снаружи то же, CPU не тратится.
        const response = await put(await payload("3.0.0", true));
        expect(response.status).toBe(400);

        // Объекта в бакете остаться не должно — запись отвергнута целиком.
        expect(await env.ARCHIVES.get("kufar/Published/3.0.0.zip")).toBeNull();
    });

    it("публикует и делает версию резолвимой", async () => {
        expect((await put(await payload("1.0.0"))).status).toBe(200);

        const meta = await call("/kufar/Published/1.0.0");
        expect(meta.status).toBe(200);
        expect((await meta.json<{ id: string }>()).id).toBe("kufar.Published");

        const archive = await call("/kufar/Published/1.0.0.zip");
        expect(archive.status).toBe(200);
    });

    it("409 на повторную публикацию той же версии", async () => {
        const response = await put(await payload("1.0.0"));
        expect(response.status).toBe(409);
    });

    it("регистрирует гит-URL для обратного поиска", async () => {
        const response = await call("/identifiers?url=git@github.com:kufar/Published.git");
        expect((await response.json<{ identifiers: string[] }>()).identifiers).toContain("kufar.Published");
    });
});

describe("маршрутизация и валидация", () => {
    it("405 на неподдерживаемый метод", async () => {
        expect((await call("/kufar/Toolbox", { method: "DELETE" })).status).toBe(405);
    });

    it("400 на идентификатор с недопустимыми символами", async () => {
        expect((await call("/ku%20far/Toolbox")).status).toBe(400);
    });
});

describe("разбор версий", () => {
    it("принимает semver с предрелизом и метаданными сборки", () => {
        expect(parseVersion("1.2.3")).toMatchObject({ major: 1, minor: 2, patch: 3, prerelease: null });
        expect(parseVersion("2.0.0-beta.1")).toMatchObject({ major: 2, prerelease: "beta.1" });
        expect(parseVersion("1.0.0+build.7")).toMatchObject({ major: 1, prerelease: null });
    });

    it("отвергает неполные и нечисловые", () => {
        for (const bad of ["1.0", "v1.0.0", "latest", "1.0.0.0", ""]) {
            expect(parseVersion(bad), bad).toBeNull();
        }
    });
});

describe("идентификаторы", () => {
    it("отвергает то, что сломало бы путь в хранилище", () => {
        for (const bad of ["", "../etc", "a/b", "-lead", "trail-", "a b"]) {
            expect(isValidSegment(bad), bad).toBe(false);
        }
        expect(isValidSegment("kufar")).toBe(true);
        expect(isValidSegment("Kufar_Foundation-2")).toBe(true);
    });
});
