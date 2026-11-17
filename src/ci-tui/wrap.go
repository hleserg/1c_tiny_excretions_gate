package main

// Перенос строк: на экране ci.exe строки не обрезаются, длинная строка переносится по словам
// с отступом продолжения (под текстом после «[OK  ] », «› » или под своим отступом).

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

var hangPrefix = regexp.MustCompile(`^(\[[^\]]{1,8}\]\s+|›\s+|-\s+|\.\.\.\s+)`)

// wrapIndent - перенос простой (без ANSI) строки журнала.
func wrapIndent(line string, width int) []string {
	if width < 10 {
		width = 10
	}
	if lipgloss.Width(line) <= width {
		return []string{line}
	}
	body := strings.TrimLeft(line, " ")
	indent := len(line) - len(body)
	hanging := indent + 2
	if m := hangPrefix.FindString(body); m != "" {
		hanging = indent + lipgloss.Width(m)
	}
	if hanging > width/2 {
		hanging = indent
	}
	first := wrapWords(body, width-indent)
	out := []string{strings.Repeat(" ", indent) + first[0]}
	if len(first) == 1 {
		return out
	}
	rest := strings.Join(first[1:], " ")
	for _, l := range wrapWords(rest, width-hanging) {
		out = append(out, strings.Repeat(" ", hanging)+l)
	}
	return out
}

// colorizeWrapped - строки журнала в цвете и с переносом под ширину.
func colorizeWrapped(lines []string, width int) string {
	var b strings.Builder
	for i, l := range lines {
		if i > 0 {
			b.WriteString("\n")
		}
		if strings.Contains(l, "\x1b[") {
			b.WriteString(l)
			continue
		}
		st, ok := lineStyle(l)
		for j, piece := range wrapIndent(l, width) {
			if j > 0 {
				b.WriteString("\n")
			}
			if ok {
				b.WriteString(st.Render(piece))
			} else {
				b.WriteString(piece)
			}
		}
	}
	return b.String()
}

// hang - текст с префиксом первой строки; следующие строки - под текстом, а не под префиксом.
func hang(prefix string, text string, width int, st lipgloss.Style) string {
	pw := lipgloss.Width(prefix)
	parts := wrapWords(text, max(10, width-pw))
	var b strings.Builder
	for i, p := range parts {
		if i == 0 {
			b.WriteString(prefix)
		} else {
			b.WriteString("\n" + strings.Repeat(" ", pw))
		}
		b.WriteString(st.Render(p))
	}
	return b.String()
}

// wrapBlock - простой перенос текста по словам (для строк хода и подсказок).
func wrapBlock(text string, width int, st lipgloss.Style) string {
	parts := wrapWords(text, max(10, width))
	for i := range parts {
		parts[i] = st.Render(parts[i])
	}
	return strings.Join(parts, "\n")
}
