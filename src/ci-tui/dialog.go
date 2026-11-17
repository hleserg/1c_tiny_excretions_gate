package main

// Окна вопросов: один пункт, несколько пунктов, да/нет, текст, просмотр длинного текста.

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type dialog struct {
	ev       uiEvent
	local    string // не пусто - вопрос самого ci.exe (остановка), не движка
	cursor   int
	offset   int
	marks    map[int]bool
	yes      bool
	input    textinput.Model
	view     viewport.Model
	warning  string
	notice   string
	width    int
	height   int
	finished bool
	result   answer
}

func newDialog(ev uiEvent, width, height int) *dialog {
	d := &dialog{ev: ev, marks: map[int]bool{}, yes: true}
	for _, i := range ev.Preselected {
		if i >= 0 && i < len(ev.Items) && len(d.clashing(i)) == 0 {
			d.marks[i] = true
		}
	}
	if ev.Kind == "text" {
		ti := textinput.New()
		ti.Prompt = "› "
		ti.CharLimit = 500
		ti.SetValue(ev.Value)
		ti.CursorEnd()
		if ev.Secret {
			ti.EchoMode = textinput.EchoPassword
			ti.EchoCharacter = '•'
		}
		ti.Focus()
		d.input = ti
	}
	if ev.Kind == "view" {
		d.view = viewport.New(10, 10)
		d.view.SetContent(colorizeWrapped(ev.Lines, max(20, width-8)))
	}
	d.resize(width, height)
	return d
}

func (d *dialog) resize(width, height int) {
	d.width = width
	d.height = height
	if d.ev.Kind == "view" {
		d.view.Width = max(20, width-8)
		d.view.Height = max(5, height-8)
		d.view.SetContent(colorizeWrapped(d.ev.Lines, d.view.Width))
	}
	if d.ev.Kind == "text" {
		d.input.Width = max(20, min(80, width-12))
	}
}

// visibleRows - сколько пунктов списка влезает в окно.
func (d *dialog) visibleRows() int {
	rows := d.height - 10 - len(d.ev.Notes)
	if rows < 3 {
		rows = 3
	}
	return rows
}

func (d *dialog) finish(a answer) {
	d.finished = true
	d.result = a
}

func (d *dialog) Update(msg tea.Msg) tea.Cmd {
	key, ok := msg.(tea.KeyMsg)
	if !ok {
		if d.ev.Kind == "text" {
			var cmd tea.Cmd
			d.input, cmd = d.input.Update(msg)
			return cmd
		}
		if d.ev.Kind == "view" {
			var cmd tea.Cmd
			d.view, cmd = d.view.Update(msg)
			return cmd
		}
		return nil
	}
	s := key.String()
	switch d.ev.Kind {
	case "one", "many":
		n := len(d.ev.Items)
		switch s {
		case "up", "k":
			if d.cursor > 0 {
				d.cursor--
			} else {
				d.cursor = n - 1
			}
		case "down", "j":
			if d.cursor < n-1 {
				d.cursor++
			} else {
				d.cursor = 0
			}
		case "home":
			d.cursor = 0
		case "end":
			d.cursor = n - 1
		case "pgup":
			d.cursor = max(0, d.cursor-d.visibleRows())
		case "pgdown":
			d.cursor = min(n-1, d.cursor+d.visibleRows())
		case "esc":
			d.finish(answer{Cancel: true})
		case " ", "x":
			if d.ev.Kind == "many" {
				d.warning = ""
				d.notice = ""
				if d.marks[d.cursor] {
					d.marks[d.cursor] = false
					break
				}
				// Одно расширение - одно обновление: отметка снимается с того, что грузит то же расширение.
				var off []string
				for _, j := range d.clashing(d.cursor) {
					d.marks[j] = false
					off = append(off, shortLabel(d.ev.Items[j]))
				}
				d.marks[d.cursor] = true
				if len(off) > 0 {
					d.notice = "снято: " + strings.Join(off, ", ") + " - у расширения одно обновление"
				}
			}
		case "a":
			if d.ev.Kind == "many" {
				all := len(d.selected()) < n
				d.notice = ""
				for i := 0; i < n; i++ {
					d.marks[i] = false
				}
				skipped := 0
				for i := 0; all && i < n; i++ {
					if len(d.clashing(i)) > 0 {
						skipped++
						continue
					}
					d.marks[i] = true
				}
				if skipped > 0 {
					d.notice = fmt.Sprintf("не отмечено %d: у расширения уже отмечено другое обновление", skipped)
				}
			}
		case "enter":
			if d.ev.Kind == "one" {
				d.finish(answer{Index: d.cursor})
			} else {
				sel := d.selected()
				if len(sel) == 0 {
					d.warning = "ничего не отмечено: пробел ставит отметку"
				} else {
					d.finish(answer{Indexes: sel, Index: -1})
				}
			}
		default:
			// Цифрой - сразу выбрать пункт (в списке из одного выбора).
			if d.ev.Kind == "one" {
				if k, err := strconv.Atoi(s); err == nil && k >= 1 && k <= n && k <= 9 {
					d.cursor = k - 1
					d.finish(answer{Index: d.cursor})
				}
			}
		}
		if d.cursor < d.offset {
			d.offset = d.cursor
		}
		if d.cursor >= d.offset+d.visibleRows() {
			d.offset = d.cursor - d.visibleRows() + 1
		}
	case "confirm":
		switch s {
		case "left", "right", "tab", "h", "l":
			d.yes = !d.yes
		case "y", "д":
			d.yes = true
			d.finish(answer{Yes: true})
		case "n", "н":
			d.yes = false
			d.finish(answer{Yes: false})
		case "enter":
			d.finish(answer{Yes: d.yes})
		case "esc":
			d.finish(answer{Cancel: true})
		}
	case "text":
		switch s {
		case "enter":
			d.finish(answer{Text: d.input.Value()})
		case "esc":
			d.finish(answer{Cancel: true})
		default:
			var cmd tea.Cmd
			d.input, cmd = d.input.Update(msg)
			return cmd
		}
	case "view":
		switch s {
		case "q", "esc", "enter":
			d.finish(answer{})
		default:
			var cmd tea.Cmd
			d.view, cmd = d.view.Update(msg)
			return cmd
		}
	}
	return nil
}

