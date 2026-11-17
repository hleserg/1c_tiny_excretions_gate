// Сборщик гейта и обработок: архивы для установки на машину гейта.
//
//	build.cmd [-private <папка>] [-out dist] [-stamp ГГГГММДД.ЧЧММСС] [-skip-exe] [-check [-src-out <папка>]]
//	(или из src/build: go run . -root ../.. ...)
//
// Что собирается (в -out):
//   - ci-gate_<штамп>.zip - папка ci: скрипты гейта, ci.exe, тесты с подставной 1С, образец настроек, руководство;
//   - ВыполнитьПослеОбновления_<штамп>.zip - выгрузка обработки в файлы (загрузить в конфигуратор, сохранить в tools);
//   - Канарейка_<штамп>.zip - то же для канарейки.
//
// Пакеты сценариев «Выполнить после обновления» берутся из packages/ репозитория и из packages/ папки -private
// (приватный репозиторий с пакетом своей базы). Сборщик вставляет их на места меток @@ПАКЕТЫ: ...@@ и сам пишет
// маршруты ядра к пакетам. -check - только проверить и собрать обработку в памяти, без архивов.
package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"encoding/xml"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const placeholder = "00000000.000000" // метка версии в исходниках, сборщик ставит на её место штамп

var (
	root    string
	private string
	outDir  string
	stamp   string
	skipExe bool
	check   bool
	srcOut  string
)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "сборка: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	flag.StringVar(&root, "root", ".", "корень репозитория")
	flag.StringVar(&private, "private", "", "папка приватного репозитория с пакетами своей базы (packages/<Имя>)")
	flag.StringVar(&outDir, "out", "dist", "куда класть архивы (относительный путь - от корня репозитория)")
	flag.StringVar(&stamp, "stamp", "", "штамп версии ГГГГММДД.ЧЧММСС (пусто - текущее время UTC+3)")
	flag.BoolVar(&skipExe, "skip-exe", false, "не собирать ci.exe и fake1c.exe (взять готовые из -out)")
	flag.BoolVar(&check, "check", false, "только собрать обработку в памяти и проверить")
	flag.StringVar(&srcOut, "src-out", "", "с -check: выложить собранные исходники обработки в эту папку (для BSL Language Server)")
	flag.Parse()
	if stamp == "" {
		stamp = time.Now().UTC().Add(3 * time.Hour).Format("20060102.150405")
	}
	if !regexp.MustCompile(`^\d{8}\.\d{6}$`).MatchString(stamp) {
		fail("штамп %q не в виде ГГГГММДД.ЧЧММСС", stamp)
	}
	root, _ = filepath.Abs(root)
	packs := loadPackages()
	vpo := buildProcessing(packs)
	if check {
		if srcOut != "" {
			for _, e := range vpo {
				path := filepath.Join(srcOut, filepath.FromSlash(e.Name))
				must(os.MkdirAll(filepath.Dir(path), 0o755))
				must(os.WriteFile(path, e.Data, 0o644))
			}
		}
		fmt.Printf("проверка пройдена: пакетов %d, файлов обработки %d\n", len(packs), len(vpo))
		return
	}
	if !filepath.IsAbs(outDir) {
		outDir = filepath.Join(root, outDir)
	}
	must(os.MkdirAll(outDir, 0o755))
	canary := buildCanary()
	writeZip(filepath.Join(outDir, "ВыполнитьПослеОбновления_"+stamp+".zip"), vpo)
	writeZip(filepath.Join(outDir, "Канарейка_"+stamp+".zip"), canary)
	// Архив гейта - всё для установки: папка ci, установщик и выгрузки обработок (их собирает install.cmd).
	gate := buildGate()
	for _, e := range append(append([]entry{}, vpo...), canary...) {
		gate = append(gate, entry{"epf/" + e.Name, e.Data})
	}
	writeZip(filepath.Join(outDir, "ci-gate_"+stamp+".zip"), gate)
	names := []string{}
	for _, p := range packs {
		names = append(names, p.Name)
	}
	fmt.Printf("сборка %s: пакеты %s\n%s\n", stamp, strings.Join(names, ", "), outDir)
}

func must(err error) {
	if err != nil {
		fail("%v", err)
	}
}

// ---------- тексты ----------

