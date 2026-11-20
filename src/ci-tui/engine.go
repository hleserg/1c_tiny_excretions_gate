package main

// Движок - run.ps1 или deploy.ps1. ci.exe запускает его с ключом -UiChannel <папка>, читает его вывод
// построчно и отвечает на вопросы файлами в папке канала. Протокол описан в ui.ps1.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const uiPrefix = "@@ui:"

// uiEvent - строка «@@ui:{json}» из вывода движка.
type uiEvent struct {
	Kind        string     `json:"kind"`
	ID          int        `json:"id"`
	Header      string     `json:"header"`
	Notes       []string   `json:"notes"`
	Items       []string   `json:"items"`
	Steps       []string   `json:"steps"`
	Parallel    []string   `json:"parallel"`
	Groups      []string   `json:"groups"`
	Value       string     `json:"value"`
	Secret      bool       `json:"secret"`
	Danger      []int      `json:"danger"`
	Current     string     `json:"current"`
	Blocks      []subBlock `json:"blocks"`
	Preselected []int      `json:"preselected"`
	AllowEmpty  bool       `json:"allowEmpty"` // вопрос many: Enter без отметок - ответ «ни одного», а не отказ
	Restart     bool       `json:"restart"`    // событие close: после выхода открыть ci заново (новый ci.exe)
	DefaultNo   bool       `json:"defaultNo"`  // вопрос confirm: Enter сразу выбирает «нет»
	Sections    []string   `json:"sections"`   // вопрос one: заголовок группы перед пунктом, "" - нет; по одному на пункт
	Keys        []string   `json:"keys"`       // вопрос one: своя клавиша пункта (1-9, a-z) вместо порядковой; по одной на пункт
	Hints       []string   `json:"hints"`      // вопрос one: пояснение пункта серым рядом с подписью, "" - нет; по одному на пункт
	Status      string     `json:"status"`     // событие step: итог долгой операции - OK, WARN или FAIL
	Ops         bool       `json:"ops"`        // событие plan: план долгих операций без вердикта, шаги закрывает событие step
	Yes         string     `json:"yes"`
	No          string     `json:"no"`
	Lines       []string   `json:"lines"`
	Poll        bool       `json:"poll"`
	Style       string     `json:"style"`
	Text        string     `json:"text"`
	More        []string   `json:"more"`
	Title       string     `json:"title"`
	Elapsed     float64    `json:"elapsed"`
	Expected    float64    `json:"expected"`
	// Сколько осталось всего прогона по оценке скрипта, секунд; -1 - неизвестно. RemainingUnknown - сколько
	// оставшихся шагов без статистики (их время в оценку не вошло).
	Remaining        *float64 `json:"remaining"`
	RemainingUnknown int      `json:"remainingUnknown"`
	Done             int      `json:"done"`
	Total            int      `json:"total"`
	Detail           string   `json:"detail"`
}

// answer - ответ на вопрос, файл a-<id>.json в папке канала.
type answer struct {
	Cancel  bool   `json:"cancel"`
	Index   int    `json:"index"`
	Indexes []int  `json:"indexes"`
	Yes     bool   `json:"yes"`
	Text    string `json:"text"`
}

// Сообщения от движка в модель.
type lineMsg struct{ text string }
type eventMsg struct{ ev uiEvent }
type exitMsg struct {
	code int
	err  error
}

type engine struct {
	cmd     *exec.Cmd
	stdout  io.Reader
	stderr  io.Reader
	channel string
	started time.Time
	script  string
}

// engineCommand - чем запускать движок. Переменная CI_ENGINE (команда через «|») - для проверки ci.exe
// без 1С: подставляется поддельный движок.
func engineCommand(baseDir, script string, extra []string, channel string) *exec.Cmd {
	if fake := os.Getenv("CI_ENGINE"); fake != "" {
		parts := strings.Split(fake, "|")
		args := append(parts[1:], extra...)
		args = append(args, "-UiChannel", channel)
		return exec.Command(parts[0], args...)
	}
	args := []string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(baseDir, script)}
	args = append(args, extra...)
	args = append(args, "-UiChannel", channel)
	return exec.Command("powershell.exe", args...)
}

func startEngine(baseDir, script string, extra []string) (*engine, error) {
	// Папка канала - в папке гейта (ui\), а не в %TEMP%: сессионную временную папку RDP Windows чистит при
	// отключении, и вопрос, оставшийся без ответа на ночь, уже не получал ответа. Не вышло - %TEMP%, как раньше.
	uiDir := filepath.Join(baseDir, "ui")
	_ = os.MkdirAll(uiDir, 0o755)
	channel, err := os.MkdirTemp(uiDir, "ci-ui-")
	if err != nil {
		channel, err = os.MkdirTemp("", "ci-ui-")
	}
	if err != nil {
		return nil, fmt.Errorf("не создал папку канала: %w", err)
	}
	cmd := engineCommand(baseDir, script, extra, channel)
	cmd.Dir = baseDir
	cmd.Stdin = nil
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	hideChildWindow(cmd)
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("не запустился %s: %w", script, err)
	}
	return &engine{cmd: cmd, stdout: stdout, stderr: stderr, channel: channel, started: time.Now(), script: script}, nil
}

// Модель уже приняла engineStartedMsg: даже короткий процесс не пришлёт выход раньше запуска.
func (e *engine) wait(p *tea.Program) tea.Msg {
	done := make(chan struct{}, 2)
	go readLines(p, e.stdout, done)
	go readLines(p, e.stderr, done)
	<-done
	<-done
	err := e.cmd.Wait()
	code := 0
	if e.cmd.ProcessState != nil {
		code = e.cmd.ProcessState.ExitCode()
	}
	return exitMsg{code: code, err: err}
}

func readLines(p *tea.Program, r io.Reader, done chan<- struct{}) {
	defer func() { done <- struct{}{} }()
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r")
		line = strings.TrimPrefix(line, "\ufeff")
		if strings.HasPrefix(line, uiPrefix) {
			var ev uiEvent
			if err := json.Unmarshal([]byte(line[len(uiPrefix):]), &ev); err == nil {
				p.Send(eventMsg{ev: ev})
				continue
			}
		}
		p.Send(lineMsg{text: line})
	}
}

// answerQuestion кладёт ответ в папку канала. Сначала во временный файл, потом переименование:
// движок не прочитает недописанный ответ.
func (e *engine) answerQuestion(id int, a answer) error {
	if a.Indexes == nil {
		a.Indexes = []int{}
	}
	data, err := json.Marshal(a)
	if err != nil {
		return err
	}
	// Папку канала могли удалить (чистка временных файлов): создаём заново - движок ждёт ответ по тому же пути.
	if err := os.MkdirAll(e.channel, 0o755); err != nil {
		return err
	}
	final := filepath.Join(e.channel, fmt.Sprintf("a-%d.json", id))
	tmp := final + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, final)
}

// requestStop - просьба движку остановиться штатно (со снятием блокировок).
func (e *engine) requestStop() error {
	if err := os.MkdirAll(e.channel, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(e.channel, "stop"), []byte("stop"), 0o644)
}

// kill - если движок не реагирует на просьбу.
func (e *engine) kill() {
	if e.cmd != nil && e.cmd.Process != nil {
		_ = e.cmd.Process.Kill()
	}
}

func (e *engine) cleanup() {
	if e.channel != "" {
		_ = os.RemoveAll(e.channel)
	}
}
