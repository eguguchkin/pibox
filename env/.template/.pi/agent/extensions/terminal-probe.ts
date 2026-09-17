/**
 * terminal-probe — «глаза» агента для визуального вывода консольных программ.
 *
 * Проблема: при pipe-запуске (`cmd | cat`) приложение видит «не-TTY» stdout и
 * отключает прогресс-бары, цвета и перерисовки; агент получает сырые
 * escape-последовательности, из которых не видно, что реально увидел
 * пользователь.
 *
 * Решение: команда запускается под настоящим псевдо-терминалом (утилита
 * `script`), поток пишется с таймингами, эмулятор терминала превращает его в
 * сетку символов «экрана», и на диск складываются ТЕКСТОВЫЕ СНИМКИ — по файлу
 * на кадр:
 *
 *   <session>/meta.json              — команда, размер экрана, список кадров
 *   <session>/frames/0001_0.42s.txt  — снимок: сетка символов, цвет —
 *                                      ANSI SGR-кодами; шапка с '#'
 *   (кадр без изменений относительно предыдущего — файл-маркер:
 *    «SAME AS PREVIOUS», место экономится, таймкод сохранён в имени)
 *
 * Ассертов в туле НЕТ: это чистый «глаз» — анализ снимков агент делает сам.
 *
 * Использование:
 *   как CLI:     node --experimental-strip-types terminal-probe.ts run -- <cmd...>
 *                node --experimental-strip-types terminal-probe.ts list <session>
 *   как pi-расширение: инструмент `terminal_probe`
 *     { action: "run",  cmd, cols?, rows?, outDir? } → запуск + сводка
 *     { action: "list", session }                    → список кадров
 *     { action: "read", session, frame }             → содержимое снимка
 */

import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as crypto from "node:crypto";
import { pathToFileURL } from "node:url";

// ===========================================================================
// Эмулятор терминала: сетка rows x cols, у каждой ячейки символ + SGR-стиль
// ===========================================================================

type Cell = { ch: string; sgr: string };

const BLANK: Cell = { ch: " ", sgr: "" };

class Term {
  rows: number;
  cols: number;
  grid: Cell[][];
  savedGrid: Cell[][] | null = null; // основной экран при alt-screen
  r = 0;
  c = 0;
  sgr = ""; // текущий SGR, напр. "1;32"
  cursorHidden = false;
  altScreen = false;

  constructor(rows: number, cols: number) {
    this.rows = rows;
    this.cols = cols;
    this.grid = Term.blankGrid(rows, cols);
  }

  static blankGrid(rows: number, cols: number): Cell[][] {
    return Array.from({ length: rows }, () =>
      Array.from({ length: cols }, () => ({ ch: " ", sgr: "" })),
    );
  }

  feed(s: string) {
    let i = 0;
    const n = s.length;
    while (i < n) {
      const ch = s[i];
      if (ch === "\x1b") {
        i = this.escape(s, i);
        continue;
      }
      if (ch === "\r") {
        this.c = 0;
      } else if (ch === "\n") {
        this.lineFeed();
      } else if (ch === "\b") {
        if (this.c > 0) this.c--;
      } else if (ch === "\t") {
        this.c = Math.min(this.cols - 1, (Math.floor(this.c / 8) + 1) * 8);
      } else if (ch === "\x07") {
        // BEL — ничего
      } else if (ch >= " ") {
        this.putChar(ch);
      }
      i++;
    }
  }

  lineFeed() {
    if (this.r === this.rows - 1) this.scrollUp();
    else this.r = Math.min(this.rows - 1, this.r + 1);
  }

  scrollUp() {
    this.grid.shift();
    this.grid.push(Array.from({ length: this.cols }, () => ({ ...BLANK })));
  }

  putChar(ch: string) {
    if (this.c >= this.cols) {
      this.c = 0;
      this.lineFeed();
    }
    this.grid[this.r][this.c] = { ch, sgr: this.sgr };
    this.c++;
  }

