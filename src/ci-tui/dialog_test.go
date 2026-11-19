package main

// Вставка из буфера обмена в окно ввода текста (пароль, токен, имя базы).

import (
	"errors"
	"fmt"
	"strings"
	"syscall"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func withClipboard(t *testing.T, text string, err error) {
	t.Helper()
	prev := readClipboard
	readClipboard = func() (string, error) { return text, err }
	t.Cleanup(func() { readClipboard = prev })
}

func newTextDialog(value string, secret bool) *dialog {
	return newDialog(uiEvent{Kind: "text", Header: "Пароль", Value: value, Secret: secret}, 100, 40)
}

// Вопрос с несколькими отметками: Enter без отметок - отказ с подсказкой; если скрипт разрешил пустой выбор
// (allowEmpty) - ответ «ни одного», не отмена.
func TestManyEmptySelection(t *testing.T) {
	strict := newDialog(uiEvent{Kind: "many", Header: "Что обновить", Items: []string{"А", "Б"}}, 100, 40)
	strict.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if strict.finished || strict.warning == "" {
		t.Fatalf("пустой выбор принят без разрешения: finished=%v warning=%q", strict.finished, strict.warning)
	}
	loose := newDialog(uiEvent{Kind: "many", Header: "Какие обработки записать", Items: []string{"А", "Б"}, AllowEmpty: true}, 100, 40)
	loose.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !loose.finished || loose.result.Cancel || len(loose.result.Indexes) != 0 {
		t.Fatalf("разрешённый пустой выбор: finished=%v cancel=%v indexes=%v", loose.finished, loose.result.Cancel, loose.result.Indexes)
	}
	if !strings.Contains(loose.View(), "можно без отметок") {
		t.Fatalf("в подсказке нет слов «можно без отметок»")
	}
	// С отметкой - как обычно.
	marked := newDialog(uiEvent{Kind: "many", Header: "Какие обработки записать", Items: []string{"А", "Б"}, AllowEmpty: true, Preselected: []int{1}}, 100, 40)
	marked.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !marked.finished || len(marked.result.Indexes) != 1 || marked.result.Indexes[0] != 1 {
		t.Fatalf("выбор с отметкой: %v", marked.result.Indexes)
	}
}

func TestPasteCtrlVTrimsNewline(t *testing.T) {
	withClipboard(t, "  github_pat_11ABC\r\n", nil)
	d := newTextDialog("", true)
	d.Update(tea.KeyMsg{Type: tea.KeyCtrlV})
	if got := d.input.Value(); got != "github_pat_11ABC" {
		t.Fatalf("значение после Ctrl+V: %q", got)
	}
	if !strings.Contains(d.notice, "16") {
		t.Fatalf("нет сообщения о вставке: %q", d.notice)
	}
	if strings.Contains(d.View(), "github_pat") {
		t.Fatal("пароль виден на экране")
	}
	d.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !d.finished || d.result.Text != "github_pat_11ABC" {
		t.Fatalf("ответ: finished=%v text=%q", d.finished, d.result.Text)
	}
}

func TestPasteInsertsAtCursor(t *testing.T) {
	withClipboard(t, "XY", nil)
	d := newTextDialog("ab", false)
	d.input.SetCursor(1)
	d.Update(tea.KeyMsg{Type: tea.KeyCtrlV})
	if got := d.input.Value(); got != "aXYb" {
		t.Fatalf("значение: %q", got)
	}
	if got := d.input.Position(); got != 3 {
		t.Fatalf("курсор: %d", got)
	}
}

func TestPasteRightClickThroughModel(t *testing.T) {
	withClipboard(t, "token123", nil)
	m := newModel("", "", nil)
	m.width, m.height = 100, 40
	m.dialog = newTextDialog("", true)
	next, _ := m.update(tea.MouseMsg{Button: tea.MouseButtonRight, Action: tea.MouseActionPress, Type: tea.MouseRight})
	nm := next.(model)
	if nm.dialog == nil || nm.dialog.input.Value() != "token123" {
		t.Fatal("правая кнопка мыши не вставила")
	}
	// Отпускание кнопки второй раз не вставляет.
	next, _ = nm.update(tea.MouseMsg{Button: tea.MouseButtonRight, Action: tea.MouseActionRelease, Type: tea.MouseRelease})
	if got := next.(model).dialog.input.Value(); got != "token123" {
		t.Fatalf("после отпускания: %q", got)
	}
}

func TestPasteEmptyAndError(t *testing.T) {
	withClipboard(t, " \r\n", nil)
	d := newTextDialog("abc", false)
	d.Update(tea.KeyMsg{Type: tea.KeyCtrlV})
	if d.input.Value() != "abc" || d.warning == "" {
		t.Fatalf("пустой буфер: %q, предупреждение %q", d.input.Value(), d.warning)
	}
	// В буфере не текст: «ошибка» с кодом 0 - как пустой буфер.
	withClipboard(t, "", syscall.Errno(0))
	d.Update(tea.KeyMsg{Type: tea.KeyCtrlV})
	if d.warning != "в буфере обмена нет текста" {
		t.Fatalf("не текст в буфере: %q", d.warning)
	}
	withClipboard(t, "", errors.New("занят"))
	d.Update(tea.KeyMsg{Type: tea.KeyCtrlV})
	if d.input.Value() != "abc" || !strings.Contains(d.warning, "занят") {
		t.Fatalf("ошибка буфера: %q, предупреждение %q", d.input.Value(), d.warning)
	}
	// Обычный ввод снимает сообщение.
	d.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("d")})
	if d.warning != "" || d.input.Value() != "abcd" {
		t.Fatalf("после ввода: %q, предупреждение %q", d.input.Value(), d.warning)
	}
}

