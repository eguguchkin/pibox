/**
 * auto-commit — автоматический коммит после каждой завершённой итерации агента.
 *
 * Триггер — `agent_settled`: событие «прогон агента закончился и pi больше
 * НИЧЕГО не будет продолжать сам» (в отличие от `agent_end`, после которого
 * возможны авто-ретрай, авто-компакт и продолжение очереди). Точка соответствует
 * сценарию «от вопроса пользователя до финального ответа».
 *
 * Алгоритм:
 *   1. Конфиг включён? (по умолчанию ВЫКЛЮЧЕНО)
 *   2. Рабочая папка — git-репозиторий? (нет → уведомление один раз за сессию)
 *   3. Есть незакомиченные изменения? Нет → выходим.
 *   4. Идёт merge/rebase/cherry-pick? → пропускаем (не лезем в чужую операцию).
 *   5. Собираем: запрос пользователя + финальный ответ агента (из сессии) +
 *      `git diff HEAD` + `git status --porcelain`.
 *   6. Тема коммита — через ТЕКУЩУЮ модель сессии
 *      (`ctx.modelRegistry.streamSimple(ctx.model, …)`, ограничение maxTokens),
 *      на вход: запрос + ответ + обрезанный дифф. При ошибке/таймауте —
 *      fallback-тема `chore: …` (коммит не отменяется).
 *   7. `git add -A` (уважает .gitignore) с настраиваемыми исключениями
 *      (pathspec `:(exclude)…`).
 *   8. `git commit -F <tmpfile>`: тема + запрос + ответ + список файлов.
 *
 * Отказобезопасность: работа ведётся в фоне (handler не блокирует ввод); весь
 * контекст захватывается СИНХРОННО в момент события (после teardown сессии ctx
 * становится «stale» и любое обращение бросает). Перед каждой мутирующей
 * git-операцией перепроверяется «не начал ли агент снова работать» (stale ctx
 * после teardown трактуем как «свободно») — если пользователь уже отправил новый
 * запрос, коммит молча откладывается (изменения подхватит следующая итерация).
 * Ошибки — уведомление + строка в лог `~/.pi/agent/auto-commit.log`.
 *
 * Конфиг (merge: глобальный → пер-проектный):
 *   глобальный:   ~/.pi/agent/auto-commit.json  (в pibox — файл слоя user;
 *                 правки через /autocommit живут до перезапуска окружения,
 *                 для постоянного включения — `pibox user pull`)
 *   пер-проект:   <cwd>/.pi/auto-commit.json
 * {
 *   "enabled": false,          // выключено по умолчанию
 *   "maxDiffChars": 10000,     // обрезка диффа для промпта модели
 *   "maxMessageChars": 2000,   // обрезка запроса/ответа в теме и теле коммита
 *   "exclude": [],             // pathspec-исключения для git add, напр. "dist"
 *   "notifyOnNonRepo": true,   // уведомить, если папка — не git-репозиторий
 *   "titleTimeoutMs": 300000   // таймаут запроса темы к модели
 * }
 *
 * Команда /autocommit [on|off|status] — статус и переключение.
 */

import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
	CONFIG_DIR_NAME,
	getAgentDir,
	type AgentSettledEvent,
	type ExtensionAPI,
	type ExtensionContext,
} from "@earendil-works/pi-coding-agent";

// ===========================================================================
// Конфиг
// ===========================================================================

interface AutoCommitConfig {
	enabled: boolean;
	maxDiffChars: number;
	maxMessageChars: number;
	exclude: string[];
	notifyOnNonRepo: boolean;
	titleTimeoutMs: number;
}

const DEFAULTS: AutoCommitConfig = {
	enabled: false,
	maxDiffChars: 10_000,
	maxMessageChars: 2_000,
	exclude: [],
	notifyOnNonRepo: true,
	titleTimeoutMs: 300_000,
};

/** Глобальный конфиг: ~/.pi/agent/auto-commit.json (в pibox — слой user). */
function globalConfigPath(): string {
	return path.join(getAgentDir(), "auto-commit.json");
}

