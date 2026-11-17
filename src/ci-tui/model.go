package main

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const maxLogLines = 6000

var stepLine = regexp.MustCompile(`^\[(OK|WARN|FAIL|SKIP)\s*\]\s+(.+)$`)

type step struct {
	status string
	name   string
}

type progressState struct {
	title    string
	elapsed  float64
	expected float64
	done     int
	total    int
	detail   string
	at       time.Time
}

type tickMsg time.Time
type engineStartedMsg struct {
	eng *engine
	err error
}

type model struct {
	baseDir   string
	script    string
	extra     []string
	eng       *engine
	running   bool
	exitCode  int
	exitErr   error
	lines     []string
	steps     []step
	pipe      []pipeNode
	planned   bool
	overall   progress.Model
	barTitle  string
	sub       *subState
	verdict   string
	logView   viewport.Model
	follow    bool
	prog      *progressState
	bar       progress.Model
	spin      spinner.Model
	dialog    *dialog
	queue     []uiEvent
	frame     int
	width     int
	height    int
	stopAsked time.Time
	notice    string
}

func newModel(baseDir, script string, extra []string) model {
	sp := spinner.New()
	// Брайлевских точек MiniDot в Consolas нет: пульсирующий блок из CP437.
	sp.Spinner = spinner.Spinner{Frames: []string{"░", "▒", "▓", "█", "▓", "▒"}, FPS: time.Second / 8}
	sp.Style = styleAccent
	bar := progress.New(progress.WithGradient("#5A56E0", "#3EC7A0"), progress.WithoutPercentage())
	return model{
		baseDir: baseDir,
		script:  script,
		extra:   extra,
		follow:  true,
		logView: viewport.New(80, 20),
		bar:     bar,
		overall: newOverallBar(),
		spin:    sp,
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.startCmd(), tick(), m.spin.Tick)
}

func tick() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) startCmd() tea.Cmd {
	base, script, extra := m.baseDir, m.script, m.extra
	return func() tea.Msg {
		eng, err := startEngine(program, base, script, extra)
		return engineStartedMsg{eng: eng, err: err}
	}
}

func (m *model) appendLine(s string) {
	m.lines = append(m.lines, s)
	if len(m.lines) > maxLogLines {
		m.lines = m.lines[len(m.lines)-maxLogLines:]
	}
	// Шаг - только строка с начала: строки с отступом (итог прошлого гейта в deploy) - справочные.
	if found := stepLine.FindStringSubmatch(strings.TrimRight(s, " ")); found != nil && !strings.HasPrefix(s, " ") {
		m.steps = append(m.steps, step{status: found[1], name: found[2]})
		m.markResult(found[1], found[2])
		// Шаг с внутренним трубопроводом закончился: колонка «Внутри» больше не нужна.
		if m.sub != nil && (samePrefix(found[2], m.sub.title) || samePrefix(m.sub.title, found[2])) {
			m.sub = nil
			m.layout()
		}
	}
	if strings.HasPrefix(strings.TrimSpace(s), "ВЕРДИКТ:") {
		m.verdict = strings.TrimSpace(s)
		m.markVerdict(m.verdict)
	}
}

func (m *model) refreshLog() {
	atBottom := m.logView.AtBottom()
	m.logView.SetContent(colorizeWrapped(m.lines, m.logView.Width))
	if m.follow || atBottom {
		m.logView.GotoBottom()
	}
}

func (m *model) layout() {
	// Шапка и подсказка - по строке, рамка журнала - ещё две, панель хода - пять.
	bodyHeight := m.height - 4
	if m.prog != nil {
		bodyHeight -= lipgloss.Height(m.viewProgress())
	}
	if bodyHeight < 3 {
		bodyHeight = 3
	}
	logWidth := m.width - 2
	if m.width >= minWidthForSteps {
		logWidth = m.width - stepsWidth - 2 - 1 - 2
	}
	if m.subWide() {
		logWidth -= subWidth + 2 + 1
	}
	m.logView.Width = max(20, logWidth)
	m.logView.Height = bodyHeight
	m.bar.Width = max(10, min(50, m.width-50))
	if m.dialog != nil {
		m.dialog.resize(m.width, m.height)
	}
}