func readText(path string) string {
	data, err := os.ReadFile(path)
	must(err)
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	if strings.ContainsRune(text, 0xFEFF) {
		fail("%s: символ BOM не в начале файла", path)
	}
	return text
}

// Файл для Windows: CRLF и, если нужно, один BOM в начале.
func windowsBytes(text string, bom bool) []byte {
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\n", "\r\n")
	if bom {
		return append([]byte{0xEF, 0xBB, 0xBF}, []byte(text)...)
	}
	return []byte(text)
}

func replaceCounted(text, old, new string, expected int, label string) string {
	if n := strings.Count(text, old); n != expected {
		fail("%s: «%s» встречается %d раз, ожидалось %d", label, old, n, expected)
	}
	return strings.ReplaceAll(text, old, new)
}

type entry struct {
	Name string
	Data []byte
}

func writeZip(path string, files []entry) {
	f, err := os.Create(path)
	must(err)
	w := zip.NewWriter(f)
	for _, e := range files {
		h := &zip.FileHeader{Name: e.Name, Method: zip.Deflate, Modified: time.Now()}
		h.Flags |= 0x800 // имя в UTF-8
		z, err := w.CreateHeader(h)
		must(err)
		_, err = z.Write(e.Data)
		must(err)
	}
	must(w.Close())
	must(f.Close())
}

func checkXML(name string, data []byte) {
	d := xml.NewDecoder(bytes.NewReader(bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})))
	for {
		_, err := d.Token()
		if err == io.EOF {
			return
		}
		if err != nil {
			fail("%s: XML не разбирается: %v", name, err)
		}
	}
}

// ---------- пакеты сценариев ----------

type pack struct {
	Name  string `json:"name"`
	Title string `json:"title"`
	Order int    `json:"order"`
	Dir   string `json:"-"`
	Files map[string]string
}

var identifier = regexp.MustCompile(`^[А-ЯЁа-яёA-Za-z_][А-ЯЁа-яёA-Za-z0-9_]*$`)

func loadPackages() []pack {
	dirs := []string{filepath.Join(root, "packages")}
	if private != "" {
		p, _ := filepath.Abs(private)
		dirs = append(dirs, filepath.Join(p, "packages"))
	}
	var packs []pack
	seen := map[string]bool{}
	for _, base := range dirs {
		entries, err := os.ReadDir(base)
		if err != nil {
			if os.IsNotExist(err) && base != dirs[0] {
				fail("в -private нет папки packages: %s", base)
			}
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			dir := filepath.Join(base, e.Name())
			manifest := filepath.Join(dir, "package.json")
			if _, err := os.Stat(manifest); err != nil {
				continue
			}
			var p pack
			must(json.Unmarshal([]byte(readText(manifest)), &p))
			if p.Name != e.Name() || !identifier.MatchString(p.Name) {
				fail("%s: имя пакета %q должно совпадать с папкой и быть идентификатором 1С", manifest, p.Name)
			}
			if seen[p.Name] {
				fail("пакет %s встречается дважды", p.Name)
			}
			seen[p.Name] = true
			p.Dir = dir
			p.Files = map[string]string{}
			for _, f := range []string{"ObjectInterface.bsl", "ObjectModule.bsl", "FormCommands.bsl", "FormModule.bsl"} {
				if _, err := os.Stat(filepath.Join(dir, f)); err == nil {
					p.Files[f] = readText(filepath.Join(dir, f))
				}
			}
			if !defines(p.Files["ObjectModule.bsl"], "ПакетПодходит"+p.Name) {
				fail("пакет %s: в ObjectModule.bsl нет функции ПакетПодходит%s(Причина)", p.Name, p.Name)
			}
			packs = append(packs, p)
		}
	}
	sort.SliceStable(packs, func(i, j int) bool {
		if packs[i].Order != packs[j].Order {
			return packs[i].Order < packs[j].Order
		}
		return packs[i].Name < packs[j].Name
	})
	return packs
}

func defines(text, name string) bool {
	re := regexp.MustCompile(`(?m)^(?:Асинх\s+)?(?:Процедура|Функция)\s+` + regexp.QuoteMeta(name) + `\s*\(`)
	return re.MatchString(text)
}

