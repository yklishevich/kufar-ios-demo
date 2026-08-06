/** Биндинги Worker'а из wrangler.toml. */
export interface Env {
    ARCHIVES: R2Bucket;
    DB: D1Database;
    REGISTRY_BASE_URL: string;
    /** Задаётся через `wrangler secret put PUBLISH_TOKEN`. */
    PUBLISH_TOKEN?: string;
}

/** Строка таблицы releases. */
export interface ReleaseRow {
    scope: string;
    name: string;
    version: string;
    major: number;
    minor: number;
    patch: number;
    prerelease: string | null;
    checksum: string;
    archive_size: number;
    archive_key: string;
    manifest: string;
    manifests_json: string;
    repository_url: string | null;
    published_at: string;
}

/**
 * Идентификатор пакета в реестре: `scope.name`.
 *
 * Это и есть то, чем реестр отличается от гит-зависимостей: identity —
 * имя, а не адрес. Исходники могут переехать в другой репозиторий,
 * потребители не заметят.
 */
export interface PackageID {
    scope: string;
    name: string;
}

/**
 * Ограничения на scope и name из спецификации: буквы, цифры, дефис
 * и подчёркивание, не начинается и не заканчивается разделителем.
 * Проверяются на входе, чтобы в путь R2 и в SQL не попало ничего лишнего.
 */
const SEGMENT = /^[a-zA-Z0-9](?:[a-zA-Z0-9_-]*[a-zA-Z0-9])?$/;

export function isValidSegment(value: string): boolean {
    return value.length > 0 && value.length <= 100 && SEGMENT.test(value);
}

/**
 * Разбор semver в числа для сортировки.
 *
 * Нужен, потому что строковое сравнение версий врёт: '1.10.0' меньше '1.9.0'
 * лексикографически. Реестр обязан отдавать latest-version правильно —
 * иначе клиент, доверившийся заголовку, зарезолвит не ту версию.
 */
export interface ParsedVersion {
    major: number;
    minor: number;
    patch: number;
    prerelease: string | null;
}

const SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/;

export function parseVersion(version: string): ParsedVersion | null {
    const match = SEMVER.exec(version);
    if (!match) return null;
    return {
        major: Number(match[1]),
        minor: Number(match[2]),
        patch: Number(match[3]),
        prerelease: match[4] ?? null,
    };
}
