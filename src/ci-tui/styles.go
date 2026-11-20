package main

import "github.com/charmbracelet/lipgloss"

// Цвета - ANSI 256: одинаково видны в conhost Windows Server и в Windows Terminal.
var (
	colAccent = lipgloss.Color("69")
	colOk     = lipgloss.Color("42")
	colWarn   = lipgloss.Color("214")
	colBad    = lipgloss.Color("203")
	colDim    = lipgloss.Color("245")
	colTrack  = lipgloss.Color("238")
	colText   = lipgloss.Color("252")

	styleHeader        = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("230")).Background(lipgloss.Color("57"))
	styleAccent        = lipgloss.NewStyle().Foreground(colAccent)
	styleOk            = lipgloss.NewStyle().Foreground(colOk)
	styleOkBold        = lipgloss.NewStyle().Foreground(colOk).Bold(true)
	styleWarn          = lipgloss.NewStyle().Foreground(colWarn)
	styleWarnBold      = lipgloss.NewStyle().Foreground(colWarn).Bold(true)
	styleBad           = lipgloss.NewStyle().Foreground(colBad)
	styleBadBold       = lipgloss.NewStyle().Foreground(colBad).Bold(true)
	styleDim           = lipgloss.NewStyle().Foreground(colDim)
	styleText          = lipgloss.NewStyle().Foreground(colText)
	styleTrack         = lipgloss.NewStyle().Foreground(colTrack)
	styleHelp          = lipgloss.NewStyle().Foreground(colDim)
	styleSection       = lipgloss.NewStyle().Bold(true).Foreground(colAccent)
	styleSteps         = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colTrack).Padding(0, 1)
	styleSub           = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colAccent).Padding(0, 1)
	styleLog           = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colTrack)
	styleProgressBox   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colAccent).Padding(0, 1)
	styleProgressTitle = lipgloss.NewStyle().Bold(true).Foreground(colText)
	styleDialog        = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colAccent).Padding(1, 2)
	styleDocked        = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colAccent).Padding(0, 1)
	styleDialogTitle   = lipgloss.NewStyle().Bold(true).Foreground(colText)
	styleDialogGroup   = lipgloss.NewStyle().Bold(true).Foreground(colDim)
	styleCursor        = lipgloss.NewStyle().Foreground(colAccent).Bold(true)
	styleSelected      = lipgloss.NewStyle().Foreground(colAccent).Bold(true)
	styleButton        = lipgloss.NewStyle().Padding(0, 2).Foreground(colText).Background(lipgloss.Color("238"))
	styleButtonActive  = lipgloss.NewStyle().Padding(0, 2).Foreground(lipgloss.Color("230")).Background(lipgloss.Color("57")).Bold(true)

	styleTitleInfo = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colAccent).Padding(0, 1)
	styleTitleOk   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colOk).Padding(0, 1)
	styleTitleWarn = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colWarn).Padding(0, 1)
	styleTitleBad  = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colBad).Padding(0, 1)

	styleDangerItem       = lipgloss.NewStyle().Border(lipgloss.DoubleBorder()).BorderForeground(colBad).Foreground(colBad).Bold(true).Padding(0, 1).Align(lipgloss.Center)
	styleDangerItemActive = lipgloss.NewStyle().Border(lipgloss.DoubleBorder()).BorderForeground(colBad).Foreground(lipgloss.Color("230")).Background(lipgloss.Color("160")).Bold(true).Padding(0, 1).Align(lipgloss.Center)

	styleBadgeOk   = lipgloss.NewStyle().Foreground(lipgloss.Color("16")).Background(colOk).Bold(true)
	styleBadgeWarn = lipgloss.NewStyle().Foreground(lipgloss.Color("16")).Background(colWarn).Bold(true)
	styleBadgeBad  = lipgloss.NewStyle().Foreground(lipgloss.Color("16")).Background(colBad).Bold(true)
)
