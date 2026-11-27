package main

import (
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// Сколько прошло с начала и сколько осталось: строка под заголовком «Шаги прогона».
func TestTimeTextElapsedAndRemaining(t *testing.T) {
	m := newModel("", "", nil)
	if m.timeText() != "" {
		t.Fatalf("скрипт не идёт, а время показано: %q", m.timeText())
	}
	m.running = true
	m.started = time.Now().Add(-65 * time.Second)
	if got := m.timeText(); !strings.HasPrefix(got, "прошло 1:0") || strings.Contains(got, "осталось") {
		t.Fatalf("без оценки ждали только «прошло 1:05», а: %q", got)
	}
	m.eta = &runEta{seconds: 600, unknown: 2, at: time.Now()}
	got := m.timeText()
	if !strings.Contains(got, "прошло 1:0") || !strings.Contains(got, "осталось около 10 мин по известным шагам. Без оценки ещё 2") {
		t.Errorf("Длительность и число шагов без оценки: %q", got)
	}
	for _, width := range []int{24, stepsWidth - 4} {
		view := m.viewPipe(width, 20)
		if lipgloss.Width(view) > width || !strings.Contains(strings.Join(strings.Fields(view), " "), "Без оценки ещё 2") {
			t.Errorf("Прогноз в колонке шириной %d:\n%s", width, view)
		}
	}
	m.width, m.height = 50, 30
	m.layout()
	if view := m.View(); !strings.Contains(view, "Без оценки ещё 2") || lipgloss.Width(view) > m.width {
		t.Errorf("Прогноз в узком окне:\n%s", view)
	}
	m.eta.seconds = 0
	if got := m.timeText(); !strings.Contains(got, "шагов без оценки: 2") || strings.Contains(got, "около 0") {
		t.Errorf("Нулевая сумма известных шагов при неполной оценке: %q", got)
	}
	m.eta.seconds, m.eta.unknown = 15, 0
	if got := m.timeText(); !strings.Contains(got, "осталось около 15 с") || strings.Contains(got, "Без оценки") {
		t.Errorf("Полностью известный прогноз: %q", got)
	}
	unknown := -1.0
	m = ask(m, uiEvent{Kind: "progress", Remaining: &unknown})
	if got := m.timeText(); strings.Contains(got, "осталось") {
		t.Errorf("Движок снял оценку, но остался старый прогноз: %q", got)
	}
}
