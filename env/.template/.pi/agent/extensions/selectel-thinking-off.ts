/**
 * selectel-thinking-off — честное выключение reasoning (thinking) для моделей
 * Selectel AI Router (api.selectel.ru/aig) на уровне pi "off".
 *
 * Эмпирика (сентябрь 2026, ~25 проверенных форм параметров):
 *   1. `reasoning:{"enabled":false}` (стиль OpenRouter/Together) — единственный
 *      рабочий способ выключить thinking у 5 моделей: deepseek-v4-flash-0731,
 *      deepseek-v4-pro-0813, z-ai/glm-5.3, qwen3.5-9b, qwen3.8-max-0902
 *      (reasoning_tokens = 0 при HTTP 200).
 *   2. ЛЮБОЙ `reasoning_effort` переопределяет `reasoning.enabled` —
 *      при off обязательно удаляем reasoning_effort из payload.
 *   3. z-ai/glm-5.3-flash: reasoning-объект ломает upstream (детерминированный
 *      400 "Upstream provider rejected"). Fallback: `reasoning_effort:"low"` —
 *      стабильно даёт reasoning_tokens ≈ 0.
 *   4. deepseek/deepseek-v4.1-flash: неотключаем — все параметры приняты (200),
 *      но thinking фиксирован (~60 токенов) и даже effort его не снижает.
 *      Оставляем payload как есть.
 *
 * Уровни minimal..max pi мапит сам (models.json → thinkingLevelMap); этот хук
 * вмешивается ТОЛЬКО на уровне "off".
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Модели, у которых reasoning:{"enabled":false} реально глушит thinking. */
const HONEST_OFF = new Set([
	"deepseek/deepseek-v4-flash-0731",
	"deepseek/deepseek-v4-pro-0813",
	"z-ai/glm-5.3",
	"qwen/qwen3.5-9b",
	"qwen/qwen3.8-max-0902",
]);

/** Модели, у которых reasoning-объект ломает upstream: off → минимум thinking. */
const LOW_EFFORT_FALLBACK = new Set(["z-ai/glm-5.3-flash"]);

export default function (pi: ExtensionAPI) {
	pi.on("before_provider_request", (event, ctx) => {
		const model = ctx.model;
		if (model?.provider !== "selectel") return;
		if (ctx.thinkingLevel !== "off") return;

		const payload = event.payload as Record<string, unknown>;

		if (HONEST_OFF.has(model.id)) {
			// effort переопределяет reasoning.enabled — удаляем, затем глушим.
			delete payload.reasoning_effort;
			payload.reasoning = { enabled: false };
			return payload;
		}

		if (LOW_EFFORT_FALLBACK.has(model.id)) {
			// Объект reasoning у этой модели ломает upstream (400) — не шлём его.
			delete payload.reasoning;
			payload.reasoning_effort = "low";
			return payload;
		}

		// deepseek-v4.1-flash и неизвестные модели: не вмешиваемся.
		// (возврат undefined сохраняет payload без изменений)
	});
}
