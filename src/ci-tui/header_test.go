package main

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
)

func TestFinishedVerdictInHeaderAndCodeInLog(t *testing.T) {
	for _, run := range []struct {
		verdict string
		code    int
	}{{"ЗЕЛЁНЫЙ", 0}, {"ЖЁЛТЫЙ", 2}, {"КРАСНЫЙ", 1}} {
		m := testModel(45, 30)
		m.starting, m.running = false, true
		m.appendLine("ВЕРДИКТ: " + run.verdict + ". Подробности в журнале.")
		next, _ := m.Update(exitMsg{code: run.code})
		m = next.(model)
		header := m.viewHeader()
		if !strings.Contains(header, run.verdict) || strings.Contains(header, "код") || strings.Contains(header, "готово") || lipgloss.Width(header) > m.width {
			t.Errorf("Шапка законченного прогона: %q", header)
		}
		if !strings.Contains(lastLine(m), fmt.Sprintf("Код завершения: %d", run.code)) {
			t.Errorf("В журнале отсутствует код %d: %q", run.code, lastLine(m))
		}
		if h := lipgloss.Height(m.View()); h > m.height {
			t.Errorf("Шапка уходит с экрана: высота %d строк при окне %d", h, m.height)
		}
	}
	m := testModel(45, 30)
	m.starting = false
	m.appendLine("  ВЕРДИКТ: ЗЕЛЁНЫЙ. Из предыдущего прогона.")
	next, _ := m.Update(exitMsg{code: 1})
	if header := next.(model).viewHeader(); !strings.Contains(header, "кодом 1") || strings.Contains(header, "ЗЕЛЁНЫЙ") {
		t.Errorf("Остановившийся скрипт без собственного вердикта: %q", header)
	}
	m.appendLine("ВЕРДИКТ: ЖЁЛТЫЙ. Есть замечания.")
	m.appendLine("Остановлено: ошибка после проверки")
	next, _ = m.Update(exitMsg{code: 1})
	if header := next.(model).viewHeader(); !strings.Contains(header, "ЖЁЛТЫЙ") || !strings.Contains(header, "сбой") || strings.Contains(header, "код") {
		t.Errorf("Сбой после жёлтого вердикта: %q", header)
	}
}

// Шапка (#32): база из события context, «ждёт ответа» при открытом вопросе и время последнего сообщения
// видны и в узком окне, где колонки шагов нет.
func TestHeaderNarrowShowsContextWaitAndQuiet(t *testing.T) {
	m := newModel("", "", nil)
	m.running = true
	m.starting = false
	m.width = minWidthForSteps - 20
	m.context = "erp_temp"
	m.lastOutput = time.Now().Add(-5 * time.Minute)
	header := m.viewHeader()
	if w := lipgloss.Width(header); w > m.width {
		t.Fatalf("шапка шире окна: %d > %d: %q", w, m.width, header)
	}
	for _, want := range []string{"erp_temp", "работает", "5 мин"} {
		if !strings.Contains(header, want) {
			t.Fatalf("в шапке узкого окна нет %q: %q", want, header)
		}
	}
	if strings.Contains(header, "гейт и обновление расширений") {
		t.Fatalf("в узком окне длинное название не сократилось: %q", header)
	}
	m.dialog = &dialog{}
	if header = m.viewHeader(); !strings.Contains(header, "ждёт ответа") {
		t.Fatalf("открыт вопрос, а в шапке нет «ждёт ответа»: %q", header)
	}
	m.dialog = nil
	m.lastOutput = time.Now()
	if header = m.viewHeader(); strings.Contains(header, "посл. сообщение") || strings.Contains(header, "тихо") {
		t.Fatalf("сообщение было только что, а в шапке «посл. сообщение»: %q", header)
	}
	m.width = minWidthForSteps + 40
	if header = m.viewHeader(); !strings.Contains(header, "гейт и обновление расширений") {
		t.Fatalf("в широком окне нет полного названия: %q", header)
	}
	// Длинный контекст deploy в узком окне: строка не шире окна, состояние на месте.
	m.context = "рабочая erp_base_очень_длинное_имя · temp erp_temp_очень_длинное_имя"
	m.lastOutput = time.Now().Add(-7 * time.Minute)
	for _, width := range []int{40, 60, 80, minWidthForSteps - 1} {
		m.width = width
		header = m.viewHeader()
		if w := lipgloss.Width(header); w > width {
			t.Fatalf("окно %d: шапка шире окна (%d): %q", width, w, header)
		}
		if !strings.Contains(header, "работает") {
			t.Fatalf("окно %d: пропало состояние: %q", width, header)
		}
	}
	m.width = minWidthForSteps + 40
	m.context = "erp_temp"
	if header = m.viewHeader(); !strings.Contains(header, "посл. сообщение") {
		t.Fatalf("в широком окне нет полной пометки о молчании: %q", header)
	}
}