func (d *dialog) selected() []int {
	var sel []int
	for i := range d.ev.Items {
		if d.marks[i] {
			sel = append(sel, i)
		}
	}
	return sel
}

func (d *dialog) View() string {
	inner := max(30, min(d.width-6, 110))
	var b strings.Builder
	header := d.ev.Header
	if header == "" && d.ev.Kind == "view" {
		header = "Просмотр"
	}
	b.WriteString(styleDialogTitle.Width(inner).Render(header))
	b.WriteString("\n")
	for _, note := range d.ev.Notes {
		b.WriteString(styleDim.Width(inner).Render(note))
		b.WriteString("\n")
	}
	if d.ev.Poll {
		b.WriteString(styleDim.Width(inner).Render("Вопрос снимется сам, когда условие выполнится."))
		b.WriteString("\n")
	}
	b.WriteString("\n")

	switch d.ev.Kind {
	case "one", "many":
		rows := d.visibleRows()
		end := min(len(d.ev.Items), d.offset+rows)
		if d.offset > 0 {
			b.WriteString(styleDim.Render(fmt.Sprintf("  ↑ ещё %d", d.offset)) + "\n")
		}
		for i := d.offset; i < end; i++ {
			mark := ""
			if d.ev.Kind == "many" {
				if d.marks[i] {
					mark = styleOk.Render("[√] ")
				} else {
					mark = "[ ] "
				}
			} else if i < 9 {
				mark = styleDim.Render(fmt.Sprintf("%d ", i+1))
			}
			text := d.ev.Items[i]
			if d.isDanger(i) {
				// Опасный пункт (откат рабочей) - красная рамка с ▲!, под курсором - залит красным.
				box := styleDangerItem
				if i == d.cursor {
					box = styleDangerItemActive
				}
				lines := strings.Split(box.Width(inner-6).Render("▲ ! "+text+" ! ▲"), "\n")
				for j, l := range lines {
					p := "  "
					if j == len(lines)/2 && i == d.cursor {
						p = styleCursor.Render("› ")
					}
					b.WriteString(p + l + "\n")
				}
				continue
			}
			st := lipgloss.NewStyle()
			// Не отмеченное, которое заменит отмеченное того же расширения, - серое, со стрелкой.
			if d.ev.Kind == "many" && !d.marks[i] && len(d.clashing(i)) > 0 {
				text += "  ↔ вместо отмеченного"
				st = styleDim
			}
			prefix := "  " + mark
			if i == d.cursor {
				prefix = styleCursor.Render("› ") + mark
				st = styleSelected
			}
			b.WriteString(hang(prefix, text, inner, st) + "\n")
		}
		if end < len(d.ev.Items) {
			b.WriteString(styleDim.Render(fmt.Sprintf("  ↓ ещё %d", len(d.ev.Items)-end)) + "\n")
		}
		if d.notice != "" {
			b.WriteString("\n" + wrapBlock(d.notice, inner, styleAccent) + "\n")
		}
		if d.warning != "" {
			b.WriteString("\n" + wrapBlock(d.warning, inner, styleWarn) + "\n")
		}
		b.WriteString("\n")
		if d.ev.Kind == "one" {
			b.WriteString(styleHelp.Render("↑↓ выбор · enter ок · цифра - сразу · esc отмена"))
		} else {
			b.WriteString(styleHelp.Render("↑↓ выбор · пробел отметить · a все · enter дальше · esc отмена"))
		}
	case "confirm":
		yes := nonEmpty(d.ev.Yes, "Да")
		no := nonEmpty(d.ev.No, "Нет")
		var yb, nb string
		if d.yes {
			yb = styleButtonActive.Render(yes)
			nb = styleButton.Render(no)
		} else {
			yb = styleButton.Render(yes)
			nb = styleButtonActive.Render(no)
		}
		b.WriteString(lipgloss.JoinHorizontal(lipgloss.Top, yb, "  ", nb))
		b.WriteString("\n\n" + styleHelp.Render("←→ выбор · enter ок · y/n · esc отмена"))
	case "text":
		b.WriteString(d.input.View())
		b.WriteString("\n\n" + styleHelp.Render("enter ок · esc отмена"))
	case "view":
		b.WriteString(d.view.View())
		b.WriteString("\n" + styleHelp.Render(fmt.Sprintf("↑↓ PgUp PgDn прокрутка · %d%% · q закрыть", int(d.view.ScrollPercent()*100))))
	}
	return styleDialog.Render(b.String())
}

