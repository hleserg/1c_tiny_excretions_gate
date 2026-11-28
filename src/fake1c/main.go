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
// Тонкий клиент (ENTERPRISE): режим - первое слово /C. canary, selfcheck (с start= - с этого задания), regepf, unregepf, kbarticle,
// precheck (проверка перед обновлением: started.txt, precheck.txt, result.txt), actions (действия после обновления:
// читает файл параметров in, пишет out.started и out - как обработка «Действия после обновления»)
// отвечают файлами так же, как настоящие обработки. Список ответов режима - по вызовам: первый вызов
// берёт первый элемент, следующие - следующие, последний повторяется. RunUnitTests=<файл настроек> - как YAxUnit:
// лог, отчёт jUnit и файл кода возврата из настроек; тесты - из сценария unittests.
//
// Загрузка расширения из файлов (/LoadConfigFromFiles <папка> -Extension <имя>) запоминает папку в каталоге журнала
// (ext\<имя>); выгрузка этого расширения (/DumpConfigToFiles) отдаёт потом её файлы - как настоящая база. Расширения
// из списка absent до загрузки «нет в базе»: их выгрузка - код 1 и «не найдено».
//
// Приёмка поставок (техническая база: файловая, создана CREATEINFOBASE): у неё свой склад расширений (ext@<база>\<имя>).
// /LoadCfg <файл> -Extension <имя> с файлом-архивом zip (подставной .cfe - архив выгрузки в файлы) кладёт его выгрузку
// в склад, /DeleteCfg -Extension <имя> - убирает. /DumpExternalDataProcessorOrReportToFiles с архивом zip (подставной
// .epf/.erf - архив выгрузки: <Имя>.xml и <Имя>/...) отдаёт его под именем корня; в архиве есть PROTECTED - код 1,
// «модуль без исходного текста».
package main

import (
	"archive/zip"
	"bytes"
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
	Match            []string `json:"match"`
	Exit             int      `json:"exit"`
	Log              string   `json:"log"`
	Sleep            float64  `json:"sleep"`
	Times            int      `json:"times"`
	Hang             bool     `json:"hang"`
	NoLog            bool     `json:"noLog"`
	NoDump           bool     `json:"noDump"`
	WaitRegistration string   `json:"waitRegistration"`
}

type task struct {
	Key   string   `json:"key"`
	Title string   `json:"title"`
	Step  string   `json:"step"`
	Lines []string `json:"lines"`
	// Снимки задания (ключ -> текст): уходят в следующую часть журнала после строк задания, как у обработки.
	Snapshots map[string]string `json:"snapshots"`
	// Два исполнителя: задание группы, которую делят (@@group=1), и ожидание второго (@@wait=1).
	group       bool
	compileOnly bool
	wait        bool
}

type selfcheck struct {
	Ext         []string `json:"ext"`
	Pack        string   `json:"pack"`
	Fingerprint string   `json:"fingerprint"`
	// Хеш исходников обработки (строка selfchecksrc в info.txt): как у обработки, входит в состав отпечатка.
	Src       string `json:"src"`
	Build     string `json:"build"`
	Tasks     []task `json:"tasks"`
	Status    string `json:"status"`
	NoStart   bool   `json:"nostart"`
	ExitAfter int    `json:"exitAfter"`
	// Второй исполнитель обрывается после стольких заданий (ExitAfter - у обоих); NoPlan - обработка прежней версии:
	// only=, split= и worker= не знает, список plan.txt не пишет.
	ExitAfterW2 int     `json:"exitAfterW2"`
	NoPlan      bool    `json:"noPlan"`
	Sleep       float64 `json:"sleep"`
}

type canary struct {
	User     *string  `json:"user"`
	Status   string   `json:"status"`
	Ext      []string `json:"ext"`
	Sessions []string `json:"sessions"`
	NoResult bool     `json:"noresult"`
}

