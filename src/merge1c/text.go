package main

import (
	"bytes"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"unicode/utf8"
)

var bom = []byte{0xEF, 0xBB, 0xBF}

// stripBOM - текст без метки порядка байтов и длина метки (3 или 0).
func stripBOM(data []byte) ([]byte, int) {
	if bytes.HasPrefix(data, bom) {
		return data[3:], 3
	}
	return data, 0
}

// normalize - текст для сравнения и хеша единицы: без BOM, переводы строк - \n, без пробелов в конце строк и без
// пустых строк по краям. Так одна и та же процедура из выгрузки с CRLF и из файла с LF - одна версия.
func normalize(data []byte) string {
	text, _ := stripBOM(data)
	s := strings.ReplaceAll(string(text), "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	lines := strings.Split(s, "\n")
	for i, line := range lines {
		lines[i] = strings.TrimRight(line, " \t")
	}
	return strings.Trim(strings.Join(lines, "\n"), "\n")
}

// unitHash - отпечаток единицы: sha256 нормализованного текста, первые 16 байт в hex.
func unitHash(data []byte) string {
	sum := sha256.Sum256([]byte(normalize(data)))
	return hex.EncodeToString(sum[:16])
}

// fileSHA256 - полный sha256 файла в hex (для бинарных частей и оригиналов).
func fileSHA256(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// gitBlobSHA - хеш блоба git (как git hash-object): им гейт и GitHub называют версии файлов.
func gitBlobSHA(data []byte) string {
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(data))
	h.Write(data)
	return hex.EncodeToString(h.Sum(nil))
}

// isText - похоже ли содержимое на текст выгрузки: UTF-8 без нулевых байтов.
func isText(data []byte) bool {
	body, _ := stripBOM(data)
	if bytes.IndexByte(body, 0) >= 0 {
		return false
	}
	return utf8.Valid(body)
}

// splitLinesKeep - строки вместе с их переводами строк (последняя - как есть).
func splitLinesKeep(text string) []string {
	var lines []string
	for len(text) > 0 {
		i := strings.IndexByte(text, '\n')
		if i < 0 {
			lines = append(lines, text)
			break
		}
		lines = append(lines, text[:i+1])
		text = text[i+1:]
	}
	return lines
}

// eolOf - перевод строки, которым пользуется текст (CRLF у выгрузок конфигуратора).
func eolOf(text string) string {
	if strings.Contains(text, "\r\n") {
		return "\r\n"
	}
	return "\n"
}

// unifiedDiff - короткая построчная разница двух версий (по нормализованному тексту): «-» - наше, «+» - поставка.
// Для решения оператора: видно ровно то, чем версии расходятся. Context - строк вокруг, Limit - не больше строк.
func unifiedDiff(ours, theirs string, context, limit int) string {
	a := strings.Split(ours, "\n")
	b := strings.Split(theirs, "\n")
	if ours == "" {
		a = nil
	}
	if theirs == "" {
		b = nil
	}
	ops := diffOps(a, b)
	// Какие строки показывать: изменённые и Context вокруг.
	show := make([]bool, len(ops))
	for i, op := range ops {
		if op.kind != ' ' {
			for j := i - context; j <= i+context; j++ {
				if j >= 0 && j < len(ops) {
					show[j] = true
				}
			}
		}
	}
	var out []string
	skipped := false
	for i, op := range ops {
		if !show[i] {
			skipped = true
			continue
		}
		if skipped && len(out) > 0 {
			out = append(out, "…")
		}
		skipped = false
		out = append(out, string(op.kind)+" "+op.text)
		if limit > 0 && len(out) >= limit {
			out = append(out, fmt.Sprintf("… (разница длиннее %d строк, полностью - в файлах поставки)", limit))
			break
		}
	}
	return strings.Join(out, "\n")
}

type diffOp struct {
	kind byte // ' ', '-', '+'
	text string
}

// diffOps - разница по наибольшей общей подпоследовательности. Для единиц (процедур, объектов) хватает квадратичной;
// на очень длинных текстах - грубо: всё старое снято, всё новое добавлено.
func diffOps(a, b []string) []diffOp {
	n, m := len(a), len(b)
	if n*m > 4_000_000 {
		var ops []diffOp
		for _, s := range a {
			ops = append(ops, diffOp{'-', s})
		}
		for _, s := range b {
			ops = append(ops, diffOp{'+', s})
		}
		return ops
	}
	lcs := make([][]int32, n+1)
	for i := range lcs {
		lcs[i] = make([]int32, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else if lcs[i+1][j] >= lcs[i][j+1] {
				lcs[i][j] = lcs[i+1][j]
			} else {
				lcs[i][j] = lcs[i][j+1]
			}
		}
	}
	var ops []diffOp
	i, j := 0, 0
	for i < n && j < m {
		if a[i] == b[j] {
			ops = append(ops, diffOp{' ', a[i]})
			i++
			j++
		} else if lcs[i+1][j] >= lcs[i][j+1] {
			ops = append(ops, diffOp{'-', a[i]})
			i++
		} else {
			ops = append(ops, diffOp{'+', b[j]})
			j++
		}
	}
	for ; i < n; i++ {
		ops = append(ops, diffOp{'-', a[i]})
	}
	for ; j < m; j++ {
		ops = append(ops, diffOp{'+', b[j]})
	}
	return ops
}

// shortText - первые строки текста для описания решения.
func shortText(text string, lines int) string {
	parts := strings.Split(text, "\n")
	if len(parts) <= lines {
		return text
	}
	return strings.Join(parts[:lines], "\n") + fmt.Sprintf("\n… ещё строк: %d", len(parts)-lines)
}
