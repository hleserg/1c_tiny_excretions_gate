package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func planModel(parallel ...string) *model {
	m := &model{running: true}
	m.setPlan([]string{"Подготовка базы", "Правила обмена", "Самопроверка после загрузки", "Модульные тесты", "Проверка конфигурации (all)"}, parallel)
	return m
}

func nodeStatus(m *model, name string) string {
	for _, n := range m.pipe {
		if n.name == name {
			return n.status
		}
	}
	return "нет шага"
}

// Событие reset (в меню выбрано следующее действие): шаги и вердикт прошлого прогона с экрана уходят.
func TestResetClearsPreviousRun(t *testing.T) {
	m := planModel()
	m.markProgress("Правила обмена")
	m.appendLine("[FAIL] Модульные тесты")
	m.appendLine("ВЕРДИКТ: КРАСНЫЙ")
	if m.verdict == "" || len(m.pipe) == 0 || len(m.steps) == 0 {
		t.Fatalf("подготовка теста: вердикт %q, труба %d, шаги %d", m.verdict, len(m.pipe), len(m.steps))
	}
	m.resetRun()
	if m.verdict != "" || len(m.pipe) != 0 || len(m.steps) != 0 || m.planned || m.sub != nil || m.eta != nil {
		t.Fatalf("после reset остался прошлый прогон: вердикт %q, труба %d, шаги %d, план %v", m.verdict, len(m.pipe), len(m.steps), m.planned)
	}
	// Журнал справа остаётся: reset - не очистка экрана.
	if len(m.lines) != 2 {
		t.Fatalf("reset тронул журнал: строк %d", len(m.lines))
	}
	// Новый план после reset - с чистого листа.
	m.setPlan([]string{"Сохранить текущее"}, nil)
	if got := nodeStatus(m, "Сохранить текущее"); got != nodePending {
		t.Fatalf("шаг нового плана: %q", got)
	}
}

// Параллельная проверка конфигурации кончилась раньше своего места в плане: шаги перед ней остаются в работе.
func TestParallelResultKeepsEarlierSteps(t *testing.T) {
	m := planModel("Проверка конфигурации (all)")
	m.markProgress("Правила обмена")
	m.markResult("WARN", "Проверка конфигурации (all)")
	if got := nodeStatus(m, "Правила обмена"); got != nodePending {
		t.Fatalf("текущий шаг закрыт результатом параллельного: %q", got)
	}
	if got := nodeStatus(m, "Самопроверка после загрузки"); got != nodePending {
		t.Fatalf("следующий шаг закрыт результатом параллельного: %q", got)
	}
	if got := nodeStatus(m, "Проверка конфигурации (all)"); got != "WARN" {
		t.Fatalf("параллельный шаг не отмечен: %q", got)
	}
	if i := m.firstPending(); i < 0 || m.pipe[i].name != "Правила обмена" {
		t.Fatalf("активным стал не текущий шаг: %d", i)
	}
	m.markResult("OK", "Правила обмена")
	m.markProgress("Самопроверка после загрузки")
	if i := m.firstPending(); i < 0 || m.pipe[i].name != "Самопроверка после загрузки" {
		t.Fatalf("после «Правил обмена» активна не самопроверка: %d", i)
	}
	if got := nodeStatus(m, verdictNode); got != nodePending {
		t.Fatalf("вердикт отмечен раньше времени: %q", got)
	}
}

// Движок старой версии не называет параллельные шаги: ранний результат закрывает шаги перед собой,
// но шаг, по которому пошла полоса хода, открывается снова и становится активным.
func TestProgressReopensStepClosedTooEarly(t *testing.T) {
	m := planModel()
	m.markProgress("Правила обмена")
	m.markResult("WARN", "Проверка конфигурации (all)")
	if got := nodeStatus(m, "Самопроверка после загрузки"); got != nodeNotRun {
		t.Fatalf("ждали «не выполнялся» до начала шага: %q", got)
	}
	m.markResult("OK", "Правила обмена")
	m.markProgress("Самопроверка после загрузки")
	if got := nodeStatus(m, "Самопроверка после загрузки"); got != nodePending {
		t.Fatalf("начатый шаг не открылся снова: %q", got)
	}
	if i := m.firstPending(); i < 0 || m.pipe[i].name != "Самопроверка после загрузки" {
		t.Fatalf("активным стал не начатый шаг: %d", i)
	}
	m.markResult("OK", "Самопроверка после загрузки")
	if got := nodeStatus(m, "Самопроверка после загрузки"); got != "OK" {
		t.Fatalf("результат не отмечен: %q", got)
	}
}

// Обычный порядок не изменился: результат шага закрывает пропущенные перед ним.
func TestSequentialResultStillClosesSkipped(t *testing.T) {
	m := planModel("Проверка конфигурации (all)")
	m.markResult("OK", "Самопроверка после загрузки")
	if got := nodeStatus(m, "Подготовка базы"); got != nodePass {
		t.Fatalf("подготовка не закрыта: %q", got)
	}
	if got := nodeStatus(m, "Правила обмена"); got != nodeNotRun {
		t.Fatalf("пропущенный шаг не отмечен невыполненным: %q", got)
	}
}