func (m *model) openNextDialog() {
	if m.dialog == nil && len(m.queue) > 0 {
		ev := m.queue[0]
		m.queue = m.queue[1:]
		m.dialog = newDialog(ev, m.width, m.height)
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		// На столбец уже окна: консоль Windows переносит строку во всю ширину, и экран съезжает вниз.
		m.width, m.height = msg.Width-1, msg.Height
		m.layout()
		m.refreshLog()
		return m, nil

	case engineStartedMsg:
		if msg.err != nil {
			m.appendLine("Остановлено: " + msg.err.Error())
			m.running = false
			m.exitCode = -1
			m.refreshLog()
			return m, nil
		}
		m.eng = msg.eng
		m.running = true
		m.exitCode = 0
		m.exitErr = nil
		m.stopAsked = time.Time{}
		m.touchActive()
		return m, nil

	case lineMsg:
		m.appendLine(msg.text)
		m.refreshLog()
		return m, m.syncOverall()

	case eventMsg:
		ev := msg.ev
		switch ev.Kind {
		case "plan":
			m.setPlan(ev.Steps)
			return m, m.syncOverall()
		case "subplan":
			m.setSubPlan(ev)
			m.layout()
		case "progress":
			m.prog = &progressState{title: ev.Title, elapsed: ev.Elapsed, expected: ev.Expected, done: ev.Done, total: ev.Total, detail: ev.Detail, at: time.Now()}
			var cmds []tea.Cmd
			if ev.Title != m.barTitle {
				// Новый шаг - новая полоса: старая не должна «отъезжать» назад к нулю.
				m.barTitle = ev.Title
				m.bar = progress.New(progress.WithGradient("#5A56E0", "#3EC7A0"), progress.WithoutPercentage())
				m.markProgress(ev.Title)
				cmds = append(cmds, m.syncOverall())
			}
			m.layout()
			if f, ok := m.prog.fraction(); ok {
				cmds = append(cmds, m.bar.SetPercent(f))
			}
			return m, tea.Batch(cmds...)
		case "progress-end":
			m.prog = nil
			m.barTitle = ""
			m.layout()
		case "title":
			for _, l := range strings.Split(renderTitleBox(ev, m.logView.Width), "\n") {
				m.appendLine(l)
			}
			m.refreshLog()
		case "cancel":
			if m.dialog != nil && m.dialog.local == "" && m.dialog.ev.ID == ev.ID {
				m.appendLine("  › вопрос снят: условие выполнилось само")
				m.dialog = nil
				m.openNextDialog()
				m.refreshLog()
			}
		case "one", "many", "confirm", "text", "view":
			m.queue = append(m.queue, ev)
			m.openNextDialog()
		}
		return m, nil

	case exitMsg:
		m.running = false
		m.exitCode = msg.code
		m.exitErr = msg.err
		m.prog = nil
		if m.dialog != nil && m.dialog.local == "" {
			m.dialog = nil
		}
		m.queue = nil
		if m.eng != nil {
			m.eng.cleanup()
		}
		m.closeAll()
		m.layout()
		m.refreshLog()
		return m, m.syncOverall()

	case tickMsg:
		m.frame++
		// Полоса по ожидаемому времени ползёт сама: раз в полсекунды новая цель для пружины.
		if m.prog != nil && m.prog.total == 0 && m.frame%5 == 0 {
			if f, ok := m.prog.fraction(); ok {
				return m, tea.Batch(tick(), m.bar.SetPercent(f))
			}
		}
		return m, tick()

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case progress.FrameMsg:
		// У каждой полосы свой id: чужие кадры она пропускает.
		pm, cmd1 := m.bar.Update(msg)
		m.bar = pm.(progress.Model)
		om, cmd2 := m.overall.Update(msg)
		m.overall = om.(progress.Model)
		return m, tea.Batch(cmd1, cmd2)

	case tea.MouseMsg:
		if m.dialog == nil {
			var cmd tea.Cmd
			m.logView, cmd = m.logView.Update(msg)
			m.follow = m.logView.AtBottom()
			return m, cmd
		}
		return m, nil

	case tea.KeyMsg:
		if m.dialog != nil {
			cmd := m.dialog.Update(msg)
			if m.dialog.finished {
				m.finishDialog()
			}
			return m, cmd
		}
		return m.handleKey(msg)
	}
	return m, nil
}

