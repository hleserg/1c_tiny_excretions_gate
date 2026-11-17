package main

// Второй трубопровод: шаги внутри длинного шага (самопроверка «Выполнить после обновления»). Движок шлёт
// событие subplan: шаги с числом заданий, сделанным, ОК, ошибками, внимание, пропусками и текущий шаг.
// На широком экране - отдельная колонка рядом с шагами прогона, на узком - текущий шаг под активным узлом.

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

type subBlock struct {
	Name  string `json:"name"`
	Done  int    `json:"done"`
	Total int    `json:"total"`
	Ok    int    `json:"ok"`
	Err   int    `json:"err"`
	Warn  int    `json:"warn"`
	Skip  int    `json:"skip"`
}

type subState struct {
	title   string
	current string
	task    string
	blocks  []subBlock
	since   time.Time // когда начался текущий шаг
}

const subWidth = 44

func (m *model) setSubPlan(ev uiEvent) {
	if m.sub == nil || m.sub.title != ev.Title || m.sub.current != ev.Current {
		since := time.Now()
		m.sub = &subState{since: since}
	}
	m.sub.title = ev.Title
	m.sub.current = ev.Current
	m.sub.task = ev.Text
	m.sub.blocks = ev.Blocks
}

// subWide - колонка внутренних шагов рядом с шагами прогона: только на широком экране.
func (m model) subWide() bool {
	return m.sub != nil && m.width >= minWidthForSteps+subWidth+20
}

func blockIcon(b subBlock, active bool, frame int) string {
	switch {
	case active:
		c := pulseColors[(frame/2)%len(pulseColors)]
		return lipgloss.NewStyle().Foreground(c).Bold(true).Render("●")
	case b.Err > 0:
		return styleBadBold.Render("×")
	case b.Warn > 0:
		return styleWarnBold.Render("!")
	case b.Total > 0 && b.Done >= b.Total:
		return styleOkBold.Render("√")
	case b.Done > 0:
		return styleAccent.Render("■")
	default:
		return styleTrack.Render("○")
	}
}

// miniBar - полоска из блоков: залитая часть - цвет итога шага.
func miniBar(done, total, width int, st lipgloss.Style) string {
	if width < 4 {
		width = 4
	}
	fill := 0
	if total > 0 {
		fill = done * width / total
		if done > 0 && fill == 0 {
			fill = 1
		}
	}
	return st.Render(strings.Repeat("█", fill)) + styleTrack.Render(strings.Repeat("░", width-fill))
}

func blockStyle(b subBlock) lipgloss.Style {
	switch {
	case b.Err > 0:
		return styleBad
	case b.Warn > 0:
		return styleWarn
	case b.Total > 0 && b.Done >= b.Total:
		return styleOk
	default:
		return styleAccent
	}
}

func blockCounters(b subBlock) string {
	var parts []string
	if b.Ok > 0 {
		parts = append(parts, styleOk.Render(fmt.Sprintf("ок %d", b.Ok)))
	}
	if b.Err > 0 {
		parts = append(parts, styleBadBold.Render(fmt.Sprintf("ошиб %d", b.Err)))
	}
	if b.Warn > 0 {
		parts = append(parts, styleWarn.Render(fmt.Sprintf("вним %d", b.Warn)))
	}
	if b.Skip > 0 {
		parts = append(parts, styleDim.Render(fmt.Sprintf("проп %d", b.Skip)))
	}
	return strings.Join(parts, " ")
}

// viewSub - колонка «Внутри шага»: общая полоса, итоги, текущее задание, шаги с полосками.
func (m model) viewSub(width, height int) string {
	s := m.sub
	var lines []string
	head := styleSection.Render("Внутри: ")
	lines = append(lines, strings.Split(hang(head, s.title, width, styleText), "\n")...)
	done, total, ok, errs, warn := 0, 0, 0, 0, 0
	for _, b := range s.blocks {
		done += b.Done
		total += b.Total
		ok += b.Ok
		errs += b.Err
		warn += b.Warn
	}
	pct := 0
	if total > 0 {
		pct = done * 100 / total
	}
	counts := fmt.Sprintf("%d/%d %3d%%", done, total, pct)
	lines = append(lines, miniBar(done, total, width-len([]rune(counts))-1, styleAccent)+" "+styleDim.Render(counts))
	tot := styleOk.Render(fmt.Sprintf("ок %d", ok))
	if errs > 0 {
		tot += "  " + styleBadBold.Render(fmt.Sprintf("ошибок %d", errs))
	}
	if warn > 0 {
		tot += "  " + styleWarnBold.Render(fmt.Sprintf("внимание %d", warn))
	}
	lines = append(lines, tot)
	if s.task != "" {
		lines = append(lines, strings.Split(hang(styleAccent.Render(m.spin.View())+" ", s.task, width, styleDim), "\n")...)
	}
	lines = append(lines, "")

	// Шаги: имя с переносом, под ним полоска и счётчики. Не влезает - окно вокруг текущего.
	type item struct{ rows []string }
	var items []item
	active := -1
	for i, b := range s.blocks {
		isActive := b.Name == s.current && (b.Total == 0 || b.Done < b.Total)
		if isActive {
			active = i
		}
		var rows []string
		nameStyle := styleText
		if !isActive && b.Done == 0 {
			nameStyle = styleTrack
		}
		if isActive {
			nameStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("230")).Bold(true)
		}
		rows = append(rows, strings.Split(hang(blockIcon(b, isActive, m.frame)+" ", b.Name, width, nameStyle), "\n")...)
		second := "  " + miniBar(b.Done, b.Total, 12, blockStyle(b)) + " " + styleDim.Render(fmt.Sprintf("%d/%d", b.Done, b.Total))
		if c := blockCounters(b); c != "" {
			second += " " + c
		}
		if isActive {
			second += " " + styleAccent.Render(formatDuration(time.Since(s.since).Seconds()))
		}
		rows = append(rows, second)
		items = append(items, item{rows: rows})
	}
	room := height - len(lines)
	from, to := 0, len(items)
	used := 0
	for _, it := range items {
		used += len(it.rows)
	}
	if used > room && room > 0 {
		center := active
		if center < 0 {
			center = 0
		}
		from, to = center, center+1
		used = len(items[center].rows)
		for {
			grown := false
			if to < len(items) && used+len(items[to].rows) <= room {
				used += len(items[to].rows)
				to++
				grown = true
			}
			if from > 0 && used+len(items[from-1].rows) <= room {
				from--
				used += len(items[from].rows)
				grown = true
			}
			if !grown {
				break
			}
		}
	}
	for i := from; i < to; i++ {
		lines = append(lines, items[i].rows...)
	}
	if len(lines) > height {
		lines = lines[:height]
	}
	return strings.Join(lines, "\n")
}

// subInline - на узком экране: текущий внутренний шаг под активным узлом трубы.
func (m model) subInline(width int) []string {
	s := m.sub
	if s == nil {
		return nil
	}
	for _, b := range s.blocks {
		if b.Name != s.current {
			continue
		}
		out := strings.Split(hang("  "+styleAccent.Render("└ "), b.Name, width, styleDim), "\n")
		out = append(out, "    "+miniBar(b.Done, b.Total, 10, blockStyle(b))+" "+styleDim.Render(fmt.Sprintf("%d/%d", b.Done, b.Total)))
		return out
	}
	return nil
}
