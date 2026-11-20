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
	"github.com/charmbracelet/x/ansi"
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

// runEta - оценка, сколько осталось всего прогона: секунды на момент at и шаги без статистики.
type runEta struct {
	seconds float64
	unknown int
	at      time.Time
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
	starting  bool
	running   bool
	exitCode  int
	exitErr   error
	lines     []string
	steps     []step
	pipe      []pipeNode
	parallel  map[string]bool // шаги плана, которые идут параллельно остальным (событие plan)
	planned   bool
	overall   progress.Model
	barTitle  string
	sub       *subState
	verdict   string
	logView   viewport.Model
	follow    bool
	prog      *progressState
	eta       *runEta
	started   time.Time
	bar       progress.Model
	spin      spinner.Model
	dialog    *dialog
	queue     []uiEvent
	frame     int
	width     int
	height    int
	stopAsked time.Time
	notice    string

	// ** Хлебников С.Ю. 20261120 Для шапки (#32): с какой базой работает скрипт (событие context) и когда от него
	// было последнее сообщение - строка или событие. Видно и в узком окне, где нет колонки шагов.
	context    string
	lastOutput time.Time

	// Скрипт попросил закрыть ci, когда кончится (событие close: гейт обновлён, а работает ещё прежний);
	// restartAfter - и сразу открыть ci заново: в папке гейта уже новый ci.exe.
	closeAfter   bool
	restartAfter bool
	// planOps - план колонки шагов прислан как план долгих операций (событие plan с ops): шаги закрывает
	// событие step, узла «Вердикт» нет.
	planOps bool
}

