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
# Публикуются ВСЕ теги пакета, а не только последний. Иначе ломается
# `pinned`-режим versioned.yml: Package.resolved фиксирует 1.0.0, а в реестре
# лежит одна свежая версия — и «клонировал и собрал» перестаёт работать
# для любого, у кого есть лок-файл.
#
# Каждая версия собирается из СВОЕГО тега через отдельное worktree.
# Публиковать старый номер из текущей рабочей копии нельзя: в реестр уедет
# сегодняшний код под вчерашней версией, и расхождение всплывёт у потребителя,
# а не здесь.
#
#   ./Tools/republish-all.sh --dry-run       что и какие версии уедут
#   ./Tools/republish-all.sh                 опубликовать всё
#   ./Tools/republish-all.sh --latest-only   только последнюю версию каждого
#   ./Tools/republish-all.sh kufar.Search    до этого пакета включительно
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
  "identity_team:kufar.SessionContracts"
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
LATEST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY=1 ;;
    --latest-only) LATEST_ONLY=1 ;;
    *)             ONLY="$arg" ;;
  esac
done

if [[ $DRY -eq 0 && -z "${PUBLISH_TOKEN:-}" ]]; then
  echo "Нет PUBLISH_TOKEN. Публикация невозможна."
  echo "  export REGISTRY_URL=$REGISTRY PUBLISH_TOKEN=…"
  exit 1
fi

# Версии пакета по тегам, по возрастанию: kufar.Foundation-1.0.2 → 1.0.2.
# Порядок важен: потребитель может запросить любую, но публиковать снизу
# вверх привычнее для чтения лога.
versions_of() {
  local team="$1" pkg="$2"
  git -C "$ROOT/$team" tag --list "$pkg-*" \
    | sed "s/^$pkg-//" \
    | sort -t. -k1,1n -k2,2n -k3,3n
}

# Публикует одну версию из её собственного тега.
#
# worktree, а не checkout: рабочая копия остаётся нетронутой, а параллельные
# ветки и незакоммиченные правки не мешают. Каталог временный и удаляется
# в любом случае — иначе `git worktree list` быстро зарастёт мусором.
publish_version() {
  local team="$1" pkg="$2" version="$3"
  local tag="$pkg-$version"
  local tmp; tmp="$(mktemp -d)"

  # shellcheck disable=SC2064
  trap "git -C '$ROOT/$team' worktree remove --force '$tmp' >/dev/null 2>&1 || true; rm -rf '$tmp'" RETURN

  git -C "$ROOT/$team" worktree add --detach --quiet "$tmp" "$tag" || return 1
  (cd "$ROOT/registry" && REGISTRY_URL="$REGISTRY" node scripts/publish.mjs \
      --package "$tmp/$pkg" --scope "${pkg%%.*}" --name "${pkg#*.}" \
      --version "$version" >/dev/null 2>&1)
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

  # Читаем в массив циклом, а не mapfile: в macOS системный bash — 3.2,
  # где нет ни mapfile, ни отрицательных индексов массива. Скрипт обязан
  # работать тем bash, который стоит из коробки: требовать `brew install bash`
  # ради одной строки — плохой размен.
  versions=()
  while IFS= read -r _version; do
    [[ -n "$_version" ]] && versions+=("$_version")
  done < <(versions_of "$team" "$pkg")

  if [[ ${#versions[@]} -eq 0 ]]; then
    printf "%-26s %-10s %s\n" "$pkg" "—" "тегов нет, пропуск"
    skipped=$((skipped + 1))
    [[ "$ONLY" == "$pkg" ]] && break
    continue
  fi
  newest="${versions[$(( ${#versions[@]} - 1 ))]}"
  [[ $LATEST_ONLY -eq 1 ]] && versions=("$newest")

  for version in "${versions[@]}"; do
    if [[ $DRY -eq 1 ]]; then
      printf "%-26s %-10s %s\n" "$pkg" "$version" "будет опубликован"
      continue
    fi

    if publish_version "$team" "$pkg" "$version"; then
      printf "%-26s %-10s %s\n" "$pkg" "$version" "✓"
    elif [[ "$version" == "$newest" ]]; then
      # Последняя версия обязана уехать: на неё смотрит `latest`-режим
      # и все, кто не фиксирует лок-файл. Дальше идти бессмысленно —
      # потребители этого пакета упадут на резолве.
      printf "%-26s %-10s %s\n" "$pkg" "$version" "✗ не удалось"
      failed=$((failed + 1))
      echo
      echo "Остановлено: потребители этого пакета всё равно не опубликуются."
      exit 1
    else
      # Старая версия могла уже лежать в реестре — это не повод останавливаться.
      printf "%-26s %-10s %s\n" "$pkg" "$version" "— пропущена (уже есть или недоступна)"
    fi
  done

  [[ "$ONLY" == "$pkg" ]] && break
done

echo
[[ $skipped -gt 0 ]] && echo "Без тега (пропущено): $skipped"
if [[ $DRY -eq 1 ]]; then
  echo "Это был --dry-run. Убери флаг, чтобы опубликовать."
else
  echo "Готово. Проверка: ./Tools/check-registry.sh kufar.AppComposition"
fi