func nonEmpty(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}

func truncate(s string, width int) string {
	if width < 4 {
		width = 4
	}
	if lipgloss.Width(s) <= width {
		return s
	}
	r := []rune(s)
	for len(r) > 0 && lipgloss.Width(string(r))+1 > width {
		r = r[:len(r)-1]
	}
	return string(r) + "…"
}

// clashing - отмеченные пункты, которые грузят то же расширение, что пункт i (groups: имена через «|»).
func (d *dialog) clashing(i int) []int {
	if i >= len(d.ev.Groups) || d.ev.Groups[i] == "" {
		return nil
	}
	mine := map[string]bool{}
	for _, n := range strings.Split(d.ev.Groups[i], "|") {
		if n != "" {
			mine[strings.ToLower(n)] = true
		}
	}
	var out []int
	for j := range d.ev.Items {
		if j == i || !d.marks[j] || j >= len(d.ev.Groups) {
			continue
		}
		for _, n := range strings.Split(d.ev.Groups[j], "|") {
			if mine[strings.ToLower(n)] {
				out = append(out, j)
				break
			}
		}
	}
	return out
}

func shortLabel(s string) string {
	if f := strings.Fields(s); len(f) > 0 {
		return f[0]
	}
	return s
}

func (d *dialog) isDanger(i int) bool {
	for _, x := range d.ev.Danger {
		if x == i {
			return true
		}
	}
	return false
}

// docked - вопрос да/нет рисуется полосой внизу экрана, а не окном поверх: чтобы решить «оставить или
// откатить», надо видеть итог прогона. Журнал при этом листается (↑↓ PgUp PgDn).
func (d *dialog) docked() bool {
	return d.ev.Kind == "confirm"
}

// ViewDocked - полоса вопроса во всю ширину экрана.
func (d *dialog) ViewDocked(width int) string {
	inner := max(20, width-6)
	var b strings.Builder
	b.WriteString(styleDialogTitle.Width(inner).Render(d.ev.Header))
	b.WriteString("\n")
	for _, note := range d.ev.Notes {
		b.WriteString(styleDim.Width(inner).Render(note))
		b.WriteString("\n")
	}
	if d.ev.Poll {
		b.WriteString(styleDim.Width(inner).Render("Вопрос снимется сам, когда условие выполнится."))
		b.WriteString("\n")
	}
	yes := nonEmpty(d.ev.Yes, "Да")
	no := nonEmpty(d.ev.No, "Нет")
	yb, nb := styleButton.Render(yes), styleButtonActive.Render(no)
	if d.yes {
		yb, nb = styleButtonActive.Render(yes), styleButton.Render(no)
	}
	help := styleHelp.Render("←→ выбор · enter ок · y/n · ↑↓ PgUp PgDn журнал · esc отмена")
	b.WriteString(lipgloss.JoinHorizontal(lipgloss.Center, yb, "  ", nb, "   ", help))
	return styleDocked.Width(width - 2).Render(b.String())
}
