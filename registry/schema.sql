-- Схема реестра. Одна таблица релизов плюс таблица соответствия
-- «гит-URL → идентификатор», которую требует эндпоинт /identifiers.

CREATE TABLE IF NOT EXISTS releases (
    -- scope и name раздельно, потому что маршрут спецификации — /{scope}/{name},
    -- и склеенный "kufar.Toolbox" пришлось бы разбирать на каждом запросе.
    scope           TEXT NOT NULL,
    name            TEXT NOT NULL,
    version         TEXT NOT NULL,

    -- Отдельные числовые колонки, потому что semver не сортируется как строка:
    -- '1.10.0' < '1.9.0' лексикографически. Список релизов и выбор latest
    -- сортируются по ним, а не по version.
    major           INTEGER NOT NULL,
    minor           INTEGER NOT NULL,
    patch           INTEGER NOT NULL,
    prerelease      TEXT,

    -- sha256 архива в hex. Именно это значение SwiftPM сверяет после скачивания,
    -- поэтому оно хранится рядом с релизом, а не считается на лету.
    checksum        TEXT NOT NULL,
    archive_size    INTEGER NOT NULL,

    -- Ключ объекта в R2. Хранится явно, чтобы схема именования архивов
    -- могла поменяться, не ломая уже опубликованные версии.
    archive_key     TEXT NOT NULL,

    -- Манифест целиком. Мал, запрашивается при каждом резолве —
    -- дешевле держать здесь, чем ходить в R2.
    manifest        TEXT NOT NULL,

    -- Манифесты под конкретные версии Swift: {"5.9": "...", "6.0": "..."}.
    -- Пусто у большинства пакетов, поэтому отдельной таблицы не завожу.
    manifests_json  TEXT NOT NULL DEFAULT '{}',

    repository_url  TEXT,
    published_at    TEXT NOT NULL,

    PRIMARY KEY (scope, name, version)
);

-- Список релизов пакета — самый частый запрос, и он идёт с сортировкой.
CREATE INDEX IF NOT EXISTS idx_releases_package
    ON releases (scope, name, major DESC, minor DESC, patch DESC);

-- Обратный поиск: по гит-URL вернуть идентификаторы реестра.
-- Нужен флагам --use-registry-identity-for-scm и --replace-scm-with-registry:
-- по ним SwiftPM схлопывает пакет, подключённый и по URL, и через реестр,
-- в один узел графа вместо двух одинаковых.
CREATE TABLE IF NOT EXISTS scm_identifiers (
    url        TEXT NOT NULL,
    scope      TEXT NOT NULL,
    name       TEXT NOT NULL,
    PRIMARY KEY (url, scope, name)
);

CREATE INDEX IF NOT EXISTS idx_scm_url ON scm_identifiers (url);
