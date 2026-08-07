#!/usr/bin/env bash
#
# Поднимает воркспейс на чистой машине: клонирует все репозитории команд
# в правильные папки и открывает KufarWorkspace.xcworkspace.
#
# Зачем это нужно. Манифесты ссылаются друг на друга по идентичности реестра
# (.package(id:from:)), как и положено в multi-repo. Но собирать локально
# через сеть неудобно: правка в kufar.Foundation должна быть видна
# в kufar.Goods сразу, а не после публикации версии.
#
# Решает это воркспейс: Xcode подменяет зависимость локальным пакетом, если
# тот добавлен в тот же .xcworkspace. Сопоставление идёт по identity, и с
# переходом на реестр (SE-0292) она изменилась:
#
#     было:  identity = последний компонент URL      → папка KufarFoundation
#     стало: identity = scope.Name из реестра        → папка kufar.Foundation
#
# Заодно это развязало упаковку: раз идентичность не адрес, пакеты одной
# команды лежат в одном репозитории и релизятся независимо.
#
# Отсюда правило, которого нет в документации и которое найдено экспериментом:
#
#     имя папки == идентичность в реестре, то есть kufar.Foundation
#
# Имя репозитория при этом не значит ничего: клонируем kufar-platform.git
# в папку platform_team, а подмена смотрит на имена папок ПАКЕТОВ внутри неё.
# Ошибка, которая это показала:
#
#     unable to override package 'Foundation' because its identity
#     'kufar.foundation' doesn't match override's identity
#     (directory name) 'foundation'
#
# Использование:
#   ./Tools/bootstrap.sh              клонировать недостающее
#   ./Tools/bootstrap.sh --status     показать состояние без изменений
#   ./Tools/bootstrap.sh --pull       ещё и обновить существующие

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Владельца берём оттуда, откуда склонирован сам воркспейс: репозитории команд
# лежат рядом с ним, у того же владельца и по тому же протоколу. Зашитая
# константа однажды разошлась бы с реальностью, и клонирование ушло бы
# в несуществующую организацию с невнятным «Repository not found».
#
# Переопределить можно всегда:  KUFAR_ORG=git@github.com:owner ./Tools/bootstrap.sh
default_org() {
  local url
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    git@*:*/*)     echo "${url%/*}" ;;            # git@github.com:owner/repo.git
    https://*/*/*) dirname "$url" ;;              # https://github.com/owner/repo.git
    *)             echo "git@github.com:kufar-demo" ;;
  esac
}

ORG="${KUFAR_ORG:-$(default_org)}"

# Репозиторий на команду. Внутри — пакеты, каждый в своей папке.
# Стало возможным после перехода на реестр: адрес больше не идентичность,
# значит из одного репозитория можно отдать сколько угодно пакетов.
#
# Папка команды И ЕСТЬ репозиторий: search_team/.git, а не
# search_team/kufar.Search/.git. Раскладка на диске от этого не изменилась,
# поэтому воркспейс и манифесты переезд не заметили.
REPOS=(
  "platform_team:kufar-platform"
  "search_team:kufar-search"
  "posting_team:kufar-posting"
  "goods_team:kufar-goods"
  "auto_team:kufar-auto"
  "identity_team:kufar-identity"
)

MODE="${1:-clone}"

status()  { printf "  %-22s %-26s %s\n" "$1" "$2" "$3"; }

printf "\nВладелец: %s\n" "$ORG"
printf "\n%-24s %-26s %s\n" "ПАПКА" "РЕПОЗИТОРИЙ" "СОСТОЯНИЕ"
printf '%.0s─' {1..70}; echo

missing=0
for entry in "${REPOS[@]}"; do
  team="${entry%%:*}"
  repo="${entry##*:}"
  dir="$ROOT/$team"

  if [[ -d "$dir/.git" ]]; then
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    if [[ "$MODE" == "--pull" ]]; then
      # --ff-only намеренно: твои коммиты и твоя ветка — не забота этого скрипта.
      # Не перематывается (нет upstream, ветка разошлась, есть локальные правки) —
      # пропускаем и идём дальше. Раньше здесь было `pull && status`, и под
      # set -e неудачный pull ронял весь проход без единого слова о причине.
      if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
        status "$team" "$repo" "обновлён ($branch)"
      else
        status "$team" "$repo" "пропущен, не перематывается ($branch)"
      fi
    else
      status "$team" "$repo" "есть ($branch)"
    fi
  elif [[ -d "$dir" ]]; then
    status "$team" "$repo" "папка есть, но не git-репозиторий"
  else
    missing=$((missing + 1))
    if [[ "$MODE" == "--status" ]]; then
      status "$team" "$repo" "НЕТ"
    else
      mkdir -p "$ROOT/$team"
      if git clone --quiet "$ORG/$repo.git" "$dir" 2>/dev/null; then
        status "$team" "$repo" "склонирован"
      else
        status "$team" "$repo" "НЕ НАЙДЕН"
        echo
        echo "Не удалось склонировать: $ORG/$repo.git"
        echo "Проверь владельца: он задаёт, откуда клонировать исходники."
        echo "На резолв зависимостей владелец больше не влияет — их адресует реестр."
        echo "Задать явно:  KUFAR_ORG=git@github.com:ВЛАДЕЛЕЦ $0"
        exit 1
      fi
    fi
  fi
done

echo
if [[ "$MODE" == "--status" && $missing -gt 0 ]]; then
  echo "Отсутствует репозиториев: $missing. Запусти ./Tools/bootstrap.sh"
  exit 1
fi

echo "Проверка графа зависимостей:"
python3 "$ROOT/Tools/deplint.py"

# Открывать воркспейс — поведение для человека за машиной. На CI это запуск
# Xcode внутри job'а: он поднимается минуты, ничего полезного не делает и
# держит job до таймаута, после которого тот отменяется. GitHub Actions,
# как и все известные CI, выставляет CI=true — по нему и различаем.
if [[ "$MODE" != "--status" && -z "${CI:-}" ]]; then
  echo
  echo "Открываю воркспейс…"
  open "$ROOT/KufarWorkspace.xcworkspace" 2>/dev/null || \
    echo "  открой вручную: $ROOT/KufarWorkspace.xcworkspace"
fi
