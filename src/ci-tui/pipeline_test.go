package main

import "testing"

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