func TestPasteCharLimit(t *testing.T) {
	withClipboard(t, "12345", nil)
	d := newTextDialog(strings.Repeat("a", 498), false)
	d.Update(tea.KeyMsg{Type: tea.KeyCtrlV})
	if got := len([]rune(d.input.Value())); got != 500 {
		t.Fatalf("длина: %d", got)
	}
	if !strings.Contains(d.warning, "не влезло: 3") {
		t.Fatalf("предупреждение: %q", d.warning)
	}
}

func TestPasteFromTerminal(t *testing.T) {
	d := newTextDialog("", false)
	d.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("C:\\ci\\inbox\n"), Paste: true})
	if got := d.input.Value(); got != "C:\\ci\\inbox" {
		t.Fatalf("значение: %q", got)
	}
}

// Меню с группами: заголовок группы - строка перед её первым пунктом, выбрать её нельзя; клавиши пунктов свои и
// не зависят от того, какие пункты показаны.
func TestOneSectionsAndKeys(t *testing.T) {
	ev := uiEvent{Kind: "one", Header: "Меню",
		Items:    []string{"Прогон", "Результаты", "Обновить рабочую", "Откатить", "Настройки"},
		Sections: []string{"Тестовая база", "", "Рабочая база", "", "Гейт"},
		Keys:     []string{"2", "7", "d", "e", "l"}}
	d := newDialog(ev, 100, 40)
	view := ansi.Strip(d.View())
	for _, title := range []string{"ТЕСТОВАЯ БАЗА", "РАБОЧАЯ БАЗА", "ГЕЙТ"} {
		if strings.Count(view, title) != 1 {
			t.Fatalf("заголовок группы %q показан %d раз, ждали 1", title, strings.Count(view, title))
		}
	}
	if len(d.hits) != len(ev.Items) {
		t.Fatalf("мест для щелчка %d, пунктов %d: заголовок группы не должен выбираться", len(d.hits), len(ev.Items))
	}
	// Щелчок по строке заголовка «Рабочая база» ничего не выбирает, по пункту под ним - выбирает его
	// (по настоящей отрисовке экрана, как в mouse_test.go).
	m := ask(testModel(120, 50), ev)
	hx, hy := onScreen(t, m, "РАБОЧАЯ БАЗА")
	m = mouse(m, hx+2, hy, tea.MouseButtonLeft)
	if m.dialog == nil {
		t.Fatalf("щелчок по заголовку группы выбрал пункт (журнал: %q)", lastLine(m))
	}
	ix, iy := onScreen(t, m, "Обновить рабочую")
	if iy != hy+1 {
		t.Fatalf("первый пункт группы на строке %d, заголовок на %d: ждали пункт сразу под заголовком", iy, hy)
	}
	m = mouse(m, ix+2, iy, tea.MouseButtonLeft)
	if m.dialog != nil || !strings.Contains(lastLine(m), "Обновить рабочую") {
		t.Fatalf("щелчок по пункту под заголовком не выбрал его (журнал: %q)", lastLine(m))
	}

	// Своя клавиша: «d» - третий пункт (порядковая «d» была бы тринадцатым), в русской раскладке - «в».
	for _, key := range []string{"d", "в", "D"} {
		k := newDialog(ev, 100, 40)
		k.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)})
		if !k.finished || k.result.Index != 2 {
			t.Fatalf("клавиша %q: finished=%v index=%d, ждали пункт 2", key, k.finished, k.result.Index)
		}
	}
	// Клавиша, которой нет ни у одного пункта (порядковая «1»), ничего не выбирает.
	gap := newDialog(ev, 100, 40)
	gap.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("1")})
	if gap.finished {
		t.Fatalf("клавиша без пункта выбрала пункт %d", gap.result.Index)
	}
	for _, want := range []string{"2 Прогон", "7 Результаты", "d Обновить рабочую", "e Откатить", "l Настройки"} {
		if !strings.Contains(view, want) {
			t.Fatalf("в меню нет %q:\n%s", want, view)
		}
	}

	// Без keys - клавиши порядковые, как раньше.
	plain := newDialog(uiEvent{Kind: "one", Header: "Меню", Items: []string{"А", "Б", "В"}}, 100, 40)
	plain.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("2")})
	if !plain.finished || plain.result.Index != 1 {
		t.Fatalf("порядковая клавиша: finished=%v index=%d", plain.finished, plain.result.Index)
	}
}