  /** Обработка ESC-последовательности; возвращает новую позицию i. */
  escape(s: string, i: number): number {
    const n = s.length;
    if (i + 1 >= n) return n;
    const next = s[i + 1];
    if (next === "[") {
      // CSI: ESC [ params final
      let j = i + 2;
      let params = "";
      while (j < n && /[0-9;?]/.test(s[j])) {
        params += s[j];
        j++;
      }
      if (j >= n) return n;
      const final = s[j];
      this.csi(params, final);
      return j + 1;
    }
    if (next === "]") {
      // OSC: до BEL или ESC \
      let j = i + 2;
      while (
        j < n &&
        s[j] !== "\x07" &&
        !(s[j] === "\x1b" && s[j + 1] === "\\")
      )
        j++;
      return j < n ? (s[j] === "\x07" ? j + 1 : j + 2) : n;
    }
    if (next === "(" || next === ")" || next === "#") return i + 3; // charset и пр.
    return i + 2; // одиночные ESC-коды
  }

  csi(paramsRaw: string, final: string) {
    const priv = paramsRaw.startsWith("?");
    const params = paramsRaw.replace(/^\?/, "");
    const nums = params
      .split(";")
      .filter((p) => p !== "")
      .map((p) => parseInt(p, 10));
    const n = (idx: number, dflt: number) =>
      nums.length > idx ? nums[idx] || dflt : dflt;
    switch (final) {
      case "A":
        this.r = Math.max(0, this.r - n(0, 1));
        break;
      case "B":
        this.r = Math.min(this.rows - 1, this.r + n(0, 1));
        break;
      case "C":
        this.c = Math.min(this.cols - 1, this.c + n(0, 1));
        break;
      case "D":
        this.c = Math.max(0, this.c - n(0, 1));
        break;
      case "H":
      case "f": {
        this.r = Math.min(this.rows - 1, n(0, 1) - 1);
        this.c = Math.min(this.cols - 1, n(1, 1) - 1);
        break;
      }
      case "G":
        this.c = Math.min(this.cols - 1, Math.max(0, n(0, 1) - 1));
        break;
      case "J": {
        const mode = n(0, 0);
        const blankRow = () =>
          Array.from({ length: this.cols }, () => ({ ...BLANK }));
        if (mode === 0) {
          for (let c = this.c; c < this.cols; c++)
            this.grid[this.r][c] = { ...BLANK };
          for (let r = this.r + 1; r < this.rows; r++)
            this.grid[r] = blankRow();
        } else if (mode === 1) {
          for (let c = 0; c <= this.c; c++) this.grid[this.r][c] = { ...BLANK };
          for (let r = 0; r < this.r; r++) this.grid[r] = blankRow();
        } else {
          for (let r = 0; r < this.rows; r++) this.grid[r] = blankRow();
        }
        break;
      }
      case "K": {
        const mode = n(0, 0);
        if (mode === 0)
          for (let c = this.c; c < this.cols; c++)
            this.grid[this.r][c] = { ...BLANK };
        else if (mode === 1)
          for (let c = 0; c <= this.c; c++) this.grid[this.r][c] = { ...BLANK };
        else
          for (let c = 0; c < this.cols; c++)
            this.grid[this.r][c] = { ...BLANK };
        break;
      }
      case "m": {
        if (params === "" || nums.includes(0)) this.sgr = "";
        else this.sgr = params;
        break;
      }
      case "h": {
        if (priv && nums.includes(1049)) {
          if (!this.savedGrid) this.savedGrid = this.grid;
          this.grid = Term.blankGrid(this.rows, this.cols);
          this.r = 0;
          this.c = 0;
          this.altScreen = true;
        }
        if (priv && nums.includes(25)) this.cursorHidden = false; // ?25h — показать
        break;
      }
      case "l": {
        if (priv && nums.includes(1049)) {
          if (this.savedGrid) {
            this.grid = this.savedGrid;
            this.savedGrid = null;
          }
          this.altScreen = false;
        }
        if (priv && nums.includes(25)) this.cursorHidden = true; // ?25l — скрыть
        break;
      }
      default:
        break; // L, M, S, T и пр. — для снимков не критичны
    }
  }

