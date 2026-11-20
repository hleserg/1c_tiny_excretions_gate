package main

import (
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
