package main

// ci.exe - экран гейта и обновления расширений 1С. Сам ничего не проверяет и не грузит: запускает run.ps1
// (или deploy.ps1 ключом -deploy) с ключом -UiChannel и показывает его ход, вопросы и журнал.
// Лежит в C:\ci рядом с run.ps1. Запуск: ci (меню гейта), ci -deploy (сразу обновление рабочей базы),
// ci -status (deploy -StatusOnly).

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var version = "dev"

var program *tea.Program

func findBaseDir(explicit string) (string, error) {
	candidates := []string{}
	if explicit != "" {
		candidates = append(candidates, explicit)
	}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Dir(exe))
	}
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates, wd)
	}
	candidates = append(candidates, `C:\ci`)
	for _, dir := range candidates {
		if _, err := os.Stat(filepath.Join(dir, "run.ps1")); err == nil {
			return dir, nil
		}
	}
	if os.Getenv("CI_ENGINE") != "" && len(candidates) > 0 {
		return candidates[0], nil
	}
	return "", fmt.Errorf("не нашёл run.ps1: ci.exe должен лежать в папке гейта (C:\\ci)")
}

func hideChildWindow(cmd *exec.Cmd) {}

// defaultFontSize - высота шрифта консоли по умолчанию: 20, или из переменной CI_FONT.
func defaultFontSize() int {
	if v := os.Getenv("CI_FONT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return 20
}

func main() {
	dirFlag := flag.String("dir", "", "папка гейта (по умолчанию - папка ci.exe)")
	deploy := flag.Bool("deploy", false, "сразу обновление рабочей базы (deploy.ps1)")
	status := flag.Bool("status", false, "deploy.ps1 -StatusOnly: итог гейта и сравнение temp и рабочей")
	settings := flag.Bool("settings", false, "настройки (settings.ps1)")
	showVersion := flag.Bool("version", false, "версия")
	fontSize := flag.Int("font", defaultFontSize(), "высота шрифта консоли, 0 - не менять (или переменная CI_FONT)")
	flag.Parse()
	if *showVersion {
		fmt.Println("ci", version)
		return
	}
	baseDir, err := findBaseDir(*dirFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	script := "run.ps1"
	var extra []string
	if *deploy || *status {
		script = "deploy.ps1"
	}
	if *status {
		extra = append(extra, "-StatusOnly")
	}
	if *settings {
		script = "settings.ps1"
	}

	// Тёмный фон задаём сами: иначе lipgloss спрашивает цвет фона у терминала и ждёт ответа до 5 секунд.
	lipgloss.SetHasDarkBackground(true)
	restoreFont := enlargeConsoleFont(*fontSize)
	defer restoreFont()
	m := newModel(baseDir, script, extra)
	program = tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	final, err := program.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "ci:", err)
		os.Exit(1)
	}
	if fm, ok := final.(model); ok {
		if fm.running && fm.eng != nil {
			// Вышли, пока скрипт работает (не должно быть: q при работе - остановка). Просим остановиться.
			_ = fm.eng.requestStop()
		}
		restoreFont()
		os.Exit(fm.exitCode)
	}
}