  /**
   * Текст снимка: сетка с ANSI-кодами цвета на границах смены стиля.
   * Хвостовые пробелы с дефолтным стилем обрезаются, пустые строки в конце
   * экрана — тоже.
   */
  render(): string {
    const lines: string[] = [];
    for (let r = 0; r < this.rows; r++) {
      let line = "";
      let cur = "";
      let last = 0;
      for (let c = 0; c < this.cols; c++) {
        const cell = this.grid[r][c];
        if (cell.sgr !== cur) {
          line += cell.sgr === "" ? "\x1b[0m" : `\x1b[${cell.sgr}m`;
          cur = cell.sgr;
        }
        line += cell.ch;
        if (cell.ch !== " " || cell.sgr !== "") last = line.length;
      }
      if (cur !== "") line += "\x1b[0m";
      lines.push(line.slice(0, last));
    }
    while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
    return lines.join("\n");
  }
}

// ===========================================================================
// Захват: pty через script(1) + нарезка на кадры
// ===========================================================================

interface FrameMeta {
  file: string;
  t: number;
  hash: string;
  sameAsPrev: boolean;
}

interface RunResult {
  sessionDir: string;
  frames: FrameMeta[];
  cols: number;
  rows: number;
  duration: number;
  exitCode: number | null;
}

const FRAME_INTERVAL_MS = 50;

async function capture(
  cmd: string,
  opts: { cols?: number; rows?: number; outDir?: string },
): Promise<RunResult> {
  const cols = opts.cols ?? 100;
  const rows = opts.rows ?? 30;
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const sessionDir =
    opts.outDir ?? path.join(os.tmpdir(), "tprobe", `run-${stamp}`);
  const framesDir = path.join(sessionDir, "frames");
  fs.mkdirSync(framesDir, { recursive: true });

  // script делает pty; размер задаём stty-префиксом. -f = flush после каждой
  // записи (важно для таймингов кадров), -e = вернуть код выхода ребёнка.
  const inner = `stty cols ${cols} rows ${rows} 2>/dev/null; ${cmd}`;
  const child = spawn("script", ["-q", "-f", "-e", "-c", inner, "/dev/null"], {
    env: { ...process.env, TERM: "xterm-256color" },
    stdio: ["ignore", "pipe", "inherit"],
  });

  type Chunk = { t: number; data: string };
  const chunks: Chunk[] = [];
  const started = Date.now();
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (d: string) => {
    chunks.push({ t: (Date.now() - started) / 1000, data: d });
  });
  const exitCode: number | null = await new Promise((resolve) => {
    child.on("close", (code) => resolve(code));
  });
  const duration = (Date.now() - started) / 1000;

  // Настроить полный терминатор: добавить финальный кадр
  chunks.push({ t: duration, data: "" });

  // Реплей: снимок после каждого чанка, отстоящего ≥FRAME_INTERVAL от
  // предыдущего снимка (дедупликация по хэшу гасит лишние одинаковые кадры).
  const term = new Term(rows, cols);
  const frames: FrameMeta[] = [];
  let idx = 0;
  let lastHash = "";

  const snapshot = (t: number, force: boolean) => {
    const text = term.render();
    const hash = crypto
      .createHash("sha256")
      .update(text)
      .digest("hex")
      .slice(0, 12);
    idx++;
    const file = `${String(idx).padStart(4, "0")}_${t.toFixed(2)}s.txt`;
    if (hash === lastHash && !force) {
      fs.writeFileSync(
        path.join(framesDir, file),
        `# SAME AS PREVIOUS\n# идентично кадру ${String(idx - 1).padStart(4, "0")} (hash ${hash})\n# полный снимок смотри в предыдущем кадре этого хэша\n`,
      );
      frames.push({ file, t, hash, sameAsPrev: true });
    } else {
      const header =
        `# tprobe frame\n# t: ${t.toFixed(2)}s  hash: ${hash}  screen: ${cols}x${rows}\n` +
        `# cursor: r=${term.r + 1},c=${term.c + 1}  alt-screen: ${term.altScreen ? "yes" : "no"}  cursor-hidden: ${term.cursorHidden ? "yes" : "no"}\n`;
      fs.writeFileSync(path.join(framesDir, file), header + text + "\n");
      frames.push({ file, t, hash, sameAsPrev: false });
      lastHash = hash;
    }
  };

  const minGap = FRAME_INTERVAL_MS / 1000;
  let lastSnapT = -Infinity;
  for (const chunk of chunks) {
    term.feed(chunk.data);
    if (chunk.data.length > 0 && chunk.t - lastSnapT >= minGap) {
      snapshot(chunk.t, false);
      lastSnapT = chunk.t;
    }
  }

  // финальный кадр — гарантировать, что сессия не пуста (если контент уже
  // записан и не изменился, дедупликация запишет маркер вместо копии)
  snapshot(duration, frames.length === 0);

  const meta = { cmd, cols, rows, duration, exitCode, frames };
  fs.writeFileSync(
    path.join(sessionDir, "meta.json"),
    JSON.stringify(meta, null, 2),
  );
  return { sessionDir, frames, cols, rows, duration, exitCode };
}

