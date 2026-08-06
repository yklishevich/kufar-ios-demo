#!/usr/bin/env bash
#
# Сброс всех семи репозиториев к одному коммиту. Разовая операция.
#
# Зачем. История накопилась черновая: коммиты с именем `u`, промежуточные
# состояния переезда и 393 МБ `node_modules`, попавшие в HEAD до того, как
# появилось правило в .gitignore. Для репозитория, который открывают, чтобы
# посмотреть на архитектуру, история такого качества — шум, мешающий увидеть
# предмет.
#
# Что теряется, названо прямо:
#
#   1. Теги версий (61 штука). По ним восстанавливалась связь «опубликованная
#      в реестре версия → коммит». После сброса связи нет, пока реестр
#      не опубликован заново — см. --registry ниже.
#
#   2. История, перенесённая `git subtree` при переезде в репозитории команд.
#      Она была смыслом того переезда, и теперь её нет. Документы, которые
#      это утверждали, поправлены.
#
# Обратного хода нет: после --push старые коммиты недостижимы и на GitHub.
#
#   ./Tools/reset-all.sh --dry-run     показать, что произойдёт
#   ./Tools/reset-all.sh               выполнить локально
#   ./Tools/reset-all.sh --push        + force-push во все репозитории
#
# Реестр сбрасывается отдельно и вручную — см. хвост вывода.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY=0
PUSH=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --push)    PUSH=1 ;;
        *)         echo "неизвестный флаг: $arg"; exit 2 ;;
    esac
done

# Порядок важен: воркспейс последним. Если что-то пойдёт не так на репозитории
# команды, мета-репозиторий с этим скриптом останется нетронутым.
TEAMS=(platform_team search_team posting_team goods_team auto_team identity_team)

# ── Мусор ───────────────────────────────────────────────────────────────
#
# Удаляется с диска, а не только из индекса: после сброса истории «убрать
# из индекса» бессмысленно — индекса с этими файлами уже не будет.
# node_modules в списке нет: он нужен для работы с реестром, и достаточно
# того, что он теперь в .gitignore.

JUNK=(
    ".migrate"            # промежуточные копии переезда в репозитории команд
    ".attic"              # два вытесненных экрана, лежат вне сборки
    "registry/.wrangler"  # локальный кеш wrangler, пересоздаётся
)

echo
echo "Сброс всех репозиториев к одному коммиту"
echo "════════════════════════════════════════"
echo

echo "Мусор:"
for path in "${JUNK[@]}"; do
    full="$ROOT/$path"
    if [[ -e "$full" ]]; then
        size="$(du -sh "$full" 2>/dev/null | cut -f1)"
        printf "  %-24s %s\n" "$path" "$size"
        [[ $DRY -eq 1 ]] || rm -rf "$full"
    fi
done

# .DS_Store ищем отдельно: их много и лежат вразнобой. -prune на .git нужен,
# чтобы не лезть внутрь служебных каталогов — там своих файлов хватает.
ds_count="$(find "$ROOT" -name .git -prune -o -name .DS_Store -print 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$ds_count" != "0" ]]; then
    printf "  %-24s %s шт.\n" ".DS_Store" "$ds_count"
    [[ $DRY -eq 1 ]] || find "$ROOT" -name .git -prune -o -name .DS_Store -exec rm -f {} + 2>/dev/null || true
fi
echo

# ── Сброс одного репозитория ────────────────────────────────────────────

