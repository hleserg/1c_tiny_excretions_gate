package main

// Панель «Шаги прогона»: план прогона (событие plan) рисуется трубой сверху вниз. Впереди - серые шаги,
// текущий пульсирует, пройденные отмечаются по строкам [OK]/[WARN]/[FAIL]/[SKIP] из вывода движка.
// Глифы только из CP437/WGL4: в conhost со шрифтом Consolas остальные рисуются квадратиками.

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/lipgloss"
)

const (
	nodePending = ""
	nodePass    = "PASS"   // строки результата нет, но движок ушёл дальше (подготовка базы)
	nodeNotRun  = "NOTRUN" // движок ушёл дальше или закончился, а шаг так и не выполнялся
	verdictNode = "Вердикт"
)

type pipeNode struct {
	name     string
	status   string
	planned  bool
	started  time.Time
	finished time.Time
}

func newOverallBar() progress.Model {
	return progress.New(progress.WithGradient("#3EC7A0", "#5A56E0"), progress.WithoutPercentage(),
		progress.WithWidth(stepsWidth-12), progress.WithFillCharacters('█', '░'))
}

func samePrefix(a, b string) bool {
	return strings.HasPrefix(strings.ToLower(a), strings.ToLower(b))
}

func isPseudoStep(name string) bool {
	return strings.HasPrefix(name, "Подготовка")
}

// setPlan - событие plan: заменяет трубу планом. Отметки, пришедшие раньше плана, сохраняются.
// parallel - шаги, которые идут параллельно остальным (проверка конфигурации в фоне): их результат может прийти
// раньше их места в плане и ничего не говорит о шагах перед ними.
func (m *model) setPlan(names []string, parallel []string) {
	old := m.pipe
	m.pipe = nil
	m.parallel = map[string]bool{}
	for _, n := range parallel {
		m.parallel[n] = true
	}
	for _, n := range names {
		m.pipe = append(m.pipe, pipeNode{name: n, planned: true})
	}
	m.pipe = append(m.pipe, pipeNode{name: verdictNode, planned: true})
	m.planned = true
	for _, n := range old {
		m.markResult(n.status, n.name)
	}
	m.touchActive()
}

func (m *model) firstPending() int {
	for i, n := range m.pipe {
		if n.status == nodePending {
			return i
		}
	}
	return -1
}

// closeBefore - всё, что до шага j так и осталось серым: подготовка считается пройденной, шаги - невыполненными.
func (m *model) closeBefore(j int) {
	now := time.Now()
	for i := 0; i < j; i++ {
		if m.pipe[i].status != nodePending {
			continue
		}
		if isPseudoStep(m.pipe[i].name) {
			m.pipe[i].status = nodePass
		} else {
			m.pipe[i].status = nodeNotRun
		}
		m.pipe[i].finished = now
	}
}

func (m *model) findPending(text string) int {
	for i, n := range m.pipe {
		// Невыполненным шаг мог посчитаться раньше времени (движок шёл не по плану): строка результата его вернёт.
		open := n.status == nodePending || n.status == nodeNotRun
		if open && n.name != verdictNode && (samePrefix(text, n.name) || samePrefix(n.name, text)) {
			return i
		}
	}
	return -1
}

// markResult - строка [OK]/[WARN]/[FAIL]/[SKIP] <текст>.
func (m *model) markResult(status, text string) {
	now := time.Now()
	j := m.findPending(text)
	if j < 0 {
		// Шага нет в плане (или плана нет): встаёт перед первым серым.
		node := pipeNode{name: text, status: status, started: now, finished: now}
		at := m.firstPending()
		if at < 0 {
			m.pipe = append(m.pipe, node)
		} else {
			m.pipe = append(m.pipe[:at], append([]pipeNode{node}, m.pipe[at:]...)...)
		}
		m.touchActive()
		return
	}
	// Параллельный шаг закончился раньше своего места в плане: шаги перед ним ещё идут, закрывать их нельзя
	// (иначе текущий шаг становится «не выполнялся», а активным - «Вердикт»).
	if !m.parallel[m.pipe[j].name] {
		m.closeBefore(j)
	}
	generic := !samePrefix(text, m.pipe[j].name) // «Канареечный вход» на весь план «Канареечный вход: …»
	for i := j; i < len(m.pipe); i++ {
		if (i > j && m.pipe[i].status != nodePending) || m.pipe[i].name == verdictNode {
			break
		}
		if i > j && !(generic && samePrefix(m.pipe[i].name, text)) {
			break
		}
		m.pipe[i].status = status
		m.pipe[i].finished = now
		if m.pipe[i].started.IsZero() {
			m.pipe[i].started = now
		}
		if !generic {
			break
		}
	}
	m.touchActive()
}