// ===========================================================================
// CLI
// ===========================================================================

function printUsage(): void {
  console.error(`terminal-probe — снимки экрана консольной программы под pty

Использование:
  terminal-probe.ts run [--cols N] [--rows N] [--out DIR] -- <команда...>
  terminal-probe.ts list <session-dir>
`);
}

async function cli(): Promise<number> {
  const argv = process.argv.slice(2);
  const sub = argv[0];
  if (sub === "run") {
    let cols: number | undefined;
    let rows: number | undefined;
    let outDir: string | undefined;
    const rest: string[] = [];
    for (let i = 1; i < argv.length; i++) {
      if (argv[i] === "--cols") cols = parseInt(argv[++i], 10);
      else if (argv[i] === "--rows") rows = parseInt(argv[++i], 10);
      else if (argv[i] === "--out") outDir = argv[++i];
      else if (argv[i] === "--") {
        rest.push(...argv.slice(i + 1));
        break;
      } else rest.push(argv[i]);
    }
    const cmd = rest.join(" ");
    if (!cmd) {
      printUsage();
      return 2;
    }
    const r = await capture(cmd, { cols, rows, outDir });
    const uniq = r.frames.filter((f) => !f.sameAsPrev).length;
    console.log(`session: ${r.sessionDir}`);
    console.log(
      `frames: ${r.frames.length} (unique: ${uniq}), duration: ${r.duration.toFixed(2)}s, exit: ${r.exitCode}`,
    );
    return 0;
  }
  if (sub === "list") {
    const session = argv[1];
    if (!session) {
      printUsage();
      return 2;
    }
    let meta: { frames: FrameMeta[] };
    try {
      meta = JSON.parse(
        fs.readFileSync(path.join(session, "meta.json"), "utf8"),
      );
    } catch (e) {
      console.error(
        `cannot read meta.json in ${session}: ${e instanceof Error ? e.message : String(e)}`,
      );
      return 1;
    }
    for (const f of meta.frames as FrameMeta[]) {
      console.log(
        `${f.sameAsPrev ? "=" : "+"} ${f.file}  t=${f.t.toFixed(2)}s`,
      );
    }
    return 0;
  }
  printUsage();
  return 2;
}

// CLI-режим: файл запущен напрямую node'ом (не импортирован pi)
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  void cli().then((code) => {
    process.exitCode = code;
  });
}

// ===========================================================================
// pi-расширение: инструмент terminal_probe
// ===========================================================================

