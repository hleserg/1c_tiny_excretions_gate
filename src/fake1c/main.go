// fake1c - подставной 1cv8.exe и 1cv8c.exe для тестов гейта без 1С.
//
// Что делать, говорит сценарий: JSON-файл в переменной окружения CI_FAKE_SCENARIO. Каждый вызов
// дописывается строкой в CI_FAKE_LOG (там же лежит счётчик вызовов fake1c-state.json): по журналу
// тест проверяет, что гейт вызывал и с какими ключами. Без сценария всё проходит успешно.
//
// Конфигуратор (первый ключ DESIGNER): правила designer - первое подходящее (все слова match есть
// в командной строке; times - сколько раз правило срабатывает) задаёт код возврата, текст лога /Out
// и задержку. /DumpCfg и /DumpConfigToFiles создают файл и каталог, /LoadExternalDataProcessorOrReportFromFiles -
// файл обработки, /DumpExternalDataProcessorOrReportToFiles - корневой XML и модуль объекта, если код возврата 0.
//
// Тонкий клиент (ENTERPRISE): режим - первое слово /C. canary, selfcheck (с start= - с этого задания), regepf, unregepf, kbarticle
// отвечают файлами так же, как настоящие обработки. Список ответов режима - по вызовам: первый вызов
// берёт первый элемент, следующие - следующие, последний повторяется. RunUnitTests=<файл настроек> - как YAxUnit:
// лог, отчёт jUnit и файл кода возврата из настроек; тесты - из сценария unittests.
//
// Загрузка расширения из файлов (/LoadConfigFromFiles <папка> -Extension <имя>) запоминает папку в каталоге журнала
// (ext\<имя>); выгрузка этого расширения (/DumpConfigToFiles) отдаёт потом её файлы - как настоящая база. Расширения
// из списка absent до загрузки «нет в базе»: их выгрузка - код 1 и «не найдено».
package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type designerRule struct {
	Match []string `json:"match"`
	Exit  int      `json:"exit"`
	Log   string   `json:"log"`
	Sleep float64  `json:"sleep"`
	Times int      `json:"times"`
	Hang  bool     `json:"hang"`
}

type task struct {
	Key   string   `json:"key"`
	Title string   `json:"title"`
	Step  string   `json:"step"`
	Lines []string `json:"lines"`
	// Снимки задания (ключ -> текст): уходят в следующую часть журнала после строк задания, как у обработки.
	Snapshots map[string]string `json:"snapshots"`
}

type selfcheck struct {
	Ext         []string `json:"ext"`
	Pack        string   `json:"pack"`
	Fingerprint string   `json:"fingerprint"`
	Tasks       []task   `json:"tasks"`
	Status      string   `json:"status"`
	NoStart     bool     `json:"nostart"`
	ExitAfter   int      `json:"exitAfter"`
	Sleep       float64  `json:"sleep"`
}

type canary struct {
	Status   string   `json:"status"`
	Ext      []string `json:"ext"`
	Sessions []string `json:"sessions"`
	NoResult bool     `json:"noresult"`
}

type processing struct {
	Status     string   `json:"status"`
	Message    string   `json:"message"`
	ObjName    string   `json:"objname"`
	ObjVersion string   `json:"objversion"`
	OldVersion string   `json:"oldversion"`
	IsNew      string   `json:"isnew"`
	Ref        string   `json:"ref"`
	Check      string   `json:"check"`
	CheckError string   `json:"checkerror"`
	FormErrors []string `json:"formerror"`
	Old        string   `json:"old"`
	NoResult   bool     `json:"noresult"`
}

type unitCase struct {
	Module  string `json:"module"`
	Method  string `json:"method"`
	Context string `json:"context"`
	Name    string `json:"name"`
	Status  string `json:"status"`
	Message string `json:"message"`
}

type unitRun struct {
	Cases       []unitCase        `json:"cases"`
	SuiteErrors map[string]string `json:"suiteErrors"`
	NoStart     bool              `json:"nostart"`
	Exited      bool              `json:"exited"`
	Code        string            `json:"code"`
}

