#!/usr/bin/env node
/**
 * Публикует пакет в реестр: собирает архив исходников, считает контрольную
 * сумму, отправляет в Worker.
 *
 *   node scripts/publish.mjs --package ../packages/Toolbox \
 *                            --scope kufar --name Toolbox --version 1.0.0
 *
 * Адрес реестра и токен берутся из окружения: REGISTRY_URL, PUBLISH_TOKEN.
 *
 * Почему архив собирает клиент, а не сервер. `swift package archive-source`
 * знает, что относится к пакету, а что нет: он уважает .gitignore, выкидывает
 * .build и локальные артефакты. Повторять эту логику на сервере — значит
 * однажды разойтись с тулчейном и опубликовать архив, который не собирается.
 */

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, mkdtempSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, basename } from "node:path";
import { tmpdir } from "node:os";

function arg(name, fallback = null) {
    const index = process.argv.indexOf(`--${name}`);
    if (index !== -1 && process.argv[index + 1]) return process.argv[index + 1];
    if (fallback !== null) return fallback;
    console.error(`Не хватает аргумента --${name}`);
    process.exit(2);
}

const packagePath = arg("package");
const scope = arg("scope");
const name = arg("name");
const version = arg("version");

const registryURL = process.env.REGISTRY_URL;
const token = process.env.PUBLISH_TOKEN;
if (!registryURL || !token) {
    console.error("Нужны переменные окружения REGISTRY_URL и PUBLISH_TOKEN.");
    process.exit(2);
}

const manifestPath = join(packagePath, "Package.swift");
if (!existsSync(manifestPath)) {
    console.error(`В ${packagePath} нет Package.swift — это не пакет.`);
    process.exit(1);
}

// Версионные манифесты: Package@swift-5.9.swift и подобные. Реестр обязан
// уметь их отдавать по ?swift-version=, иначе пакет, поддерживающий
// несколько тулчейнов, на старом Swift не соберётся.
const alternates = {};
for (const file of readdirSync(packagePath)) {
    const match = /^Package@swift-(\d+(?:\.\d+)*)\.swift$/.exec(file);
    if (match) alternates[match[1]] = readFileSync(join(packagePath, file), "utf8");
}

const outputDir = mkdtempSync(join(tmpdir(), "registry-"));
console.log(`Собираю архив ${scope}.${name} ${version}…`);
execFileSync("swift", ["package", "archive-source", "--output", join(outputDir, `${name}.zip`)], {
    cwd: packagePath,
    stdio: "inherit",
});

const archivePath = join(outputDir, `${name}.zip`);
const archive = readFileSync(archivePath);
const checksum = createHash("sha256").update(archive).digest("hex");

console.log(`  ${basename(archivePath)}: ${(archive.length / 1024).toFixed(1)} КБ, sha256 ${checksum.slice(0, 12)}…`);

const response = await fetch(`${registryURL}/_publish`, {
    method: "PUT",
    headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
    },
    body: JSON.stringify({
        scope,
        name,
        version,
        archive: archive.toString("base64"),
        checksum,
        manifest: readFileSync(manifestPath, "utf8"),
        manifests: alternates,
        repositoryURL: process.env.REPOSITORY_URL ?? null,
    }),
});

if (response.status === 409) {
    // Версия уже опубликована — не ошибка пайплайна. Тег могли перезапустить
    // вручную; падать из-за этого незачем, а перезаписывать нельзя.
    console.log(`  ${version} уже в реестре, пропускаю.`);
    process.exit(0);
}

if (!response.ok) {
    const body = await response.text();
    console.error(`Публикация не удалась: ${response.status} ${body}`);
    process.exit(1);
}

const result = await response.json();
console.log(`  опубликовано: ${result.id} ${result.version}`);