// Определённые в модуле процедуры и функции.
func definedNames(text string) map[string]bool {
	re := regexp.MustCompile(`(?m)^(?:Асинх\s+)?(?:Процедура|Функция)\s+([^\s(]+)\s*\(`)
	out := map[string]bool{}
	for _, m := range re.FindAllStringSubmatch(text, -1) {
		if out[m[1]] {
			fail("метод %s определён дважды (пакеты пересекаются по именам?)", m[1])
		}
		out[m[1]] = true
	}
	return out
}

// Маршрут ядра к пакетам. Impl - имя функции пакета, %s - имя пакета.
type hook struct {
	Name, Params, Default, Impl, Directive, Doc string
	Proc                                        bool
}

const genMark = "// ** Хлебников С.Ю. Сгенерировано сборщиком (src/build): маршруты к пакетам сценариев, руками не править."

var objectHooks = []hook{
	{Name: "ДобавитьШагиПакета", Proc: true, Params: "Шаги, Место", Impl: "ДобавитьШагиПакета%s",
		Doc: "Добавляет шаги пакета в место, которое отводит ядро (ПослеОкружения, ПослеПрименимости, ПослеКомпиляции, ПослеОпераций)."},
	{Name: "ВыполнитьШагПакета", Params: "ИмяШага, ЭлементШага", Default: "Ложь", Impl: "ВыполнитьШагПакета%s",
		Doc: "Выполняет шаг пакета. Ложь - такого шага в пакете нет."},
	{Name: "ЭлементыШагаПакета", Params: "ИмяШага", Default: "Неопределено", Impl: "ЭлементыШагаПакета%s",
		Doc: "Элементы шага пакета, который выполняется по частям; Неопределено - шаг целиком."},
	{Name: "ПредставлениеШагаВнеПрогонаПакета", Params: "ИмяШага", Default: `""`, Impl: "ПредставлениеШагаВнеПрогонаПакета%s",
		Doc: "Представление шага пакета вне обычного прогона (его вызывает кнопка формы)."},
	{Name: "ОбъектыПакета", Params: "Вид", Default: "Новый Массив", Impl: "ОбъектыПакета%s",
		Doc: "Объекты расширений для механизмов ядра: ОбщиеМодули, МодулиОбъектов, МодулиМенеджеров, МодулиНаборовЗаписей, Формы, ДокументыДляПерепроведения."},
	{Name: "НашиРасширения", Default: "Новый Массив", Impl: "НашиРасширенияПакета%s",
		Doc: "Имена наших расширений: их ошибки - ошибки, а не предупреждения."},
	{Name: "ПометкаНашихРасширений", Default: `""`, Impl: "ПометкаНашихРасширенийПакета%s",
		Doc: "Слово, которым записи журнала называют наши расширения, с пробелом в начале."},
	{Name: "ПрефиксыНашихОбъектов", Default: "Новый Массив", Impl: "ПрефиксыНашихОбъектовПакета%s",
		Doc: "Префиксы имён наших объектов (ошибка запроса формы с таким именем - ошибка расширения)."},
	{Name: "ПояснениеКомпиляцииПакета", Default: `""`, Impl: "ПояснениеКомпиляцииПакета%s",
		Doc: "Что шаг компиляции модулей не проверяет и почему."},
	{Name: "ОкружениеПакета", Proc: true, Params: "ИменаРасширенийБазы, ИменаРасширенийСеанса", Impl: "ОкружениеПакета%s",
		Doc: "Часть шага «Окружение», которую пишет пакет."},
	{Name: "РегистрыСОбъяснимымиРасхождениямиПакета", Params: "ИмяДокумента", Default: "Новый Массив", Impl: "РегистрыСОбъяснимымиРасхождениямиПакета%s",
		Doc: "Регистры, расхождения в движениях которых после перепроведения объясняет пакет."},
	{Name: "ПодготовкаПерепроведенияПакета", Proc: true, Impl: "ПодготовкаПерепроведенияПакета%s",
		Doc: "Сведения пакета в начале перепроведения документов."},
	{Name: "УзлыДляСнимковОбменаПакета", Default: "Новый Массив", Impl: "УзлыДляСнимковОбменаПакета%s",
		Doc: "Узлы обмена для снимков шага «Обмены»: Массив из Структура (Узел, Имя)."},
	{Name: "ОбъектыДляСнимковОбменаПакета", Params: "Узел, ИмяУзла", Default: "Новый Массив", Impl: "ОбъектыДляСнимковОбменаПакета%s",
		Doc: "Объекты, для которых шаг «Обмены» формирует сообщение обмена по узлу."},
	{Name: "ДокументыДляСнимковДвиженийПакета", Default: "Новый Массив", Impl: "ДокументыДляСнимковДвиженийПакета%s",
		Doc: "Имена видов документов, движения которых после перепроведения уходят снимком в гейт."},
	{Name: "ПечатныеФормыДляСнимковПакета", Default: "Новый Массив", Impl: "ПечатныеФормыДляСнимковПакета%s",
		Doc: "Печатные формы для шага «ПечатныеФормы»: Массив из Структура (Документ - имя вида, Команд - сколько первых команд печати)."},
	{Name: "ОтчетыДляСнимковПакета", Default: "Новый Массив", Impl: "ОтчетыДляСнимковПакета%s",
		Doc: "Отчёты на СКД для шага «Отчеты»: Массив из Структура (Имя, необязательно Параметры - Структура параметров данных)."},
	{Name: "СценарииПакета", Default: "Новый Массив", Impl: "СценарииПакета%s",
		Doc: "Сценарии по ТЗ для шага «Сценарии»: Массив из Структура (Имя, Представление, ТЗ)."},
	{Name: "ВыполнитьСценарийПакета", Proc: true, Params: "ИмяСценария, Результат", Impl: "ВыполнитьСценарийПакета%s",
		Doc: "Выполняет сценарий внутри отменяемой транзакции ядра; итог - в Результат (Выполнен, Успех, Текст, Пропуск)."},
}

