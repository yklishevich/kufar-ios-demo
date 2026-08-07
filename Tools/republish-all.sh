#!/usr/bin/env bash
#
# Публикует в реестр все пакеты воркспейса — по существующим тегам гита.
#
# Когда нужно. Реестр и гит хранят состояние независимо, и разъехаться они
# могут в обе стороны. Этот скрипт лечит одно направление: теги на месте,
# а релизов в реестре нет. Так бывает после сброса истории (reset-all.sh)
# или после ручной очистки таблицы releases.
#
# Обратное направление — релиз в реестре без тега в гите — тут не лечится
# и лечиться не должно: это значит, что опубликовали не то, и разбираться
# надо руками.
#
# Порядок публикации — топологический, снизу вверх. Он обязателен: SwiftPM
# при резолве идёт по зависимостям, и потребитель не опубликуется, пока
# в реестре нет того, на что он ссылается. Порядок задан списком явно,
# а не вычисляется: пакетов двадцать, граф меняется раз в квартал,
# а вычисленный порядок пришлось бы отлаживать вместо публикации.
#
#   ./Tools/republish-all.sh --dry-run     что и с какой версией уедет
#   ./Tools/republish-all.sh               опубликовать
#   ./Tools/republish-all.sh kufar.Search  только один пакет и всё, что ниже него
#
# Окружение:
#   REGISTRY_URL    адрес реестра
#   PUBLISH_TOKEN   токен публикации

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${REGISTRY_URL:-https://spm-registry.byklishevich.com}"

# Уровнями: внутри уровня порядок не важен, между уровнями — важен.
ORDER=(
  # Foundation
  "platform_team:kufar.Foundation"
  # Platform, ничего не требующие кроме ядра
  "platform_team:kufar.Navigation"
  "platform_team:kufar.DesignTokens"
  "platform_team:kufar.Analytics"
  "search_team:kufar.CatalogContracts"
  # Контракты вертикалей
  "search_team:kufar.SearchContracts"
  "posting_team:kufar.PostingContracts"
  "goods_team:kufar.GoodsContracts"
  "auto_team:kufar.AutoContracts"
  "identity_team:kufar.IdentityContracts"
  # Дизайн-система и киты
  "platform_team:kufar.DesignComponents"
  "platform_team:kufar.SchemaKit"
  "platform_team:kufar.ListingKit"
  # Вертикали и общие поверхности
  "search_team:kufar.Search"
  "posting_team:kufar.Posting"
  "goods_team:kufar.Goods"
  "auto_team:kufar.Auto"
  "identity_team:kufar.Identity"
  # Корень
  "platform_team:kufar.AppFeature"
  "platform_team:kufar.AppComposition"
)

DRY=0
ONLY=""
case "${1:-}" in
  --dry-run) DRY=1 ;;
  "")        ;;
  *)         ONLY="$1" ;;
esac

if [[ $DRY -eq 0 && -z "${PUBLISH_TOKEN:-}" ]]; then
  echo "Нет PUBLISH_TOKEN. Публикация невозможна."
  echo "  export REGISTRY_URL=$REGISTRY PUBLISH_TOKEN=…"
  exit 1
fi

# Последний тег пакета в его репозитории: kufar.Foundation-1.0.2 → 1.0.2.
latest_version() {
  local team="$1" pkg="$2"
  git -C "$ROOT/$team" tag --list "$pkg-*" \
    | sed "s/^$pkg-//" \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1
}

printf "\nРеестр: %s\n" "$REGISTRY"
[[ $DRY -eq 1 ]] && printf "Режим : --dry-run, ничего не отправляется\n"
[[ -n "$ONLY" ]] && printf "Только: %s и всё, что ниже\n" "$ONLY"
printf "\n%-26s %-10s %s\n" "ПАКЕТ" "ВЕРСИЯ" "РЕЗУЛЬТАТ"
printf '%.0s─' {1..64}; echo

failed=0
skipped=0
for entry in "${ORDER[@]}"; do
  team="${entry%%:*}"
  pkg="${entry##*:}"
  dir="$ROOT/$team/$pkg"

  version="$(latest_version "$team" "$pkg")"
  if [[ -z "$version" ]]; then
    printf "%-26s %-10s %s\n" "$pkg" "—" "тега нет, пропуск"
    skipped=$((skipped + 1))
    [[ "$ONLY" == "$pkg" ]] && break
    continue
  fi

  if [[ $DRY -eq 1 ]]; then
    printf "%-26s %-10s %s\n" "$pkg" "$version" "будет опубликован"
  else
    if (cd "$ROOT/registry" && REGISTRY_URL="$REGISTRY" node scripts/publish.mjs \
          --package "$dir" --scope "${pkg%%.*}" --name "${pkg#*.}" \
          --version "$version" >/dev/null 2>&1); then
      printf "%-26s %-10s %s\n" "$pkg" "$version" "✓"
    else
      printf "%-26s %-10s %s\n" "$pkg" "$version" "✗ не удалось"
      failed=$((failed + 1))
      # Дальше идти бессмысленно: следующие пакеты зависят от этого
      # и упадут на резолве, засыпав вывод вторичными ошибками.
      echo
      echo "Остановлено: потребители этого пакета всё равно не опубликуются."
      exit 1
    fi
  fi

  [[ "$ONLY" == "$pkg" ]] && break
done

echo
[[ $skipped -gt 0 ]] && echo "Без тега (пропущено): $skipped"
if [[ $DRY -eq 1 ]]; then
  echo "Это был --dry-run. Убери флаг, чтобы опубликовать."
else
  echo "Готово. Проверка: ./Tools/check-registry.sh kufar.AppComposition"
fi
