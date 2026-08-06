/**
 * Пять эндпоинтов чтения из SE-0292. Ровно столько нужно SwiftPM,
 * чтобы зарезолвить и скачать зависимость.
 */

import { json, problem, baseHeaders, linkHeader } from "./protocol";
import type { Env, PackageID, ReleaseRow } from "./types";
import { isValidSegment, parseVersion } from "./types";

/** Сортировка по semver: сначала старшие, предрелизы ниже релизов той же версии. */
const ORDER_BY = "ORDER BY major DESC, minor DESC, patch DESC, prerelease IS NULL DESC, prerelease DESC";

function packageURL(env: Env, id: PackageID): string {
    return `${env.REGISTRY_BASE_URL}/${id.scope}/${id.name}`;
}

/**
 * `GET /{scope}/{name}` — список релизов.
 *
 * Первый запрос при резолве: клиент узнаёт, какие версии вообще есть,
 * и только потом сопоставляет их с диапазоном из манифеста.
 */
export async function listReleases(env: Env, id: PackageID): Promise<Response> {
    const { results } = await env.DB.prepare(
        `SELECT version, major, minor, patch, prerelease FROM releases
         WHERE scope = ? AND name = ? ${ORDER_BY}`
    ).bind(id.scope, id.name).all<Pick<ReleaseRow, "version" | "major" | "minor" | "patch" | "prerelease">>();

    if (!results || results.length === 0) {
        return problem(404, `Пакет ${id.scope}.${id.name} в реестре не найден.`);
    }

    const base = packageURL(env, id);
    const releases: Record<string, { url: string }> = {};
    for (const row of results) {
        releases[row.version] = { url: `${base}/${row.version}` };
    }

    // latest-version — первая невыпущенная-предрелизом строка. Предрелизы
    // последней версией не считаются: клиент, попросивший `from:`, их не берёт,
    // и указывать на них в заголовке значило бы вводить в заблуждение.
    const latest = results.find((row) => row.prerelease === null) ?? results[0];

    const links = [{ url: base, rel: "canonical" }];
    if (latest) links.unshift({ url: `${base}/${latest.version}`, rel: "latest-version" });

    return json({ releases }, { Link: linkHeader(links) });
}

/**
 * `GET /{scope}/{name}/{version}` — метаданные релиза.
 *
 * Здесь клиент получает контрольную сумму архива. Он сверит её после
 * скачивания и откажется собирать при расхождении — то есть это, а не
 * HTTPS, защищает от подмены содержимого в хранилище.
 */
export async function releaseMetadata(env: Env, id: PackageID, version: string): Promise<Response> {
    const row = await env.DB.prepare(
        `SELECT * FROM releases WHERE scope = ? AND name = ? AND version = ?`
    ).bind(id.scope, id.name, version).first<ReleaseRow>();

    if (!row) return problem(404, `Версия ${version} пакета ${id.scope}.${id.name} не опубликована.`);

    const base = packageURL(env, id);
    return json(
        {
            id: `${id.scope}.${id.name}`,
            version: row.version,
            resources: [
                {
                    name: "source-archive",
                    type: "application/zip",
                    checksum: row.checksum,
                },
            ],
            metadata: {
                repositoryURLs: row.repository_url ? [row.repository_url] : [],
            },
            publishedAt: row.published_at,
        },
        {
            Link: linkHeader([
                { url: `${base}/${version}.zip`, rel: "alternate", type: "application/zip" },
                { url: base, rel: "canonical" },
            ]),
        }
    );
}

/**
 * `GET /{scope}/{name}/{version}/Package.swift` — манифест.
 *
 * Параметр `swift-version` выбирает версионный манифест
 * (`Package@swift-5.9.swift`). Если запрошенной версии нет, спецификация
 * велит отдать основной манифест, а не 404: пакет должен собираться
 * на тулчейне, о котором его автор не знал.
 */
export async function manifest(
    env: Env,
    id: PackageID,
    version: string,
    swiftVersion: string | null
): Promise<Response> {
    const row = await env.DB.prepare(
        `SELECT manifest, manifests_json FROM releases WHERE scope = ? AND name = ? AND version = ?`
    ).bind(id.scope, id.name, version).first<Pick<ReleaseRow, "manifest" | "manifests_json">>();

    if (!row) return problem(404, `Версия ${version} пакета ${id.scope}.${id.name} не опубликована.`);

    const alternates: Record<string, string> = JSON.parse(row.manifests_json || "{}");
    const body = (swiftVersion && alternates[swiftVersion]) || row.manifest;

    const base = `${packageURL(env, id)}/${version}/Package.swift`;
    const links = Object.keys(alternates).map((v) => ({
        url: `${base}?swift-version=${v}`,
        rel: "alternate",
        type: "text/x-swift",
    }));

    const headers = baseHeaders({
        "Content-Type": "text/x-swift",
        "Content-Disposition": 'attachment; filename="Package.swift"',
    });
    if (links.length > 0) headers.set("Link", linkHeader(links));

    return new Response(body, { headers });
}