var formHooks = []hook{
	{Name: "ПриСозданииНаСервереПакета", Proc: true, Directive: "&НаСервере", Impl: "ПриСозданииНаСервереПакета%s",
		Doc: "То, что форма делает при создании для пакета этой базы."},
	{Name: "ЗаписатьСтатьюБазыЗнанийПакета", Directive: "&НаСервере", Impl: "ЗаписатьСтатьюБазыЗнанийПакета%s",
		Default: `ВызватьИсключение "В этой сборке обработки нет пакета сценариев, который пишет статьи в базу знаний."`,
		Doc:     "Записывает статью об обновлении в базу знаний (режим автозапуска kbarticle)."},
	{Name: "КомандыФормыПакета", Directive: "&НаСервере", Default: "Новый Массив", Impl: "КомандыФормыПакета%s",
		Doc: "Кнопки пакета на форме: Массив из Структура (Имя, Заголовок, Действие - процедура из команд формы пакета)."},
}

func routers(hooks []hook, packs []pack, files []string, packageName string) string {
	var b strings.Builder
	for _, h := range hooks {
		kind, end := "Функция", "КонецФункции"
		if h.Proc {
			kind, end = "Процедура", "КонецПроцедуры"
		}
		b.WriteString("// " + h.Doc + "\n")
		if h.Directive != "" {
			b.WriteString(h.Directive + "\n")
		}
		fmt.Fprintf(&b, "%s %s(%s)\n\n", kind, h.Name, h.Params)
		first := true
		for _, p := range packs {
			impl := fmt.Sprintf(h.Impl, p.Name)
			found := false
			for _, f := range files {
				if defines(p.Files[f], impl) {
					found = true
				}
			}
			if !found {
				continue
			}
			if first {
				b.WriteString("\tИмяПакета = " + packageName + ";\n")
				b.WriteString("\tЕсли ИмяПакета = \"" + p.Name + "\" Тогда\n")
				first = false
			} else {
				b.WriteString("\tИначеЕсли ИмяПакета = \"" + p.Name + "\" Тогда\n")
			}
			if h.Proc {
				fmt.Fprintf(&b, "\t\t%s(%s);\n", impl, h.Params)
			} else {
				fmt.Fprintf(&b, "\t\tВозврат %s(%s);\n", impl, h.Params)
			}
		}
		if !first {
			b.WriteString("\tКонецЕсли;\n")
		}
		if !h.Proc {
			if strings.HasPrefix(h.Default, "ВызватьИсключение") {
				if !first {
					b.WriteString("\n")
				}
				b.WriteString("\t" + h.Default + ";\n")
			} else {
				if !first {
					b.WriteString("\n")
				}
				b.WriteString("\tВозврат " + h.Default + ";\n")
			}
		}
		b.WriteString("\n" + end + "\n\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func selectFunction(packs []pack) string {
	var b strings.Builder
	b.WriteString(genMark + "\n")
	b.WriteString(`// Возвращает пакет сценариев этой базы: первый (по order из package.json), чья функция ПакетПодходит<Имя>
// вернула Истина. Выбирается один раз за вызов сервера.
//
// Возвращаемое значение:
//  Структура - ключи Имя (пустая строка - пакета нет, выполняется одно ядро), Представление, Причина.
//
Функция ТекущийПакетСценариев() Экспорт

	Если ПакетСценариев <> Неопределено Тогда
		Возврат ПакетСценариев;
	КонецЕсли;

	ПакетСценариев = Новый Структура("Имя, Представление, Причина", "", "только ядро",
		"к этой базе не подходит ни один пакет сценариев");
`)
	for _, p := range packs {
		title := strings.ReplaceAll(p.Title, `"`, `""`)
		fmt.Fprintf(&b, `
	Причина = "";
	Если ПакетПодходит%[1]s(Причина) Тогда
		ПакетСценариев.Имя = "%[1]s";
		ПакетСценариев.Представление = "%[2]s";
		ПакетСценариев.Причина = Причина;
		Возврат ПакетСценариев;
	КонецЕсли;
`, p.Name, title)
	}
	b.WriteString("\n\tВозврат ПакетСценариев;\n\nКонецФункции")
	return b.String()
}

func region(name, body string) string {
	return "#Область " + name + "\n\n" + strings.Trim(body, "\n") + "\n\n#КонецОбласти"
}

func insert(text, marker, value, label string) string {
	return replaceCounted(text, "// @@ПАКЕТЫ: "+marker+"@@", value, 1, label)
}

// ---------- обработка «Выполнить после обновления» ----------

func buildProcessing(packs []pack) []entry {
	src := filepath.Join(root, "epf", "ВыполнитьПослеОбновления")
	object := readText(filepath.Join(src, "Ext", "ObjectModule.bsl"))
	form := readText(filepath.Join(src, "Forms", "Форма", "Ext", "Form", "Module.bsl"))
	formXML := readText(filepath.Join(src, "Forms", "Форма", "Ext", "Form.xml"))

	var iface, modules, commands, formModules []string
	for _, p := range packs {
		head := fmt.Sprintf("// Пакет «%s»: %s", p.Name, p.Title)
		if t := p.Files["ObjectInterface.bsl"]; t != "" {
			iface = append(iface, head+"\n\n"+strings.Trim(t, "\n"))
		}
		modules = append(modules, region("Пакет"+p.Name, p.Files["ObjectModule.bsl"]))
		if t := p.Files["FormCommands.bsl"]; t != "" {
			commands = append(commands, head+"\n\n"+strings.Trim(t, "\n"))
		}
		if t := p.Files["FormModule.bsl"]; t != "" {
			formModules = append(formModules, region("Пакет"+p.Name, t))
		}
	}
	objectFiles := []string{"ObjectModule.bsl", "ObjectInterface.bsl"}
	object = insert(object, "ВЫБОР", selectFunction(packs), "модуль объекта")
	object = insert(object, "ИНТЕРФЕЙС", strings.Join(iface, "\n\n"), "модуль объекта")
	object = insert(object, "МАРШРУТЫ", region("ПакетыСценариев", genMark+"\n\n"+routers(objectHooks, packs, objectFiles, "ТекущийПакетСценариев().Имя")), "модуль объекта")
	object = insert(object, "МОДУЛЬ", strings.Join(modules, "\n\n"), "модуль объекта")

	formRouters := genMark + "\n\n// Имя пакета сценариев этой базы, см. ТекущийПакетСценариев модуля объекта.\n&НаСервере\nФункция ИмяПакетаСценариевНаСервере()\n\n" +
		"\tВозврат РеквизитФормыВЗначение(\"Объект\").ТекущийПакетСценариев().Имя;\n\nКонецФункции\n\n" +
		routers(formHooks, packs, []string{"FormModule.bsl", "FormCommands.bsl"}, "ИмяПакетаСценариевНаСервере()")
	form = insert(form, "ФОРМА", strings.Join(append(formModules, region("ПакетыСценариевФормы", formRouters)), "\n\n"), "модуль формы")

	// Команды формы: обработчики пакетов, а на команды без обработчика - заглушки.
	defined := definedNames(form + "\n" + strings.Join(commands, "\n"))
	actions := regexp.MustCompile(`<Action>([^<]+)</Action>`).FindAllStringSubmatch(formXML, -1)
	var stubs []string
	for _, a := range actions {
		if defined[a[1]] {
			continue
		}
		stubs = append(stubs, fmt.Sprintf("// Команда пакета сценариев, которого нет в этой сборке.\n&НаКлиенте\nПроцедура %[1]s(Команда)\n\n"+
			"\tПоказатьПредупреждение(, \"Команда «%[1]s» относится к пакету сценариев, которого нет в этой сборке обработки.\");\n\nКонецПроцедуры", a[1]))
		defined[a[1]] = true
	}
	if len(stubs) > 0 {
		commands = append(commands, genMark+"\n\n"+strings.Join(stubs, "\n\n"))
	}
	form = insert(form, "КОМАНДЫ", strings.Join(commands, "\n\n"), "модуль формы")
	for _, m := range regexp.MustCompile(`<Event name="[^"]+">([^<]+)</Event>`).FindAllStringSubmatch(formXML, -1) {
		if !definedNames(form)[m[1]] {
			fail("обработчик события формы %s не определён", m[1])
		}
	}
	definedNames(object) // нет ли двойных определений
	if regexp.MustCompile(`(?m)^\s*// @@ПАКЕТЫ: [А-ЯЁ]+@@`).MatchString(object + form) {
		fail("в обработке остались метки @@ПАКЕТЫ")
	}

	object = replaceCounted(object, placeholder, stamp, 1, "модуль объекта")
	form = replaceCounted(form, placeholder, stamp, strings.Count(form, placeholder), "модуль формы")
	if strings.Count(form, stamp) < 2 {
		fail("модуль формы: меток версии меньше двух")
	}
	rootXML := replaceCounted(readText(filepath.Join(root, "epf", "ВыполнитьПослеОбновления.xml")), placeholder, stamp, 1, "ВыполнитьПослеОбновления.xml")

	files := []entry{
		{"ВыполнитьПослеОбновления.xml", windowsBytes(rootXML, true)},
		{"ВыполнитьПослеОбновления/Ext/ObjectModule.bsl", windowsBytes(object, true)},
		{"ВыполнитьПослеОбновления/Forms/Форма/Ext/Form/Module.bsl", windowsBytes(form, true)},
		{"ВыполнитьПослеОбновления/Forms/Форма/Ext/Form.xml", windowsBytes(formXML, true)},
		{"ВыполнитьПослеОбновления/Forms/Форма.xml", windowsBytes(readText(filepath.Join(src, "Forms", "Форма.xml")), true)},
	}
	for _, f := range files {
		if strings.HasSuffix(f.Name, ".xml") {
			checkXML(f.Name, f.Data)
		}
	}
	return files
}

// ---------- канарейка ----------

func buildCanary() []entry {
	base := filepath.Join(root, "epf")
	var files []entry
	walk := []string{"Канарейка.xml"}
	must(filepath.WalkDir(filepath.Join(base, "Канарейка"), func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			rel, _ := filepath.Rel(base, path)
			walk = append(walk, filepath.ToSlash(rel))
		}
		return err
	}))
	total := 0
	for _, rel := range walk {
		text := readText(filepath.Join(base, filepath.FromSlash(rel)))
		total += strings.Count(text, placeholder)
		text = strings.ReplaceAll(text, placeholder, stamp)
		data := windowsBytes(text, true)
		if strings.HasSuffix(rel, ".xml") {
			checkXML(rel, data)
		}
		files = append(files, entry{rel, data})
	}
	if total != 3 {
		fail("канарейка: меток версии %d, ожидалось 3", total)
	}
	return files
}