func newModel(baseDir, script string, extra []string) model {
	sp := spinner.New()
	// Брайлевских точек MiniDot в Consolas нет: пульсирующий блок из CP437.
	sp.Spinner = spinner.Spinner{Frames: []string{"░", "▒", "▓", "█", "▓", "▒"}, FPS: time.Second / 8}
	sp.Style = styleAccent
	bar := progress.New(progress.WithGradient("#5A56E0", "#3EC7A0"), progress.WithoutPercentage())
	return model{
		baseDir:  baseDir,
		script:   script,
		extra:    extra,
		starting: true,
		follow:   true,
		logView:  viewport.New(80, 20),
		bar:      bar,
		overall:  newOverallBar(),
		spin:     sp,
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
		eng, err := startEngine(base, script, extra)
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
	if m.dialog != nil && m.dialog.docked() {
		// Полоса вопроса встаёт на место строки подсказки.
		bodyHeight -= lipgloss.Height(m.dialog.ViewDocked(m.width)) - 1
	} else {
		// Подсказка внизу переносится: каждая лишняя строка - у журнала.
		bodyHeight -= lipgloss.Height(m.viewFooter()) - 1
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
	wasDocked := m.dialog != nil && m.dialog.docked()
	wasFooter := lipgloss.Height(m.viewFooter())
	next, cmd := m.update(msg)
	nm := next.(model)
	nowDocked := nm.dialog != nil && nm.dialog.docked()
	if nowDocked == wasDocked && !nowDocked && lipgloss.Height(nm.viewFooter()) != wasFooter {
		nm.layout()
		nm.refreshLog()
	}
	if nowDocked != wasDocked {
		// Полоса вопроса появилась или ушла: журнал меняет высоту; на появлении - к концу журнала, к итогу.
		nm.layout()
		nm.refreshLog()
		if nowDocked {
			nm.follow = true
			nm.logView.GotoBottom()
		}
	}
	return nm, cmd
}

func (m model) update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		// На столбец уже окна: консоль Windows переносит строку во всю ширину, и экран съезжает вниз.
		m.width, m.height = msg.Width-1, msg.Height
		m.layout()
		m.refreshLog()
		return m, nil

	case engineStartedMsg:
		m.starting = false
		if msg.err != nil {
			m.appendLine("Остановлено: " + msg.err.Error())
			m.running = false
			m.exitCode = -1
			m.refreshLog()
			return m, nil
		}
		m.eng = msg.eng
		m.running = true
		m.started = msg.eng.started
		m.exitCode = 0
		m.exitErr = nil
		m.stopAsked = time.Time{}
		m.closeAfter = false
		m.restartAfter = false
		m.touchActive()
		return m, func() tea.Msg { return msg.eng.wait(program) }

	case lineMsg:
		m.lastOutput = time.Now()
		m.appendLine(msg.text)
		m.refreshLog()
		return m, m.syncOverall()

	case eventMsg:
		ev := msg.ev
		m.lastOutput = time.Now()
		switch ev.Kind {
		case "context":
			m.context = ev.Text
		case "plan":
			m.setPlan(ev.Steps, ev.Parallel, ev.Ops)
			return m, m.syncOverall()
		case "reset":
			m.resetRun()
			m.layout()
		case "close":
			m.closeAfter = true
			m.restartAfter = ev.Restart
		case "step":
			// Долгая операция кончилась. У действия без своего плана шагов (выгрузка в git, типовая, сравнения)
			// она встаёт в колонку шагов с итогом и временем; с планом колонку ведут план и строки [OK]/[FAIL].
			m.addOperation(ev.Title, ev.Status, ev.Elapsed)
			return m, m.syncOverall()
		case "subplan":
			m.setSubPlan(ev)
			m.layout()
		case "progress":
			m.prog = &progressState{title: ev.Title, elapsed: ev.Elapsed, expected: ev.Expected, done: ev.Done, total: ev.Total, detail: ev.Detail, at: time.Now()}
			if ev.Remaining != nil && *ev.Remaining >= 0 {
				m.eta = &runEta{seconds: *ev.Remaining, unknown: ev.RemainingUnknown, at: time.Now()}
			}
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
			m.eng = nil
		}
		m.closeAll()
		if m.closeAfter && msg.code == 0 {
			// Скрипт просил закрыть ci (после обновления гейта) и кончился без ошибки. С ошибкой экран остаётся:
			// её нужно прочитать.
			return m, tea.Quit
		}
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
		if m.dialog != nil && m.dialog.docked() && msg.Button == tea.MouseButtonLeft {
			// Полоса вопроса внизу: щелчок - по её кнопкам; колесо остаётся журналу.
			return m.dialogMouse(m.dockedMouse(msg))
		}
		if m.dialog == nil || m.dialog.docked() {
			var cmd tea.Cmd
			m.logView, cmd = m.logView.Update(msg)
			m.follow = m.logView.AtBottom()
			return m, cmd
		}
		// Окно поверх: мышь - ему (щелчок по пункту, колесо, правая кнопка в поле ввода - вставка).
		return m.dialogMouse(m.overlayMouse(msg))

	case tea.KeyMsg:
		if msg.String() == "f2" {
			// Весь журнал - в буфер обмена. Мышь у ci.exe занята прокруткой и щелчками по пунктам, поэтому выделить
			// текст в окне, как в обычной консоли, нельзя. Работает и при открытом вопросе.
			m.copyLog()
			return m, nil
		}
		if m.dialog != nil && m.dialog.docked() {
			switch msg.String() {
			case "up", "down", "pgup", "pgdown", "home", "end":
				var cmd tea.Cmd
				m.logView, cmd = m.logView.Update(msg)
				m.follow = m.logView.AtBottom()
				return m, cmd
			}
		}
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

// dialogMouse - мышь окну вопроса; щелчок мог закончить вопрос, как Enter.
func (m model) dialogMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	cmd := m.dialog.Update(msg)
	if m.dialog.finished {
		m.finishDialog()
	}
	return m, cmd
}

// centerOffset - отступ блока по центру, как у lipgloss.Place (Center). Блок выше окна: Bubble Tea
// срезает лишние строки сверху - отступ отрицательный (для столбцов вызывающий берёт не меньше нуля).
func centerOffset(total, size int) int {
	gap := total - size
	if gap < 0 {
		return gap
	}
	return gap / 2
}

// overlayMouse - координаты мыши внутри окна вопроса посреди экрана (без рамки и полей).
func (m model) overlayMouse(msg tea.MouseMsg) tea.MouseMsg {
	d := m.dialog
	msg.X -= max(0, centerOffset(m.width, d.boxW)) + styleDialog.GetBorderLeftSize() + styleDialog.GetPaddingLeft()
	msg.Y -= centerOffset(m.height, d.boxH) + styleDialog.GetBorderTopSize() + styleDialog.GetPaddingTop()
	return msg
}

// dockedMouse - координаты мыши внутри полосы вопроса внизу (без рамки и полей).
func (m model) dockedMouse(msg tea.MouseMsg) tea.MouseMsg {
	var panel string
	if m.prog != nil {
		panel = m.viewProgress()
	}
	top := lipgloss.Height(lipgloss.JoinVertical(lipgloss.Left, m.viewHeader(), m.viewBody(), panel))
	if total := top + lipgloss.Height(m.dialog.ViewDocked(m.width)); total > m.height {
		top -= total - m.height
	}
	msg.X -= styleDocked.GetBorderLeftSize() + styleDocked.GetPaddingLeft()
	msg.Y -= top + styleDocked.GetBorderTopSize() + styleDocked.GetPaddingTop()
	return msg
}

func (m *model) finishDialog() {
	d := m.dialog
	m.dialog = nil
	if d.local == "stop" {
		if !d.result.Cancel && d.result.Yes && m.eng != nil && m.running {
			if err := m.eng.requestStop(); err != nil {
				// Просьба не дошла - ждать нечего: снять процесс можно сразу.
				m.stopAsked = time.Now().Add(-time.Minute)
				m.appendLine("Не смог попросить остановку: " + err.Error())
				m.notice = "просьба остановиться не дошла: k - снять процесс (блокировки тогда снимать руками)"
				m.refreshLog()
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
			m.appendLine("Скрипт ждёт ответа и сам не пойдёт дальше: q - остановить, k - снять процесс.")
			m.stopAsked = time.Now().Add(-time.Minute)
			m.notice = "ответ не дошёл до скрипта: q - остановить, k - снять процесс"
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
		if d.ev.Secret {
			// Пароль и токен в журнал не пишутся - ни сами, ни их длина.
			return "введено: ***"
		}
		return "введено: " + d.result.Text
	case "view":
		return "просмотр закрыт"
	}
	return "ответ отправлен"
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		if m.starting {
			return m, nil
		}
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
	case "enter", "r", "esc":
		// Прогон кончился: снова главное меню гейта. Esc - так же, как Enter: привычнее.
		if !m.starting && !m.running {
			m.starting = true
			m.lines = nil
			m.resetRun()
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
	if m.dialog != nil && m.dialog.docked() {
		footer = m.dialog.ViewDocked(m.width)
	}
	screen := lipgloss.JoinVertical(lipgloss.Left, header, body, panel, footer)
	if m.dialog != nil && !m.dialog.docked() {
		return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, m.dialog.View(),
			lipgloss.WithWhitespaceChars(" "))
	}
	return screen
}

func (m model) viewHeader() string {
	title := " CI · гейт и обновление расширений "
	if m.width < minWidthForSteps {
		title = " CI "
	}
	left := styleHeader.Render(title)
	if m.context != "" {
		left += styleAccent.Render(" " + m.context + " ")
	}
	state := ""
	switch {
	case m.running && !m.stopAsked.IsZero():
		state = styleWarn.Render(" останавливается ")
	case m.running && m.dialog != nil:
		state = styleWarn.Render(" ждёт ответа ")
	case m.running:
		state = styleOk.Render(" " + m.spin.View() + " работает ")
	case m.starting:
		state = styleAccent.Render(" запускается ")
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
	// Скрипт давно молчит - когда было последнее сообщение; вывода «завис» нет: тихий шаг бывает и долгим.
	if quiet := m.quietText(time.Now()); quiet != "" {
		clock = styleDim.Render(quiet+" · ") + clock
	}
	gap := m.width - lipgloss.Width(left) - lipgloss.Width(state) - lipgloss.Width(clock)
	if gap < 1 {
		gap = 1
	}
	return left + state + strings.Repeat(" ", gap) + clock
}

// quietText - «посл. сообщение 03:12 (5 мин)», если скрипт работает и молчит дольше минуты; иначе пусто.
func (m model) quietText(now time.Time) string {
	if !m.running || m.lastOutput.IsZero() {
		return ""
	}
	silent := now.Sub(m.lastOutput)
	if silent < time.Minute {
		return ""
	}
	return fmt.Sprintf("посл. сообщение %s (%d мин)", m.lastOutput.Format("15:04"), int(silent.Minutes()))
}

// ** Хлебников С.Ю. 20261120 конец

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

// copyLog - весь журнал (то, что в окне справа, без раскраски) в буфер обмена; итог - строкой подсказки.
func (m *model) copyLog() {
	lines := make([]string, len(m.lines))
	for i, l := range m.lines {
		lines[i] = ansi.Strip(l)
	}
	if err := writeClipboard(strings.Join(lines, "\r\n")); err != nil {
		m.notice = "журнал в буфер обмена не скопировался: " + err.Error()
		return
	}
	m.notice = fmt.Sprintf("журнал в буфере обмена: строк %d", len(lines))
}

func (m model) viewFooter() string {
	var help string
	switch {
	case m.dialog != nil || m.starting:
		help = ""
	case m.running:
		help = "↑↓ PgUp PgDn журнал · f к концу · F2 журнал в буфер обмена · q остановить скрипт"
		if !m.stopAsked.IsZero() && time.Since(m.stopAsked) > 20*time.Second {
			help += " · k снять процесс"
		}
	default:
		help = "enter или esc снова в меню · q выход · ↑↓ журнал · F2 журнал в буфер обмена"
	}
	// Строки подсказки не обрезаются: не влезает - переносится. Версия сборки - в правом нижнем углу.
	width := max(20, m.width)
	var lines []string
	if help != "" {
		lines = append(lines, strings.Split(wrapBlock(" "+help, width-1, styleHelp), "\n")...)
	}
	if m.notice != "" {
		lines = append(lines, strings.Split(wrapBlock(" "+m.notice, width-1, styleWarn), "\n")...)
	}
	if len(lines) == 0 {
		lines = []string{""}
	}
	ver := styleHelp.Render("ci " + version + " ")
	last := lines[len(lines)-1]
	if gap := width - lipgloss.Width(last) - lipgloss.Width(ver); gap >= 2 {
		lines[len(lines)-1] = last + strings.Repeat(" ", gap) + ver
	} else {
		lines = append(lines, strings.Repeat(" ", max(0, width-lipgloss.Width(ver)))+ver)
	}
	return strings.Join(lines, "\n")
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

// Подписи под полосой хода, когда у операции нет своих подробностей: любая долгая операция (конфигуратор,
// клиент 1С, git), поэтому без имён - «сервер 1С занят делом» при отправке в GitHub сбивало с толку.
var idleCaptions = []string{"работа идёт", "жду, пока закончит", "процесс жив", "ещё немного"}

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