func (m *model) finishDialog() {
	d := m.dialog
	m.dialog = nil
	if d.local == "stop" {
		if !d.result.Cancel && d.result.Yes && m.eng != nil && m.running {
			if err := m.eng.requestStop(); err != nil {
				m.notice = "не смог попросить остановку: " + err.Error()
			} else {
				m.stopAsked = time.Now()
				m.notice = "просьба остановиться отправлена: скрипт снимет блокировки и остановится"
			}
		}
		m.openNextDialog()
		return
	}
	if m.eng != nil {
		if err := m.eng.answerQuestion(d.ev.ID, d.result); err != nil {
			m.appendLine("Ответ не записался: " + err.Error())
		}
	}
	m.appendLine("  › " + describeAnswer(d))
	m.refreshLog()
	m.openNextDialog()
}

func describeAnswer(d *dialog) string {
	if d.result.Cancel {
		return "отмена"
	}
	switch d.ev.Kind {
	case "one":
		if d.result.Index >= 0 && d.result.Index < len(d.ev.Items) {
			return d.ev.Items[d.result.Index]
		}
	case "many":
		var names []string
		for _, i := range d.result.Indexes {
			names = append(names, d.ev.Items[i])
		}
		return "отмечено: " + strings.Join(names, "; ")
	case "confirm":
		if d.result.Yes {
			return nonEmpty(d.ev.Yes, "Да")
		}
		return nonEmpty(d.ev.No, "Нет")
	case "text":
		return "введено: " + d.result.Text
	case "view":
		return "просмотр закрыт"
	}
	return "ответ отправлен"
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		if !m.running {
			return m, tea.Quit
		}
		if !m.stopAsked.IsZero() && time.Since(m.stopAsked) > 20*time.Second {
			m.notice = "скрипт не остановился сам: k - снять процесс (блокировки тогда снимать руками)"
			return m, nil
		}
		d := newDialog(uiEvent{Kind: "confirm", Header: "Остановить скрипт? Он снимет свои блокировки и остановится; процесс 1С, если идёт, может доработать.", Yes: "Остановить", No: "Продолжить"}, m.width, m.height)
		d.local = "stop"
		d.yes = false
		m.dialog = d
		return m, nil
	case "k":
		if m.running && !m.stopAsked.IsZero() && time.Since(m.stopAsked) > 20*time.Second {
			m.eng.kill()
			m.notice = "процесс снят. Проверь блокировки базы в консоли кластера"
		}
		return m, nil
	case "enter", "r":
		if !m.running {
			m.lines = nil
			m.steps = nil
			m.pipe = nil
			m.sub = nil
			m.planned = false
			m.overall = newOverallBar()
			m.verdict = ""
			m.notice = ""
			m.refreshLog()
			return m, m.startCmd()
		}
		return m, nil
	case "f":
		m.follow = true
		m.logView.GotoBottom()
		return m, nil
	}
	var cmd tea.Cmd
	m.logView, cmd = m.logView.Update(msg)
	m.follow = m.logView.AtBottom()
	return m, cmd
}

// ---------------------------------------------------------------------------------------------------------------

const stepsWidth = 36

// minWidthForSteps - уже этого панель шагов прячется: крупный шрифт делает окно уже в символах.
const minWidthForSteps = 96

func (m model) View() string {
	if m.width == 0 {
		return "запуск…"
	}
	header := m.viewHeader()
	body := m.viewBody()
	var panel string
	if m.prog != nil {
		panel = m.viewProgress()
	}
	footer := m.viewFooter()
	screen := lipgloss.JoinVertical(lipgloss.Left, header, body, panel, footer)
	if m.dialog != nil {
		return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, m.dialog.View(),
			lipgloss.WithWhitespaceChars(" "))
	}
	return screen
}

func (m model) viewHeader() string {
	left := styleHeader.Render(" CI · гейт и обновление расширений ")
	state := ""
	switch {
	case m.running && !m.stopAsked.IsZero():
		state = styleWarn.Render(" останавливается ")
	case m.running:
		state = styleOk.Render(" " + m.spin.View() + " работает ")
	case m.exitCode == 0:
		state = styleOk.Render(" готово ")
	default:
		state = styleBad.Render(fmt.Sprintf(" завершился с кодом %d ", m.exitCode))
	}
	if m.verdict != "" {
		// В шапке - только цвет вердикта, весь текст - в журнале.
		short := m.verdict
		if i := strings.Index(short, "."); i > 0 {
			short = short[:i]
		}
		state += " " + verdictStyle(m.verdict).Render(" "+short+" ")
	}
	clock := styleDim.Render(time.Now().Format("15:04:05") + " ")
	gap := m.width - lipgloss.Width(left) - lipgloss.Width(state) - lipgloss.Width(clock)
	if gap < 1 {
		gap = 1
	}
	return left + state + strings.Repeat(" ", gap) + clock
}

