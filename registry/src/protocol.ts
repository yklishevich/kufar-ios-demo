/**
 * Транспортный слой спецификации: согласование версии API и формат ошибок.
 *
 * Вынесено отдельно от обработчиков, потому что это единственная часть,
 * которая обязана быть одинаковой во всех ответах. Забыть `Content-Version`
 * в одном эндпоинте из пяти — типичная ошибка, и клиент на неё реагирует
 * не отказом, а странным поведением резолва.
 */

/** Версия API реестра, которую реализует этот сервер. */
export const API_VERSION = "1";

/**
 * Медиатип запроса: `application/vnd.swift.registry.v1+json`.
 *
 * Версия API живёт в `Accept`, а не в пути URL. Решение спецификации,
 * и оно правильное: адрес релиза остаётся стабильным навсегда, а клиент
 * договаривается о формате отдельно. Ссылка на пакет не протухает
 * от того, что реестр научился новой версии протокола.
 */
const ACCEPT_PATTERN = /^application\/vnd\.swift\.registry(?:\.v(\d+))?(?:\+(\w+))?$/;

export interface AcceptHeader {
    version: string;
    format?: string;
}

/**
 * Разбирает `Accept`. Возвращает `null`, если заголовок не про наш протокол —
 * тогда применяется значение по умолчанию: спецификация требует отдавать
 * актуальную версию, а не отказывать.
 */
export function parseAccept(header: string | null): AcceptHeader | null {
    if (!header) return null;

    for (const raw of header.split(",")) {
        const candidate = raw.split(";")[0]?.trim();
        if (!candidate) continue;

        const match = ACCEPT_PATTERN.exec(candidate);
        if (match) {
            return { version: match[1] ?? API_VERSION, format: match[2] };
        }
    }
    return null;
}

/** Заголовки, обязательные в каждом ответе реестра. */
export function baseHeaders(extra: Record<string, string> = {}): Headers {
    const headers = new Headers(extra);
    headers.set("Content-Version", API_VERSION);
    return headers;
}

/**
 * Ошибка в формате problem+json (RFC 7807).
 *
 * Спецификация требует именно его, и это не формальность: SwiftPM показывает
 * поле `detail` пользователю. Голый текст ошибки он проглотит молча,
 * и человек увидит «resolution failed» без причины.
 */
export function problem(status: number, detail: string, extra: Record<string, unknown> = {}): Response {
    return new Response(JSON.stringify({ detail, ...extra }), {
        status,
        headers: baseHeaders({ "Content-Type": "application/problem+json" }),
    });
}

/**
 * Проверяет запрошенную версию API до вызова обработчика.
 *
 * Отказ идёт с 400 и внятным текстом: клиент, который просит v2 у сервера,
 * умеющего v1, должен получить причину, а не разбираться, почему пакет
 * «не найден».
 */
export function checkApiVersion(request: Request): Response | null {
    const accept = parseAccept(request.headers.get("Accept"));
    if (accept && accept.version !== API_VERSION) {
        return problem(
            400,
            `Реестр реализует версию API ${API_VERSION}, запрошена ${accept.version}.`
        );
    }
    return null;
}

/** Ответ с JSON-телом и обязательными заголовками. */
export function json(body: unknown, extra: Record<string, string> = {}): Response {
    return new Response(JSON.stringify(body), {
        headers: baseHeaders({ "Content-Type": "application/json", ...extra }),
    });
}

/**
 * Собирает Link-заголовок.
 *
 * Клиент SwiftPM ходит по `rel="latest-version"`, чтобы понять, что считать
 * последней версией, не разбирая semver самостоятельно. Сортировку делает
 * сервер — у него для этого есть отдельные числовые колонки.
 */
export function linkHeader(links: Array<{ url: string; rel: string; type?: string }>): string {
    return links
        .map(({ url, rel, type }) => {
            const parts = [`<${url}>`, `rel="${rel}"`];
            if (type) parts.push(`type="${type}"`);
            return parts.join("; ");
        })
        .join(", ");
}
