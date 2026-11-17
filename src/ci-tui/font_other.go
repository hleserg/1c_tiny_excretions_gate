//go:build !windows

package main

func enlargeConsoleFont(size int) func() { return func() {} }
