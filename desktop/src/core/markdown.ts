import type { Meeting, Point } from "../contracts";
import { timestamp } from "./audio";
const clean = (s: string) =>
  s.replace(/[\r\n]+/g, " ").replace(/([\\`*_{}\[\]<>])/g, "\\$1");
export function markdown(m: Meeting): string {
  const lines = [
    `# ${clean(m.title)}`,
    "",
    `${m.startedAt.slice(0, 10)} · ${timestamp(m.duration)}${m.project ? ` · ${clean(m.project)}` : ""}`,
    "",
  ];
  const items = (title: string, points: Point[]) => {
    if (!points.length) return;
    lines.push(`## ${clean(title)}`, "");
    for (const p of points) {
      lines.push(`- ${clean(p.text)}`);
      for (const e of p.evidence) {
        const c = m.chunks.find((c) => c.id === e.source);
        if (c)
          lines.push(`  - Источник ${timestamp(c.start)}: «${clean(e.quote)}»`);
      }
    }
    lines.push("");
  };
  if (m.brief) {
    lines.push("## Резюме", "", clean(m.brief.overview), "");
    for (const topic of m.brief.topics) items(topic.title, [topic]);
    items("Решения", m.brief.decisions);
    items("Открытые вопросы", m.brief.questions);
    items(
      "Предложенные действия",
      m.brief.actions.map((a) => ({
        ...a,
        text: `${a.text}${a.owner ? ` — ${a.owner}` : ""}${a.due ? ` · ${a.due}` : ""}`,
      })),
    );
  }
  if (m.tasks.length)
    lines.push(
      "## Рабочий список задач",
      "",
      ...m.tasks.map(
        (t) =>
          `- [${t.done ? "x" : " "}] ${clean(t.text)}${t.owner ? ` — ${clean(t.owner)}` : ""}${t.due ? ` · ${clean(t.due)}` : ""}`,
      ),
      "",
    );
  if (m.notes.trim()) lines.push("## Личные заметки", "", m.notes, "");
  if (m.bookmarks.length)
    lines.push(
      "## Отмеченные моменты",
      "",
      ...m.bookmarks.map((t) => `- ${timestamp(t)}`),
      "",
    );
  lines.push("## Полная расшифровка", "");
  for (const c of m.chunks)
    if (c.text?.trim())
      lines.push(`**[${timestamp(c.start)}]** ${clean(c.text)}`, "");
  const pending = m.chunks.filter(
    (c) => c.voiced && c.text === undefined,
  ).length;
  if (pending)
    lines.push(
      `> Ещё не распознано фрагментов: ${pending}. Исходное аудио сохранено.`,
      "",
    );
  lines.push(
    "---",
    `Создано в Cool Assist Ai${m.summaryModelUsed ? ` · Резюме: ${clean(m.summaryModelUsed)}` : ""}. Проверьте имена, числа и решения по исходной записи.`,
    "",
  );
  return lines.join("\n");
}
