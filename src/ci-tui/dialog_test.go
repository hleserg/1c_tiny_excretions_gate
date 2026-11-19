package main

// Вставка из буфера обмена в окно ввода текста (пароль, токен, имя базы).

import (
	"errors"
	"strings"
	"syscall"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
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
