package main

// Клавиши пунктов после 9 (буквы, русская раскладка) и мышь: щелчок по пункту, по кнопке внизу.
// Щелчки - по настоящей отрисовке экрана: ищем текст пункта и жмём туда, где он нарисован.

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func testModel(w, h int) model {
	m := newModel("", "", nil)
	next, _ := m.Update(tea.WindowSizeMsg{Width: w + 1, Height: h})
	return next.(model)
}

func ask(m model, ev uiEvent) model {
	next, _ := m.Update(eventMsg{ev: ev})
	return next.(model)
}

func items(n int) []string {
	var out []string
	for i := 1; i <= n; i++ {
		out = append(out, fmt.Sprintf("Пункт %02d", i))
	}
	return out
}

// onScreen - столбец и строка текста на экране так, как его покажет Bubble Tea (лишнее сверху срезано);
// ищется снизу вверх.
func onScreen(t *testing.T, m model, text string) (int, int) {
	t.Helper()
	lines := strings.Split(m.View(), "\n")
	if len(lines) > m.height {
		lines = lines[len(lines)-m.height:]
	}
	// Снизу вверх: кнопки полосы вопроса внизу, а те же слова бывают в журнале выше.
	for y := len(lines) - 1; y >= 0; y-- {
		plain := ansi.Strip(lines[y])
		if i := strings.Index(plain, text); i >= 0 {
			return ansi.StringWidth(plain[:i]), y
		}
	}
	t.Fatalf("на экране нет %q", text)
	return 0, 0
}

func mouse(m model, x, y int, button tea.MouseButton) model {
	next, _ := m.Update(tea.MouseMsg{X: x, Y: y, Button: button, Action: tea.MouseActionPress})
	return next.(model)
}

func lastLine(m model) string {
	if len(m.lines) == 0 {
		return ""
	}
	return m.lines[len(m.lines)-1]
}

func TestHotkeysAfterNine(t *testing.T) {
	cases := []struct {
		key  tea.KeyMsg
		want int
	}{
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("1")}, 0},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("9")}, 8},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("a")}, 9},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("ф")}, 9},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("G")}, 15},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("П")}, 15},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("z")}, -1},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")}, -1},
		{tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("0")}, -1},
	}
	for _, c := range cases {
		d := newDialog(uiEvent{Kind: "one", Header: "Меню", Items: items(16)}, 100, 40)
		d.Update(c.key)
		if c.want < 0 {
			if d.finished || d.cursor != 0 {
				t.Fatalf("клавиша %q: выбрано %v, курсор %d", c.key.String(), d.finished, d.cursor)
			}
			continue
		}
		if !d.finished || d.result.Index != c.want {
			t.Fatalf("клавиша %q: ждали пункт %d, вышло %v/%d", c.key.String(), c.want, d.finished, d.result.Index)
		}
	}
	view := ansi.Strip(newDialog(uiEvent{Kind: "one", Header: "Меню", Items: items(16)}, 100, 40).View())
	for _, want := range []string{"9 Пункт 09", "a Пункт 10", "g Пункт 16"} {
		if !strings.Contains(view, want) {
			t.Fatalf("в меню нет %q:\n%s", want, view)
		}
	}
}

func TestClickMenuItem(t *testing.T) {
	for _, size := range [][2]int{{100, 40}, {80, 30}, {140, 50}} {
		m := ask(testModel(size[0], size[1]), uiEvent{Kind: "one", ID: 1, Header: "Гейт расширений", Items: items(16)})
		x, y := onScreen(t, m, "Пункт 12")
		m = mouse(m, x+2, y, tea.MouseButtonLeft)
		if m.dialog != nil || !strings.Contains(lastLine(m), "Пункт 12") {
			t.Fatalf("окно %v: щелчок по «Пункт 12» не выбрал его (журнал: %q)", size, lastLine(m))
		}
	}
}

func TestClickMissesTitleAndOutside(t *testing.T) {
	m := ask(testModel(100, 40), uiEvent{Kind: "one", ID: 1, Header: "Гейт расширений", Items: items(5)})
	x, y := onScreen(t, m, "Гейт расширений")
	m = mouse(m, x+2, y, tea.MouseButtonLeft)
	m = mouse(m, 0, 0, tea.MouseButtonLeft)
	_, y5 := onScreen(t, m, "Пункт 05")
	m = mouse(m, 1, y5, tea.MouseButtonLeft)         // та же строка, но слева от окна
	m = mouse(m, m.width-1, y5, tea.MouseButtonLeft) // и справа от окна
	if m.dialog == nil {
		t.Fatal("щелчок мимо пунктов закрыл меню")
	}
}

