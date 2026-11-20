package main

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"testing"
	"time"
)

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