type processing struct {
	Status          string   `json:"status"`
	Message         string   `json:"message"`
	ObjName         string   `json:"objname"`
	ObjVersion      string   `json:"objversion"`
	OldVersion      string   `json:"oldversion"`
	IsNew           string   `json:"isnew"`
	Ref             string   `json:"ref"`
	Check           string   `json:"check"`
	CheckError      string   `json:"checkerror"`
	FormErrors      []string `json:"formerror"`
	NamedFormErrors []string `json:"namedFormErrors"`
	WaitBuild       string   `json:"waitBuild"`
	Old             string   `json:"old"`
	NoResult        bool     `json:"noresult"`
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
	// NoExitCode - отчёт пишется, кода возврата нет (движок упал после отчёта); Hang - сколько секунд клиент
	// после этого ещё висит.
	NoReport   bool    `json:"noReport"`
	NoExitCode bool    `json:"noexitcode"`
	Hang       float64 `json:"hang"`
}

// precheck - ответ режима precheck. Lines - строки журнала (пусто - журнал по умолчанию); NoStart - сборка обработки
// режима не знает: форма открыта и ждёт, файлов нет; NoResult - отметка запуска есть, итога нет.
type precheck struct {
	Lines    []string `json:"lines"`
	Status   string   `json:"status"`
	Message  string   `json:"message"`
	NoStart  bool     `json:"nostart"`
	NoResult bool     `json:"noresult"`
}

// actionsRun - ответ режима actions. По умолчанию все действия из файла параметров выполнены сейчас, регистры есть.
// Already - выполнены раньше; Fail - на каком действии упасть (Error - текст); Register - done-register (ok, missing,
// notset, nodimension); History - history; Log - строки журнала каждого выполненного действия; Mismatch - обработка
// собрана с другим списком; NoStart - форма не открылась; NoResult - отметка есть, итога нет.
type actionsRun struct {
	Already  []string `json:"already"`
	Fail     string   `json:"fail"`
	Error    string   `json:"error"`
	Register string   `json:"register"`
	History  string   `json:"history"`
	Log      []string `json:"log"`
	Mismatch bool     `json:"mismatch"`
	NoStart  bool     `json:"nostart"`
	NoResult bool     `json:"noresult"`
}

