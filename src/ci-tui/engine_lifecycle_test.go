package main

import (
	"errors"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestRestartOnlyStartsOneEngine(t *testing.T) {
	m := testModel(100, 30)
	next, _ := m.Update(engineStartedMsg{eng: &engine{}})
	next, _ = next.Update(exitMsg{})
	enter := tea.KeyMsg{Type: tea.KeyEnter}

	next, start := next.Update(enter)
	if start == nil {
		t.Fatal("после выхода скрипта первый Enter должен запустить его снова")
	}
	for _, key := range []tea.KeyMsg{enter, {Type: tea.KeyEsc}, {Type: tea.KeyRunes, Runes: []rune("r")}} {
		var cmd tea.Cmd
		next, cmd = next.Update(key)
		if cmd != nil {
			t.Fatalf("%s повторно запустил скрипт до подтверждения первого запуска", key.String())
		}
	}
	next, _ = next.Update(engineStartedMsg{err: errors.New("ошибка запуска")})
	if _, retry := next.Update(enter); retry == nil {
		t.Fatal("после ошибки запуска Enter должен разрешать повторную попытку")
	}
}

func TestInitialLaunchIgnoresRestartAndQuitUntilStarted(t *testing.T) {
	m := testModel(100, 30)
	if m.Init() == nil {
		t.Fatal("при открытии экрана должна создаваться команда запуска")
	}
	for _, key := range []tea.KeyMsg{{Type: tea.KeyEnter}, {Type: tea.KeyCtrlC}, {Type: tea.KeyRunes, Runes: []rune("q")}} {
		next, cmd := m.Update(key)
		if cmd != nil || next.(model).dialog != nil {
			t.Fatalf("%s сработала до регистрации процесса", key.String())
		}
		m = next.(model)
	}
	eng := &engine{}
	next, wait := m.Update(engineStartedMsg{eng: eng})
	if wait == nil || !next.(model).running || next.(model).eng != eng {
		t.Fatal("скрипт должен быть зарегистрирован к началу чтения его вывода")
	}
}