// markProgress - движок начал шаг с таким заголовком: всё серое до него закрывается. Шаг, уже посчитанный
// невыполненным (результат более позднего шага пришёл раньше), открывается снова: он и есть текущий.
func (m *model) markProgress(title string) {
	j := m.findPending(title)
	if j < 0 {
		return
	}
	if m.pipe[j].status == nodeNotRun {
		m.pipe[j].status = nodePending
		m.pipe[j].finished = time.Time{}
	}
	m.closeBefore(j)
	m.touchActive()
}

func (m *model) markVerdict(v string) {
	status := "WARN"
	switch {
	case strings.Contains(v, "ЗЕЛЁН"):
		status = "OK"
	case strings.Contains(v, "КРАСН"):
		status = "FAIL"
	}
	for i := range m.pipe {
		if m.pipe[i].name == verdictNode {
			m.closeBefore(i)
			m.pipe[i].status = status
			m.pipe[i].finished = time.Now()
			m.touchActive()
			return
		}
	}
}

// closeAll - движок закончился: серое так и не выполнялось.
func (m *model) closeAll() {
	m.closeBefore(len(m.pipe))
	m.touchActive()
}

// touchActive - у нового текущего шага засекается время начала.
func (m *model) touchActive() {
	if i := m.firstPending(); i >= 0 && m.pipe[i].started.IsZero() && m.running {
		m.pipe[i].started = time.Now()
	}
}

func (m *model) pipeFraction() float64 {
	if len(m.pipe) == 0 {
		return 0
	}
	done := 0
	for _, n := range m.pipe {
		if n.status != nodePending {
			done++
		}
	}
	return float64(done) / float64(len(m.pipe))
}

// ---------------------------------------------------------------------------------------------------------------

func nodeIcon(n pipeNode) string {
	switch n.status {
	case "OK":
		return styleOkBold.Render("√")
	case nodePass:
		return styleOk.Render("√")
	case "WARN":
		return styleWarnBold.Render("!")
	case "FAIL":
		return styleBadBold.Render("×")
	case "SKIP", nodeNotRun:
		return styleDim.Render("-")
	default:
		return styleTrack.Render("○")
	}
}

func nodeNameStyle(n pipeNode) lipgloss.Style {
	switch n.status {
	case "OK", nodePass:
		return styleText
	case "WARN":
		return styleWarn
	case "FAIL":
		return styleBad
	case "SKIP", nodeNotRun:
		return styleDim
	default:
		return styleTrack
	}
}

// pulse - текущий шаг: ● мигает яркостью, имя подсвечено.
var pulseColors = []lipgloss.Color{"69", "75", "111", "153", "111", "75"}

// nodeLines - строки шага: значок, имя с переносом по словам; у текущего - пульс и время справа.
func (m model) nodeLines(n pipeNode, active bool, width int) []string {
	icon := nodeIcon(n)
	style := nodeNameStyle(n)
	t := ""
	if active {
		c := pulseColors[(m.frame/2)%len(pulseColors)]
		icon = lipgloss.NewStyle().Foreground(c).Bold(true).Render("●")
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("230")).Bold(true)
		if !n.started.IsZero() {
			t = formatDuration(time.Since(n.started).Seconds())
		}
	}
	textWidth := width - 2
	parts := wrapWords(n.name, textWidth)
	// Время - на последней строке, если там есть место, иначе отдельной строкой.
	if t != "" {
		last := parts[len(parts)-1]
		if lipgloss.Width(last)+1+lipgloss.Width(t) > textWidth {
			parts = append(parts, "")
		}
	}
	out := make([]string, len(parts))
	for i, p := range parts {
		prefix := "  "
		if i == 0 {
			prefix = icon + " "
		}
		line := prefix + style.Render(p)
		if t != "" && i == len(parts)-1 {
			gap := textWidth - lipgloss.Width(p) - lipgloss.Width(t)
			line += strings.Repeat(" ", max(1, gap)) + styleAccent.Render(t)
		}
		out[i] = line
	}
	return out
}

// wrapWords - перенос по словам; слово длиннее строки режется.
func wrapWords(s string, width int) []string {
	if width < 4 {
		width = 4
	}
	var lines []string
	cur := ""
	for _, w := range strings.Fields(s) {
		for len([]rune(w)) > width {
			if cur != "" {
				lines = append(lines, cur)
				cur = ""
			}
			r := []rune(w)
			lines = append(lines, string(r[:width]))
			w = string(r[width:])
		}
		switch {
		case cur == "":
			cur = w
		case len([]rune(cur))+1+len([]rune(w)) <= width:
			cur += " " + w
		default:
			lines = append(lines, cur)
			cur = w
		}
	}
	if cur != "" || len(lines) == 0 {
		lines = append(lines, cur)
	}
	return lines
}