func TestClickWhenDialogTallerThanScreen(t *testing.T) {
	var notes []string
	for i := 0; i < 12; i++ {
		notes = append(notes, fmt.Sprintf("примечание %d", i))
	}
	m := ask(testModel(100, 20), uiEvent{Kind: "one", ID: 1, Header: "Меню", Notes: notes, Items: items(5)})
	if h := strings.Count(m.View(), "\n") + 1; h <= m.height {
		t.Fatalf("окно не выше экрана: %d строк", h)
	}
	x, y := onScreen(t, m, "Пункт 02")
	m = mouse(m, x+2, y, tea.MouseButtonLeft)
	if m.dialog != nil || !strings.Contains(lastLine(m), "Пункт 02") {
		t.Fatalf("щелчок по «Пункт 02» (окно выше экрана): %q", lastLine(m))
	}
}

func TestClickToggleMany(t *testing.T) {
	m := ask(testModel(100, 40), uiEvent{Kind: "many", ID: 1, Header: "Что ставить", Items: items(4)})
	x, y := onScreen(t, m, "Пункт 03")
	m = mouse(m, x+2, y, tea.MouseButtonLeft)
	if !m.dialog.marks[2] {
		t.Fatal("щелчок не отметил пункт")
	}
	x, y = onScreen(t, m, "Пункт 03")
	m = mouse(m, x+2, y, tea.MouseButtonLeft)
	if m.dialog.marks[2] {
		t.Fatal("второй щелчок не снял отметку")
	}
}

func TestWheelMovesCursor(t *testing.T) {
	m := ask(testModel(100, 40), uiEvent{Kind: "one", ID: 1, Header: "Меню", Items: items(5)})
	m.View()
	m = mouse(m, 50, 20, tea.MouseButtonWheelDown)
	m = mouse(m, 50, 20, tea.MouseButtonWheelDown)
	if m.dialog == nil || m.dialog.cursor != 2 {
		t.Fatal("колесо не двигает выбор")
	}
}

func TestClickDockedButtons(t *testing.T) {
	for _, size := range [][2]int{{100, 40}, {80, 30}} {
		m := testModel(size[0], size[1])
		for i := 0; i < 60; i++ {
			next, _ := m.Update(lineMsg{text: fmt.Sprintf("строка журнала %d", i)})
			m = next.(model)
		}
		m = ask(m, uiEvent{Kind: "confirm", ID: 1, Header: "Комплект: оставить?", Yes: "Оставить", No: "Откатить"})
		x, y := onScreen(t, m, "Откатить")
		m = mouse(m, x+1, y, tea.MouseButtonLeft)
		if m.dialog != nil || !strings.Contains(lastLine(m), "Откатить") {
			t.Fatalf("окно %v: щелчок по «Откатить»: %q", size, lastLine(m))
		}
		m = ask(m, uiEvent{Kind: "one", ID: 2, Style: "dock", Header: "Посмотрел?", Items: []string{"Вернуться в меню", "Ещё раз"}})
		x, y = onScreen(t, m, "Ещё раз")
		m = mouse(m, x+1, y, tea.MouseButtonLeft)
		if m.dialog != nil || !strings.Contains(lastLine(m), "Ещё раз") {
			t.Fatalf("окно %v: щелчок по кнопке «Ещё раз»: %q", size, lastLine(m))
		}
	}
}

func TestDockedWheelStillScrollsLog(t *testing.T) {
	m := testModel(100, 30)
	for i := 0; i < 80; i++ {
		next, _ := m.Update(lineMsg{text: fmt.Sprintf("строка журнала %d", i)})
		m = next.(model)
	}
	m = ask(m, uiEvent{Kind: "confirm", ID: 1, Header: "Оставить?", Yes: "Оставить", No: "Откатить"})
	m.View()
	m = mouse(m, 10, 5, tea.MouseButtonWheelUp)
	if m.dialog == nil || m.follow {
		t.Fatal("колесо при полосе вопроса должно листать журнал, а не отвечать")
	}
}