type scenario struct {
	Designer  []designerRule `json:"designer"`
	Actions   []actionsRun   `json:"actions"`
	Canary    []canary       `json:"canary"`
	Selfcheck []selfcheck    `json:"selfcheck"`
	Regepf    []processing   `json:"regepf"`
	Unregepf  []processing   `json:"unregepf"`
	Kbarticle []processing   `json:"kbarticle"`
	Precheck  []precheck     `json:"precheck"`
	// Выгрузка расширения в файлы (/DumpConfigToFiles): расширение -> путь файла от корня выгрузки -> текст;
	// основная конфигурация (без -Extension) - ключ "@config"
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
	} else if len(args) > 1 && strings.EqualFold(args[0], "CREATEINFOBASE") {
		// Файловая база, созданная так (техническая база приёмки), получает свой склад расширений - метка в её папке.
		mode = "CREATEINFOBASE"
		if path := createdFileBase(args[1]); path != "" {
			_ = os.MkdirAll(path, 0o755)
			_ = os.WriteFile(filepath.Join(path, createdMarker), []byte("fake1c"), 0o644)
		}
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
	if out := valueAfter(args, "/Out"); out != "" && !rule.NoLog {
		writeUTF8(out, rule.Log)
	}
	if rule.Exit != 0 {
		return rule.Exit
	}
	if file := valueAfter(args, "/LoadCfg"); file != "" && logDir != "" {
		if ext := valueAfter(args, "-Extension"); ext != "" {
			if data, err := os.ReadFile(file); err == nil && bytes.HasPrefix(data, []byte("PK")) {
				if !zipHas(data, "Configuration.xml") {
					if out := valueAfter(args, "/Out"); out != "" {
						writeUTF8(out, "Файл не является расширением конфигурации")
					}
					return 1
				}
				store := extStore(args, ext)
				_ = os.RemoveAll(store)
				if err := unzipTo(data, store, ""); err != nil {
					if out := valueAfter(args, "/Out"); out != "" {
						writeUTF8(out, "Файл не является расширением конфигурации: "+err.Error())
					}
					return 1
				}
			}
		}
	}
	// Удаление расширения очищает склад только у базы, созданной подставной 1С (техническая база приёмки): у остальных
	// склад остаётся, как раньше, - на нём держатся тесты, которые правят выгрузку «в базе» после прогона.
	if hasArg(args, "/DeleteCfg") && logDir != "" && isFileBase(args) {
		if ext := valueAfter(args, "-Extension"); ext != "" {
			_ = os.RemoveAll(extStore(args, ext))
		}
	}
	if file := valueAfter(args, "/DumpCfg"); file != "" && !rule.NoDump {
		_ = os.MkdirAll(filepath.Dir(file), 0o755)
		_ = os.WriteFile(file, []byte("FAKECFE "+valueAfter(args, "-Extension")), 0o644)
	}
	if dir := valueAfter(args, "/LoadConfigFromFiles"); dir != "" && logDir != "" {
		ext := valueAfter(args, "-Extension")
		store := extStore(args, ext)
		_ = os.RemoveAll(store)
		copyTree(dir, store)
	}
	if dir := valueAfter(args, "/DumpConfigToFiles"); dir != "" {
		ext := valueAfter(args, "-Extension")
		store := ""
		if logDir != "" {
			store = extStore(args, ext)
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
		// Без -Extension - основная конфигурация: ключ "@config".
		key := ext
		if key == "" {
			key = "@config"
		}
		files := sc.Dumps[key]
		// "<расширение>@<база>" - выгрузка именно этой базы (сравнение temp и рабочей); нет такой - общая.
		if byBase, ok := sc.Dumps[key+"@"+infobaseName(args)]; ok {
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
			if bytes.HasPrefix(data, []byte("PK")) {
				if zipHas(data, "PROTECTED") {
					if out := valueAfter(args, "/Out"); out != "" {
						writeUTF8(out, "Модуль без исходного текста: выгрузка в файлы невозможна")
					}
					return 1
				}
				if err := unzipTo(data, filepath.Dir(root), name); err != nil {
					return 1
				}
				continue
			}
			writeUTF8(root, "<MetaDataObject><ExternalDataProcessor><Properties><Name>"+name+"</Name></Properties></ExternalDataProcessor></MetaDataObject>")
			writeUTF8(filepath.Join(filepath.Dir(root), name, "Ext", "ObjectModule.bsl"), string(trimBOM(data)))
		}
		if strings.EqualFold(a, "/LoadExternalDataProcessorOrReportFromFiles") && i+2 < len(args) {
			if rule.WaitRegistration != "" {
				marker := filepath.Join(filepath.Dir(filepath.Dir(args[i+2])), rule.WaitRegistration, "register", "started.txt")
				if !waitForFile(marker) {
					return 1
				}
			}
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
		lines := []string{"canary=20261117.999999", "status=" + c.Status}
		if c.User == nil {
			lines = append(lines, "user=Тест")
		} else if *c.User != "" {
			lines = append(lines, "user="+*c.User)
		}
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
		// Второй исполнитель запускается, пока первый ещё идёт (его счётчик ещё не записан): он взял тот же сценарий,
		// а счётчик не двигает - оба одна самопроверка.
		if p["worker"] == "2" {
			state["selfcheck"]--
		}
		start := 0
		fmt.Sscanf(p["start"], "%d", &start)
		selfcheckRun(s, dirOf(p["out"]), p["known"], start, p)
	case "rununittests":
		u, ok := pick(sc.Unittests, state, "unittests")
		if !ok {
			u = unitRun{Cases: []unitCase{{Module: "ОМ_Пример", Method: "Тест", Status: "ok"}}}
		}
		unitRun1(u, p["config"])
	case "actions":
		a, _ := pick(sc.Actions, state, "actions")
		actionsRun1(a, p["in"], p["out"])
	case "precheck":
		c, ok := pick(sc.Precheck, state, "precheck")
		if !ok {
			c = precheck{}
		}
		precheckRun(c, dirOf(p["out"]))
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
// Сигналы гейта второму исполнителю и первому, который его ждёт: строки par.txt (go=1, done2=1, stop=1).
func laneSignals(dir string) map[string]bool {
	out := map[string]bool{}
	data, err := os.ReadFile(dir + "par.txt")
	if err != nil {
		return out
	}
	for _, l := range strings.Split(string(trimBOM(data)), "\n") {
		out[strings.TrimSpace(l)] = true
	}
	return out
}

// Ждёт одного из сигналов не дольше двух минут; ответ - какой пришёл (пусто - не дождался).
func waitSignal(dir string, names ...string) string {
	for i := 0; i < 600; i++ {
		got := laneSignals(dir)
		for _, n := range names {
			if got[n] {
				return n
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return ""
}

// Очередь исполнителя - как ОчередьИсполнителя обработки: only= - одна группа, split= и worker= - группу делят
// два исполнителя по очереди, первый после последнего задания группы ждёт второго. Весь список - в plan.txt.
func laneTasks(tasks []task, dir string, p map[string]string) []task {
	only, split := p["only"], p["split"]
	worker := 1
	fmt.Sscanf(p["worker"], "%d", &worker)
	if only == "" && split == "" {
		return tasks
	}
	picked := []task{}
	for _, t := range tasks {
		if only == "" || t.Step == only {
			picked = append(picked, t)
		}
	}
	inGroup := func(t task) bool { return split != "" && t.Step == split && !strings.HasPrefix(t.Key, "Запись/") }
	// ** Хлебников С.Ю. 20261123 Подставная 1С составляет общий план ранних чтений для двух сеансов.
	if only == "" && p["earlyreads"] == "1" {
		readSteps := map[string]bool{}
		for _, t := range picked {
			kind, _, _ := strings.Cut(t.Key, "/")
			if kind == "Запись" {
				continue
			}
			if allowed, seen := readSteps[t.Step]; seen && !allowed {
				continue
			}
			switch kind {
			case "Форма", "КлиентскийМодуль", "КомпиляцияМодулей", "ПечатныеФормы", "Отчеты":
				readSteps[t.Step] = true
			default:
				readSteps[t.Step] = false
			}
		}
		inGroup = func(t task) bool { return readSteps[t.Step] && !strings.HasPrefix(t.Key, "Запись/") }
		early, later := []task{}, []task{}
		reads := 0
		for _, t := range picked {
			if readSteps[t.Step] {
				early = append(early, t)
			} else {
				later = append(later, t)
			}
			if inGroup(t) {
				reads++
			}
		}
		if reads > 1 {
			picked = append(early, later...)
		}
	}
	// ** Хлебников С.Ю. 20261123 конец
	last, count := -1, 0
	for i, t := range picked {
		if inGroup(t) {
			last, count = i, count+1
		}
	}
	canSplit := count > 1
	kept := []task{}
	deferred := []task{}
	plan := []string{}
	k := 0
	for i, t := range picked {
		lane := 1
		if canSplit && inGroup(t) {
			t.compileOnly = p["overlapcompile"] == "1" && p["earlyreads"] == "1" && only == "" && (strings.HasPrefix(t.Key, "КлиентскийМодуль/") ||
				strings.HasPrefix(t.Key, "КомпиляцияМодулей/ОбщийМодуль|") || strings.HasPrefix(t.Key, "КомпиляцияМодулей/Менеджер|"))
			if t.compileOnly {
				lane = 2
			} else {
				lane = k%2 + 1
				k++
			}
			t.group = true
		}
		plan = append(plan, fmt.Sprintf("%d\t%d\t%s", i, lane, t.Key))
		if lane == worker {
			if t.compileOnly {
				deferred = append(deferred, t)
			} else {
				kept = append(kept, t)
			}
		}
		if canSplit && worker == 1 && i == last {
			kept = append(kept, task{Key: "Ожидание/Ожидание второго исполнителя: " + split, Title: "Ожидание второго исполнителя", Step: split,
				Lines: []string{"[ИНФО] Второй исполнитель закончил свою часть группы"}, wait: true})
		}
	}
	writeUTF8(dir+"plan.txt", strings.Join(plan, "\n"))
	return append(kept, deferred...)
}

func selfcheckRun(s selfcheck, dir, known string, start int, p map[string]string) {
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
	build := s.Build
	if build == "" {
		build = "20261117.999999"
	}
	info := []string{"selfcheck=" + build, "selfchecksrc=" + s.Src, "base=erp_temp_test", "config=УправлениеПредприятием 2.5", "testbase=1",
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
			// Ключ - как у ядра: «КомпиляцияМодулей/<вид>|<имя>».
			{Key: "КомпиляцияМодулей/ОбщийМодуль|Адаптация_ОбщийСервер", Title: "ОбщийМодуль.Адаптация_ОбщийСервер", Step: "КомпиляцияМодулей", Lines: []string{"[ОК] ОбщийМодуль.Адаптация_ОбщийСервер: компилируется"}},
		}
	}
	if !s.NoPlan {
		tasks = laneTasks(tasks, dir, p)
	}
	exitAfter := s.ExitAfter
	if p["worker"] == "2" && s.ExitAfterW2 > 0 {
		exitAfter = s.ExitAfterW2
	}
	if p["worker"] == "2" && len(tasks) > 0 && !s.NoPlan {
		if waitSignal(dir, "go=1", "stop=1") != "go=1" {
			writeUTF8(dir+"result.txt", "status=stopped\nversion=20261117.999999\nfingerprint=\npieces=0\nwriteerrors=0")
			return
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
	// Шаги - как в настоящей обработке: в заголовке каждой части строка @@block на каждый шаг (а не только на
	// текущий) со счётом по уже выполненным заданиям: сделано/всего/ОК/ошибок/внимание/пропусков|имя.
	type stepBlock struct {
		name                                string
		done, total, ok, errs, warns, skips int
	}
	blocks := []*stepBlock{}
	blockOf := map[string]*stepBlock{}
	for _, t := range tasks {
		b := blockOf[t.Step]
		if b == nil {
			b = &stepBlock{name: t.Step}
			blockOf[t.Step] = b
			blocks = append(blocks, b)
		}
		b.total++
	}
	blockLines := func() string {
		out := ""
		for _, b := range blocks {
			out += fmt.Sprintf("@@block=%d/%d/%d/%d/%d/%d|%s\n", b.done, b.total, b.ok, b.errs, b.warns, b.skips, b.name)
		}
		return out
	}
	pieces := 0
	previous := []string{"[ИНФО] Самопроверка (подставная 1С)"}
	var previousSnaps map[string]string
	for n, t := range tasks {
		if exitAfter > 0 && n >= exitAfter {
			return
		}
		pieces++
		head := fmt.Sprintf("@@n=%d\n@@total=%d\n@@key=%s\n@@title=%s\n@@step=%s\n", n, len(tasks), t.Key, t.Title, t.Step) + blockLines()
		if t.group {
			head += "@@group=1\n"
		}
		if t.compileOnly {
			head += "@@compileonly=1\n"
		}
		if t.wait {
			head += "@@wait=1\n"
		}
		head += "@@journal\n"
		writeUTF8(fmt.Sprintf("%sp%06d.txt", dir, pieces), head+journal(previous)+snaps(previousSnaps))
		if t.wait {
			waitSignal(dir, "done2=1", "stop=1")
		}
		count(t.Lines)
		b := blockOf[t.Step]
		b.done++
		for _, l := range t.Lines {
			switch {
			case strings.HasPrefix(l, "[ОК]"):
				b.ok++
			case strings.HasPrefix(l, "[ОШИБКА]"):
				b.errs++
			case strings.HasPrefix(l, "[ВНИМАНИЕ]"):
				b.warns++
			case strings.HasPrefix(l, "[ПРОПУСК]"):
				b.skips++
			}
		}
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

// actionsRun1 - как обработка «Действия после обновления»: отметка запуска, действия по порядку из файла параметров,
// первое упавшее останавливает остальные, итог.
func actionsRun1(a actionsRun, in, out string) {
	if a.NoStart || out == "" {
		return
	}
	writeUTF8(out+".started", "started=1")
	if a.NoResult {
		time.Sleep(time.Hour)
	}
	data, err := os.ReadFile(in)
	if err != nil {
		writeUTF8(out, "status=error\nerror=не прочитал файл параметров: "+err.Error())
		return
	}
	var ids []string
	for _, line := range strings.Split(strings.ReplaceAll(string(trimBOM(data)), "\r\n", "\n"), "\n") {
		if strings.HasPrefix(line, "action=") {
			ids = append(ids, strings.TrimPrefix(line, "action="))
		}
	}
	lines := []string{"actions=20261117.999999"}
	if a.Mismatch {
		writeUTF8(out, strings.Join(append(lines, "error=обработка собрана с другим списком действий: старое", "status=error"), "\n"))
		return
	}
	register := a.Register
	if register == "" {
		register = "ok"
	}
	lines = append(lines, "done-register="+register)
	status := "ok"
	for _, id := range ids {
		switch {
		case status != "ok" || register != "ok":
			status = "failed"
			lines = append(lines, "action="+id+"|notrun")
		case id == a.Fail:
			status = "failed"
			text := a.Error
			if text == "" {
				text = "{ВнешняяОбработка.ДействияПослеОбновления.МодульОбъекта(10)}: Деление на 0"
			}
			lines = append(lines, "action="+id+"|failed|"+text)
		case contains(a.Already, id):
			lines = append(lines, "action="+id+"|already")
		default:
			for _, l := range a.Log {
				lines = append(lines, "log="+id+"|"+l)
			}
			lines = append(lines, "action="+id+"|done|12")
		}
	}
	history := a.History
	if history == "" {
		history = "ok"
	}
	lines = append(lines, "history="+history, "status="+status)
	writeUTF8(out, strings.Join(lines, "\n"))
}

func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

// precheckRun - как режим precheck обработки «Выполнить после обновления»: отметка запуска, журнал двух шагов, итог.
func precheckRun(c precheck, dir string) {
	if c.NoStart {
		time.Sleep(time.Hour)
	}
	writeUTF8(dir+"started.txt", "started=20261117.999999")
	if c.NoResult {
		time.Sleep(time.Hour)
	}
	lines := c.Lines
	if len(lines) == 0 {
		lines = []string{
			"Проверка перед обновлением (только чтение), сборка обработки 20261117.999999, 19.11.2026 18:00:00",
			"",
			"=== Окружение и расширения ===",
			"18:00:01 [ИНФО]     Имя базы: erp_base - не похоже на тестовую",
			"18:00:01 [ОК]       Обработка запущена под полными правами",
			"--- шаг занял 10 мс; ОК: 1, ошибок: 0, внимание: 0, пропусков: 0",
			"",
			"=== Перед обновлением: что изменит загрузка комплекта (только чтение) ===",
			"18:00:02 [ИНФО]     Шаг только читает и выполняется в любой базе.",
			"18:00:02 [ОК]       Значений, которые очистит обновление, в данных нет.",
		}
	}
	writeUTF8(dir+"precheck.txt", strings.Join(lines, "\n"))
	status := c.Status
	if status == "" {
		status = "done"
	}
	result := []string{"status=" + status, "version=20261117.999999", "fingerprint=", "pieces=0", "writeerrors=0"}
	if c.Message != "" {
		result = append(result, "message="+c.Message)
	}
	writeUTF8(dir+"result.txt", strings.Join(result, "\n"))
}

func waitForFile(path string) bool {
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}

func processingRun(mode string, r processing, dir string, p map[string]string) {
	writeUTF8(dir+"started.txt", "started=20261117.999999")
	if r.WaitBuild != "" {
		built := filepath.Join(dir, "..", "..", r.WaitBuild, r.WaitBuild+".epf")
		if !waitForFile(built) {
			r.Status, r.Message = "failed", "не дождался фоновой сборки"
		}
	}
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
			ref = p["ref"]
		}
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
		if p["allforms"] == "1" {
			r.FormErrors = append(r.FormErrors, r.NamedFormErrors...)
		}
		for _, f := range r.FormErrors {
			lines = append(lines, "formerror="+f)
		}
		// Что запись поменяла в карточке (как у обработки со сборки 20261120): с ref= назначение остаётся прежним.
		kept := "0"
		if p["ref"] != "" {
			kept = "1"
		}
		lines = append(lines, "commandsold=Печать", "commandsnew=Печать", "targetsold=Документ.Заказ", "targetsnew=Документ.Заказ", "targetskept="+kept, "publication=Используется")
	}
	writeUTF8(dir+"result.txt", strings.Join(lines, "\n"))
}

// createdMarker - метка файловой базы, созданной подставной 1С (CREATEINFOBASE): у неё свой склад расширений.
const createdMarker = "fake1c-created.txt"

// createdFileBase - путь из File="<путь>" (или File=<путь>) команды CREATEINFOBASE.
func createdFileBase(arg string) string {
	if !strings.HasPrefix(strings.ToLower(arg), "file=") {
		return ""
	}
	value := strings.TrimSpace(arg[5:])
	value = strings.TrimSuffix(value, ";")
	return strings.Trim(value, "\"")
}

// fileBasePath - папка файловой базы из /F"<путь>", если она создана подставной 1С; иначе пусто.
func fileBasePath(args []string) string {
	for _, a := range args {
		if len(a) > 2 && (strings.HasPrefix(a, "/F") || strings.HasPrefix(a, "/f")) {
			path := strings.Trim(a[2:], "\"")
			if _, err := os.Stat(filepath.Join(path, createdMarker)); err == nil {
				return path
			}
		}
	}
	return ""
}

// extStore - склад выгрузок расширения базы: ext\<имя>, как раньше (и у файловой базы тестов гейта); у файловой базы,
// созданной CREATEINFOBASE (техническая база приёмки), - свой: ext@<папка базы>\<имя>, чтобы не смешивать с temp.
func extStore(args []string, ext string) string {
	if path := fileBasePath(args); path != "" {
		return filepath.Join(logDir, "ext@"+filepath.Base(path), ext)
	}
	return filepath.Join(logDir, "ext", ext)
}

func isFileBase(args []string) bool {
	return fileBasePath(args) != ""
}

func hasArg(args []string, key string) bool {
	for _, a := range args {
		if strings.EqualFold(a, key) {
			return true
		}
	}
	return false
}

func zipHas(data []byte, name string) bool {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return false
	}
	for _, f := range r.File {
		if f.Name == name {
			return true
		}
	}
	return false
}

// unzipTo - архив в папку. Root - имя корня выгрузки обработки: <первая папка>.xml и <первая папка>/... ложатся как
// <root>.xml и <root>/... (выгрузка обработки называется по корневому файлу).
func unzipTo(data []byte, dir, root string) error {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return err
	}
	first := ""
	for _, f := range r.File {
		if root != "" && strings.HasSuffix(f.Name, ".xml") && !strings.Contains(f.Name, "/") {
			first = strings.TrimSuffix(f.Name, ".xml")
		}
	}
	for _, f := range r.File {
		if strings.HasSuffix(f.Name, "/") || f.Name == "PROTECTED" {
			continue
		}
		name := f.Name
		if root != "" && first != "" {
			if name == first+".xml" {
				name = root + ".xml"
			} else if strings.HasPrefix(name, first+"/") {
				name = root + "/" + strings.TrimPrefix(name, first+"/")
			}
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		var buf bytes.Buffer
		_, _ = buf.ReadFrom(rc)
		rc.Close()
		target := filepath.Join(dir, filepath.FromSlash(name))
		_ = os.MkdirAll(filepath.Dir(target), 0o755)
		if err := os.WriteFile(target, buf.Bytes(), 0o644); err != nil {
			return err
		}
	}
	return nil
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
			File    string `json:"file"`
			Console bool   `json:"console"`
		} `json:"logging"`
	}
	if json.Unmarshal(trimBOM(data), &cfg) != nil {
		return
	}
	if cfg.Logging.File != "" {
		writeUTF8(cfg.Logging.File, "------\n01.01.2026 00:00:00 [Клиент][Информация]: Инициализация")
	}
	if cfg.Logging.Console {
		fmt.Println("[Клиент][INF]: Инициализация /P\"тестовый-пароль\"")
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
	if cfg.ReportPath != "" && !u.NoReport {
		_ = os.MkdirAll(filepath.Dir(cfg.ReportPath), 0o755)
		_ = os.WriteFile(cfg.ReportPath, []byte(b.String()), 0o644)
	}
	if u.NoExitCode {
		if u.Hang > 0 {
			time.Sleep(time.Duration(u.Hang * float64(time.Second)))
		}
		return
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
