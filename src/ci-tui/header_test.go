package main

import (
	"strings"
	"testing"
	"time"
)

// Шапка (#32): база из события context, «ждёт ответа» при открытом вопросе и время последнего сообщения
// видны и в узком окне, где колонки шагов нет.
func TestHeaderNarrowShowsContextWaitAndQuiet(t *testing.T) {
	m := newModel("", "", nil)
	m.running = true
	m.starting = false
	m.width = minWidthForSteps - 30
	m.context = "erp_temp"
	m.lastOutput = time.Now().Add(-5 * time.Minute)
	header := m.viewHeader()
	for _, want := range []string{"erp_temp", "работает", "посл. сообщение", "(5 мин)"} {
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
	if header = m.viewHeader(); strings.Contains(header, "посл. сообщение") {
		t.Fatalf("сообщение было только что, а в шапке «посл. сообщение»: %q", header)
	}
	m.width = minWidthForSteps + 40
	if header = m.viewHeader(); !strings.Contains(header, "гейт и обновление расширений") {
		t.Fatalf("в широком окне нет полного названия: %q", header)
	}
}