/**
 * `GET /{scope}/{name}/{version}.zip` — архив исходников.
 *
 * Единственное место, где реестр отдаёт мегабайты, поэтому поток идёт
 * из R2 напрямую, без чтения в память Worker'а.
 */
export async function sourceArchive(env: Env, id: PackageID, version: string): Promise<Response> {
    const row = await env.DB.prepare(
        `SELECT archive_key, checksum, archive_size FROM releases
         WHERE scope = ? AND name = ? AND version = ?`
    ).bind(id.scope, id.name, version).first<Pick<ReleaseRow, "archive_key" | "checksum" | "archive_size">>();

    if (!row) return problem(404, `Версия ${version} пакета ${id.scope}.${id.name} не опубликована.`);

    const object = await env.ARCHIVES.get(row.archive_key);
    if (!object) {
        // Метаданные есть, объекта нет — рассинхрон D1 и R2. Это 500,
        // а не 404: пакет опубликован, сломан именно реестр, и клиенту
        // имеет смысл повторить, а не считать версию несуществующей.
        return problem(500, `Архив ${row.archive_key} отсутствует в хранилище.`);
    }

    return new Response(object.body, {
        headers: baseHeaders({
            "Content-Type": "application/zip",
            "Content-Length": String(row.archive_size),
            "Content-Disposition": `attachment; filename="${id.name}-${version}.zip"`,
            // Digest по RFC 3230 — base64, тогда как checksum в метаданных hex.
            // Разные представления одной суммы: заголовок пришёл из HTTP-мира,
            // поле в JSON — из мира пакетных менеджеров. Клиент сверяет второе.
            Digest: `sha-256=${hexToBase64(row.checksum)}`,
            "Accept-Ranges": "bytes",
        }),
    });
}

/**
 * `GET /identifiers?url=…` — обратный поиск идентификатора по гит-URL.
 *
 * Нужен флагам `--use-registry-identity-for-scm` и `--replace-scm-with-registry`.
 * Без него один и тот же пакет, подключённый где-то по URL, а где-то через
 * реестр, попадёт в граф дважды под разными identity — и SwiftPM либо
 * соберёт две копии, либо откажется резолвить конфликт версий, которого нет.
 */
export async function lookupIdentifiers(env: Env, url: string): Promise<Response> {
    const { results } = await env.DB.prepare(
        `SELECT scope, name FROM scm_identifiers WHERE url = ?`
    ).bind(normalizeGitURL(url)).all<Pick<ReleaseRow, "scope" | "name">>();

    if (!results || results.length === 0) {
        return problem(404, `Для ${url} идентификаторов в реестре нет.`);
    }

    return json({ identifiers: results.map((r) => `${r.scope}.${r.name}`) });
}

/**
 * Приводит гит-URL к каноническому виду перед сравнением.
 *
 * Один и тот же репозиторий записывают минимум четырьмя способами: по https
 * и по ssh, с суффиксом `.git` и без. Не нормализовать — значит требовать
 * от потребителя записать URL ровно так же, как это сделал издатель.
 */
export function normalizeGitURL(url: string): string {
    let value = url.trim().toLowerCase();
    value = value.replace(/^git\+/, "");
    value = value.replace(/^ssh:\/\//, "");
    value = value.replace(/^git@([^:]+):/, "https://$1/");
    if (!value.startsWith("http")) value = `https://${value}`;
    value = value.replace(/\.git$/, "");
    value = value.replace(/\/+$/, "");
    return value;
}

/** hex → base64 для заголовка Digest. */
function hexToBase64(hex: string): string {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
        bytes[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
    }
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary);
}

/** Проверка scope и name до обращения к базе. */
export function validatePackageID(scope: string, name: string): Response | null {
    if (!isValidSegment(scope) || !isValidSegment(name)) {
        return problem(400, `Некорректный идентификатор пакета: ${scope}.${name}`);
    }
    return null;
}

/** Проверка версии до обращения к базе. */
export function validateVersion(version: string): Response | null {
    if (!parseVersion(version)) {
        return problem(400, `Версия «${version}» не соответствует semver.`);
    }
    return null;
}
