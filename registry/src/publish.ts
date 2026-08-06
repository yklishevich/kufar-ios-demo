/**
 * Публикация версии. Не часть SE-0292 — там описано только чтение.
 *
 * Стандартный способ записи — `PUT /{scope}/{name}/{version}` по SE-0391
 * с multipart-телом, токенами и подписями. Здесь вместо него узкий
 * собственный эндпоинт: архив уже собран в CI, контрольная сумма посчитана
 * там же, серверу остаётся положить блоб и вставить строку.
 *
 * Размен назван осознанно: `swift package-registry publish` с этим реестром
 * работать не будет, публиковать может только свой пайплайн. Взамен нет
 * ни разбора multipart, ни валидации CMS-подписей — то есть нет и половины
 * поверхности для ошибок. Добавить SE-0391 позже — это ещё один маршрут,
 * схема хранения не меняется.
 */

import { problem, json } from "./protocol";
import { isValidSegment, parseVersion } from "./types";
import { normalizeGitURL } from "./handlers";
import type { Env } from "./types";

interface PublishBody {
    scope: string;
    name: string;
    version: string;
    /** Архив исходников в base64. */
    archive: string;
    /** sha256 архива в hex. Считает CI, сверяет R2 при записи. */
    checksum: string;
    manifest: string;
    /** Манифесты под конкретные версии Swift: {"5.9": "..."}. */
    manifests?: Record<string, string>;
    repositoryURL?: string;
}

export async function publish(request: Request, env: Env): Promise<Response> {
    if (!env.PUBLISH_TOKEN) {
        return problem(501, "Публикация не настроена: PUBLISH_TOKEN не задан.");
    }

    const auth = request.headers.get("Authorization");
    if (auth !== `Bearer ${env.PUBLISH_TOKEN}`) {
        return problem(401, "Требуется корректный bearer-токен.");
    }

    let body: PublishBody;
    try {
        body = await request.json<PublishBody>();
    } catch {
        return problem(400, "Тело запроса не является JSON.");
    }

    const { scope, name, version } = body;
    if (!isValidSegment(scope ?? "") || !isValidSegment(name ?? "")) {
        return problem(400, `Некорректный идентификатор пакета: ${scope}.${name}`);
    }

    const parsed = parseVersion(version ?? "");
    if (!parsed) return problem(400, `Версия «${version}» не соответствует semver.`);

    // Версия неизменяема. Перезапись означала бы, что зафиксированный
    // в Package.resolved коммит однажды отдаст другой код — тот же довод,
    // по которому теги не двигают силой.
    const existing = await env.DB.prepare(
        `SELECT version FROM releases WHERE scope = ? AND name = ? AND version = ?`
    ).bind(scope, name, version).first();

    if (existing) {
        return problem(409, `Версия ${version} пакета ${scope}.${name} уже опубликована.`);
    }

    const archive = base64ToBytes(body.archive ?? "");
    if (archive.length === 0) return problem(400, "Архив пуст.");

    const declared = (body.checksum ?? "").toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(declared)) {
        return problem(400, "Поле checksum должно быть sha256 в hex.");
    }

    const archiveKey = `${scope}/${name}/${version}.zip`;

    // Сумму проверяет R2, а не Worker.
    //
    // Смысл проверки прежний: подпись пайплайна должна совпасть с тем, что
    // реально легло в хранилище, иначе ошибка публикации превратится
    // в ошибку резолва у всех потребителей и всплывёт через месяц.
    //
    // Но считать sha256 по многомегабайтному архиву в самом Worker'е дорого:
    // на бесплатном тарифе бюджет 10 мс CPU на вызов, и публикация — единственное
    // место, которое в него не укладывается. R2 сверяет сумму на своей стороне
    // при записи и отвергает объект при расхождении: гарантия та же, CPU ноль.
    try {
        await env.ARCHIVES.put(archiveKey, archive, {
            sha256: declared,
            httpMetadata: { contentType: "application/zip" },
        });
    } catch (error) {
        // R2 отвергает запись при несовпадении суммы. Отличить это от сетевой
        // ошибки по типу нельзя, поэтому текст ошибки отдаём как есть —
        // человеку в логе CI он скажет больше, чем наша интерпретация.
        return problem(400, `Хранилище отвергло архив: ${(error as Error).message}`);
    }

    const actual = declared;

    // R2 записан раньше D1 намеренно. При падении между шагами останется
    // «сирота» в хранилище — безвредно, следующая попытка её перезапишет.
    // Обратный порядок дал бы метаданные без архива, то есть 500 на скачивании.
    await env.DB.prepare(
        `INSERT INTO releases
           (scope, name, version, major, minor, patch, prerelease,
            checksum, archive_size, archive_key, manifest, manifests_json,
            repository_url, published_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
        scope, name, version,
        parsed.major, parsed.minor, parsed.patch, parsed.prerelease,
        actual, archive.length, archiveKey,
        body.manifest ?? "", JSON.stringify(body.manifests ?? {}),
        body.repositoryURL ?? null, new Date().toISOString()
    ).run();

    if (body.repositoryURL) {
        await env.DB.prepare(
            `INSERT OR IGNORE INTO scm_identifiers (url, scope, name) VALUES (?, ?, ?)`
        ).bind(normalizeGitURL(body.repositoryURL), scope, name).run();
    }

    return json({ id: `${scope}.${name}`, version, checksum: actual }, { Location: `/${scope}/${name}/${version}` });
}

function base64ToBytes(value: string): Uint8Array {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}
