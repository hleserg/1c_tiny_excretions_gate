package main

import (
	"strings"
	"testing"
	"time"
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
	m.eta = &runEta{seconds: 600, unknown: 1, at: time.Now()}
	got := m.timeText()
	if !strings.Contains(got, "прошло 1:0") || !strings.Contains(got, "осталось ~9:") && !strings.Contains(got, "осталось ~10:") || !strings.HasSuffix(got, "+") {
		t.Fatalf("ждали «прошло … · осталось ~10:00+», а: %q", got)
	}
	m.pipe = nil
	view := m.viewPipe(60, 20)
	if !strings.Contains(view, "прошло ") {
		t.Fatalf("в колонке шагов нет строки времени: %q", view)
	}
}