/** Пер-проектный override: <cwd>/.pi/auto-commit.json. */
function projectConfigPath(cwd: string): string {
	return path.join(cwd, CONFIG_DIR_NAME, "auto-commit.json");
}

function readJson(file: string): Record<string, unknown> | null {
	try {
		const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
		return parsed && typeof parsed === "object" && !Array.isArray(parsed)
			? (parsed as Record<string, unknown>)
			: null;
	} catch {
		return null;
	}
}

/** Числовое поле с проверкой типа и разумных границ. */
function num(
	src: Record<string, unknown>,
	key: string,
	dflt: number,
	min: number,
): number {
	const v = src[key];
	return typeof v === "number" && Number.isFinite(v) && v >= min ? v : dflt;
}

function loadConfig(cwd: string): AutoCommitConfig {
	const cfg: AutoCommitConfig = { ...DEFAULTS };
	for (const src of [readJson(globalConfigPath()), readJson(projectConfigPath(cwd))]) {
		if (!src) continue;
		if (typeof src.enabled === "boolean") cfg.enabled = src.enabled;
		if (typeof src.notifyOnNonRepo === "boolean") cfg.notifyOnNonRepo = src.notifyOnNonRepo;
		cfg.maxDiffChars = num(src, "maxDiffChars", cfg.maxDiffChars, 500);
		cfg.maxMessageChars = num(src, "maxMessageChars", cfg.maxMessageChars, 200);
		cfg.titleTimeoutMs = num(src, "titleTimeoutMs", cfg.titleTimeoutMs, 10_000);
		if (Array.isArray(src.exclude)) {
			cfg.exclude = src.exclude.filter((e): e is string => typeof e === "string" && e.length > 0);
		}
	}
	return cfg;
}

function writeGlobalConfig(patch: Partial<AutoCommitConfig>): void {
	const file = globalConfigPath();
	const merged = { ...DEFAULTS, ...readJson(file), ...patch };
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, `${JSON.stringify(merged, null, "\t")}\n`);
}

// ===========================================================================
// Git
// ===========================================================================

interface GitResult {
	ok: boolean;
	out: string;
	err: string;
}

function git(cwd: string, args: string[]): GitResult {
	const r = spawnSync("git", args, {
		cwd,
		encoding: "utf8",
		maxBuffer: 64 * 1024 * 1024,
	});
	return {
		ok: r.status === 0,
		out: (r.stdout ?? "").trim(),
		err: (r.stderr ?? "").trim(),
	};
}

/** Идёт ли прерывающая операция git (merge/rebase/cherry-pick/am). */
function gitOperationInProgress(cwd: string): boolean {
	const d = git(cwd, ["rev-parse", "--absolute-git-dir"]);
	if (!d.ok) return true; // не смогли определить — воздержимся
	const gitDir = d.out;
	for (const marker of ["MERGE_HEAD", "CHERRY_PICK_HEAD", "rebase-merge", "rebase-apply"]) {
		if (fs.existsSync(path.join(gitDir, marker))) return true;
	}
	return false;
}

// ===========================================================================
// Извлечение текста из сессии
// ===========================================================================

interface LooseMessage {
	role?: string;
	stopReason?: string;
	content?: unknown;
}

interface LooseEntry {
	type?: string;
	message?: LooseMessage;
}

interface LooseTextBlock {
	type?: string;
	text?: string;
}

function contentToText(content: unknown): string {
	if (typeof content === "string") return content;
	if (Array.isArray(content)) {
		return content
			.filter(
				(b): b is LooseTextBlock =>
					!!b &&
					typeof b === "object" &&
					(b as LooseTextBlock).type === "text" &&
					typeof (b as LooseTextBlock).text === "string",
			)
			.map((b) => b.text)
			.join("\n");
	}
	return "";
}

