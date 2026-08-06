#!/usr/bin/env bash
#
# Проверяет, что реестр умеет то, ради чего он существует: отдать пакет
# постороннему потребителю, у которого нет ни воркспейса, ни соседних папок.
#
# Зачем отдельный скрипт. Когда Xcode отказывается добавить зависимость,
# причин две: сломан реестр или в диалог введено не то. Различить их
# по сообщению Xcode нельзя — он показывает одну и ту же ошибку доступа.
# Здесь Xcode не участвует: пустой пакет во временной папке, один
# `swift package resolve`, чистый ответ.
#
#   ./Tools/check-registry.sh                    проверить kufar.AppComposition
#   ./Tools/check-registry.sh kufar.Foundation   проверить другой пакет
#
# Переопределить адрес:  REGISTRY_URL=https://… ./Tools/check-registry.sh

set -euo pipefail

PACKAGE="${1:-kufar.AppComposition}"
REGISTRY="${REGISTRY_URL:-https://spm-registry.byklishevich.com}"

SCOPE="${PACKAGE%%.*}"
NAME="${PACKAGE#*.}"

echo
echo "Реестр : $REGISTRY"
echo "Пакет  : $PACKAGE"
echo

# ── 1. Протокол SE-0292 напрямую ────────────────────────────────────────
# Если тут пусто — дальше идти незачем, SwiftPM увидит ровно то же самое.

echo "1. Список релизов"
releases="$(curl -sS -f \
    -H "Accept: application/vnd.swift.registry.v1+json" \
    "$REGISTRY/$SCOPE/$NAME")" || {
    echo "   реестр не ответил на GET /$SCOPE/$NAME"
    echo "   пакет не опубликован, либо адрес реестра другой"
    exit 1
}

# Версии разбирает питон, а не jq: jq стоит не у всех, а питон уже нужен
# для deplint.py — значит он есть у каждого, кто вообще работает с проектом.
printf '%s' "$releases" | python3 <<'PY'
import json, sys

data = json.load(sys.stdin)
versions = list(data.get("releases", {}))
if not versions:
    sys.exit("   релизов нет — пакет заведён, но ни одна версия не опубликована")

versions.sort(key=lambda v: [int(p) for p in v.split(".")])
print("   версии:", ", ".join(versions))
print("   последняя:", versions[-1])
PY

# ── 2. Резолв настоящим SwiftPM ─────────────────────────────────────────
# Именно этот шаг доказывает, что реестром можно пользоваться, а не только
# читать его curl-ом: SwiftPM скачает архив, сверит контрольную сумму
# и рекурсивно разберёт манифест зависимостей.

echo
echo "2. Резолв из пустого пакета"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Sources/Probe" "$work/.swiftpm/configuration"

# security здесь не для удобства, а чтобы проверка совпадала с реальностью:
# ровно та же политика подписи лежит в registries.json воркспейса и проекта.
# Без неё скрипт бы отвечал «всё хорошо» там, где Xcode отказывается.
#
# Реестр не подписывает архивы (SE-0391 не реализован), а SwiftPM по умолчанию
# на неподписанное отвечает prompt — в неинтерактивном резолве это отказ.
# Послабление адресное, через registryOverrides: политика для всех остальных
# реестров остаётся строгой.
cat > "$work/.swiftpm/configuration/registries.json" <<JSON
{
  "registries": { "[default]": { "url": "$REGISTRY" } },
  "security": {
    "registryOverrides": {
      "$(printf '%s' "$REGISTRY" | sed -E 's#^https?://##; s#/.*##')": {
        "signing": { "onUnsigned": "silentAllow" }
      }
    }
  },
  "version": 1
}
JSON

cat > "$work/Package.swift" <<MANIFEST
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(id: "$PACKAGE", from: "1.0.0")
    ],
    targets: [.target(name: "Probe")]
)
MANIFEST

echo "// пусто намеренно: проверяется резолв, а не сборка" \
    > "$work/Sources/Probe/Probe.swift"

# pipefail (включён выше) обязателен: без него `if` смотрел бы на код sed,
# а не swift, и провал резолва выглядел бы успехом.
if ! swift package --package-path "$work" resolve 2>&1 | sed 's/^/   /'; then
    echo
    echo "Резолв не прошёл. Реестр отвечает, но пакет собрать не удалось —"
    echo "смотри текст выше. Обычно это либо несовпадение контрольной суммы"
    echo "архива, либо зависимость, которую забыли опубликовать."
    exit 1
fi

# ── 3. Что закрепилось ──────────────────────────────────────────────────
# Package.resolved интересен не версиями, а полем kind. Если хоть один пин
# пришёл по git — значит какая-то зависимость в графе всё ещё адресуется
# ссылкой, и «чужой клон соберётся из реестра» уже неправда.

echo
echo "3. Что закрепилось в Package.resolved"
python3 - "$work/Package.resolved" <<'PY'
import json, sys

pins = json.load(open(sys.argv[1])).get("pins", [])
registry = sorted((p for p in pins if p.get("kind") == "registry"),
                  key=lambda p: p["identity"])
scm = [p for p in pins if p.get("kind") != "registry"]

for p in registry:
    print("   {:<28} {}".format(p["identity"], p["state"].get("version", "?")))

print()
print("   из реестра: {}".format(len(registry)))

if scm:
    print("   МИМО РЕЕСТРА, по git: {}".format(len(scm)))
    for p in scm:
        print("     {}".format(p["identity"]))
    sys.exit(1)
PY

echo
echo "Реестр работает: посторонний пакет получил весь граф по одной"
echo "идентичности, без единой git-ссылки."
echo
echo "Если Xcode всё равно отказывается — дело в том, ЧТО введено в диалог"
echo "«Add Package Dependencies». Нужна идентичность:"
echo
echo "    $PACKAGE"
echo
echo "Адрес реестра туда вводить нельзя: строку со схемой http(s) Xcode"
echo "принимает за git-репозиторий и спрашивает логин с паролем."
