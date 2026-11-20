package main

import (
	"fmt"
	"sort"
	"strings"
)

var classTitles = map[string]string{
	clSame:          "одинаково",
	clOursOnly:      "в поставке нет, оставлено наше",
	clTheirsNew:     "новое из поставки",
	clTheirsChanged: "правка подрядчика поверх его прежней версии",
	clStale:         "в поставке прежняя версия, оставлено наше",
	clRejected:      "отклонено раньше, оставлено наше",
	clDecided:       "решено",
	clPending:       "ждёт решения",
	clVersion:       "новый штамп версии",
}

var kindTitles = map[string]string{
	"conflict": "расхождение", "removed": "в поставке удалено", "revived": "у нас удалено, в поставке изменено",
	"clash": "одноимённый объект с другим UUID", "identity": "другой объект (UUID)", "binary": "целая версия файла",
}

var statusTitles = map[string]string{
	"unchanged": "нового нет", "changed": "есть принятые изменения", "new": "новый объект",
	"pending": "ждёт решения", "opaque": "принят файлом целиком",
}

// renderReport - отчёт объединения для человека (markdown): что взято, что оставлено и почему, что ждёт решения.
func renderReport(res *result) string {
	var b strings.Builder
	fmt.Fprintf(&b, "## Объединение поставки %s\n\n", res.Delivery)
	if res.Pending > 0 {
		fmt.Fprintf(&b, "**Ждут решения: %d.** Остальное разобрано по истории автоматически.\n\n", res.Pending)
	} else {
		b.WriteString("Решений не требуется: всё разобрано по истории или уже решено.\n\n")
	}
	for _, obj := range res.Objects {
		title := obj.Title
		if title == "" {
			title = obj.Name
		}
		first := "нет"
		if obj.First {
			first = "да (отсутствие наших частей ничего не удаляет)"
		}
		fmt.Fprintf(&b, "### %s (%s `%s`) - %s\n\n", title, kindName(obj.Kind), obj.RepoPath, statusTitles[obj.Status])
		fmt.Fprintf(&b, "Первая поставка этого объекта: %s.\n\n", first)
		var counts []string
		for _, cl := range []string{clTheirsNew, clTheirsChanged, clDecided, clOursOnly, clStale, clRejected, clPending, clVersion} {
			if n := obj.Counts[cl]; n > 0 {
				counts = append(counts, fmt.Sprintf("%s - %d", classTitles[cl], n))
			}
		}
		if len(counts) > 0 {
			b.WriteString("Итог по частям: " + strings.Join(counts, "; ") + ".\n\n")
		}
		if obj.Binary != "" {
			fmt.Fprintf(&b, "Файл поставки: sha256 `%s`.\n\n", obj.Binary)
		}
		var pending, decided []*Decision
		for _, d := range obj.Decisions {
			if d.Chosen == "" {
				pending = append(pending, d)
			} else {
				decided = append(decided, d)
			}
		}
		if len(pending) > 0 {
			b.WriteString("#### Ждёт решения\n\n")
			for i, d := range pending {
				writeDecision(&b, i+1, d)
			}
		}
		section := func(header string, pick func(Change) bool) {
			var rows []string
			for _, ch := range obj.Changes {
				if pick(ch) {
					rows = append(rows, fmt.Sprintf("- %s - %s", ch.Title, ch.Evidence))
				}
			}
			if len(rows) == 0 {
				return
			}
			sort.Strings(rows)
			b.WriteString("#### " + header + "\n\n" + strings.Join(rows, "\n") + "\n\n")
		}
		section("Принято из поставки", func(ch Change) bool {
			return (ch.Class == clTheirsNew || ch.Class == clTheirsChanged) && ch.Result == "theirs"
		})
		section("Оставлено наше", func(ch Change) bool {
			return ch.Class == clOursOnly || ch.Class == clStale || ch.Class == clRejected
		})
		if len(decided) > 0 {
			b.WriteString("#### Решено человеком\n\n")
			for _, d := range decided {
				fmt.Fprintf(&b, "- `%s` %s: %s\n", d.ID, d.Title, choiceText(d.Chosen))
			}
			b.WriteString("\n")
		}
		if len(obj.Problems) > 0 {
			b.WriteString("#### Проблемы\n\n")
			for _, p := range obj.Problems {
				b.WriteString("- " + p + "\n")
			}
			b.WriteString("\n")
		}
	}
	if len(res.Warnings) > 0 {
		b.WriteString("#### Предупреждения\n\n")
		for _, w := range res.Warnings {
			b.WriteString("- " + w + "\n")
		}
		b.WriteString("\n")
	}
	return b.String()
}

func kindName(kind string) string {
	switch kind {
	case "extension":
		return "расширение"
	case "processing":
		return "обработка или отчёт"
	}
	return kind
}

func writeDecision(b *strings.Builder, n int, d *Decision) {
	fmt.Fprintf(b, "%d. **%s** - %s, решение `%s`\n\n", n, d.Title, kindTitles[d.Kind], d.ID)
	if d.Diff != "" {
		b.WriteString("   Разница (`-` у нас, `+` в поставке):\n\n   ```diff\n")
		for _, line := range strings.Split(d.Diff, "\n") {
			b.WriteString("   " + line + "\n")
		}
		b.WriteString("   ```\n\n")
	} else {
		fmt.Fprintf(b, "   Сейчас у нас: %s\n\n   Пришло: %s\n\n", oneLine(d.Ours), oneLine(d.Theirs))
	}
	fmt.Fprintf(b, "   Последствия: %s.\n\n", d.Consequences)
	fmt.Fprintf(b, "   Рекомендую: **%s** - %s.\n\n", choiceText(d.Recommended), d.Why)
}

func oneLine(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len([]rune(s)) > 200 {
		return string([]rune(s)[:200]) + "…"
	}
	return s
}