export default function terminalProbeExtension(pi: ExtensionAPI) {
  const tool = defineTool({
    name: "terminal_probe",
    label: "Terminal Probe",
    description:
      "Запускает консольную команду под псевдо-терминалом (pty) и записывает " +
      "текстовые снимки экрана по кадрам (~50мс): сетка символов, ANSI-цвета, " +
      "таймкод в имени файла. Кадры без изменений — файлы-маркеры. " +
      "Ассертов нет: анализ снимков выполняет агент.",
    parameters: Type.Object({
      action: Type.String({ description: "run | list | read" }),
      cmd: Type.Optional(
        Type.String({ description: "Команда (shell-строка) для action=run" }),
      ),
      cols: Type.Optional(
        Type.Number({ description: "Ширина экрана, по умолчанию 100" }),
      ),
      rows: Type.Optional(
        Type.Number({ description: "Высота экрана, по умолчанию 30" }),
      ),
      outDir: Type.Optional(
        Type.String({
          description: "Каталог сессии (по умолчанию /tmp/tprobe/run-<ts>)",
        }),
      ),
      session: Type.Optional(
        Type.String({ description: "Каталог сессии для action=list|read" }),
      ),
      frame: Type.Optional(
        Type.String({ description: "Имя файла кадра для action=read" }),
      ),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      if (params.action === "run") {
        if (!params.cmd) {
          return {
            content: [{ type: "text", text: "Ошибка: нужен параметр cmd" }],
            details: {},
          };
        }
        try {
          const r = await capture(params.cmd, {
            cols: params.cols,
            rows: params.rows,
            outDir: params.outDir,
          });
          const uniq = r.frames.filter((f) => !f.sameAsPrev);
          const summary =
            `Сессия: ${r.sessionDir}\n` +
            `Команда: ${params.cmd}\n` +
            `Кадров: ${r.frames.length} (уникальных: ${uniq.length}), длительность ${r.duration.toFixed(2)}s, exit ${r.exitCode}\n` +
            `meta.json: ${path.join(r.sessionDir, "meta.json")}\n` +
            `Уникальные кадры:\n` +
            uniq.map((f) => `  ${f.file} [t=${f.t.toFixed(2)}s]`).join("\n");
          return {
            content: [{ type: "text", text: summary }],
            details: { sessionDir: r.sessionDir },
          };
        } catch (e) {
          return {
            content: [
              {
                type: "text",
                text: `Ошибка: ${e instanceof Error ? e.message : String(e)}`,
              },
            ],
            details: {},
          };
        }
      }
      if (params.action === "list") {
        if (!params.session) {
          return {
            content: [{ type: "text", text: "Ошибка: нужен session" }],
            details: {},
          };
        }
        let meta: { frames: FrameMeta[] };
        try {
          meta = JSON.parse(
            fs.readFileSync(path.join(params.session, "meta.json"), "utf8"),
          );
        } catch (e) {
          return {
            content: [
              {
                type: "text",
                text: `Ошибка: не удалось прочитать meta.json в ${params.session}: ${e instanceof Error ? e.message : String(e)}`,
              },
            ],
            details: {},
          };
        }
        const lines = (meta.frames as FrameMeta[])
          .map(
            (f) =>
              `${f.sameAsPrev ? "=" : "+"} ${f.file}  t=${f.t.toFixed(2)}s`,
          )
          .join("\n");
        return {
          content: [
            {
              type: "text",
              text: `${params.session}: ${meta.frames.length} кадров\n${lines}`,
            },
          ],
          details: {},
        };
      }
      if (params.action === "read") {
        if (!params.session || !params.frame) {
          return {
            content: [{ type: "text", text: "Ошибка: нужны session и frame" }],
            details: {},
          };
        }
        const file = path.join(params.session, "frames", params.frame);
        const text = fs.readFileSync(file, "utf8");
        return { content: [{ type: "text", text }], details: {} };
      }
      return {
        content: [
          {
            type: "text",
            text: `Ошибка: неизвестное action '${params.action}'`,
          },
        ],
        details: {},
      };
    },
  });

  pi.registerTool(tool);
}
