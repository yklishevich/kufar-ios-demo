/**
 * Реестр пакетов Swift (SE-0292) на Cloudflare Workers.
 *
 * Маршрутизация написана руками, а не фреймворком: путей шесть, и они
 * различаются формой, а не только префиксом — `/{scope}/{name}/{version}.zip`
 * и `/{scope}/{name}/{version}/Package.swift` разбираются по одному и тому же
 * сегменту. Регулярка тут честнее, чем цепочка `app.get()`.
 */

import { checkApiVersion, problem } from "./protocol";
import {
    listReleases,
    releaseMetadata,
    manifest,
    sourceArchive,
    lookupIdentifiers,
    validatePackageID,
    validateVersion,
} from "./handlers";
import { publish } from "./publish";
import type { Env } from "./types";

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        try {
            return await route(request, env);
        } catch (error) {
            // Наружу утекает только текст. Стек в problem+json попал бы
            // пользователю в консоль сборки — реестр внутренний, но привычка
            // отдавать внутренности клиенту плохая.
            console.error(error);
            return problem(500, "Внутренняя ошибка реестра.");
        }
    },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);

    // Публикация — не часть SE-0292. Свой протокол с bearer-токеном:
    // архив собирает CI, он же считает контрольную сумму. Полноценный
    // PUT по SE-0391 потребовал бы multipart и проверки подписей,
    // а демонстрирует всё равно чтение — именно его использует SwiftPM.
    if (request.method === "PUT" && segments[0] === "_publish") {
        return publish(request, env);
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
        return problem(405, `Метод ${request.method} реестром не поддерживается.`);
    }

    const versionError = checkApiVersion(request);
    if (versionError) return versionError;

    // GET /identifiers?url=…
    if (segments.length === 1 && segments[0] === "identifiers") {
        const target = url.searchParams.get("url");
        if (!target) return problem(400, "Параметр url обязателен.");
        return lookupIdentifiers(env, target);
    }

    const [scope, name, third, fourth] = segments;
    if (!scope || !name) {
        return problem(404, "Маршрут не найден. Формат: /{scope}/{name}[/{version}].");
    }

    const idError = validatePackageID(scope, name);
    if (idError) return idError;
    const id = { scope, name };

    // GET /{scope}/{name}
    if (segments.length === 2) {
        return listReleases(env, id);
    }

    if (segments.length === 3 && third) {
        // GET /{scope}/{name}/{version}.zip
        //
        // Расширение, а не отдельный сегмент, — так в спецификации. Отрезаем
        // до валидации версии, иначе '1.0.0.zip' не пройдёт проверку semver.
        if (third.endsWith(".zip")) {
            const version = third.slice(0, -4);
            const error = validateVersion(version);
            return error ?? sourceArchive(env, id, version);
        }

        // GET /{scope}/{name}/{version}
        const error = validateVersion(third);
        return error ?? releaseMetadata(env, id, third);
    }

    // GET /{scope}/{name}/{version}/Package.swift
    if (segments.length === 4 && third && fourth === "Package.swift") {
        const error = validateVersion(third);
        return error ?? manifest(env, id, third, url.searchParams.get("swift-version"));
    }

    return problem(404, `Маршрут ${url.pathname} не найден.`);
}
