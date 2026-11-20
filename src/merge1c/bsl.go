package main

import (
	"regexp"
	"strings"
)

// Модуль на встроенном языке, разобранный на единицы: процедуры и функции (с комментарием и директивами над
// объявлением) и блоки кода вне процедур (переменные модуля, раздел основной программы, свободные комментарии).
// Пустые строки и области (#Область/#КонецОбласти) - структура модуля: при объединении остаётся наша, новые
// процедуры поставки встают в ту же область, что у подрядчика, после той же процедуры.

type lineKind int

const (
	lkBlank lineKind = iota
	lkRegion
	lkEndRegion
	lkComment
	lkDirective
	lkDecl
	lkEnd
	lkCode
)

var (
	reDecl      = regexp.MustCompile(`(?i)^\s*(?:(?:асинх|async)\s+)?(?:процедура|функция|procedure|function)\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(`)
	reEnd       = regexp.MustCompile(`(?i)^\s*(?:конецпроцедуры|конецфункции|endprocedure|endfunction)(?:\s|;|//|$)`)
	reRegion    = regexp.MustCompile(`(?i)^\s*#\s*(?:область|region)(?:\s+(\S+))?`)
	reEndRegion = regexp.MustCompile(`(?i)^\s*#\s*(?:конецобласти|endregion)(?:\s|$)`)
)

type bslMethod struct {
	Name   string
	Key    string
	First  int // первая строка (комментарий или директива над объявлением)
	Decl   int
	Last   int // строка КонецПроцедуры
	Region []string
}

type bslBlock struct {
	Key    string
	Anchor string // ключ процедуры перед блоком или "^"
	First  int
	Last   int
	Region []string
}

type bslModule struct {
	BOM     bool
	EOL     string
	Lines   []string
	Kinds   []lineKind
	Methods []*bslMethod
	Blocks  []*bslBlock
	// Owner: чья строка - "m:<ключ>", "b:<ключ>" или "" (структура: пустая строка, область).
	Owner []string
	// RegionOf: путь областей для строки структуры (после её обработки).
	RegionEnd map[string]int // путь области (через /) -> строка её #КонецОбласти
	Err       string
}

func classifyLine(line string) lineKind {
	t := strings.TrimSpace(line)
	switch {
	case t == "":
		return lkBlank
	case reEndRegion.MatchString(t):
		return lkEndRegion
	case reRegion.MatchString(t):
		return lkRegion
	case strings.HasPrefix(t, "//"):
		return lkComment
	case strings.HasPrefix(t, "&"):
		return lkDirective
	case reDecl.MatchString(t):
		return lkDecl
	case reEnd.MatchString(t):
		return lkEnd
	}
	return lkCode
}

func regionName(line string) string {
	m := reRegion.FindStringSubmatch(strings.TrimSpace(line))
	if len(m) > 1 && m[1] != "" {
		return m[1]
	}
	return "?"
}