// ---------- гейт ----------

func goBuild(dir, out, ldflags string) []byte {
	if !skipExe {
		cmd := exec.Command("go", "build", "-trimpath", "-ldflags", ldflags, "-o", out, ".")
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GOOS=windows", "GOARCH=amd64", "CGO_ENABLED=0")
		if res, err := cmd.CombinedOutput(); err != nil {
			fail("%s не собрался: %v\n%s", filepath.Base(out), err, res)
		}
	}
	data, err := os.ReadFile(out)
	must(err)
	if !bytes.HasPrefix(data, []byte("MZ")) {
		fail("%s - не исполняемый файл Windows", out)
	}
	return data
}

func buildGate() []entry {
	gate := filepath.Join(root, "gate")
	version := "Версия " + placeholder + "."
	scripts := []string{"run.ps1", "deploy.ps1", "nightly.ps1", "report.ps1", "settings.ps1", "stats.ps1", "ui.ps1", "check.ps1", "test/tests.ps1", "test/fakecom.ps1"}
	stamped := map[string]bool{"run.ps1": true, "deploy.ps1": true, "nightly.ps1": true, "report.ps1": true, "settings.ps1": true, "stats.ps1": true, "test/tests.ps1": true, "test/fakecom.ps1": true}
	var files []entry
	texts := map[string]string{}
	for _, s := range scripts {
		text := readText(filepath.Join(gate, filepath.FromSlash(s)))
		if stamped[s] {
			text = replaceCounted(text, version, "Версия "+stamp+".", 1, s)
		}
		if !strings.HasPrefix(text, "#requires") {
			fail("%s: скрипт должен начинаться с #requires", s)
		}
		texts[s] = text
		files = append(files, entry{"ci/" + s, windowsBytes(text, true)})
	}
	clashCheck(texts)
	cmds, _ := filepath.Glob(filepath.Join(gate, "*.cmd"))
	for _, c := range cmds {
		text := readText(c)
		for _, r := range text {
			if r > 127 {
				fail("%s: в .cmd только ASCII", filepath.Base(c))
			}
		}
		files = append(files, entry{"ci/" + filepath.Base(c), windowsBytes(text, false)})
	}
	config := readText(filepath.Join(gate, "config.example.psd1"))
	files = append(files, entry{"ci/config.example.psd1", windowsBytes(config, true)})
	manual := replaceCounted(readText(filepath.Join(gate, "readme.txt")), "@@ВЕРСИЯ@@", stamp, strings.Count(readText(filepath.Join(gate, "readme.txt")), "@@ВЕРСИЯ@@"), "readme.txt")
	files = append(files, entry{"ci/readme.txt", windowsBytes(manual, true)})
	files = append(files, entry{"ci/ci.exe", goBuild(filepath.Join(root, "src", "ci-tui"), filepath.Join(outDir, "ci.exe"), "-s -w -X main.version="+stamp)})
	files = append(files, entry{"ci/test/fake1c.exe", goBuild(filepath.Join(root, "src", "fake1c"), filepath.Join(outDir, "fake1c.exe"), "-s -w")})
	// Установщик - в архиве рядом с папкой ci.
	for _, f := range []string{"install.ps1", "install.cmd"} {
		text := readText(filepath.Join(root, f))
		files = append(files, entry{f, windowsBytes(text, strings.HasSuffix(f, ".ps1"))})
	}
	return files
}