func TestBlockKnownCounts(t *testing.T) {
	b := subBlock{Name: "Метаданные и права", Done: 1, Total: 1, Ok: 43, Warn: 3, KnownWarn: 3}
	if b.newWarn() != 0 || b.known() != 3 {
		t.Fatalf("известные предупреждения: новых %d, известных %d", b.newWarn(), b.known())
	}
	// Известного не может быть больше, чем всего: лишнее не уводит счёт в минус.
	c := subBlock{Err: 1, KnownErr: 5, Skip: 2}
	if c.newErr() != 0 || c.newSkip() != 2 || c.known() != 1 {
		t.Fatalf("границы: новых ошибок %d, пропусков %d, известных %d", c.newErr(), c.newSkip(), c.known())
	}
	d := subBlock{Err: 2, KnownErr: 1}
	if d.newErr() != 1 {
		t.Fatalf("одна ошибка новая: %d", d.newErr())
	}
}

// Событие close (после обновления гейта): ci закрывается сам, когда скрипт кончился без ошибки; restart - признак
// для main, что нужно открыть ci заново. С ошибкой скрипта экран остаётся.
func TestCloseEventQuitsAfterScript(t *testing.T) {
	m := newModel("", "", nil)
	m.running = true
	next, _ := m.update(eventMsg{ev: uiEvent{Kind: "close", Restart: true}})
	m = next.(model)
	if !m.closeAfter || !m.restartAfter {
		t.Fatalf("close не запомнен: закрыть %v, перезапустить %v", m.closeAfter, m.restartAfter)
	}
	next, cmd := m.update(exitMsg{code: 0})
	done := next.(model)
	if cmd == nil {
		t.Fatal("скрипт кончился после close, а ci не закрывается")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatalf("после close ждали выход из ci, пришло %T", cmd())
	}
	if done.running || !done.restartAfter {
		t.Fatalf("состояние перед выходом: работает %v, перезапустить %v", done.running, done.restartAfter)
	}

	// Скрипт упал: ci остаётся на экране, чтобы ошибку прочитали.
	failed, _ := m.update(exitMsg{code: 1})
	if fm := failed.(model); fm.exitCode != 1 || fm.running {
		t.Fatalf("после ошибки: код %d, работает %v", fm.exitCode, fm.running)
	}
	_, failCmd := m.update(exitMsg{code: 1})
	if failCmd != nil {
		if _, quit := failCmd().(tea.QuitMsg); quit {
			t.Fatal("скрипт кончился с ошибкой, а ci закрылся")
		}
	}

	// Без restart - просто закрыться.
	plain := newModel("", "", nil)
	plain.running = true
	next, _ = plain.update(eventMsg{ev: uiEvent{Kind: "close"}})
	if pm := next.(model); !pm.closeAfter || pm.restartAfter {
		t.Fatalf("close без restart: закрыть %v, перезапустить %v", pm.closeAfter, pm.restartAfter)
	}

	// Скрипт запущен заново (Enter после ошибки): прежняя просьба закрыться больше не действует.
	again, _ := m.update(engineStartedMsg{eng: nil})
	if am := again.(model); am.closeAfter || am.restartAfter {
		t.Fatal("новый запуск скрипта унаследовал просьбу закрыть ci")
	}
}

// Перезапуск берёт ci.exe из папки гейта (после обновления там новый), а если его нет - тот же файл, что работает.
func TestRestartTarget(t *testing.T) {
	dir := t.TempDir()
	self := filepath.Join(dir, "self.exe")
	if err := os.WriteFile(self, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	gate := filepath.Join(dir, "gate")
	if err := os.MkdirAll(gate, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := restartTarget(gate, self); got != self {
		t.Fatalf("в папке гейта ci.exe нет: ждали %q, получили %q", self, got)
	}
	fresh := filepath.Join(gate, "ci.exe")
	if err := os.WriteFile(fresh, []byte("y"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := restartTarget(gate, self); got != fresh {
		t.Fatalf("в папке гейта новый ci.exe: ждали %q, получили %q", fresh, got)
	}
	if got := restartTarget(filepath.Join(dir, "нет"), ""); got != "" {
		t.Fatalf("ни одного файла: ждали пусто, получили %q", got)
	}
}

// Событие step: у действия без плана шагов долгие операции копятся в колонке шагов с итогом и временем; при плане
// колонку ведёт план, событие её не трогает.
func TestStepEventWithoutPlan(t *testing.T) {
	m := newModel("", "", nil)
	m.running = true
	for _, ev := range []uiEvent{
		{Kind: "step", Title: "Типовая: git add (файлы - в pack)", Status: "OK", Elapsed: 367},
		{Kind: "step", Title: "Типовая: git fetch (что сейчас в GitHub)", Status: "WARN", Elapsed: 1},
		{Kind: "step", Title: "Типовая: git push (отправка в GitHub)", Status: "FAIL", Elapsed: 725},
		{Kind: "step", Title: "", Status: "OK"},
		{Kind: "step", Title: "Мусор", Status: "чужое"},
	} {
		next, _ := m.update(eventMsg{ev: ev})
		m = next.(model)
	}
	if len(m.pipe) != 3 {
		t.Fatalf("в колонке шагов %d операций, ждали 3", len(m.pipe))
	}
	if m.pipe[0].status != "OK" || m.pipe[1].status != "WARN" || m.pipe[2].status != "FAIL" {
		t.Fatalf("итоги операций: %q %q %q", m.pipe[0].status, m.pipe[1].status, m.pipe[2].status)
	}
	if got := m.pipe[0].finished.Sub(m.pipe[0].started).Round(time.Second); got != 367*time.Second {
		t.Fatalf("длительность первой операции %v, ждали 6m7s", got)
	}
	// С планом шагов событие step колонку не меняет.
	planned := planModel()
	before := len(planned.pipe)
	planned.addOperation("Выгрузить расширение в файлы", "OK", 30)
	if len(planned.pipe) != before {
		t.Fatalf("при плане шагов событие step добавило шаг: было %d, стало %d", before, len(planned.pipe))
	}
}
