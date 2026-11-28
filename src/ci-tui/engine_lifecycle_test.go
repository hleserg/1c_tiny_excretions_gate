package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
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

func TestEngineStartupFailureExplainsHowToRetry(t *testing.T) {
	t.Setenv("CI_ENGINE", "missing-gate-test-engine")
	_, err := startEngine(t.TempDir(), "run.ps1", nil)
	if err == nil {
		t.Fatal("ожидался отказ при запуске")
	}
	for _, want := range []string{"run.ps1", "missing-gate-test-engine", "Enter"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("в причине %q нет %q", err, want)
		}
	}
}

func TestSilentEngineFailureNamesTheScriptAndDiagnostic(t *testing.T) {
	m := testModel(100, 30)
	m.script = "deploy.ps1"
	m.lines = nil
	next, _ := m.Update(exitMsg{code: 7, err: errors.New("exit status 7")})
	out := strings.Join(next.(model).lines, "\n")
	for _, want := range []string{"deploy.ps1", "Просмотр событий", "Код завершения: 7"} {
		if !strings.Contains(out, want) {
			t.Errorf("в журнале %q нет %q", out, want)
		}
	}
}

func TestEmergencyStopKey(t *testing.T) {
	q := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("q")}
	for _, tc := range []struct {
		name   string
		dialog *dialog
		key    tea.KeyMsg
		stop   bool
	}{
		{"работает", nil, q, true},
		{"вопрос", newDialog(uiEvent{Kind: "confirm"}, 100, 30), q, true},
		{"ввод", newDialog(uiEvent{Kind: "text"}, 100, 30), q, false},
		{"Ctrl+C при вводе", newDialog(uiEvent{Kind: "text"}, 100, 30), tea.KeyMsg{Type: tea.KeyCtrlC}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := testModel(100, 30)
			m.starting, m.running = false, true
			m.eng = &engine{channel: t.TempDir()}
			m.dialog = tc.dialog
			next, _ := m.Update(tc.key)
			got := next.(model)
			_, err := os.Stat(filepath.Join(m.eng.channel, "stop"))
			if (err == nil) != tc.stop || got.stopSent != tc.stop {
				t.Fatal("неверное состояние канала остановки")
			}
			if tc.stop {
				next, _ = next.Update(eventMsg{ev: uiEvent{Kind: "confirm", ID: 42}})
				if next.(model).dialog != nil {
					t.Fatal("открылся вопрос после остановки")
				}
			}
		})
	}
}