type scenario struct {
	Designer  []designerRule `json:"designer"`
	Canary    []canary       `json:"canary"`
	Selfcheck []selfcheck    `json:"selfcheck"`
	Regepf    []processing   `json:"regepf"`
	Unregepf  []processing   `json:"unregepf"`
	Kbarticle []processing   `json:"kbarticle"`
	// Выгрузка расширения в файлы (/DumpConfigToFiles): расширение -> путь файла от корня выгрузки -> текст.
	Dumps      map[string]map[string]string `json:"dumps"`
	ClientExit int                          `json:"clientExit"`
	Unittests  []unitRun                    `json:"unittests"`
	// Расширения, которых в базе нет, пока их не загрузят из файлов.
	Absent []string `json:"absent"`
}

var logDir string

func main() {
	args := os.Args[1:]
	var sc scenario
	if path := os.Getenv("CI_FAKE_SCENARIO"); path != "" {
		data, err := os.ReadFile(path)
		if err == nil {
			data = trimBOM(data)
			if err := json.Unmarshal(data, &sc); err != nil {
				fail("сценарий не разобрался: " + err.Error())
			}
		}
	}
	logFile := os.Getenv("CI_FAKE_LOG")
	if logFile != "" {
		logDir = filepath.Dir(logFile)
	}
	line := strings.Join(args, " ")
	state := loadState()
	before := map[string]int{}
	for k, v := range state {
		before[k] = v
	}
	code := 0
	mode := "?"
	if len(args) > 0 && strings.EqualFold(args[0], "DESIGNER") {
		mode = "DESIGNER"
		code = designer(sc, args, line, state)
	} else if len(args) > 0 && strings.EqualFold(args[0], "ENTERPRISE") {
		mode = "ENTERPRISE"
		code = client(sc, args, state)
	}
	// Гейт может держать два процесса 1С сразу (проверка конфигурации параллельно с остальными шагами):
	// счётчики дописываются к тому, что лежит в файле сейчас, а не перезаписывают его прежней копией.
	changed := false
	fresh := loadState()
	for k, v := range state {
		if v != before[k] {
			fresh[k] += v - before[k]
			changed = true
		}
	}
	if changed {
		saveState(fresh)
	}
	if logFile != "" {
		f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err == nil {
			fmt.Fprintf(f, "%s\t%s\t%d\t%s\n", time.Now().Format("15:04:05.000"), mode, code, line)
			f.Close()
		}
	}
	os.Exit(code)
}

func fail(text string) {
	fmt.Fprintln(os.Stderr, "fake1c: "+text)
	os.Exit(99)
}

func trimBOM(data []byte) []byte {
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
		return data[3:]
	}
	return data
}

// Счётчики: сколько раз сработало правило конфигуратора, сколько раз вызывался режим клиента.
func loadState() map[string]int {
	state := map[string]int{}
	if logDir == "" {
		return state
	}
	data, err := os.ReadFile(filepath.Join(logDir, "fake1c-state.json"))
	if err == nil {
		_ = json.Unmarshal(data, &state)
	}
	return state
}

func saveState(state map[string]int) {
	if logDir == "" {
		return
	}
	data, _ := json.Marshal(state)
	_ = os.WriteFile(filepath.Join(logDir, "fake1c-state.json"), data, 0o644)
}