// parseBSL разбирает модуль. Err не пустой - разбор не удался (процедура без конца, два метода с одним именем):
// тогда модуль сравнивается целиком.
func parseBSL(data []byte) *bslModule {
	body, n := stripBOM(data)
	text := string(body)
	m := &bslModule{BOM: n > 0, EOL: eolOf(text), Lines: splitLinesKeep(text), RegionEnd: map[string]int{}}
	m.Kinds = make([]lineKind, len(m.Lines))
	m.Owner = make([]string, len(m.Lines))
	for i, line := range m.Lines {
		m.Kinds[i] = classifyLine(line)
	}
	var region []string
	var pending []int
	lastKey := "^"
	blockCount := map[string]int{}
	seen := map[string]bool{}
	flush := func(upto []int) {
		// Строки до процедуры: структура и блоки кода (подряд идущие строки кода и свободных комментариев).
		var run []int
		closeRun := func() {
			if len(run) == 0 {
				return
			}
			blockCount[lastKey]++
			key := "code:" + lastKey
			if blockCount[lastKey] > 1 {
				key += "#" + itoa(blockCount[lastKey])
			}
			b := &bslBlock{Key: key, Anchor: lastKey, First: run[0], Last: run[len(run)-1], Region: append([]string(nil), region...)}
			for _, i := range run {
				m.Owner[i] = "b:" + key
			}
			m.Blocks = append(m.Blocks, b)
			run = nil
		}
		for _, i := range upto {
			switch m.Kinds[i] {
			case lkBlank:
				closeRun()
			case lkRegion:
				closeRun()
				region = append(region, regionName(m.Lines[i]))
			case lkEndRegion:
				closeRun()
				if len(region) > 0 {
					m.RegionEnd[strings.Join(region, "/")] = i
					region = region[:len(region)-1]
				}
			default:
				run = append(run, i)
			}
		}
		closeRun()
	}
	for i := 0; i < len(m.Lines); i++ {
		if m.Kinds[i] != lkDecl {
			pending = append(pending, i)
			continue
		}
		name := reDecl.FindStringSubmatch(strings.TrimSpace(m.Lines[i]))[1]
		key := "method:" + strings.ToLower(name)
		if seen[key] {
			m.Err = "два метода с именем " + name
			return m
		}
		seen[key] = true
		// Комментарий и директивы прямо над объявлением - часть процедуры.
		lead := len(pending)
		for lead > 0 {
			k := m.Kinds[pending[lead-1]]
			if k != lkComment && k != lkDirective {
				break
			}
			lead--
		}
		flush(pending[:lead])
		first := i
		if lead < len(pending) {
			first = pending[lead]
		}
		pending = nil
		end := -1
		for j := i + 1; j < len(m.Lines); j++ {
			if m.Kinds[j] == lkDecl {
				break
			}
			if m.Kinds[j] == lkEnd {
				end = j
				break
			}
		}
		if end < 0 {
			m.Err = "у метода " + name + " нет конца"
			return m
		}
		meth := &bslMethod{Name: name, Key: key, First: first, Decl: i, Last: end, Region: append([]string(nil), region...)}
		for j := first; j <= end; j++ {
			m.Owner[j] = "m:" + key
		}
		m.Methods = append(m.Methods, meth)
		lastKey = strings.ToLower(name)
		i = end
	}
	flush(pending)
	return m
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

func (m *bslModule) text(first, last int) string {
	return strings.Join(m.Lines[first:last+1], "")
}

// bslUnits - единицы модуля: ключ -> текст, порядок ключей и заголовки для отчёта.
func bslUnits(m *bslModule) (map[string]string, []string, map[string]string) {
	units := map[string]string{}
	titles := map[string]string{}
	var order []string
	for i := 0; i < len(m.Lines); i++ {
		owner := m.Owner[i]
		if owner == "" {
			continue
		}
		key := owner[2:]
		if _, ok := units[key]; ok {
			continue
		}
		if owner[0] == 'm' {
			for _, meth := range m.Methods {
				if meth.Key == key {
					units[key] = m.text(meth.First, meth.Last)
					titles[key] = methodTitle(m.Lines[meth.Decl], meth.Name)
				}
			}
		} else {
			for _, b := range m.Blocks {
				if b.Key == key {
					units[key] = m.text(b.First, b.Last)
					if b.Anchor == "^" {
						titles[key] = "код модуля до первой процедуры"
					} else {
						titles[key] = "код модуля после " + b.Anchor
					}
				}
			}
		}
		order = append(order, key)
	}
	return units, order, titles
}

func methodTitle(decl, name string) string {
	t := strings.ToLower(strings.TrimSpace(decl))
	if strings.Contains(t, "функция") || strings.Contains(t, "function") {
		return "функция " + name
	}
	return "процедура " + name
}

// bslResult - чем стала единица: Text - итоговый текст (пусто и Present=false - единицы нет).
type bslResult struct {
	Present bool
	Text    string
	FromT   bool
}

// rebuildBSL собирает модуль: наша структура, единицы - по результатам, новые единицы поставки - в той же области
// после той же процедуры, что у подрядчика; области, которой у нас нет, - новой областью в конце ближайшей
// существующей (или модуля).
func rebuildBSL(o, t *bslModule, results map[string]bslResult) string {
	eol := o.EOL
	fix := func(s string) string {
		s = strings.ReplaceAll(s, "\r\n", "\n")
		if eol == "\r\n" {
			s = strings.ReplaceAll(s, "\n", "\r\n")
		}
		if !strings.HasSuffix(s, eol) {
			s += eol
		}
		return s
	}
	inO := map[string]bool{}
	for _, mm := range o.Methods {
		inO[mm.Key] = true
	}
	for _, b := range o.Blocks {
		inO[b.Key] = true
	}
	// Вставки: перед строкой с индексом (len(o.Lines) - в конец), по порядку.
	inserts := map[int][]string{}
	blankBefore := func(at int) bool {
		if at <= 0 || at > len(o.Lines) {
			return at <= 0
		}
		return o.Kinds[at-1] == lkBlank
	}
	addInsert := func(at int, body string) {
		text := ""
		if at == len(o.Lines) && at > 0 && !strings.HasSuffix(o.Lines[at-1], "\n") {
			text = eol
		}
		blank := blankBefore(at)
		if n := len(inserts[at]); n > 0 {
			blank = strings.HasSuffix(inserts[at][n-1], eol+eol)
		}
		if blank {
			text += body + eol + eol
		} else {
			text += eol + body + eol
		}
		inserts[at] = append(inserts[at], text)
	}
	lastLine := func(key string) int {
		for _, mm := range o.Methods {
			if mm.Key == key {
				return mm.Last
			}
		}
		for _, b := range o.Blocks {
			if b.Key == key {
				return b.Last
			}
		}
		return -1
	}
	present := func(key string) bool {
		r, ok := results[key]
		return !ok || r.Present
	}
	join := func(p []string) string { return strings.Join(p, "/") }
	regionOfO := map[string][]string{}
	for _, mm := range o.Methods {
		regionOfO[mm.Key] = mm.Region
	}
	type pendingRegion struct {
		path  []string
		at    int
		texts []string
	}
	var wrap *pendingRegion
	closeWrap := func() {
		if wrap == nil {
			return
		}
		have := 0
		for k := len(wrap.path); k > 0; k-- {
			if _, ok := o.RegionEnd[join(wrap.path[:k])]; ok {
				have = k
				break
			}
		}
		var sb strings.Builder
		for _, name := range wrap.path[have:] {
			sb.WriteString("#Область " + name + eol + eol)
		}
		for i, text := range wrap.texts {
			if i > 0 {
				sb.WriteString(eol)
			}
			sb.WriteString(fix(text))
		}
		for range wrap.path[have:] {
			sb.WriteString(eol + "#КонецОбласти" + eol)
		}
		addInsert(wrap.at, strings.TrimSuffix(sb.String(), eol))
		wrap = nil
	}
	prevAt := -1
	var prevRegion []string
	for _, tm := range t.Methods {
		key := tm.Key
		if inO[key] {
			if present(key) {
				closeWrap()
				prevAt = lastLine(key) + 1
				prevRegion = regionOfO[key]
			}
			continue
		}
		r, ok := results[key]
		if !ok || !r.Present {
			continue
		}
		path := tm.Region
		body := strings.TrimSuffix(fix(r.Text), eol)
		if wrap != nil && join(wrap.path) == join(path) {
			wrap.texts = append(wrap.texts, r.Text)
			continue
		}
		closeWrap()
		if prevAt >= 0 && join(prevRegion) == join(path) {
			addInsert(prevAt, body)
			continue
		}
		if end, ok := o.RegionEnd[join(path)]; ok && len(path) > 0 {
			addInsert(end, body)
			prevAt, prevRegion = end, path
			continue
		}
		at := len(o.Lines)
		if len(path) == 0 {
			addInsert(at, body)
			prevAt, prevRegion = at, nil
			continue
		}
		for k := len(path) - 1; k > 0; k-- {
			if end, ok := o.RegionEnd[join(path[:k])]; ok {
				at = end
				break
			}
		}
		wrap = &pendingRegion{path: path, at: at, texts: []string{r.Text}}
		prevAt = -1
	}
	closeWrap()
	// Новые блоки кода вне процедур: после той же процедуры, у "^" - в начало модуля.
	for _, tb := range t.Blocks {
		r, ok := results[tb.Key]
		if inO[tb.Key] || !ok || !r.Present {
			continue
		}
		at := 0
		if tb.Anchor != "^" {
			if l := lastLine("method:" + tb.Anchor); l >= 0 {
				at = l + 1
			} else {
				at = len(o.Lines)
			}
		}
		addInsert(at, strings.TrimSuffix(fix(r.Text), eol))
	}
	var sb strings.Builder
	if o.BOM {
		sb.Write(bom)
	}
	emitted := map[string]bool{}
	for i := 0; i <= len(o.Lines); i++ {
		for _, text := range inserts[i] {
			sb.WriteString(text)
		}
		if i == len(o.Lines) {
			break
		}
		owner := o.Owner[i]
		if owner == "" {
			sb.WriteString(o.Lines[i])
			continue
		}
		key := owner[2:]
		if emitted[key] {
			continue
		}
		emitted[key] = true
		r, ok := results[key]
		if !ok || (r.Present && !r.FromT) {
			// Наша версия - байт в байт.
			first, last := -1, -1
			for _, mm := range o.Methods {
				if mm.Key == key {
					first, last = mm.First, mm.Last
				}
			}
			for _, b := range o.Blocks {
				if b.Key == key {
					first, last = b.First, b.Last
				}
			}
			sb.WriteString(o.text(first, last))
			continue
		}
		if r.Present {
			sb.WriteString(fix(r.Text))
			continue
		}
		// Единицы больше нет: пустую строку перед ней тоже убираем, чтобы не копились пустые строки.
		if i+1 >= len(o.Lines) {
			continue
		}
	}
	return sb.String()
}
