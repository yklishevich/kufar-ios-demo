#!/usr/bin/env bash
#
# Полная очистка реестра: архивы из R2 и строки релизов из D1.
#
# Порядок здесь не вопрос вкуса. Ключи объектов в R2 хранятся в колонке
# archive_key — то есть D1 и есть каталог хранилища. Удалишь строки первыми,
# и архивы останутся навсегда: перечислить объекты бакета нечем, у wrangler 3
# команды `r2 object list` попросту нет. Поэтому сначала читаем ключи,
# потом удаляем блобы, и только затем чистим таблицу.
#
# Схема хранения не трогается — CREATE TABLE в schema.sql переживает очистку.
#
#   ./registry/scripts/reset.sh --dry-run   показать, что будет удалено
#   ./registry/scripts/reset.sh             удалить
#
# После очистки реестр пуст, и ни один потребитель ничего не зарезолвит,
# пока пакеты не опубликованы заново:
#
#   ./Tools/publish.sh --push --tag

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$(cd "$HERE/.." && pwd)"

DB="spm-registry"
BUCKET="spm-registry-archives"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

cd "$REGISTRY"

echo
echo "Очистка реестра"
echo "═══════════════"
echo "  D1:  $DB"
echo "  R2:  $BUCKET"
echo

# ── 1. Каталог: что вообще опубликовано ─────────────────────────────────

raw="$(npx wrangler d1 execute "$DB" --remote --json \
        --command "SELECT scope, name, version, archive_key FROM releases ORDER BY scope, name, version" 2>/dev/null)"

# wrangler печатает баннер перед JSON; отрезаем всё до первой скобки.
keys="$(printf '%s' "$raw" | python3 -c '
import json, sys

text = sys.stdin.read()
start = text.find("[")
if start == -1:
    sys.exit("не удалось разобрать ответ D1")

rows = []
for block in json.loads(text[start:]):
    rows.extend(block.get("results", []))

for r in rows:
    print("{}\t{}.{}\t{}".format(r["archive_key"], r["scope"], r["name"], r["version"]))
')"

if [[ -z "$keys" ]]; then
    echo "  Реестр уже пуст."
    exit 0
fi

count="$(printf '%s\n' "$keys" | wc -l | tr -d ' ')"
echo "Опубликовано релизов: $count"
printf '%s\n' "$keys" | awk -F'\t' '{ printf "  %-30s %s\n", $2, $3 }'
echo

if [[ $DRY -eq 1 ]]; then
    echo "Будет удалено: $count архивов из R2 и все строки из releases."
    echo "Это был --dry-run. Убери флаг, чтобы удалить."
    exit 0
fi

# Подтверждение обязательно: версии неизменяемы, и восстановить удалённую
# можно только повторной публикацией из того же исходника.
printf "Удалить %s релизов безвозвратно? [введи «да»]: " "$count"
read -r answer
[[ "$answer" == "да" ]] || { echo "Отменено."; exit 1; }
echo

# ── 2. Архивы ───────────────────────────────────────────────────────────
#
# По одному вызову wrangler на объект — пакетного удаления в CLI нет.
# На шести десятках архивов это пара минут; массовая очистка тут разовая
# операция, оптимизировать нечего.

echo "Архивы:"
failed=0
while IFS=$'\t' read -r key pkg version; do
    if npx wrangler r2 object delete "$BUCKET/$key" >/dev/null 2>&1; then
        printf "  ✓ %-30s %s\n" "$pkg" "$version"
    else
        printf "  ✗ %-30s %s — не удалён\n" "$pkg" "$version"
        failed=$((failed + 1))
    fi
done <<< "$keys"

if [[ $failed -gt 0 ]]; then
    echo
    echo "Не удалено архивов: $failed. Строки в D1 оставлены нетронутыми —"
    echo "иначе ключи этих объектов было бы уже не восстановить."
    exit 1
fi

# ── 3. Метаданные ───────────────────────────────────────────────────────

echo
echo "Строки релизов:"
npx wrangler d1 execute "$DB" --remote --command "DELETE FROM releases" >/dev/null
echo "  ✓ releases очищена"

cat <<'NEXT'

Реестр пуст. Пока пакеты не опубликованы заново, ни один потребитель
ничего не зарезолвит:

  export REGISTRY_URL=https://spm-registry.byklishevich.com
  export PUBLISH_TOKEN=…
  ./Tools/publish.sh --push --tag

Тегов на HEAD нет, поэтому каждый пакет получит 1.0.0.
NEXT
echo
