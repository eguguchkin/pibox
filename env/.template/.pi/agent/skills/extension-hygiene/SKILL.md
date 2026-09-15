---
name: extension-hygiene
description: Гигиена расширений pi в ~/.pi/agent/npm — поиск и чистка мёртвых платформенных дублей (musl, чужая архитектура) и npm-кэша. Загружать проактивно после любой установки пакетов (pi install, npm install в ~/.pi/agent/npm), а также по просьбам «почисти дубли/кэш/освободи место» и при ошибках расширений вида «Cannot find module».
---

# Гигиена расширений

Расширения pi живут в `~/.pi/agent/npm/node_modules` — это персистентный home,
мусор здесь не вычищается пересозданием контейнера. npm ставит **все**
платформенные варианты optionalDependencies и не фильтрует по libc, поэтому
копятся мёртвые копии (до сотен МБ): musl-дубли на glibc, бинарники чужой
архитектуры, x64-артефакты внутри основных пакетов при наличии платформенных.

## Проактивный режим

После **любого** `pi install ...` или `npm install` в `~/.pi/agent/npm`:

1. Прогони «Обследование» (ниже) и сообщи одной строкой: «найдено мусора на
   N МБ — почистить?» Не удаляй без подтверждения.
2. Если в выводе установки было `removed N packages` — npm отреваншил дерево
   по package.json/lock и мог вычистить вручную поставленные peer-зависимости
   (реальный случай: пропал `apache-arrow`, сломался pi-mem). Проверь, что
   критичные пакеты живы (импорт из node_modules), при потере ставь явной
   зависимостью: `npm install <pkg>` в `~/.pi/agent/npm` — тогда реванш
   больше не вычистит.

## Шаг 1. Обследование (ничего не удалять)

```bash
ARCH=$(uname -m); ldd --version 2>/dev/null | grep -qi musl && LIBC=musl || LIBC=gnu
echo "рабочая платформа: linux-$ARCH-$LIBC"

cd ~/.pi/agent/npm/node_modules
# все платформенные пакеты — рабочие и лишние (лишние: не linux-$ARCH-$LIBC)
find . -maxdepth 4 -type d \( -name '*-linux-*' -o -name '*-darwin*' -o -name '*-win32*' \) |
  while read -r d; do printf "%s\t%s\n" "$(du -sh "$d" | cut -f1)" "$d"; done

# .node-файлы не той архитектуры
find . -name '*.node' -type f | while read -r f; do
  printf "%s\t%s\t%s\n" "$(du -h "$f" | cut -f1)" "$f" \
    "$(file -b "$f" | grep -o 'x86-64\|aarch64\|ARM aarch64' | head -1)"
done

# npm-кэш (безопасно чистить всегда — регенерируемый)
du -sh ~/.npm/_cacache
```

## Шаг 2. Правила удаления

- Удалять платформенный пакет-дубль **только** если есть рабочий твин:
  `*-gnu` при glibc, `*-musl` при musl, архитектура совпадает с `uname -m`.
- `.node`/`.so` чужой архитектуры: перед удалением убедись, что рядом есть
  платформенный пакет с рабочим вариантом (`<имя>-linux-<arch>-gnu`) и что код
  дистрибутива не ссылается на файл: `grep -r "<имяфайла>" <пакет>/dist/`.
- Запрещено: удалять рабочий вариант, весь пакет целиком, что-либо вне
  `~/.pi/agent/npm/node_modules` и `~/.npm/_cacache`. workspace не трогать
  (см. workspace-hygiene).
- Помни: чистка временная — следующий `npm install` вернёт дубли (optionalDeps
  не фильтруются по libc). Сообщай об этом пользователю.

## Шаг 3. Чистка

```bash
cd ~/.pi/agent/npm/node_modules
rm -rf <мусорные платформенные пакеты>          # каждый — после проверки твина
rm <мусорные .node/.so файлы>                   # каждый — после проверки ссылок
npm cache clean --force                         # ~/.npm/_cacache
```

## Шаг 4. Верификация (обязательно после удаления)

```bash
cd ~/.pi/agent/npm && node -e "
(async () => {
  const t = async (n, f) => { try { await f(); console.log('OK ' + n); }
    catch (e) { console.log('FAIL ' + n + ': ' + e.message.slice(0, 80)); } };
  await t('lancedb', async () => (await import('@lancedb/lancedb')).connect('~/.pi-mem/lancedb'));
  await t('better-sqlite3', () => import('better-sqlite3'));
  await t('apache-arrow', () => import('apache-arrow'));
  await t('liteparse', () => import('@llamaindex/liteparse'));
})()"
~/.pi/agent/npm/node_modules/@ast-grep/cli-linux-arm64-gnu/sg --version
```

Если что-то FAIL — восстанови пакет: `cd ~/.pi/agent/npm && npm install`.
Для чужих расширений добавь в список проверки их нативные зависимости.

## Известные случаи (справочник)

- `@lancedb/lancedb-linux-arm64-musl` — 129M дубль на arm64-glibc.
- `@napi-rs/keyring-linux-arm64-musl` — 3.1M дубль.
- `@llamaindex/liteparse`: в основном пакете лежат x64 `*.node` и
  `libpdfium.so` (езут всем по `files` в package.json); работает через
  платформенный пакет `@llamaindex/liteparse-linux-<arch>-gnu` со своими
  копиями. X64-файлы в основном пакете на arm64 — балласт.
- Peer-зависимости (`apache-arrow` для lancedb, `typebox` и др.) — уязвимы к
  реваншу npm; держать явными зависимостями в `~/.pi/agent/npm/package.json`.

## Если расширение сломалось

Ошибка тула вида «Cannot find module» / «not enabled» при живом расширении →
проверь наличие пакета в `node_modules` и его peer-зависимости. Пропавших
peer'ов ставить `npm install <pkg>` в `~/.pi/agent/npm` (явной зависимостью).