// connector - вертикаль между шагами. Перед текущим шагом по трубе «стекает» стрелка.
func (m model) connector(next pipeNode, active bool) string {
	if active {
		glyphs := []string{"│", "│", "↓", "↓"}
		c := pulseColors[(m.frame/2)%len(pulseColors)]
		return lipgloss.NewStyle().Foreground(c).Render(glyphs[(m.frame/3)%len(glyphs)])
	}
	if next.status == nodePending {
		return styleTrack.Render("│")
	}
	return styleOk.Render("│")
}

// timeText - сколько прошло с начала скрипта и (у прогона, если скрипт умеет оценить) сколько осталось:
// «прошло 1:02:03 · осталось ~12:34+». «+» - есть шаги без статистики. Скрипт не идёт - пусто.
func (m model) timeText() string {
	if !m.running || m.started.IsZero() {
		return ""
	}
	text := "прошло " + formatDuration(time.Since(m.started).Seconds())
	if m.eta != nil {
		left := m.eta.seconds - time.Since(m.eta.at).Seconds()
		text += " · осталось ~" + formatDuration(left)
		if m.eta.unknown > 0 {
			text += "+"
		}
	}
	return text
}

func (m model) viewPipe(width, height int) string {
	var b strings.Builder
	done := 0
	for _, n := range m.pipe {
		if n.status != nodePending {
			done++
		}
	}
	head := styleSection.Render("Шаги прогона")
	if len(m.pipe) > 0 {
		count := styleDim.Render(fmt.Sprintf("%d/%d", done, len(m.pipe)))
		gap := width - lipgloss.Width(head) - lipgloss.Width(count)
		if gap < 1 {
			gap = 1
		}
		head += strings.Repeat(" ", gap) + count
	}
	b.WriteString(head + "\n")
	// Сколько прошло с начала и сколько осталось - отдельной строкой: в узкую колонку рядом с заголовком не влезает.
	timeLine := m.timeText()
	if timeLine != "" {
		b.WriteString(hang("", timeLine, width, styleDim) + "\n")
	}
	if len(m.pipe) == 0 {
		if m.prog != nil {
			b.WriteString(hang(styleAccent.Render(m.spin.View())+" ", m.prog.title, width, styleText) + "\n")
		} else {
			b.WriteString(styleDim.Render("появятся, когда начнётся прогон") + "\n")
		}
		return b.String()
	}
	b.WriteString(m.overall.View() + " " + styleDim.Render(fmt.Sprintf("%3d%%", int(m.pipeFraction()*100))) + "\n")

	rows := height - 2
	if timeLine != "" {
		rows -= strings.Count(hang("", timeLine, width, styleDim), "\n") + 1
	}
	active := -1
	if m.running {
		active = m.firstPending()
	}
	// Каждый шаг - одна или несколько строк: длинное имя переносится по словам, а не обрезается.
	type block struct {
		lines []string
		pipe  string
	}
	blocks := make([]block, len(m.pipe))
	total := 0
	for i, node := range m.pipe {
		blocks[i].lines = m.nodeLines(node, i == active, width)
		total += len(blocks[i].lines)
		if i > 0 {
			blocks[i].pipe = m.connector(node, i == active)
		}
	}
	withPipes := total+len(m.pipe)-1 <= rows
	if withPipes {
		total += len(m.pipe) - 1
	}
	// Не влезает: окно строк вокруг текущего шага.
	from, to := 0, len(m.pipe)
	if total > rows && rows > 0 {
		center := active
		if center < 0 {
			center = len(m.pipe) - 1
		}
		from, to = center, center+1
		used := len(blocks[center].lines)
		for {
			grown := false
			if to < len(m.pipe) && used+len(blocks[to].lines) <= rows && (to-center <= center-from || from == 0) {
				used += len(blocks[to].lines)
				to++
				grown = true
			}
			if from > 0 && used+len(blocks[from-1].lines) <= rows {
				from--
				used += len(blocks[from].lines)
				grown = true
			}
			if !grown {
				break
			}
		}
	}
	for i := from; i < to; i++ {
		if withPipes && i > from {
			b.WriteString(blocks[i].pipe + "\n")
		}
		for _, l := range blocks[i].lines {
			b.WriteString(l + "\n")
		}
		// Узкий экран: колонки «Внутри» нет - текущий внутренний шаг прямо под активным узлом.
		if i == active && !m.subWide() {
			for _, l := range m.subInline(width) {
				b.WriteString(l + "\n")
			}
		}
	}
	return b.String()
}
