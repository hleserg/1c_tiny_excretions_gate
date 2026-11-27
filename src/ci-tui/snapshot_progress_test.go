package main

import (
	"strings"
	"testing"
	"time"
)

func TestSnapshotProgress(t *testing.T) {
	m := newModel("", "", nil)
	m.running, m.width, m.height = true, 110, 32
	send := func(ev uiEvent) {
		next, _ := m.update(eventMsg{ev: ev})
		m = next.(model)
	}
	for _, name := range []string{"Первое", "Второе", "Третье"} {
		send(uiEvent{Kind: "step", Title: "Выгрузить " + name, Status: "OK"})
	}
	if s := m.viewPipe(32, 20); strings.Contains(s, "100%") || strings.Contains(s, "3/3") {
		t.Fatalf("У операций без общего плана появился итог всего прогона:\n%s", s)
	}
	for _, done := range []int{2, 3} {
		send(uiEvent{Kind: "snapshot-extensions", Done: done, Total: 3})
		s := m.viewPipe(32, 20)
		if done == 2 && (!strings.Contains(s, "2 из 3") || strings.Contains(s, "Расширения выгружены")) {
			t.Fatalf("Неполная выгрузка:\n%s", s)
		}
		if done == 3 && (!strings.Contains(s, "Расширения выгружены") || !strings.Contains(s, "3 из 3")) {
			t.Fatalf("Итог выгрузки расширений:\n%s", s)
		}
	}
	send(uiEvent{Kind: "snapshot-extensions"})
	if s := m.viewPipe(32, 20); strings.Contains(s, "3 из 3") {
		t.Fatalf("Счётчик остался после снимка:\n%s", s)
	}
	send(uiEvent{Kind: "plan", Steps: []string{"Проверка"}})
	if s := m.viewPipe(32, 20); !strings.Contains(s, "Шаги прогона") || !strings.Contains(s, "%") {
		t.Fatalf("У полного плана пропал общий прогресс:\n%s", s)
	}
}

func TestProgressEstimateCaption(t *testing.T) {
	m := newModel("", "", nil)
	m.width = 110
	m.prog = &progressState{title: "Чтение", elapsed: 26, expected: 54, done: -1, at: time.Now()}
	if s := m.viewProgress(); !strings.Contains(s, "по времени") {
		t.Fatalf("Основание оценки не видно:\n%s", s)
	}
	m.prog.done, m.prog.total = 1, 2
	if s := m.viewProgress(); !strings.Contains(s, "1 из 2") || strings.Contains(s, "по времени") {
		t.Fatalf("Счётчик выполненной работы:\n%s", s)
	}
}
