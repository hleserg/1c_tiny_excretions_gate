package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestOptionalHookDeclarationRoutesToPackage(t *testing.T) {
	route := func(module string) string {
		p := pack{Name: "Пример", Files: map[string]string{"ObjectModule.bsl": module}}
		return routers(objectHooks, []pack{p}, []string{"ObjectModule.bsl"}, "ТекущийПакетСценариев().Имя")
	}
	original := "Функция ОбъектыПакетаПример(Вид)\n\tВозврат Новый Массив;\nКонецФункции"
	want := route(original)
	if !strings.Contains(want, "Если ИмяПакета = \"Пример\" Тогда") ||
		!strings.Contains(want, "Возврат ОбъектыПакетаПример(Вид);") {
		t.Fatalf("в маршруте нет вызова метода пакета:\n%s", want)
	}
	for _, declaration := range []string{"  " + original, "\t" + strings.ToLower(original), strings.ToUpper(original)} {
		if got := route(declaration); got != want {
			t.Errorf("маршрут изменился для объявления %q:\n%s", declaration, got)
		}
	}
	for _, module := range []string{"// " + original, strings.Replace(original, "Пример(", "ПримерДругой(", 1)} {
		if got := route(module); got != route("") {
			t.Errorf("сгенерирован вызов отсутствующего метода:\n%s", got)
		}
	}
}

func TestDefinedNamesIndexesIndentedAsyncHandler(t *testing.T) {
	module := "// Процедура ЧужаяКоманда()\n\tаСиНх  прОцедура КомандаФормы(Команда)\nКонецПроцедуры"
	names := definedNames(module)
	if len(names) != 1 || !names[strings.ToLower("КОМАНДАФОРМЫ")] {
		t.Fatalf("обработчик команды не найден по имени из формы: %v", names)
	}
}

func TestNotifyHandlerProblems(t *testing.T) {
	good := "&НаКлиенте\nПроцедура Начать()\n\tОповещение = Новый ОписаниеОповещения(\"ПослеЧтения\", ЭтотОбъект, Неопределено,\n\t\t\"ПриОшибке\", ЭтотОбъект);\n" +
		"\tДокумент.НачатьЧтение(Оповещение, Файл, \"UTF-8\");\nКонецПроцедуры\n\n" +
		"&НаКлиенте\nПроцедура ПослеЧтения(ДополнительныеПараметры) Экспорт\nКонецПроцедуры\n\n" +
		"&НаКлиенте\nПроцедура ПриОшибке(ИнформацияОбОшибке, СтандартнаяОбработка, ДополнительныеПараметры) Экспорт\nКонецПроцедуры\n"
	if got := notifyHandlerProblems(good); len(got) != 0 {
		t.Fatalf("правильные обработчики отвергнуты: %v", got)
	}
	cases := map[string]string{
		"два необязательных параметра у конца чтения": strings.Replace(good, "ПослеЧтения(ДополнительныеПараметры)", "ПослеЧтения(ПервыйПараметр = Неопределено, ВторойПараметр = Неопределено)", 1),
		"два параметра у конца чтения":                strings.Replace(good, "ПослеЧтения(ДополнительныеПараметры)", "ПослеЧтения(Результат, ДополнительныеПараметры)", 1),
		"два параметра у обработчика ошибки":          strings.Replace(good, "ПриОшибке(ИнформацияОбОшибке, СтандартнаяОбработка, ДополнительныеПараметры)", "ПриОшибке(ИнформацияОбОшибке, ДополнительныеПараметры)", 1),
		"обработчика нет":                             strings.Replace(good, "Процедура ПослеЧтения(", "Процедура ПослеЧтенияДругое(", 1),
	}
	for name, module := range cases {
		if got := notifyHandlerProblems(module); len(got) == 0 {
			t.Errorf("%s: ошибка не найдена", name)
		}
	}
}

func TestInvalidPackageManifestNamesTheFile(t *testing.T) {
	const helper = "GATE_TEST_INVALID_MANIFEST"
	if dir := os.Getenv(helper); dir != "" {
		root = dir
		loadPackages()
		return
	}
	dir := t.TempDir()
	packDir := filepath.Join(dir, "packages", "Sample")
	if err := os.MkdirAll(packDir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(packDir, "package.json")
	if err := os.WriteFile(path, []byte("{broken}"), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestInvalidPackageManifestNamesTheFile$")
	cmd.Env = append(os.Environ(), helper+"="+dir)
	out, err := cmd.CombinedOutput()
	if err == nil || !strings.Contains(string(out), path) || !strings.Contains(string(out), "JSON") || !strings.Contains(string(out), "invalid character") {
		t.Fatalf("ошибка чтения пакета должна назвать файл и причину: %s (%v)", out, err)
	}
}