func TestSecretAnswerNotInLog(t *testing.T) {
	m := ask(testModel(100, 40), uiEvent{Kind: "text", ID: 1, Header: "Пароль", Secret: true})
	for _, r := range "github_pat_SECRET" {
		next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		m = next.(model)
	}
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)
	for _, l := range m.lines {
		if strings.Contains(l, "SECRET") {
			t.Fatalf("пароль в журнале: %q", l)
		}
	}
	if !strings.Contains(lastLine(m), "***") {
		t.Fatalf("нет отметки о вводе: %q", lastLine(m))
	}
}

func TestDangerNeedsSecondClick(t *testing.T) {
	// После вердикта: «Откатить» помечен опасным - первый щелчок только выбирает.
	m := ask(testModel(100, 40), uiEvent{Kind: "one", ID: 1, Style: "dock", Header: "Комплект: оставить или откатить?",
		Items: []string{"Оставить", "Оставить и принять", "Откатить"}, Danger: []int{2}})
	x, y := onScreen(t, m, "Откатить")
	m = mouse(m, x+1, y, tea.MouseButtonLeft)
	if m.dialog == nil {
		t.Fatal("откат сработал с первого щелчка")
	}
	if m.dialog.cursor != 2 || !strings.Contains(ansi.Strip(m.View()), "щёлкни по нему ещё раз") {
		t.Fatal("после первого щелчка выбор не на откате или нет подсказки")
	}
	x, y = onScreen(t, m, "3  Откатить")
	m = mouse(m, x+1, y, tea.MouseButtonLeft)
	if m.dialog != nil || !strings.Contains(lastLine(m), "Откатить") {
		t.Fatalf("второй щелчок не откатил: %q", lastLine(m))
	}

	// Да/нет после deploy: «Откатить» - «да» опасное; первый щелчок, потом Enter.
	m = ask(m, uiEvent{Kind: "confirm", ID: 2, Header: "Откатить?", Yes: "Откатить", No: "Оставить", Danger: []int{0}})
	m.dialog.yes = false
	x, y = onScreen(t, m, "Откатить")
	m = mouse(m, x+1, y, tea.MouseButtonLeft)
	if m.dialog == nil || !m.dialog.yes {
		t.Fatal("первый щелчок по опасному «да»: окно закрылось или выбор не на нём")
	}
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)
	if m.dialog != nil || !strings.Contains(lastLine(m), "Откатить") {
		t.Fatalf("Enter после щелчка: %q", lastLine(m))
	}

	// Окно отката рабочей (опасный пункт в красной рамке) - тоже со второго раза; другой пункт - сразу.
	m = ask(m, uiEvent{Kind: "one", ID: 3, Header: "Откат рабочей", Items: []string{"Обновление 1", "Обновление 2"}, Danger: []int{0}})
	x, y = onScreen(t, m, "Обновление 1")
	m = mouse(m, x+1, y, tea.MouseButtonLeft)
	if m.dialog == nil {
		t.Fatal("опасный пункт в окне сработал с первого щелчка")
	}
	x, y = onScreen(t, m, "Обновление 2")
	m = mouse(m, x+1, y, tea.MouseButtonLeft)
	if m.dialog != nil || !strings.Contains(lastLine(m), "Обновление 2") {
		t.Fatalf("обычный пункт не выбрался сразу: %q", lastLine(m))
	}
}

// F2 - весь журнал в буфер обмена, без раскраски; работает и при открытом вопросе с кнопками внизу.
func TestCopyLogF2(t *testing.T) {
	var copied string
	prev := writeClipboard
	writeClipboard = func(text string) error { copied = text; return nil }
	t.Cleanup(func() { writeClipboard = prev })

	m := testModel(100, 40)
	m.appendLine("ВЫГРУЗИТЬ temp В GIT")
	m.appendLine(styleOk.Render("       готово за 6:07"))
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyF2})
	m = next.(model)
	if copied != "ВЫГРУЗИТЬ temp В GIT\r\n       готово за 6:07" {
		t.Fatalf("в буфере обмена: %q", copied)
	}
	if !strings.Contains(m.notice, "строк 2") {
		t.Fatalf("нет сообщения о копировании: %q", m.notice)
	}
	// Вопрос с кнопками внизу открыт: F2 копирует и вопрос не трогает.
	copied = ""
	m = ask(m, uiEvent{Kind: "one", ID: 7, Style: "dock", Header: "Посмотрел?", Items: []string{"Вернуться в меню"}})
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyF2})
	m = next.(model)
	if copied == "" || m.dialog == nil {
		t.Fatalf("при открытом вопросе: скопировано %q, вопрос открыт %v", copied, m.dialog != nil)
	}
}