func (m model) viewBody() string {
	logBox := styleLog.Render(m.logView.View())
	if m.width < minWidthForSteps {
		return logBox
	}
	content := m.viewPipe(stepsWidth-4, m.logView.Height)
	steps := styleSteps.Width(stepsWidth - 2).Height(m.logView.Height).Render(strings.TrimRight(content, "\n"))
	if m.subWide() {
		sub := styleSub.Width(subWidth).Height(m.logView.Height).Render(m.viewSub(subWidth-2, m.logView.Height))
		return lipgloss.JoinHorizontal(lipgloss.Top, steps, " ", sub, " ", logBox)
	}
	return lipgloss.JoinHorizontal(lipgloss.Top, steps, " ", logBox)
}

func stepIcon(status string) string {
	switch status {
	case "OK":
		return styleOk.Render("√")
	case "WARN":
		return styleWarn.Render("!")
	case "FAIL":
		return styleBad.Render("×")
	default:
		return styleDim.Render("–")
	}
}

func (m model) viewProgress() string {
	p := m.prog
	elapsed := p.elapsed + time.Since(p.at).Seconds()
	var bar, percent, timeText string
	timeText = formatDuration(elapsed)
	switch {
	case p.total > 0 && p.done >= 0:
		fraction := float64(p.done) / float64(p.total)
		bar = m.bar.View()
		percent = fmt.Sprintf("%3d%%", int(fraction*100))
		if p.expected > 0 {
			timeText += " / ~" + formatDuration(p.expected)
		}
	case p.expected > 0 && elapsed < p.expected:
		fraction := elapsed / p.expected
		if fraction > 0.99 {
			fraction = 0.99
		}
		bar = m.bar.View()
		percent = fmt.Sprintf("~%2d%%", int(fraction*100))
		timeText += " / ~" + formatDuration(p.expected)
	default:
		bar = bounceBar(m.bar.Width, m.frame)
		percent = "    "
		if p.expected > 0 {
			timeText += ", план ~" + formatDuration(p.expected) + ", дольше на " + formatDuration(elapsed-p.expected)
		}
	}
	line1 := hang(m.spin.View()+" ", p.title, m.width-6-lipgloss.Width(timeText)-2, styleProgressTitle)
	line1 = lipgloss.JoinHorizontal(lipgloss.Top, line1, "  ", styleDim.Render(timeText))
	line2 := bar + " " + percent
	detail := p.detail
	if detail == "" && p.total == 0 && p.expected == 0 {
		detail = idleCaption(m.frame)
	}
	line3 := wrapBlock(detail, m.width-6, styleDim)
	return styleProgressBox.Width(m.width - 2).Render(line1 + "\n" + line2 + "\n" + line3)
}

func (m model) viewFooter() string {
	var help string
	switch {
	case m.dialog != nil:
		help = ""
	case m.running:
		help = "↑↓ PgUp PgDn журнал · f к концу · q остановить скрипт"
		if !m.stopAsked.IsZero() && time.Since(m.stopAsked) > 20*time.Second {
			help += " · k снять процесс"
		}
	default:
		help = "enter снова в меню · q выход · ↑↓ журнал"
	}
	text := styleHelp.Render(" " + help)
	if m.notice != "" {
		text += "  " + styleWarn.Render(m.notice)
	}
	return text
}

// ---------------------------------------------------------------------------------------------------------------

func formatDuration(seconds float64) string {
	if seconds < 0 {
		seconds = 0
	}
	total := int(seconds + 0.5)
	h, mnt, s := total/3600, (total%3600)/60, total%60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, mnt, s)
	}
	return fmt.Sprintf("%d:%02d", mnt, s)
}