// Значение ключа: «/Out путь» - следующий аргумент.
func valueAfter(args []string, key string) string {
	for i, a := range args {
		if strings.EqualFold(a, key) && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func writeUTF8(path, text string) {
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	_ = os.WriteFile(path, append([]byte{0xEF, 0xBB, 0xBF}, []byte(strings.ReplaceAll(text, "\n", "\r\n"))...), 0o644)
}

func designer(sc scenario, args []string, line string, state map[string]int) int {
	rule := designerRule{}
	for i, r := range sc.Designer {
		ok := true
		for _, word := range r.Match {
			if !strings.Contains(line, word) {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		key := fmt.Sprintf("designer#%d", i)
		if r.Times > 0 && state[key] >= r.Times {
			continue
		}
		state[key]++
		rule = r
		break
	}
	if rule.Hang {
		time.Sleep(time.Hour)
	}
	if rule.Sleep > 0 {
		time.Sleep(time.Duration(rule.Sleep * float64(time.Second)))
	}
	if out := valueAfter(args, "/Out"); out != "" {
		writeUTF8(out, rule.Log)
	}
	if rule.Exit != 0 {
		return rule.Exit
	}
	if file := valueAfter(args, "/DumpCfg"); file != "" {
		_ = os.MkdirAll(filepath.Dir(file), 0o755)
		_ = os.WriteFile(file, []byte("FAKECFE "+valueAfter(args, "-Extension")), 0o644)
	}
	if dir := valueAfter(args, "/LoadConfigFromFiles"); dir != "" && logDir != "" {
		ext := valueAfter(args, "-Extension")
		store := filepath.Join(logDir, "ext", ext)
		_ = os.RemoveAll(store)
		copyTree(dir, store)
	}
	if dir := valueAfter(args, "/DumpConfigToFiles"); dir != "" {
		ext := valueAfter(args, "-Extension")
		store := ""
		if logDir != "" {
			store = filepath.Join(logDir, "ext", ext)
		}
		loaded := false
		if store != "" {
			if _, err := os.Stat(store); err == nil {
				loaded = true
			}
		}
		for _, a := range sc.Absent {
			if a == ext && !loaded {
				if out := valueAfter(args, "/Out"); out != "" {
					writeUTF8(out, "Расширение конфигурации "+ext+" не найдено")
				}
				return 1
			}
		}
		writeUTF8(filepath.Join(dir, "Configuration.xml"), "<MetaDataObject><Configuration><Properties><Name>"+ext+"</Name></Properties></Configuration></MetaDataObject>")
		if loaded {
			copyTree(store, dir)
		}
		writeUTF8(filepath.Join(dir, "ConfigDumpInfo.xml"), "<ConfigDumpInfo/>")
		files := sc.Dumps[ext]
		// "<расширение>@<база>" - выгрузка именно этой базы (сравнение temp и рабочей); нет такой - общая.
		if byBase, ok := sc.Dumps[ext+"@"+infobaseName(args)]; ok {
			files = byBase
		}
		for rel, text := range files {
			writeUTF8(filepath.Join(dir, filepath.FromSlash(rel)), text)
		}
	}
	for i, a := range args {
		// Выгрузка внешней обработки в файлы: корневой XML и модуль объекта - текст самого файла обработки
		// (в тестах это код на встроенном языке), чтобы отчёт об изменениях видел разницу по процедурам.
		if strings.EqualFold(a, "/DumpExternalDataProcessorOrReportToFiles") && i+2 < len(args) {
			root := args[i+1]
			name := strings.TrimSuffix(filepath.Base(root), filepath.Ext(root))
			data, _ := os.ReadFile(args[i+2])
			writeUTF8(root, "<MetaDataObject><ExternalDataProcessor><Properties><Name>"+name+"</Name></Properties></ExternalDataProcessor></MetaDataObject>")
			writeUTF8(filepath.Join(filepath.Dir(root), name, "Ext", "ObjectModule.bsl"), string(trimBOM(data)))
		}
		if strings.EqualFold(a, "/LoadExternalDataProcessorOrReportFromFiles") && i+2 < len(args) {
			_ = os.MkdirAll(filepath.Dir(args[i+2]), 0o755)
			_ = os.WriteFile(args[i+2], []byte("FAKEEPF "+filepath.Base(args[i+2])), 0o644)
		}
	}
	return 0
}

// Параметры /C: «режим;ключ=значение;...». Аргумент приходит как /C<текст>. «RunUnitTests=<файл>» - режим
// rununittests, файл - в параметре config.
func launch(args []string) (string, map[string]string) {
	params := map[string]string{}
	mode := ""
	for _, a := range args {
		if len(a) >= 2 && (strings.HasPrefix(a, "/C") || strings.HasPrefix(a, "/c")) {
			for n, part := range strings.Split(a[2:], ";") {
				part = strings.TrimSpace(part)
				if n == 0 {
					mode = strings.ToLower(part)
					if strings.HasPrefix(mode, "rununittests") {
						mode = "rununittests"
						if p := strings.Index(part, "="); p > 0 {
							params["config"] = part[p+1:]
						}
					}
					continue
				}
				if p := strings.Index(part, "="); p > 0 {
					params[strings.ToLower(part[:p])] = part[p+1:]
				}
			}
		}
	}
	return mode, params
}

func pick[T any](list []T, state map[string]int, key string) (T, bool) {
	var zero T
	if len(list) == 0 {
		return zero, false
	}
	n := state[key]
	state[key]++
	if n >= len(list) {
		n = len(list) - 1
	}
	return list[n], true
}

func dirOf(path string) string {
	if path == "" {
		return "."
	}
	return strings.TrimRight(path, `\/`) + string(os.PathSeparator)
}

func client(sc scenario, args []string, state map[string]int) int {
	mode, p := launch(args)
	switch mode {
	case "canary":
		c, ok := pick(sc.Canary, state, "canary")
		if !ok {
			c = canary{Status: "ok"}
		}
		out := p["out"]
		writeUTF8(out+".started", "started")
		if c.NoResult {
			time.Sleep(time.Hour)
		}
		lines := []string{"canary=20261117.999999", "status=" + c.Status, "user=Тест"}
		for _, e := range c.Ext {
			lines = append(lines, "ext="+e)
		}
		for _, s := range c.Sessions {
			lines = append(lines, "session="+s)
		}
		writeUTF8(out, strings.Join(lines, "\n"))
	case "selfcheck":
		s, ok := pick(sc.Selfcheck, state, "selfcheck")
		if !ok {
			s = selfcheck{}
		}
		start := 0
		fmt.Sscanf(p["start"], "%d", &start)
		selfcheckRun(s, dirOf(p["out"]), p["known"], start)
	case "rununittests":
		u, ok := pick(sc.Unittests, state, "unittests")
		if !ok {
			u = unitRun{Cases: []unitCase{{Module: "ОМ_Пример", Method: "Тест", Status: "ok"}}}
		}
		unitRun1(u, p["config"])
	case "regepf", "unregepf", "kbarticle":
		list := sc.Regepf
		if mode == "unregepf" {
			list = sc.Unregepf
		} else if mode == "kbarticle" {
			list = sc.Kbarticle
		}
		r, ok := pick(list, state, mode)
		if !ok {
			r = processing{Status: "done"}
		}
		processingRun(mode, r, dirOf(p["out"]), p)
	}
	return sc.ClientExit
}

// start - как у обработки: продолжить с задания start (с нуля). Дальше конца очереди - заданий нет, только сведения
// о базе и итог (так гейт проверяет базу перед продолжением прогона).
func selfcheckRun(s selfcheck, dir, known string, start int) {
	if s.NoStart {
		return
	}
	writeUTF8(dir+"started.txt", "started=20261117.999999")
	ext := s.Ext
	if ext == nil {
		ext = []string{"Адаптация|1|active|hashA", "Доработки|1|active|hashB"}
	}
	pack := s.Pack
	if pack == "" {
		pack = "Пример"
	}
	seed := s.Fingerprint
	if seed == "" {
		seed = strings.Join(ext, ";")
	}
	sum := sha256.Sum256([]byte(seed))
	fingerprint := fmt.Sprintf("%x", sum)
	info := []string{"selfcheck=20261117.999999", "base=erp_temp_test", "config=УправлениеПредприятием 2.5", "testbase=1",
		"pack=" + pack, "packname=" + pack, "packreason=тест"}
	for _, e := range ext {
		info = append(info, "ext="+e)
	}
	info = append(info, "fingerprint="+fingerprint, "fingerprintreliable=1")
	writeUTF8(dir+"info.txt", strings.Join(info, "\n"))
	if known != "" && known == fingerprint {
		writeUTF8(dir+"result.txt", "status=same\nfingerprint="+fingerprint+"\npieces=0\nwriteerrors=0")
		return
	}
	tasks := s.Tasks
	if tasks == nil {
		tasks = []task{
			{Key: "Окружение", Title: "Окружение и расширения", Step: "Окружение", Lines: []string{"[ОК] Обработка запущена под полными правами"}},
			{Key: "КомпиляцияМодулей|Общий|Адаптация_ОбщийСервер", Title: "Компиляция Адаптация_ОбщийСервер", Step: "КомпиляцияМодулей", Lines: []string{"[ОК] Адаптация_ОбщийСервер компилируется"}},
		}
	}
	if start > 0 {
		if start >= len(tasks) {
			tasks = []task{}
		} else {
			tasks = tasks[start:]
		}
	}
	now := time.Now().Format("15:04:05")
	snaps := func(m map[string]string) string {
		if len(m) == 0 {
			return ""
		}
		keys := make([]string, 0, len(m))
		for k := range m {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		out := []string{"", "@@snapshots"}
		for _, k := range keys {
			out = append(out, "@@snap "+k)
			for _, l := range strings.Split(m[k], "\n") {
				out = append(out, "|"+l)
			}
			out = append(out, "@@snap-end")
		}
		return strings.Join(out, "\n")
	}
	journal := func(lines []string) string {
		out := []string{}
		for _, l := range lines {
			kind, text := l, ""
			if i := strings.Index(l, "] "); i > 0 && strings.HasPrefix(l, "[") {
				kind, text = l[:i+1], l[i+2:]
			}
			out = append(out, fmt.Sprintf("%s %-10s %s", now, kind, text))
		}
		return strings.Join(out, "\n")
	}
	ok, errs, warns, skips := 0, 0, 0, 0
	count := func(lines []string) {
		for _, l := range lines {
			switch {
			case strings.HasPrefix(l, "[ОК]"):
				ok++
			case strings.HasPrefix(l, "[ОШИБКА]"):
				errs++
			case strings.HasPrefix(l, "[ВНИМАНИЕ]"):
				warns++
			case strings.HasPrefix(l, "[ПРОПУСК]"):
				skips++
			}
		}
	}
	pieces := 0
	previous := []string{"[ИНФО] Самопроверка (подставная 1С)"}
	var previousSnaps map[string]string
	for n, t := range tasks {
		if s.ExitAfter > 0 && n >= s.ExitAfter {
			return
		}
		pieces++
		head := fmt.Sprintf("@@n=%d\n@@total=%d\n@@key=%s\n@@title=%s\n@@step=%s\n@@block=%d/%d/0/0/0/0|%s\n@@journal\n", n, len(tasks), t.Key, t.Title, t.Step, n, len(tasks), t.Step)
		writeUTF8(fmt.Sprintf("%sp%06d.txt", dir, pieces), head+journal(previous)+snaps(previousSnaps))
		count(t.Lines)
		previous = t.Lines
		previousSnaps = t.Snapshots
		if s.Sleep > 0 {
			time.Sleep(time.Duration(s.Sleep * float64(time.Second)))
		}
	}
	pieces++
	writeUTF8(fmt.Sprintf("%sp%06d.txt", dir, pieces), "@@journal\n"+journal(previous)+snaps(previousSnaps))
	status := s.Status
	if status == "" {
		status = "done"
	}
	writeUTF8(dir+"result.txt", fmt.Sprintf("status=%s\nversion=20261117.999999\nfingerprint=%s\npieces=%d\nwriteerrors=0\nok=%d\nerrors=%d\nwarnings=%d\nskipped=%d",
		status, fingerprint, pieces, ok, errs, warns, skips))
}

func processingRun(mode string, r processing, dir string, p map[string]string) {
	writeUTF8(dir+"started.txt", "started=20261117.999999")
	if r.NoResult {
		time.Sleep(time.Hour)
	}
	lines := []string{"status=" + r.Status, "version=20261117.999999"}
	if r.Message != "" {
		lines = append(lines, "message="+r.Message)
	}
	if mode == "regepf" {
		if r.Old != "" {
			_ = os.WriteFile(dir+"old.b64", []byte(base64.StdEncoding.EncodeToString([]byte(r.Old))), 0o644)
			lines = append(lines, "oldsaved=1")
		}
		name := r.ObjName
		if name == "" {
			name = strings.TrimSuffix(strings.TrimSuffix(p["name"], ".epf"), ".erf")
		}
		isNew := r.IsNew
		if isNew == "" {
			isNew = "0"
		}
		ref := r.Ref
		if ref == "" {
			ref = "00000000-0000-0000-0000-000000000001"
		}
		check := r.Check
		if check == "" {
			check = "ok"
		}
		lines = append(lines, "objname="+name, "title="+name, "objversion="+r.ObjVersion, "oldversion="+r.OldVersion,
			"isnew="+isNew, "ref="+ref, "kind=ДополнительнаяОбработка", "commands=1", "forms=1", "check="+check)
		if r.CheckError != "" {
			lines = append(lines, "checkerror="+r.CheckError)
		}
		for _, f := range r.FormErrors {
			lines = append(lines, "formerror="+f)
		}
	}
	writeUTF8(dir+"result.txt", strings.Join(lines, "\n"))
}

// infobaseName - имя базы из ключа /S"сервер\база" (кавычки уже сняты разбором командной строки) или
// последней папки из /F.
func infobaseName(args []string) string {
	for _, a := range args {
		if len(a) > 2 && (strings.HasPrefix(a, "/S") || strings.HasPrefix(a, "/s")) {
			v := strings.Trim(a[2:], "\"")
			if i := strings.LastIndexAny(v, "\\/"); i >= 0 {
				return v[i+1:]
			}
			return v
		}
		if len(a) > 2 && (strings.HasPrefix(a, "/F") || strings.HasPrefix(a, "/f")) {
			return filepath.Base(strings.Trim(a[2:], "\""))
		}
	}
	return ""
}

// copyTree - копия папки с подпапками (файлы как есть).
func copyTree(from, to string) {
	_ = filepath.Walk(from, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(from, path)
		target := filepath.Join(to, rel)
		if info.IsDir() {
			_ = os.MkdirAll(target, 0o755)
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr == nil {
			_ = os.MkdirAll(filepath.Dir(target), 0o755)
			_ = os.WriteFile(target, data, 0o644)
		}
		return nil
	})
}

// unitRun1 - как YAxUnit по файлу настроек: лог (начало работы), отчёт jUnit, код возврата 0 или 1.
func unitRun1(u unitRun, configPath string) {
	if u.NoStart {
		return
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		return
	}
	var cfg struct {
		ReportPath string `json:"reportPath"`
		ExitCode   string `json:"exitCode"`
		Logging    struct {
			File string `json:"file"`
		} `json:"logging"`
	}
	if json.Unmarshal(trimBOM(data), &cfg) != nil {
		return
	}
	if cfg.Logging.File != "" {
		writeUTF8(cfg.Logging.File, "------\n01.01.2026 00:00:00 [Клиент][Информация]: Инициализация")
	}
	if u.Exited {
		return
	}
	esc := func(t string) string {
		t = strings.ReplaceAll(t, "&", "&amp;")
		t = strings.ReplaceAll(t, "<", "&lt;")
		t = strings.ReplaceAll(t, ">", "&gt;")
		return strings.ReplaceAll(t, "\"", "&quot;")
	}
	modules := []string{}
	byModule := map[string][]unitCase{}
	for _, c := range u.Cases {
		if c.Context == "" {
			c.Context = "Сервер"
		}
		if _, ok := byModule[c.Module]; !ok {
			modules = append(modules, c.Module)
		}
		byModule[c.Module] = append(byModule[c.Module], c)
	}
	for m := range u.SuiteErrors {
		if _, ok := byModule[m]; !ok {
			modules = append(modules, m)
			byModule[m] = nil
		}
	}
	failed := false
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?><testsuites>`)
	for i, m := range modules {
		b.WriteString(fmt.Sprintf(`<testsuite id="%d" name="%s [Сервер]" classname="%s" context="Сервер" package="tests">`, i, esc(m), esc(m)))
		if text, ok := u.SuiteErrors[m]; ok {
			failed = true
			b.WriteString(fmt.Sprintf(`<error message="%s"/>`, esc(text)))
		}
		for _, c := range byModule[m] {
			name := c.Name
			if name == "" {
				name = c.Method
			}
			b.WriteString(fmt.Sprintf(`<testcase name="%s" classname="%s.%s" time="0.01" context="%s">`, esc(name), esc(c.Module), esc(c.Method), esc(c.Context)))
			switch c.Status {
			case "fail":
				failed = true
				b.WriteString(fmt.Sprintf(`<failure message="%s"/>`, esc(c.Message)))
			case "error":
				failed = true
				b.WriteString(fmt.Sprintf(`<error message="%s">стек</error>`, esc(c.Message)))
			case "skip":
				b.WriteString(fmt.Sprintf(`<skipped message="%s"/>`, esc(c.Message)))
			}
			b.WriteString(`</testcase>`)
		}
		b.WriteString(`</testsuite>`)
	}
	b.WriteString(`</testsuites>`)
	if cfg.ReportPath != "" {
		_ = os.MkdirAll(filepath.Dir(cfg.ReportPath), 0o755)
		_ = os.WriteFile(cfg.ReportPath, []byte(b.String()), 0o644)
	}
	code := u.Code
	if code == "" {
		code = "0"
		if failed {
			code = "1"
		}
	}
	if cfg.ExitCode != "" {
		_ = os.WriteFile(cfg.ExitCode, []byte(code), 0o644)
	}
}
