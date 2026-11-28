package main

// Окна вопросов: один пункт, несколько пунктов, да/нет, текст, просмотр длинного текста.

import (
	"errors"
	"fmt"
	"strings"
	"syscall"

	"github.com/atotto/clipboard"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// readClipboard - текст из буфера обмена Windows (в тестах подменяется).
var readClipboard = clipboard.ReadAll

// writeClipboard - текст в буфер обмена Windows (в тестах подменяется).
var writeClipboard = clipboard.WriteAll

type dialog struct {
	ev       uiEvent
	local    string // не пусто - вопрос самого ci.exe (например, журнал тестов), не движка
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

	copyNotice string
	// Где пункты и кнопки по последней отрисовке (для мыши): строки и столбцы внутри окна.
	hits     []hitArea
	dockHits []hitArea
	boxW     int
	boxH     int
	// armed - опасный пункт, по которому уже щёлкнули один раз (второй щелчок - выбор); -1 - нет.
	armed int
}

// hitArea - место пункта или кнопки: строки [y0, y1), столбцы [x0, x1); x1 = 0 - вся ширина.
type hitArea struct {
	y0, y1 int
	x0, x1 int
	index  int
}

// hotkeys - клавиши пунктов списка: 1-9, потом a-z, как в консоли без ci.exe.
const hotkeys = "123456789abcdefghijklmnopqrstuvwxyz"

// ruToLat - русская раскладка: буква на той же клавише, что латинская (ф - это a).
var ruToLat = map[rune]rune{
	'й': 'q', 'ц': 'w', 'у': 'e', 'к': 'r', 'е': 't', 'н': 'y', 'г': 'u', 'ш': 'i', 'щ': 'o', 'з': 'p',
	'ф': 'a', 'ы': 's', 'в': 'd', 'а': 'f', 'п': 'g', 'р': 'h', 'о': 'j', 'л': 'k', 'д': 'l',
	'я': 'z', 'ч': 'x', 'с': 'c', 'м': 'v', 'и': 'b', 'т': 'n', 'ь': 'm',
}

// hotkeyLabel - клавиша пункта i; "" - у пункта клавиши нет (дальше 35-го).
func hotkeyLabel(i int) string {
	if i < 0 || i >= len(hotkeys) {
		return ""
	}
	return string(hotkeys[i])
}

// hotkeyIndex - номер пункта по нажатой клавише в любой раскладке; -1 - не клавиша пункта.
func hotkeyIndex(s string) int {
	r := []rune(strings.ToLower(s))
	if len(r) != 1 {
		return -1
	}
	c := r[0]
	if lat, ok := ruToLat[c]; ok {
		c = lat
	}
	return strings.IndexRune(hotkeys, c)
}

// customKeys - у пунктов свои клавиши (вопрос one с keys, по одной на пункт): клавиша пункта не зависит от того,
// какие пункты сейчас показаны выше него (меню гейта).
func (d *dialog) customKeys() bool {
	return d.ev.Kind == "one" && len(d.ev.Keys) > 0 && len(d.ev.Keys) == len(d.ev.Items)
}

// itemKey - клавиша пункта i: своя или порядковая; "" - клавиши нет.
func (d *dialog) itemKey(i int) string {
	if d.customKeys() {
		return strings.ToLower(d.ev.Keys[i])
	}
	return hotkeyLabel(i)
}

// keyItem - номер пункта по нажатой клавише в любой раскладке; -1 - не клавиша пункта.
func (d *dialog) keyItem(s string) int {
	k := hotkeyIndex(s)
	if k < 0 {
		return -1
	}
	if !d.customKeys() {
		if k < len(d.ev.Items) {
			return k
		}
		return -1
	}
	pressed := string(hotkeys[k])
	for i, key := range d.ev.Keys {
		if strings.ToLower(key) == pressed {
			return i
		}
	}
	return -1
}

// innerWidth - ширина текста внутри окна вопроса.
func (d *dialog) innerWidth() int {
	return max(30, min(d.width-6, 110))
}

// itemHint - пояснение пункта i (вопрос one с hints): переменное и подробности серым рядом с подписью, сама
// подпись при этом не меняется; "" - нет.
func (d *dialog) itemHint(i int) string {
	if d.ev.Kind != "one" || d.docked() || len(d.ev.Hints) != len(d.ev.Items) || i < 0 || i >= len(d.ev.Items) {
		return ""
	}
	return d.ev.Hints[i]
}

// itemRows - сколько строк занимает пункт i в списке выбора одного: длинная подпись и пояснение, не влезшее в
// строку, переносятся. Опасный пункт (рамка) и отметки считаются одной строкой, как раньше.
func (d *dialog) itemRows(i int) int {
	if d.ev.Kind != "one" || d.docked() || d.isDanger(i) || i < 0 || i >= len(d.ev.Items) {
		return 1
	}
	prefix := "  "
	if k := d.itemKey(i); k != "" {
		prefix += k + " "
	}
	return lipgloss.Height(hangHint(prefix, d.ev.Items[i], d.itemHint(i), d.innerWidth(), lipgloss.NewStyle()))
}

// sectionTitle - заголовок группы, которая начинается с пункта i (вопрос one с sections); "" - нет.
func (d *dialog) sectionTitle(i int) string {
	if d.ev.Kind != "one" || d.docked() || len(d.ev.Sections) != len(d.ev.Items) || i < 0 || i >= len(d.ev.Items) {
		return ""
	}
	return d.ev.Sections[i]
}

// sectionOf - заголовок группы, в которую входит пункт i: его собственный или ближайший выше.
func (d *dialog) sectionOf(i int) string {
	for ; i >= 0; i-- {
		if title := d.sectionTitle(i); title != "" {
			return title
		}
	}
	return ""
}

// windowEnd - до какого пункта (не включая) список влезает в окно, если первый видимый - offset. Пункт - строка
// (с переносами - больше, itemRows), заголовок группы - ещё одна; над первым видимым пунктом заголовок его
// группы стоит всегда.
func (d *dialog) windowEnd(offset int) int {
	rows := d.visibleRows()
	used := 0
	i := offset
	for ; i < len(d.ev.Items); i++ {
		cost := d.itemRows(i)
		if (i == offset && d.sectionOf(i) != "") || (i != offset && d.sectionTitle(i) != "") {
			cost++
		}
		if used+cost > rows && i > offset {
			break
		}
		used += cost
	}
	return i
}

func newDialog(ev uiEvent, width, height int) *dialog {
	d := &dialog{ev: ev, marks: map[int]bool{}, yes: !ev.DefaultNo, armed: -1}
	for _, i := range ev.Preselected {
		if i >= 0 && i < len(ev.Items) && len(d.clashing(i)) == 0 {
			d.marks[i] = true
		}
	}
	if ev.Kind == "one" && len(ev.Preselected) > 0 && ev.Preselected[0] >= 0 && ev.Preselected[0] < len(ev.Items) {
		// Пункт, на котором стоит выбор сразу (обычно самый безопасный).
		d.cursor = ev.Preselected[0]
	}
	if ev.Kind == "text" {
		ti := textinput.New()
		ti.Prompt = "› "
		ti.CharLimit = 500
		// Вставка - своя (pasteClipboard): у поля она приходит отдельным сообщением, которое терялось.
		ti.KeyMap.Paste.SetEnabled(false)
		ti.SetValue(ev.Value)
		ti.CursorEnd()
		if ev.Secret {
			ti.EchoMode = textinput.EchoPassword
			ti.EchoCharacter = '•'
		}
		ti.Focus()
		d.input = ti
	}
	if ev.Kind == "view" || d.sessionList() {
		d.view = viewport.New(10, 10)
		d.view.SetContent(colorizeWrapped(ev.Lines, max(20, width-8)))
	}
	d.resize(width, height)
	return d
}

func (d *dialog) sessionList() bool {
	return d.ev.Kind == "one" && len(d.ev.Lines) > 0
}

func (d *dialog) resize(width, height int) {
	d.width = width
	d.height = height
	if d.ev.Kind == "view" {
		d.view.Width = max(20, width-8)
		d.view.Height = max(5, height-8)
		d.view.SetContent(colorizeWrapped(d.ev.Lines, d.view.Width))
	}
	if d.sessionList() {
		d.view.Width = max(1, d.innerWidth())
		content := colorizeWrapped(d.ev.Lines, d.view.Width)
		fixed := 9 + lipgloss.Height(styleDialogTitle.Width(d.view.Width).Render(d.ev.Header))
		for i := range d.ev.Items {
			fixed += d.itemRows(i)
		}
		d.view.Height = max(1, min(lipgloss.Height(content), height-fixed))
		d.view.SetContent(content)
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
	if mouse, isMouse := msg.(tea.MouseMsg); isMouse {
		return d.mouse(mouse)
	}
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
	if d.sessionList() && (s == "pgup" || s == "pgdown" || s == "home" || s == "end") {
		switch s {
		case "home":
			d.view.GotoTop()
		case "end":
			d.view.GotoBottom()
		default:
			d.view, _ = d.view.Update(msg)
		}
		return nil
	}
	switch d.ev.Kind {
	case "one", "many":
		n := len(d.ev.Items)
		if d.docked() {
			// Кнопки внизу - в ряд: ←→ и Tab двигают выбор (↑↓ листают журнал).
			switch s {
			case "left", "shift+tab":
				s = "up"
			case "right", "tab":
				s = "down"
			}
		}
		if d.ev.Kind == "one" {
			// Цифрой или буквой (1-9, a-z, в русской раскладке - те же клавиши) - сразу выбрать пункт.
			if k := d.keyItem(s); k >= 0 {
				d.cursor = k
				d.finish(answer{Index: k})
				return nil
			}
		}
		if d.ev.Kind == "many" {
			// j/k - только в отметках: в выборе одного буквы - клавиши пунктов.
			switch s {
			case "k":
				s = "up"
			case "j":
				s = "down"
			}
		}
		switch s {
		case "up":
			if d.cursor > 0 {
				d.cursor--
			} else {
				d.cursor = n - 1
			}
		case "down":
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
				d.toggle(d.cursor)
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
				if len(sel) == 0 && d.ev.AllowEmpty {
					// Скрипт разрешил пустой выбор (например, «какие обработки записать» - ни одной).
					d.finish(answer{Indexes: []int{}, Index: -1})
				} else if len(sel) == 0 {
					d.warning = "ничего не отмечено: пробел ставит отметку"
				} else {
					d.finish(answer{Indexes: sel, Index: -1})
				}
			}
		}
		if d.cursor < d.offset {
			d.offset = d.cursor
		}
		if d.armed != d.cursor {
			d.armed = -1
		}
		// Заголовки групп занимают строки: окно считает windowEnd, а не число пунктов.
		for d.offset < d.cursor && d.cursor >= d.windowEnd(d.offset) {
			d.offset++
		}
	case "confirm":
		switch s {
		case "left", "right", "tab", "h", "l":
			d.yes = !d.yes
			d.armed = -1
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
		case "ctrl+v":
			d.pasteClipboard()
		default:
			if key.Paste {
				// Вставка, которую прислал сам терминал (bracketed paste).
				d.insertText(string(key.Runes))
				return nil
			}
			d.notice = ""
			d.warning = ""
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

// toggle - поставить или снять отметку пункта i (пробел, щелчок мышью).
func (d *dialog) toggle(i int) {
	d.warning = ""
	d.notice = ""
	if d.marks[i] {
		d.marks[i] = false
		return
	}
	// Одно расширение - одно обновление: отметка снимается с того, что грузит то же расширение.
	var off []string
	for _, j := range d.clashing(i) {
		d.marks[j] = false
		off = append(off, shortLabel(d.ev.Items[j]))
	}
	d.marks[i] = true
	if len(off) > 0 {
		d.notice = "снято: " + strings.Join(off, ", ") + " - у расширения одно обновление"
	}
}

// mouse - мышь в окне вопроса. Координаты уже внутри окна (их пересчитывает model).
// Щелчок по пункту - выбрать (в отметках - отметить), по кнопке - нажать; колесо - выбор вверх-вниз;
// в поле ввода правая кнопка - вставить; в просмотре колесо листает.
func (d *dialog) mouse(msg tea.MouseMsg) tea.Cmd {
	switch d.ev.Kind {
	case "text":
		// Мышь у ci.exe включена (прокрутка журнала), и сама консоль по правой кнопке больше не вставляет.
		if msg.Button == tea.MouseButtonRight && msg.Action == tea.MouseActionPress {
			d.pasteClipboard()
		}
		return nil
	case "view":
		var cmd tea.Cmd
		d.view, cmd = d.view.Update(msg)
		return cmd
	}
	if msg.Action != tea.MouseActionPress {
		return nil
	}
	switch msg.Button {
	case tea.MouseButtonWheelUp, tea.MouseButtonWheelDown:
		if d.sessionList() {
			d.view, _ = d.view.Update(msg)
			return nil
		}
		if d.docked() {
			return nil
		}
		k := tea.KeyMsg{Type: tea.KeyDown}
		if msg.Button == tea.MouseButtonWheelUp {
			k = tea.KeyMsg{Type: tea.KeyUp}
		}
		return d.Update(k)
	case tea.MouseButtonLeft:
	default:
		return nil
	}
	hits := d.hits
	// Пункт - во всю ширину окна, но не правее его рамки.
	right := d.boxW - styleDialog.GetHorizontalFrameSize()
	if d.docked() {
		hits = d.dockHits
		right = 0
	}
	i := -1
	for _, h := range hits {
		x1 := h.x1
		if x1 == 0 {
			x1 = right
		}
		if msg.Y >= h.y0 && msg.Y < h.y1 && msg.X >= h.x0 && msg.X < x1 {
			i = h.index
			break
		}
	}
	if i < 0 {
		return nil
	}
	if d.ev.Kind != "many" && d.isDanger(i) && d.armed != i {
		// Откат щелчком - только со второго раза: первый щелчок мог просто сделать окно активным.
		d.armed = i
		d.cursor = i
		if d.ev.Kind == "confirm" {
			d.yes = i == 0
		}
		d.notice = ""
		return nil
	}
	switch d.ev.Kind {
	case "one":
		d.cursor = i
		d.finish(answer{Index: i})
	case "many":
		d.cursor = i
		d.toggle(i)
	case "confirm":
		d.yes = i == 0
		d.finish(answer{Yes: d.yes})
	}
	return nil
}

// pasteClipboard - вставка из буфера обмена в поле ввода (Ctrl+V, правая кнопка мыши).
func (d *dialog) pasteClipboard() {
	text, err := readClipboard()
	var errno syscall.Errno
	if err != nil && errors.As(err, &errno) && errno == 0 {
		// В буфере не текст (картинка, файл): библиотека отдаёт «ошибку» с кодом 0.
		err = nil
	}
	if err != nil {
		d.notice = ""
		d.warning = "буфер обмена не прочитан: " + err.Error()
		return
	}
	d.insertText(text)
}

// insertText - вставить текст в место курсора. Пробелы и переводы строк по краям отрезаются:
// токен или пароль, скопированный со страницы, часто приходит с переводом строки в конце,
// а с ним вход не проходит. Переводы строк внутри - пробелом, как у самого поля.
func (d *dialog) insertText(text string) {
	d.notice = ""
	d.warning = ""
	text = strings.TrimSpace(text)
	text = strings.NewReplacer("\r\n", " ", "\r", " ", "\n", " ", "\t", " ").Replace(text)
	if text == "" {
		d.warning = "в буфере обмена нет текста"
		return
	}
	value := []rune(d.input.Value())
	pos := min(max(0, d.input.Position()), len(value))
	ins := []rune(text)
	lost := 0
	if limit := d.input.CharLimit; limit > 0 && len(value)+len(ins) > limit {
		keep := max(0, limit-len(value))
		lost = len(ins) - keep
		ins = ins[:keep]
	}
	d.input.SetValue(string(value[:pos]) + string(ins) + string(value[pos:]))
	d.input.SetCursor(pos + len(ins))
	if lost > 0 {
		d.warning = fmt.Sprintf("вставлено символов: %d, не влезло: %d (предел поля %d)", len(ins), lost, d.input.CharLimit)
		return
	}
	d.notice = fmt.Sprintf("вставлено из буфера, символов: %d", len(ins))
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
	inner := d.innerWidth()
	var b strings.Builder
	header := d.ev.Header
	if header == "" && d.ev.Kind == "view" {
		header = "Просмотр"
	}
	b.WriteString(styleDialogTitle.Width(inner).Render(header))
	b.WriteString("\n")
	if d.sessionList() {
		b.WriteString(d.view.View() + "\n")
		if d.view.TotalLineCount() > d.view.Height {
			b.WriteString(styleDim.Width(inner).Render("Сеансы: PgUp/PgDn или колесо мыши") + "\n")
		}
	}
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
		d.hits = d.hits[:0]
		end := d.windowEnd(d.offset)
		if d.offset > 0 {
			b.WriteString(styleDim.Render(fmt.Sprintf("  ↑ ещё %d", d.offset)) + "\n")
		}
		for i := d.offset; i < end; i++ {
			// Заголовок группы - перед её первым пунктом; у первого видимого - заголовок его группы, даже если
			// начало группы прокручено вверх.
			title := d.sectionTitle(i)
			if i == d.offset {
				title = d.sectionOf(i)
			}
			if title != "" {
				b.WriteString("  " + styleDialogGroup.Render(strings.ToUpper(title)) + "\n")
			}
			mark := ""
			if d.ev.Kind == "many" {
				if d.marks[i] {
					mark = styleOk.Render("[√] ")
				} else {
					mark = "[ ] "
				}
			} else if k := d.itemKey(i); k != "" {
				mark = styleDim.Render(k + " ")
			}
			top := strings.Count(b.String(), "\n")
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
				d.hits = append(d.hits, hitArea{y0: top, y1: top + len(lines), index: i})
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
			row := hangHint(prefix, text, d.itemHint(i), inner, st)
			b.WriteString(row + "\n")
			d.hits = append(d.hits, hitArea{y0: top, y1: top + lipgloss.Height(row), index: i})
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
			b.WriteString(d.dangerMouseHint(inner))
			b.WriteString(wrapBlock("↑↓ выбор · enter ок · цифра, буква или щелчок · esc отмена", inner, styleHelp))
		} else {
			help := "↑↓ выбор · пробел или щелчок - отметить · a все · enter дальше · esc отмена"
			if d.ev.AllowEmpty {
				help = "↑↓ выбор · пробел или щелчок - отметить · a все · enter дальше (можно без отметок) · esc отмена"
			}
			b.WriteString(wrapBlock(help, inner, styleHelp))
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
		if d.notice != "" {
			b.WriteString("\n\n" + wrapBlock(d.notice, inner, styleAccent))
		}
		if d.warning != "" {
			b.WriteString("\n\n" + wrapBlock(d.warning, inner, styleWarn))
		}
		b.WriteString("\n\n" + wrapBlock("enter ок · ctrl+v или правая кнопка мыши - вставить · esc отмена", inner, styleHelp))
	case "view":
		b.WriteString(d.view.View())
		if d.local == "test-log" {
			b.WriteString("\n" + wrapBlock("↑↓ PgUp PgDn листать · Home/End начало/конец · F2 копировать · F3/Esc назад", d.view.Width, styleHelp))
		} else {
			b.WriteString("\n" + styleHelp.Render(fmt.Sprintf("↑↓ PgUp PgDn прокрутка · %d%% · q закрыть", int(d.view.ScrollPercent()*100))))
		}
	}
	if d.copyNotice != "" {
		b.WriteString("\n" + wrapBlock(d.copyNotice, inner, styleAccent))
	}
	out := styleDialog.Render(b.String())
	d.boxW, d.boxH = lipgloss.Width(out), lipgloss.Height(out)
	return out
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

// Обе подсказки занимают одинаковое место: второй щелчок попадает на ту же кнопку.
func (d *dialog) dangerMouseHint(width int) string {
	if len(d.ev.Danger) == 0 {
		return ""
	}
	first := wrapBlock("Первый щелчок выделяет пункт с ▲. Второй подтверждает выбор.", width, styleWarn)
	second := wrapBlock("Чтобы подтвердить выбор, щёлкни по нему ещё раз или нажми Enter.", width, styleWarn)
	hint := first
	if d.armed >= 0 {
		hint = second
	}
	height := max(lipgloss.Height(first), lipgloss.Height(second))
	return hint + strings.Repeat("\n", height-lipgloss.Height(hint)+1)
}

// docked - вопрос да/нет рисуется полосой внизу экрана, а не окном поверх: чтобы решить «оставить или
// откатить», надо видеть итог прогона. Журнал при этом листается (↑↓ PgUp PgDn).
func (d *dialog) docked() bool {
	return d.ev.Kind == "confirm" || (d.ev.Kind == "one" && d.ev.Style == "dock")
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
	var buttons []string
	var help string
	button := func(i int, label string, active bool) string {
		if d.isDanger(i) {
			label += " ▲"
		}
		st := styleButton
		if active {
			st = styleButtonActive
		}
		if lipgloss.Width(label)+st.GetHorizontalFrameSize() > inner {
			st = st.Width(inner)
		}
		return st.Render(label)
	}
	if d.ev.Kind == "one" {
		for i, item := range d.ev.Items {
			label := item
			if k := hotkeyLabel(i); k != "" {
				label = k + "  " + item
			}
			buttons = append(buttons, button(i, label, i == d.cursor))
		}
		help = "←→ выбор · enter ок · цифра или щелчок · ↑↓ PgUp PgDn журнал · F2 скопировать журнал окна · esc закрыть вопрос"
	} else {
		yes := nonEmpty(d.ev.Yes, "Да")
		no := nonEmpty(d.ev.No, "Нет")
		buttons = []string{button(0, yes, d.yes), button(1, no, !d.yes)}
		help = "←→ выбор · enter ок · y/n, щелчок мышью · ↑↓ PgUp PgDn журнал · F2 скопировать журнал окна · esc отмена"
	}
	// Кнопки в ряд; не влезают в ширину - столбиком. Места кнопок - для щелчка мышью.
	top := strings.Count(b.String(), "\n")
	d.dockHits = d.dockHits[:0]
	row := ""
	x := 0
	for i, btn := range buttons {
		if i > 0 {
			row = lipgloss.JoinHorizontal(lipgloss.Center, row, "  ", btn)
			x += 2
		} else {
			row = btn
		}
		w := lipgloss.Width(btn)
		d.dockHits = append(d.dockHits, hitArea{y0: top, y1: top + lipgloss.Height(btn), x0: x, x1: x + w, index: i})
		x += w
	}
	if lipgloss.Width(row) > inner {
		row = lipgloss.JoinVertical(lipgloss.Left, buttons...)
		d.dockHits = d.dockHits[:0]
		y := top
		for i, btn := range buttons {
			h := lipgloss.Height(btn)
			d.dockHits = append(d.dockHits, hitArea{y0: y, y1: y + h, x0: 0, x1: lipgloss.Width(btn), index: i})
			y += h
		}
	}
	b.WriteString(row)
	b.WriteString("\n")
	if d.warning != "" {
		b.WriteString(wrapBlock(d.warning, inner, styleWarn) + "\n")
	}
	b.WriteString(d.dangerMouseHint(inner))
	if d.copyNotice != "" {
		b.WriteString(wrapBlock(d.copyNotice, inner, styleAccent) + "\n")
	}
	b.WriteString(wrapBlock(help, inner, styleHelp))
	return styleDocked.Width(width - 2).Render(b.String())
}
