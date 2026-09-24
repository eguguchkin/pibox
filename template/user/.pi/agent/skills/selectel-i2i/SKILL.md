---
name: selectel-i2i
description: Редактирование изображения по референсу (image-to-image) через Selectel AIG на моделях поддерживающих генерацию изображений. Загружать, когда нужно изменить/перерисовать существующую картинку, добавить/удалить деталь, поменять цвет или стиль с сохранением остального. Не для генерации с нуля (для этого pi-image-gen) и не для показа картинок (для этого show-image).
---

# Selectel i2i: редактирование картинки по референсу

## Суть (проверено экспериментально, 2026-09)

Selectel AIG (`https://api.selectel.ru/aig/v1`, OpenAI-совместимый шлюз) поддерживает
image-to-image **только одним способом** — `POST /v1/images/generations` с массивом
`input_references`. Способы из других провайдеров НЕ работают:

| Способ | Endpoint | Статус на Selectel |
|---|---|---|
| `input_references` (OpenRouter-стиль) | `POST /v1/images/generations`, JSON | ✅ **работает** |
| поле `image` (data-URL) | `POST /v1/images/generations`, JSON | ⚠️ принимает, но игнорирует преферанс — сцена перегенерируется целиком |
| OpenAI-канонический | `POST /v1/images/edits`, multipart | ❌ 404 Unknown route |
| чат-стиль (image_url в сообщении) | `POST /v1/chat/completions` | ❌ 422 capability_unsupported |

Контракт `input_references` совпадает с OpenRouter Image API — вероятно, общий роутер.
Ключ: `SELECTEL_AIG_KEY` (лежит в `~/.pi/agent/pi-image-gen/settings.json` →
`customProviders.selectel.apiKey`; не выводить в лог).

## Быстрый путь — готовый скрипт

```bash
~/.pi/agent/skills/selectel-i2i/scripts/selectel-i2i.sh ref.png \
  "change the apple color from red to green, keep everything else exactly the same" \
  out.png
# 4-й аргумент — модель (по умолчанию qwen/qwen-image-3):
~/.pi/agent/skills/selectel-i2i/scripts/selectel-i2i.sh ref.png "..." out.png qwen/qwen-image-3-pro
```

Скрипт читает ключ из `SELECTEL_AIG_KEY`, сам кодирует картинку в data-URL,
отправляет запрос, разбирает ответ и пишет PNG. Печатает путь к результату.

## Своими руками (curl)

```bash
python3 - <<'PY' > /tmp/i2i_req.json
import base64, json
b64 = base64.b64encode(open('ref.png','rb').read()).decode()
json.dump({
    'model': 'qwen/qwen-image-3',
    'prompt': 'change the apple color from red to green, keep everything else exactly the same',
    'input_references': [{'type': 'image_url',
                          'image_url': {'url': 'data:image/png;base64,' + b64}}],
}, open('/tmp/i2i_req.json','w'))
PY

curl -s -X POST https://api.selectel.ru/aig/v1/images/generations \
  -H "Authorization: Bearer $SELECTEL_AIG_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/i2i_req.json | jq -r '.data[0].b64_json' | base64 -d > out.png
```

## Формат запроса

```jsonc
{
  "model": "qwen/qwen-image-3",            // или qwen/qwen-image-3-pro
  "prompt": "инструкция по-английски",      // обязателен, даже с input_references
  "input_references": [                     // 1–3 картинки
    { "type": "image_url",
      "image_url": { "url": "data:image/png;base64,..." } }  // data-URL или http(s) URL
  ],
  "size": "1024x1024"                       // опционально; без него выход ~2048×2048
}
```

Ответ: `data[0].b64_json` + `data[0].media_type` (как у OpenAI/OpenRouter Image API).

## Практика

- **Промпт — императивная инструкция**: «change X to Y, keep everything else exactly
  the same». Формулировка «edit this image…» работает хуже.
- **Критерий качества i2i** — изменилась ли только указанная деталь. Проверять
  сравнением референса и результата через pi-multimodal-proxy (`analyze_image`
  с 2 картинками и вопросом), НЕ загружая картинки в свой контекст.
- **Мульти-референс** — несколько `input_references` для fusion (это тоже работает,
  формат тот же); в промпте ссылаться на «Image 1 / Image 2».
- **Уточнение детали** лучше делать цепочкой правок (edit → edit), а не одним
  сложным промптом.
- pi-image-gen i2i **не умеет** (его settings.json не трогать ради этого); при
  желании добавить туда i2i — провайдеру selectel нужен тип `input_references`,
  а не `/images/edits`.

## Как проверять результат (пример реального теста)

Референс: красное яблоко на белом столе. Промпт как выше. Сравнение
`analyze_image([ref, result])` с вопросом: стал ли фрукт зелёным; сохранились ли
композиция/фон/ракурс/тень; какие отличия кроме цвета. На `input_references`
qwen-image-3 сохраняет сцену (мелкие артефакты стебля/силуэта — норма); на поле
`image` — полностью перегенерирует фон и стол, т.е. тест провален.
