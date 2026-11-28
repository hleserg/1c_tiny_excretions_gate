package main

import (
	"fmt"
	"strings"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// Сообщения YAxUnit хранятся отдельно от шагов, вопросов и вердикта гейта.
type testLog struct {
	title  string
	lines  []string
	window *dialog
}

func (l *testLog) receive(ev uiEvent, width, height int) {
	if ev.Title != "" {
		l.title = ev.Title
		l.lines = nil
	}
	for _, line := range ev.Lines {
		line = strings.Map(func(r rune) rune {
			if r == '\t' {
				return ' '
			}
			if unicode.IsControl(r) {
				return -1
			}
			return r
		}, ansi.Strip(line))
		l.lines = append(l.lines, line)
	}
	if len(l.lines) > maxLogLines {
		l.lines = l.lines[len(l.lines)-maxLogLines:]
	}
	if d := l.window; d != nil {
		follow := d.view.AtBottom()
		d.ev.Header, d.ev.Lines = l.title, l.displayLines()
		d.resize(width, height)
		if follow {
			d.view.GotoBottom()
		}
	}
}

func (l *testLog) displayLines() []string {
	if len(l.lines) == 0 {
		return []string{"Пока нет сообщений."}
	}
	return l.lines
}

func (l *testLog) toggle(width, height int) {
	if l.window != nil {
		l.window = nil
	} else if l.title != "" {
		l.window = newDialog(uiEvent{Kind: "view", Header: l.title, Lines: l.displayLines()}, width, height)
		l.window.local = "test-log"
		l.window.view.GotoBottom()
	}
}

func (l *testLog) key(msg tea.KeyMsg) tea.Cmd {
	switch msg.String() {
	case "f2":
		if err := writeClipboard(strings.Join(l.lines, "\r\n")); err != nil {
			l.window.copyNotice = "Не удалось скопировать журнал: " + err.Error()
		} else {
			l.window.copyNotice = fmt.Sprintf("Скопировано строк: %d.", len(l.lines))
		}
	case "home":
		l.window.view.GotoTop()
	case "end":
		l.window.view.GotoBottom()
	case "esc", "enter", "q", "ctrl+c":
		l.window = nil
	default:
		return l.window.Update(msg)
	}
	return nil
}