// ui.ps1 и stats.ps1 подключаются точкой: их переменные $script:X живут в одной области с ключами и
// переменными верхнего уровня скрипта. Совпадение имён без учёта регистра затирает значение.
func clashCheck(texts map[string]string) {
	vars := map[string]bool{}
	re := regexp.MustCompile(`\$script:([A-Za-z_][A-Za-z0-9_]*)`)
	for _, s := range []string{"ui.ps1", "stats.ps1"} {
		for _, m := range re.FindAllStringSubmatch(texts[s], -1) {
			vars[strings.ToLower(m[1])] = true
		}
	}
	top := regexp.MustCompile(`(?m)^\$(?:script:)?([A-Za-z_][A-Za-z0-9_]*)\s*=`)
	param := regexp.MustCompile(`\]\s*\$([A-Za-z_][A-Za-z0-9_]*)`)
	for _, s := range []string{"run.ps1", "deploy.ps1", "settings.ps1"} {
		text := texts[s]
		names := map[string]bool{}
		if i := strings.Index(text, "param("); i >= 0 {
			head := text[i:]
			if j := strings.Index(head, "\n)"); j > 0 {
				for _, m := range param.FindAllStringSubmatch(head[:j], -1) {
					names[strings.ToLower(m[1])] = true
				}
			}
		}
		for _, m := range top.FindAllStringSubmatch(text, -1) {
			names[strings.ToLower(m[1])] = true
		}
		for n := range names {
			if vars[n] {
				fail("%s: имя $%s совпадает с переменной ui.ps1/stats.ps1", s, n)
			}
		}
	}
}
