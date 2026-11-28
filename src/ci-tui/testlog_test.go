package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestF3TracksTestLogWithoutAnsweringQuestions(t *testing.T) {
	m := testModel(96, 24)
	m.starting, m.running = false, true
	key := func(k tea.KeyType) { next, _ := m.Update(tea.KeyMsg{Type: k}); m = next.(model) }
	if strings.Contains(m.View(), "F3") {
		t.Fatal("подсказка до запуска YAxUnit")
	}
	m = ask(m, uiEvent{Kind: "test-log", Title: "YAxUnit · вывод клиента"})
	if !strings.Contains(m.View(), "F3") {
		t.Fatal("нет подсказки о журнале тестов")
	}
	key(tea.KeyF3)
	m = ask(m, uiEvent{Kind: "test-log", Lines: []string{"живой вывод"}})
	if !strings.Contains(m.View(), "живой вывод") {
		t.Fatal("новая строка не появилась в открытом журнале")
	}
	key(tea.KeyEsc)
	if strings.Contains(m.View(), "живой вывод") {
		t.Fatal("вывод теста попал в основной журнал")
	}
	key(tea.KeyF3)
	m = ask(m, uiEvent{Kind: "confirm", ID: 4, Header: "Вопрос скрипта?"})
	if !strings.Contains(m.View(), "Вопрос скрипта?") {
		t.Fatal("просмотр закрыл собой новый вопрос")
	}
	m = ask(m, uiEvent{Kind: "test-log", Title: "YAxUnit · yaxunit.log", Lines: []string{"включая сервер"}})
	key(tea.KeyF3)
	if !strings.Contains(m.View(), "включая сервер") || strings.Contains(m.View(), "живой вывод") {
		t.Fatal("итоговый файл должен заменить вывод клиента")
	}
	key(tea.KeyF3)
	if !strings.Contains(m.View(), "Вопрос скрипта?") || m.dialog.finished {
		t.Fatal("F3 ответила на вопрос")
	}
	m = ask(m, uiEvent{Kind: "reset"})
	key(tea.KeyF3)
	if strings.Contains(m.View(), "включая сервер") {
		t.Fatal("журнал перешёл в следующий прогон")
	}
}

func TestF3KeepsScrollPositionAndFollowsAtEnd(t *testing.T) {
	m := testModel(80, 19)
	m.starting, m.running = false, true
	m = ask(m, uiEvent{Kind: "test-log", Title: "YAxUnit", Lines: items(40)})
	key := func(k tea.KeyType) { next, _ := m.Update(tea.KeyMsg{Type: k}); m = next.(model) }
	key(tea.KeyF3)
	if !strings.Contains(m.View(), "Пункт 40") {
		t.Fatal("журнал должен открываться на последней строке")
	}
	key(tea.KeyHome)
	m = ask(m, uiEvent{Kind: "test-log", Lines: []string{"новая запись"}})
	if !strings.Contains(m.View(), "Пункт 01") || strings.Contains(m.View(), "новая запись") {
		t.Fatal("прокрутка сбросилась при записи")
	}
	key(tea.KeyEnd)
	m = ask(m, uiEvent{Kind: "test-log", Lines: []string{"последняя запись"}})
	if !strings.Contains(m.View(), "последняя запись") {
		t.Fatal("не работает слежение за концом")
	}
}