/** Последний запрос пользователя и финальный ответ агента текущей ветки. */
function lastTurnTexts(ctx: ExtensionContext): { user: string; assistant: string } {
	let user: string | null = null;
	let assistant: string | null = null;
	try {
		// SAFETY: getBranch() возвращает типизированные SessionEntry, но поле
		// message может быть любой роли/формы (system/custom/compaction) — читаем
		// структурно и толерантно к неизвестным шейпам, поэтому приводим к LooseEntry.
		const branch = ctx.sessionManager.getBranch() as unknown as LooseEntry[];
		for (let i = branch.length - 1; i >= 0 && (user === null || assistant === null); i--) {
			const m = branch[i]?.message;
			if (!m || branch[i]?.type !== "message") continue;
			if (m.role === "user" && user === null) {
				user = contentToText(m.content).trim();
			} else if (m.role === "assistant" && m.stopReason === "stop" && assistant === null) {
				assistant = contentToText(m.content).trim();
			}
		}
	} catch {
		// нет доступа к сессии — коммитим с пустыми полями текста
	}
	return { user: user ?? "", assistant: assistant ?? "" };
}

// ===========================================================================
// Формирование темы и тела коммита
// ===========================================================================

function truncate(text: string, limit: number): string {
	if (text.length <= limit) return text;
	return `${text.slice(0, limit)}\n[… обрезано, было ${text.length} симв.]`;
}