// bounceBar - бегающий блок, когда сколько осталось неизвестно.
func bounceBar(width, frame int) string {
	if width < 10 {
		width = 10
	}
	span := width + 4
	pos := frame % (2 * span)
	if pos >= span {
		pos = 2*span - pos - 1
	}
	pos -= 2
	shape := []string{"░", "▒", "▓", "█", "▓", "▒", "░"}
	var b strings.Builder
	for i := 0; i < width; i++ {
		k := i - pos + 3
		if k >= 0 && k < len(shape) {
			b.WriteString(styleAccent.Render(shape[k]))
		} else {
			b.WriteString(styleTrack.Render("·"))
		}
	}
	return b.String()
}

var idleCaptions = []string{"конфигуратор работает", "SQL шуршит", "сервер 1С занят делом", "платформа думает", "ещё немного"}

func idleCaption(frame int) string {
	return idleCaptions[(frame/40)%len(idleCaptions)]
}

func renderTitleBox(ev uiEvent, width int) string {
	style := styleTitleInfo
	switch ev.Style {
	case "ok":
		style = styleTitleOk
	case "warn":
		style = styleTitleWarn
	case "bad":
		style = styleTitleBad
	}
	body := ev.Text
	for _, l := range ev.More {
		body += "\n" + l
	}
	w := max(30, min(width-4, 100))
	return style.Width(w).Render(body)
}

func colorizeLines(lines []string) string {
	var b strings.Builder
	for i, l := range lines {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(colorizeLine(l))
	}
	return b.String()
}

func colorizeLine(l string) string {
	if strings.Contains(l, "\x1b[") {
		return l
	}
	if st, ok := lineStyle(l); ok {
		return st.Render(l)
	}
	return l
}

// lineStyle - цвет строки журнала по её началу; false - без цвета.
func lineStyle(l string) (lipgloss.Style, bool) {
	t := strings.TrimSpace(l)
	switch {
	case strings.HasPrefix(t, "ВЕРДИКТ: ЗЕЛЁН"), strings.HasPrefix(t, "ИТОГ: обновлено"):
		return styleOkBold, true
	case strings.HasPrefix(t, "ВЕРДИКТ: ЖЁЛТ"):
		return styleWarnBold, true
	case strings.HasPrefix(t, "ВЕРДИКТ: КРАСН"), strings.HasPrefix(t, "Остановлено"), strings.HasPrefix(t, "ИТОГ:"), strings.HasPrefix(t, "НЕ СНЯЛ"):
		return styleBadBold, true
	case strings.HasPrefix(t, "[OK"), strings.HasPrefix(t, "[ИСПР]"):
		return styleOk, true
	case strings.HasPrefix(t, "[FAIL"), strings.HasPrefix(t, "[КРАСН]"), strings.HasPrefix(t, "нельзя:"), strings.HasPrefix(t, "не советую:"), strings.HasPrefix(t, "ПРОВЕРИТЬ"):
		return styleBad, true
	case strings.HasPrefix(t, "[WARN"), strings.HasPrefix(t, "[ЖЁЛТ]"), strings.HasPrefix(t, "[ВНИМ]"):
		return styleWarn, true
	case strings.HasPrefix(t, "["):
		return styleDim, true
	case strings.HasPrefix(t, "..."), strings.HasPrefix(t, "› "):
		return styleDim, true
	case strings.HasPrefix(t, "можно:"):
		return styleOk, true
	}
	return lipgloss.Style{}, false
}

func verdictStyle(v string) lipgloss.Style {
	switch {
	case strings.Contains(v, "ЗЕЛЁН"):
		return styleBadgeOk
	case strings.Contains(v, "ЖЁЛТ"):
		return styleBadgeWarn
	default:
		return styleBadgeBad
	}
}

// fraction - доля для полосы хода: по счётчику заданий или по ожидаемому времени. false - неизвестно сколько.
func (p *progressState) fraction() (float64, bool) {
	if p.total > 0 && p.done >= 0 {
		return float64(p.done) / float64(p.total), true
	}
	if p.expected > 0 {
		f := (p.elapsed + time.Since(p.at).Seconds()) / p.expected
		if f > 0.99 {
			f = 0.99
		}
		return f, true
	}
	return 0, false
}

// syncOverall - общая полоса плана догоняет долю пройденных шагов.
func (m *model) syncOverall() tea.Cmd {
	if len(m.pipe) == 0 {
		return nil
	}
	return m.overall.SetPercent(m.pipeFraction())
}
