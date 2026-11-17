//go:build windows

package main

// Шрифт консоли. Bubble Tea шрифт не меняет: это свойство окна консоли (conhost), его ставит WinAPI
// SetCurrentConsoleFontEx. В Windows Terminal вызов ничего не делает - там шрифт крупнее по Ctrl+=.

import (
	"syscall"
	"unsafe"
)

type consoleFontInfoEx struct {
	cbSize     uint32
	nFont      uint32
	sizeX      int16
	sizeY      int16
	fontFamily uint32
	fontWeight uint32
	faceName   [32]uint16
}

var (
	kernel32           = syscall.NewLazyDLL("kernel32.dll")
	procGetStdHandle   = kernel32.NewProc("GetStdHandle")
	procGetConsoleFont = kernel32.NewProc("GetCurrentConsoleFontEx")
	procSetConsoleFont = kernel32.NewProc("SetCurrentConsoleFontEx")
)

func consoleOut() uintptr {
	const stdOutputHandle = ^uintptr(10) // (DWORD)-11
	h, _, _ := procGetStdHandle.Call(stdOutputHandle)
	return h
}

// enlargeConsoleFont - крупнее шрифт, если сейчас он мельче size. Возвращает, как вернуть прежний.
func enlargeConsoleFont(size int) func() {
	if size <= 0 {
		return func() {}
	}
	h := consoleOut()
	var old consoleFontInfoEx
	old.cbSize = uint32(unsafe.Sizeof(old))
	if r, _, _ := procGetConsoleFont.Call(h, 0, uintptr(unsafe.Pointer(&old))); r == 0 {
		return func() {}
	}
	if int(old.sizeY) >= size {
		return func() {}
	}
	next := old
	next.nFont = 0
	next.sizeX = 0
	next.sizeY = int16(size)
	if r, _, _ := procSetConsoleFont.Call(h, 0, uintptr(unsafe.Pointer(&next))); r == 0 {
		return func() {}
	}
	return func() {
		back := old
		back.nFont = 0
		procSetConsoleFont.Call(h, 0, uintptr(unsafe.Pointer(&back)))
	}
}