/** Тема от модели: одна строка, без markdown-обёртки, ≤72 символов. */
function sanitizeSubject(raw: string): string {
	let line = "";
	for (const l of raw.split("\n")) {
		const t = l.trim();
		if (t.length > 0) {
			line = t;
			break;
		}
	}
	line = line.replace(/[`"']/g, "").replace(/^-+\s*/, "").replace(/\s+/g, " ").trim();
	if (line.endsWith(".")) line = line.slice(0, -1);
	return line.slice(0, 72);
}

function fallbackSubject(userText: string): string {
	const head = userText.replace(/\s+/g, " ").trim().slice(0, 48);
	return `chore: auto-commit after "${head || "agent iteration"}"`;
}

const SUBJECT_PROMPT_HEADER =
	"Ты — генератор темы git-коммита. Верни РОВНО ОДНУ строку: тему коммита " +
	"(Conventional Commits: type из feat|fix|docs|refactor|test|chore|build|ci|perf|style, " +
	"кратко и по существу, до 72 символов, без кавычек, без точки в конце, без markdown). " +
	"Пиши на языке запроса пользователя. Никаких пояснений — только строка темы.\n\n";

function buildSubjectPrompt(
	userText: string,
	assistantText: string,
	diff: string,
	maxMessageChars: number,
): string {
	const parts = [SUBJECT_PROMPT_HEADER, "## Запрос пользователя\n", truncate(userText || "(пусто)", maxMessageChars)];
	parts.push("\n\n## Финальный ответ агента\n", truncate(assistantText || "(пусто)", maxMessageChars));
	parts.push("\n\n## Изменения (git diff HEAD + список файлов, может быть обрезан)\n", diff);
	return parts.join("");
}

function buildCommitBody(
	subject: string,
	userText: string,
	assistantText: string,
	statusLines: string[],
	maxMessageChars: number,
): string {
	const files = statusLines.slice(0, 60).join("\n");
	const filesNote = statusLines.length > 60 ? `\n[… и ещё ${statusLines.length - 60}]` : "";
	return [
		subject,
		"",
		"User request:",
		truncate(userText || "(пусто)", maxMessageChars),
		"",
		"Agent answer:",
		truncate(assistantText || "(пусто)", maxMessageChars),
		"",
		"Changed files:",
		files + filesNote,
		"",
	].join("\n");
}

// ===========================================================================
// Лог
// ===========================================================================

function log(file: string, line: string): void {
	try {
		fs.appendFileSync(file, `${new Date().toISOString()} ${line}\n`);
	} catch {
		// лог не критичен
	}
}

// ===========================================================================
// Ядро: авто-коммит одной итерации (выполняется в фоне)
// ===========================================================================

/**
 * Снимок контекста итерации, захваченный СИНХРОННО в момент agent_settled.
 * После завершения прогона ctx может стать «stale» (teardown сессии, print-режим)
 * и любое обращение к нему бросает — поэтому в фоне используем только этот снимок.
 */
interface CapturedTurn {
	cwd: string;
	model: ExtensionContext["model"];
	registry: ExtensionContext["modelRegistry"];
	texts: { user: string; assistant: string };
	/** Уведомление пользователю: после teardown ctx — тихий no-op. */
	notify: (msg: string, level?: "info" | "warning" | "error") => void;
	/**
	 * Проверка «агент снова работает?». Если ctx уже stale (сессия закрыта,
	 * print-режим) — гонки нет, считаем «свободно».
	 */
	isIdleSafe: () => boolean;
}

async function requestSubject(
	turn: CapturedTurn,
	prompt: string,
	timeoutMs: number,
): Promise<string | null> {
	const { model, registry } = turn;
	if (!model) return null;
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), timeoutMs);
	try {
		// maxTokens с запасом: у reasoning-моделей часть бюджета уходит на thinking.
		const stream = registry.streamSimple(
			model,
			{ messages: [{ role: "user", content: prompt, timestamp: Date.now() }] },
			{ maxTokens: 256, temperature: 0.2, reasoning: "minimal", signal: controller.signal },
		);
		const msg = await stream.result();
		// stopReason не фильтруем: при length-thinking уже есть полезный текст;
		// важен только непустой результат.
		const text = contentToText(msg.content).trim();
		return text.length > 0 ? sanitizeSubject(text) : null;
	} catch {
		return null; // любая ошибка модели → fallback-тема
	} finally {
		clearTimeout(timer);
	}
}

async function runAutoCommit(turn: CapturedTurn, cfg: AutoCommitConfig): Promise<void> {
	const cwd = turn.cwd;
	const logFile = path.join(getAgentDir(), "auto-commit.log");
	const notify = turn.notify;

	// Тексты итерации уже захвачены синхронно при agent_settled (turn.texts).
	const { user: userText, assistant: assistantText } = turn.texts;

	// 1. Это git-репозиторий?
	if (!git(cwd, ["rev-parse", "--is-inside-work-tree"]).ok) {
		if (cfg.notifyOnNonRepo && !nonRepoNotified) {
			nonRepoNotified = true;
			notify(`${cwd} — не git-репозиторий, авто-коммит недоступен`, "warning");
		}
		return;
	}

	// 2. Есть ли незакомиченные изменения?
	const status = git(cwd, ["status", "--porcelain"]);
	if (!status.ok) {
		log(logFile, `ERROR git status failed: ${status.err}`);
		notify(`git status не удался: ${status.err}`, "error");
		return;
	}
	const statusLines = status.out.split("\n").filter((l) => l.length > 0);
	if (statusLines.length === 0) return; // чисто — коммитить нечего

	// 3. Не идёт ли merge/rebase/cherry-pick?
	if (gitOperationInProgress(cwd)) {
		log(logFile, `SKIP git operation in progress in ${cwd}`);
		notify("пропущено: в репозитории идёт merge/rebase/cherry-pick", "warning");
		return;
	}

	// 4. Дифф (для unborn HEAD — только рабочий каталог).
	const hasHead = git(cwd, ["rev-parse", "--verify", "HEAD"]).ok;
	const diffRange = hasHead ? ["diff", "HEAD"] : ["diff"];
	const diffResult = git(cwd, diffRange);
	const diffStat = git(cwd, [...diffRange, "--stat"]).out;
	const diffRaw = diffStat
		? `${diffStat}\n\n${diffResult.out || "(изменения только в новых/непроиндексированных файлах)"}`
		: "(трекаемых изменений нет — только новые файлы)";
	const diff = `${truncate(diffRaw, cfg.maxDiffChars)}\n\nUntracked/changed (porcelain):\n${status.out}`;

	// 5. Тема — текущая модель сессии; при ошибке fallback.
	const subject =
		(await requestSubject(
			turn,
			buildSubjectPrompt(userText, assistantText, diff, cfg.maxMessageChars),
			cfg.titleTimeoutMs,
		)) ?? fallbackSubject(userText);

	// 6. Перед мутирующими операциями — агент не должен снова работать
	// (stale ctx после teardown сессии трактуем как «свободно»).
	if (!turn.isIdleSafe()) {
		log(logFile, `SKIP user started a new run before commit in ${cwd}`);
		return;
	}

	// 7. Стейджинг: git add -A с исключениями (pathspec-магия).
	const addArgs = ["add", "-A", "--", ".", ...cfg.exclude.map((e) => `:(exclude)${e}`)];
	const addResult = git(cwd, addArgs);
	if (!addResult.ok) {
		log(logFile, `ERROR git add failed: ${addResult.err}`);
		notify(`git add не удался: ${addResult.err}`, "error");
		return;
	}

	// 8. Коммит: тема + запрос + ответ + список файлов.
	const msgFile = path.join(os.tmpdir(), `auto-commit-msg-${process.pid}.txt`);
	fs.writeFileSync(
		msgFile,
		buildCommitBody(subject, userText, assistantText, statusLines, cfg.maxMessageChars),
	);
	const commit = git(cwd, ["commit", "-F", msgFile]);
	fs.rmSync(msgFile, { force: true });
	if (!commit.ok) {
		log(logFile, `ERROR git commit failed: ${commit.err}`);
		notify(`git commit не удался: ${commit.err}`, "error");
		return;
	}

	const hash = git(cwd, ["rev-parse", "--short", "HEAD"]).out;
	log(logFile, `COMMIT ${hash} ${subject} (${cwd})`);
	notify(`${hash} ${subject}`);
}

// ===========================================================================
// Расширение
// ===========================================================================

let busy = false; // защита от параллельных авто-коммитов
let nonRepoNotified = false; // уведомление «не репо» — один раз за сессию

export default function autoCommitExtension(pi: ExtensionAPI) {
	pi.on("session_start", () => {
		nonRepoNotified = false;
	});

	pi.on("agent_settled", async (_event: AgentSettledEvent, ctx: ExtensionContext) => {
		const cfg = loadConfig(ctx.cwd);
		if (!cfg.enabled || busy) return;
		if (!ctx.isIdle()) return; // что-то уже продолжается — не наш случай

		// Захватываем ВСЁ нужное синхронно: после teardown сессии ctx становится
		// «stale» (любое обращение бросает) — фон работает только со снимком.
		const turn: CapturedTurn = {
			cwd: ctx.cwd,
			model: ctx.model,
			registry: ctx.modelRegistry,
			texts: lastTurnTexts(ctx),
			notify: (msg, level = "info") => {
				try {
					ctx.ui.notify(`auto-commit: ${msg}`, level);
				} catch {
					// ctx stale (print-режим/teardown) — уведомить некому, не падаем
				}
			},
			isIdleSafe: () => {
				try {
					return ctx.isIdle();
				} catch {
					return true; // сессия закрыта — гонки с новым прогоном нет
				}
			},
		};

		busy = true;
		// ВАЖНО: не awaited — длинный запрос темы (например, холодная локальная
		// модель) не должен задерживать возврат ввода пользователю.
		void runAutoCommit(turn, cfg).finally(() => {
			busy = false;
		});
	});

	pi.registerCommand("autocommit", {
		description:
			"auto-commit: статус и переключение — /autocommit [on|off|status]",
		handler: async (args: string, ctx: ExtensionContext) => {
			const sub = args.trim().toLowerCase();
			const cfg = loadConfig(ctx.cwd);
			const globalPath = globalConfigPath();
			const projectPath = projectConfigPath(ctx.cwd);

			if (sub === "on" || sub === "off") {
				writeGlobalConfig({ enabled: sub === "on" });
				ctx.ui.notify(
					`auto-commit ${sub === "on" ? "ВКЛЮЧЁН" : "выключен"} → ${globalPath}\n` +
						`правка живёт до перезапуска окружения; сохранить постоянно: pibox user pull ${path.relative(os.homedir(), globalPath)}`,
					"info",
				);
				return;
			}

			const state = cfg.enabled ? "ВКЛЮЧЁН" : "выключен (default)";
			const src = fs.existsSync(projectPath)
				? `источник: ${projectPath} (пер-проектный override)`
				: `источник: ${globalPath}`;
			ctx.ui.notify(
				`auto-commit ${state}; ${src}\n` +
					`включить: /autocommit on — выключить: /autocommit off\n` +
					`конфиг: enabled, maxDiffChars, maxMessageChars, exclude[], notifyOnNonRepo, titleTimeoutMs`,
				"info",
			);
		},
	});
}