// Окно ниже списка: заголовки групп занимают строки, курсор остаётся на экране, а над первым видимым пунктом
// стоит заголовок его группы.
func TestOneSectionsScroll(t *testing.T) {
	items := make([]string, 12)
	sections := make([]string, 12)
	for i := range items {
		items[i] = fmt.Sprintf("Пункт %02d", i)
	}
	sections[0], sections[4], sections[8] = "Первая", "Вторая", "Третья"
	// Высота 16: visibleRows = 16 - 10 = 6 строк на пункты и заголовки.
	d := newDialog(uiEvent{Kind: "one", Header: "Меню", Items: items, Sections: sections}, 100, 16)
	if got := d.windowEnd(0); got != 4 {
		t.Fatalf("с начала влезает до пункта %d, ждали 4: заголовки «Первая» и «Вторая» занимают строки", got)
	}
	for i := 0; i < 9; i++ {
		d.Update(tea.KeyMsg{Type: tea.KeyDown})
		if d.cursor < d.offset || d.cursor >= d.windowEnd(d.offset) {
			t.Fatalf("после %d нажатий вниз курсор %d вне окна [%d, %d)", i+1, d.cursor, d.offset, d.windowEnd(d.offset))
		}
	}
	view := ansi.Strip(d.View())
	if !strings.Contains(view, "Пункт 09") {
		t.Fatal("пункт под курсором не на экране")
	}
	if rows := strings.Count(view, "Пункт "); rows > 6 {
		t.Fatalf("на экране %d пунктов при шести строках", rows)
	}
	first := items[d.offset]
	if strings.Index(view, strings.ToUpper(d.sectionOf(d.offset))) > strings.Index(view, first) {
		t.Fatal("заголовок группы первого видимого пункта стоит не над ним")
	}
}