reset_repo() {
    local dir="$1"
    local name="$2"
    local message="$3"

    [[ -d "$dir/.git" ]] || { printf "  %-16s пропуск: не репозиторий\n" "$name"; return 0; }

    local commits tags size
    commits="$(git -C "$dir" rev-list --count HEAD 2>/dev/null || echo 0)"
    tags="$(git -C "$dir" tag -l | wc -l | tr -d ' ')"
    size="$(du -sh "$dir/.git" 2>/dev/null | cut -f1)"

    if [[ $DRY -eq 1 ]]; then
        printf "  %-16s %s коммитов → 1, %s тегов → 0, .git %s\n" "$name" "$commits" "$tags" "$size"
        return 0
    fi

    # Залипший lock остаётся от прерванного git и блокирует всё дальнейшее.
    # || true намеренно: недоступный файл не должен ронять проход целиком.
    rm -f "$dir/.git/index.lock" || true

    # Ветка могла остаться от прерванного запуска — тогда --orphan откажется
    # её создавать, и скрипт упал бы на репозитории, который сбрасывали дважды.
    git -C "$dir" branch -D _reset >/dev/null 2>&1 || true

    # Осиротевшая ветка: рабочее дерево остаётся на месте, но у коммита
    # не будет родителя. Это и есть «начало» — не откат к первому коммиту,
    # а новый первый коммит с текущим содержимым.
    git -C "$dir" checkout --quiet --orphan _reset
    git -C "$dir" add -A
    git -C "$dir" commit --quiet -m "$message"

    # -M поверх существующей main: перезаписывает её, старая ветка исчезает.
    git -C "$dir" branch -M main

    # Теги удаляются после смены ветки, иначе они удержали бы старые коммиты
    # достижимыми и gc ничего бы не собрал.
    local tag_list
    tag_list="$(git -C "$dir" tag -l)"
    if [[ -n "$tag_list" ]]; then
        # xargs, а не цикл: тегов до тридцати трёх, вызовов git будет один.
        printf '%s\n' "$tag_list" | xargs git -C "$dir" tag -d >/dev/null
    fi

    # Ветки слежения за удалёнными — последние ссылки на старую историю.
    # Пока жива хоть одна, gc обязан сохранить всё, до чего она достаёт,
    # и .git не уменьшится ни на байт.
    #
    # Удаляются ВСЕ, а не `refs/remotes/origin/main`. Первая версия скрипта
    # удаляла именно её — и промахнулась: рядом с origin (HTTPS) жил второй
    # remote с именем ssh, указывающий на тот же репозиторий. Он в одиночку
    # удержал 8235 объектов node_modules, и .git остался 36 МБ вместо двух.
    # Точечное удаление одной известной ссылки ошибочно в принципе: их число
    # и имена — свойство чужой настройки, а не нашего скрипта.
    git -C "$dir" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null \
      | while read -r ref; do git -C "$dir" update-ref -d "$ref" || true; done

    # ORIG_HEAD и FETCH_HEAD — тоже ссылки, и обход достижимости их учитывает.
    rm -f "$dir/.git/ORIG_HEAD" "$dir/.git/FETCH_HEAD" || true

    git -C "$dir" reflog expire --expire=now --all
    git -C "$dir" gc --prune=now --quiet

    local new_size
    new_size="$(du -sh "$dir/.git" 2>/dev/null | cut -f1)"
    printf "  ✓ %-14s 1 коммит, 0 тегов, .git %s → %s\n" "$name" "$size" "$new_size"

    [[ $PUSH -eq 1 ]] || return 0

    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
        printf "    remote не настроен, пуш пропущен\n"
        return 0
    fi

    # Пуш по SSH. Остальные скрипты проекта пишут так же: у владельца есть
    # ключи, а HTTPS-пуш потребовал бы токена в credential helper — GitHub
    # не принимает пароли с 2021 года и вместо отказа задаёт вопрос
    # «Username for github.com», на который в скрипте отвечать некому.
    #
    # На чужие клоны это не влияет: там свой origin, взятый из адреса клона.
    if [[ "${KUFAR_REMOTE_PROTO:-ssh}" != "https" ]]; then
        local url
        url="$(git -C "$dir" remote get-url origin)"
        case "$url" in
            https://github.com/*)
                url="git@github.com:${url#https://github.com/}"
                git -C "$dir" remote set-url origin "$url"
                printf "    origin переведён на SSH: %s\n" "$url"
                ;;
        esac
    fi

    # Теги на удалённой стороне живут своей жизнью: force-push ветки их
    # не трогает. Без явного удаления на GitHub остались бы тридцать тегов,
    # указывающих на коммиты, которых больше нет ни в одной ветке.
    local remote_tags
    remote_tags="$(git -C "$dir" ls-remote --tags origin 2>/dev/null \
                   | awk '{print $2}' | grep -v '\^{}$' || true)"
    if [[ -n "$remote_tags" ]]; then
        # shellcheck disable=SC2086
        git -C "$dir" push --quiet origin $(printf ':%s ' $remote_tags) || true
    fi

    git -C "$dir" push --quiet --force origin main
    printf "    → запушено\n"
}

echo "Репозитории:"
for team in "${TEAMS[@]}"; do
    reset_repo "$ROOT/$team" "kufar-${team%_team}" \
               "kufar-${team%_team}: пакеты команды"
done

reset_repo "$ROOT" "kufar-ios" \
           "Демо модульной архитектуры классифайда"

echo
if [[ $DRY -eq 1 ]]; then
    echo "Это был --dry-run. Убери флаг, чтобы выполнить."
    exit 0
fi

if [[ $PUSH -eq 0 ]]; then
    cat <<'NEXT'
Локально сброшено. Дальше:

  ./Tools/reset-all.sh --push     отправить на GitHub (force)

До пуша старую историю ещё можно достать из бэкапа GitHub — после нельзя.
NEXT
    exit 0
fi

cat <<'NEXT'
Готово. Осталось привести реестр в соответствие: тегов в гите больше нет,
а версии 1.0.0–1.2.0 в реестре есть, и сослаться им теперь не на что.

  1. Очистить таблицу релизов:
       cd registry
       npx wrangler d1 execute spm-registry --remote \
           --command "DELETE FROM releases"

     Архивы в R2 останутся сиротами (~80 МБ). Публикация 1.0.0 перезапишет
     их по тем же ключам; лишними будут только 1.1.0 и 1.2.0, и бесплатный
     тариф R2 (10 ГБ) это переживёт.

  2. Опубликовать всё заново как 1.0.0:
       export REGISTRY_URL=https://spm-registry.byklishevich.com
       export PUBLISH_TOKEN=…
       ./Tools/publish.sh --push --tag

     Тега на HEAD нет ни у одного пакета, поэтому каждый получит 1.0.0.

  3. Поправить требование версии в приложении: в KufarDemo.xcodeproj
     minimumVersion сейчас 1.2.0, такой версии больше не будет.
       Xcode → Package Dependencies → AppComposition → Up to Next Major 1.0.0

  4. Пересобрать и закоммитить Package.resolved — он пинит 1.1.0/1.2.0.

  5. Проверить, что чужой клон собирается:
       ./Tools/check-registry.sh
NEXT
echo
