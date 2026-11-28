package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	extUUID = "aaaaaaaa-0000-0000-0000-000000000001"
	docUUID = "bbbbbbbb-0000-0000-0000-000000000001"
	attrOrg = "cccccccc-0000-0000-0000-000000000001"
	attrNew = "cccccccc-0000-0000-0000-000000000002"
	attrK   = "cccccccc-0000-0000-0000-000000000003"
	repoExt = "extensions/Пр_Доработки"
)

func baseTree() tree {
	return tree{
		"Configuration.xml":                       configXML("Пр_Доработки", extUUID, "20261101.100000", "<Document>Пр_Заказ</Document>"),
		"Documents/Пр_Заказ.xml":                  docXML(docUUID, "Пр_Заказ", "", attrXML(attrOrg, "Организация", "cfg:CatalogRef.Организации")),
		"Documents/Пр_Заказ/Ext/ObjectModule.bsl": mod(modBase),
	}
}

func TestBSLUnits(t *testing.T) {
	m := parseBSL([]byte(mod(modBase)))
	if m.Err != "" {
		t.Fatal(m.Err)
	}
	units, order, titles := bslUnits(m)
	want := []string{"method:пр_обработкапроведения", "method:пр_пересчитать", "method:пр_скидка"}
	if strings.Join(order, ",") != strings.Join(want, ",") {
		t.Fatalf("единицы: %v", order)
	}
	if !strings.HasPrefix(units["method:пр_обработкапроведения"], "&После") {
		t.Fatalf("директива не в процедуре: %q", units["method:пр_обработкапроведения"])
	}
	if !strings.HasPrefix(units["method:пр_пересчитать"], "// Пересчитывает") {
		t.Fatalf("комментарий не в процедуре: %q", units["method:пр_пересчитать"])
	}
	if titles["method:пр_скидка"] != "функция Пр_Скидка" {
		t.Fatal(titles["method:пр_скидка"])
	}
	if m.Methods[1].Region[0] != "СлужебныеПроцедурыИФункции" {
		t.Fatalf("область: %v", m.Methods[1].Region)
	}
	// Ничего не меняли - модуль собирается байт в байт.
	results := map[string]bslResult{}
	for k, v := range units {
		results[k] = bslResult{Present: true, Text: v}
	}
	if got := rebuildBSL(m, m, results); got != mod(modBase) {
		t.Fatalf("сборка без изменений не совпала:\n%q", got)
	}
}

// Сценарий 1: первая поставка CFE без истории поставок. В temp (и уже в git) новый реквизит, которого нет в
// поставке, - остаётся; спорная замена процедуры - на решение; новая процедура поставки - принята.
func TestScenario1FirstDelivery(t *testing.T) {
	e := newEnv(t)
	ours := baseTree()
	ours["Documents/Пр_Заказ.xml"] = docXML(docUUID, "Пр_Заказ", "", attrXML(attrOrg, "Организация", "cfg:CatalogRef.Организации"), attrXML(attrNew, "Пр_Склад", "cfg:CatalogRef.Склады"))
	e.remember(repoExt, "main@1111111", baseTree())
	e.remember(repoExt, "main@2222222", ours)
	theirs := baseTree()
	theirs["Configuration.xml"] = configXML("Пр_Доработки", extUUID, "1.0.0.7", "<Document>Пр_Заказ</Document>")
	theirs["Documents/Пр_Заказ/Ext/ObjectModule.bsl"] = mod(modBase,
		[2]string{"Окр(СтрокаТЧ.Цена * СтрокаТЧ.Количество, 2)", "Окр(СтрокаТЧ.Цена * СтрокаТЧ.Количество, 0)"},
		[2]string{"Функция Пр_Скидка(Сумма)\n\tВозврат 0;\nКонецФункции\n", "Функция Пр_Скидка(Сумма)\n\tВозврат 0;\nКонецФункции\n\nФункция Пр_Наценка(Сумма)\n\tВозврат Сумма * 0.1;\nКонецФункции\n"})
	sp := e.object("extension", "Пр_Доработки", repoExt, ours, theirs, "s1")
	res := e.run("D1", nil, sp)
	obj := res.Objects[0]
	if !obj.First || res.Pending != 1 || obj.Status != "pending" {
		t.Fatalf("ждали одно решение в первой поставке: pending %d, status %s, first %v\n%s", res.Pending, obj.Status, obj.First, renderReport(res))
	}
	if ch := changeOf(obj, "child:Attribute:"+attrNew); ch == nil || ch.Class != clOursOnly || ch.Result != "ours" {
		t.Fatalf("реквизит temp: %+v", ch)
	}
	if ch := changeOf(obj, "method:пр_наценка"); ch == nil || ch.Class != clTheirsNew {
		t.Fatalf("новая функция: %+v", ch)
	}
	d := obj.Decisions[0]
	if d.Unit != "method:пр_пересчитать" || d.Kind != "conflict" || !strings.Contains(d.Diff, "- \t\tСтрокаТЧ.Сумма = Окр(СтрокаТЧ.Цена * СтрокаТЧ.Количество, 2);") || !strings.Contains(d.Diff, "+ \t\tСтрокаТЧ.Сумма = Окр(СтрокаТЧ.Цена * СтрокаТЧ.Количество, 0);") {
		t.Fatalf("решение: %+v", d)
	}
	if d.Recommended != "theirs" {
		t.Fatalf("у нас процедура не менялась - рекомендовать поставку: %+v", d)
	}
	if _, err := os.Stat(sp.Out); err == nil {
		t.Fatal("пока есть решение, результат не пишется")
	}
	// Оставить наше: реквизит и округление наши, новая функция поставки - в той же области после Пр_Скидка.
	res = e.run("D1", map[string]string{d.ID: "ours"}, sp)
	obj = res.Objects[0]
	if res.Pending != 0 || obj.Status != "changed" {
		t.Fatalf("после решения: %d %s", res.Pending, obj.Status)
	}
	module := readOut(t, sp, "Documents/Пр_Заказ/Ext/ObjectModule.bsl")
	if !strings.Contains(module, "Количество, 2)") || strings.Contains(module, "Количество, 0)") {
		t.Fatal("округление должно остаться нашим")
	}
	if !strings.Contains(module, "КонецФункции\r\n\r\nФункция Пр_Наценка(Сумма)\r\n\tВозврат Сумма * 0.1;\r\nКонецФункции\r\n\r\n#КонецОбласти") {
		t.Fatalf("новая функция не на месте:\n%s", module)
	}
	doc := readOut(t, sp, "Documents/Пр_Заказ.xml")
	if doc != ours["Documents/Пр_Заказ.xml"] {
		t.Fatal("документ должен остаться нашим байт в байт")
	}
	cfg := readOut(t, sp, "Configuration.xml")
	if !strings.Contains(cfg, "<Version>20261120.150000</Version>") {
		t.Fatal("нет нового штампа версии")
	}
	if len(obj.Rejected) != 1 || obj.Rejected[0].Unit != "method:пр_пересчитать" {
		t.Fatalf("отклонённая правка не записана: %+v", obj.Rejected)
	}
}

// Сценарий 2: повторная поставка. Подрядчик изменил одну процедуру (у нас она - как в его прошлой поставке),
// мы - другую (у него - прежняя версия). Обе правки в итоге. Правка обеих сторон в одной процедуре - точный конфликт.
func TestScenario2Redelivery(t *testing.T) {
	e := newEnv(t)
	v0 := baseTree()
	e.remember(repoExt, "main@1111111", v0)
	d1 := baseTree()
	d1["Documents/Пр_Заказ/Ext/ObjectModule.bsl"] = mod(modBase, [2]string{"Возврат 0;", "Возврат Сумма * 0.05;"})
	e.remember(repoExt, "delivery:D1", d1)
	e.remember(repoExt, "main@2222222", d1)
	ours := baseTree()
	ours["Documents/Пр_Заказ/Ext/ObjectModule.bsl"] = mod(modBase, [2]string{"Возврат 0;", "Возврат Сумма * 0.05;"}, [2]string{"\tПр_Пересчитать();\n", "\tПр_Пересчитать();\n\tПр_Записать();\n"})
	e.remember(repoExt, "main@3333333", ours)
	theirs := baseTree()
	theirs["Documents/Пр_Заказ/Ext/ObjectModule.bsl"] = mod(modBase, [2]string{"Возврат 0;", "Возврат Сумма * 0.07;"})
	sp := e.object("extension", "Пр_Доработки", repoExt, ours, theirs, "s2")
	res := e.run("D2", nil, sp)
	obj := res.Objects[0]
	if obj.First || res.Pending != 0 || obj.Status != "changed" {
		t.Fatalf("повторная поставка без решений: first %v pending %d status %s\n%s", obj.First, res.Pending, obj.Status, renderReport(res))
	}
	if ch := changeOf(obj, "method:пр_скидка"); ch == nil || ch.Class != clTheirsChanged {
		t.Fatalf("правка подрядчика: %+v", ch)
	}
	if ch := changeOf(obj, "method:пр_обработкапроведения"); ch == nil || ch.Class != clStale || ch.Result != "ours" {
		t.Fatalf("наша правка: %+v", ch)
	}
	module := readOut(t, sp, "Documents/Пр_Заказ/Ext/ObjectModule.bsl")
	if !strings.Contains(module, "Сумма * 0.07") || !strings.Contains(module, "Пр_Записать();") {
		t.Fatalf("в модуле должны быть обе правки:\n%s", module)
	}
	// Обе стороны в одной процедуре.
	e2 := newEnv(t)
	e2.history = e.history
	ours2 := baseTree()
	ours2["Documents/Пр_Заказ/Ext/ObjectModule.bsl"] = mod(modBase, [2]string{"Возврат 0;", "Возврат Сумма * 0.06;"})
	sp2 := e2.object("extension", "Пр_Доработки", repoExt, ours2, theirs, "s2b")
	e2.dir = e.dir
	res = e2.run("D2b", nil, sp2)
	if res.Pending != 1 {
		t.Fatalf("ждали точный конфликт: %d\n%s", res.Pending, renderReport(res))
	}
	d := res.Objects[0].Decisions[0]
	if d.Unit != "method:пр_скидка" || !strings.Contains(d.Diff, "- \tВозврат Сумма * 0.06;") || !strings.Contains(d.Diff, "+ \tВозврат Сумма * 0.07;") || d.Recommended != "ours" {
		t.Fatalf("конфликт: %+v", d)
	}
}

// Сценарий 3: старый файл под новым именем (или с прежним номером версии). Всё в поставке известно по истории -
// ничего не меняется; отклонённая раньше правка не возвращается.
func TestScenario3OldFile(t *testing.T) {
	e := newEnv(t)
	v0 := baseTree()
	e.remember(repoExt, "main@1111111", v0)
	d1 := baseTree()
	d1["Documents/Пр_Заказ/Ext/ObjectModule.bsl"] = mod(modBase, [2]string{"Количество, 2)", "Количество, 0)"})
	e.remember(repoExt, "delivery:D1", d1)
	// Отклонённая в D1 правка процедуры.
	rejectedHash := unitHash([]byte(unitText(t, d1["Documents/Пр_Заказ/Ext/ObjectModule.bsl"], "method:пр_пересчитать")))
	e.ledger("D1.json", []rejectedUnit{{Path: repoExt + "/Documents/Пр_Заказ/Ext/ObjectModule.bsl", Unit: "method:пр_пересчитать", Hash: rejectedHash, Delivery: "D1", Decision: "abc"}})
	ours := baseTree()
	ours["Documents/Пр_Заказ.xml"] = docXML(docUUID, "Пр_Заказ", "наш комментарий", attrXML(attrOrg, "Организация", "cfg:CatalogRef.Организации"))
	e.remember(repoExt, "main@2222222", ours)
	// Подрядчик прислал тот же файл, что в D1, под другим именем и с тем же номером версии.
	sp := e.object("extension", "Пр_Доработки", repoExt, ours, d1, "s3")
	res := e.run("D3", nil, sp)
	obj := res.Objects[0]
	if res.Pending != 0 || obj.Status != "unchanged" {
		t.Fatalf("старый файл: pending %d status %s\n%s", res.Pending, obj.Status, renderReport(res))
	}
	if ch := changeOf(obj, "method:пр_пересчитать"); ch == nil || ch.Class != clRejected {
		t.Fatalf("отклонённая правка: %+v", ch)
	}
	if ch := changeOf(obj, "props/prop:Comment"); ch == nil || ch.Class != clStale {
		t.Fatalf("наш поздний комментарий: %+v", ch)
	}
}

func unitText(t *testing.T, module, key string) string {
	m := parseBSL([]byte(module))
	units, _, _ := bslUnits(m)
	if _, ok := units[key]; !ok {
		t.Fatalf("нет единицы %s", key)
	}
	return units[key]
}

// Сценарий 6: непрозрачный макет (двоичный) - решение целой версией с sha256; защищённая обработка целиком.
func TestScenario6Opaque(t *testing.T) {
	e := newEnv(t)
	ours := baseTree()
	ours["Documents/Пр_Заказ/Templates/Печать/Ext/Template.bin"] = "\x00\x01старый"
	e.remember(repoExt, "main@1111111", ours)
	theirs := baseTree()
	theirs["Documents/Пр_Заказ/Templates/Печать/Ext/Template.bin"] = "\x00\x01новый"
	sp := e.object("extension", "Пр_Доработки", repoExt, ours, theirs, "s6")
	res := e.run("D6", nil, sp)
	if res.Pending != 1 {
		t.Fatalf("ждали решение по двоичному макету\n%s", renderReport(res))
	}
	d := res.Objects[0].Decisions[0]
	if d.Kind != "binary" || !strings.Contains(d.Theirs, fileSHA256([]byte("\x00\x01новый"))) {
		t.Fatalf("решение по макету: %+v", d)
	}
	// Защищённая обработка: объект целиком.
	op := objectSpec{Kind: "processing", Name: "Пр_Печать", Title: "Пр_Печать", RepoPath: "processings/Пр_Печать", Opaque: true,
		OpaqueReason: "модуль без исходного текста", TheirsSHA256: "ab12", OursSHA256: "cd34"}
	res = e.run("D6b", nil, op)
	if res.Pending != 1 || res.Objects[0].Decisions[0].Kind != "binary" || res.Objects[0].Binary != "ab12" {
		t.Fatalf("защищённая обработка: %+v", res.Objects[0])
	}
	id := res.Objects[0].Decisions[0].ID
	res = e.run("D6b", map[string]string{id: "theirs"}, op)
	if res.Pending != 0 || res.Objects[0].Status != "opaque" {
		t.Fatalf("после выбора целой версии: %+v", res.Objects[0])
	}
}

// Одноимённый реквизит с другим UUID - одно критичное решение, рекомендация - наш.
func TestClashAndIdentity(t *testing.T) {
	e := newEnv(t)
	ours := baseTree()
	e.remember(repoExt, "main@1111111", ours)
	theirs := baseTree()
	theirs["Documents/Пр_Заказ.xml"] = docXML(docUUID, "Пр_Заказ", "", attrXML(attrK, "Организация", "cfg:CatalogRef.Организации"))
	sp := e.object("extension", "Пр_Доработки", repoExt, ours, theirs, "clash")
	res := e.run("DC", nil, sp)
	if res.Pending != 1 {
		t.Fatalf("ждали одно решение\n%s", renderReport(res))
	}
	d := res.Objects[0].Decisions[0]
	if d.Kind != "clash" || !d.Critical || d.Recommended != "ours" || !strings.Contains(d.Theirs, attrK) {
		t.Fatalf("решение: %+v", d)
	}
	res = e.run("DC", map[string]string{d.ID: "ours"}, sp)
	if res.Objects[0].Status != "unchanged" {
		t.Fatalf("наш реквизит должен остаться: %s", res.Objects[0].Status)
	}
	// Документ с другим UUID корня.
	theirs2 := baseTree()
	theirs2["Documents/Пр_Заказ.xml"] = docXML("bbbbbbbb-0000-0000-0000-00000000ffff", "Пр_Заказ", "", attrXML(attrOrg, "Организация", "cfg:CatalogRef.Организации"))
	sp2 := e.object("extension", "Пр_Доработки", repoExt, ours, theirs2, "identity")
	res = e.run("DI", nil, sp2)
	if res.Pending != 1 || res.Objects[0].Decisions[0].Kind != "identity" {
		t.Fatalf("идентичность: %+v", res.Objects[0].Decisions)
	}
}

// Новые реквизиты поставки встают после того же соседа; новые процедуры в новой области - новой областью.
func TestPlacement(t *testing.T) {
	e := newEnv(t)
	ours := baseTree()
	e.remember(repoExt, "main@1111111", ours)
	theirs := baseTree()
	theirs["Documents/Пр_Заказ.xml"] = docXML(docUUID, "Пр_Заказ", "", attrXML(attrOrg, "Организация", "cfg:CatalogRef.Организации"), attrXML(attrK, "Пр_Комментарий", "xs:string"))
	theirs["Documents/Пр_Заказ/Ext/ObjectModule.bsl"] = mod(modBase, [2]string{"#КонецОбласти\n\n#Область СлужебныеПроцедурыИФункции", "#КонецОбласти\n\n#Область ПрограммныйИнтерфейс\n\nПроцедура Пр_Новая() Экспорт\nКонецПроцедуры\n\n#КонецОбласти\n\n#Область СлужебныеПроцедурыИФункции"})
	sp := e.object("extension", "Пр_Доработки", repoExt, ours, theirs, "place")
	res := e.run("DP", nil, sp)
	if res.Pending != 0 {
		t.Fatalf("всё новое - без решений\n%s", renderReport(res))
	}
	doc := readOut(t, sp, "Documents/Пр_Заказ.xml")
	if doc != theirs["Documents/Пр_Заказ.xml"] {
		t.Fatalf("документ с новым реквизитом должен совпасть с поставкой:\n%s", doc)
	}
	module := readOut(t, sp, "Documents/Пр_Заказ/Ext/ObjectModule.bsl")
	if !strings.Contains(module, "#Область ПрограммныйИнтерфейс\r\n\r\nПроцедура Пр_Новая() Экспорт\r\nКонецПроцедуры\r\n\r\n#КонецОбласти") {
		t.Fatalf("новая область:\n%s", module)
	}
	m := parseBSL([]byte(module))
	if m.Err != "" || len(m.Methods) != 4 {
		t.Fatalf("модуль после сборки: %s, методов %d", m.Err, len(m.Methods))
	}
}

// Права роли - по объектам: наше право остаётся, новое право поставки добавляется.
func TestRights(t *testing.T) {
	rights := func(objs ...string) string {
		return dump(`
<?xml version="1.0" encoding="UTF-8"?>
<Rights xmlns="http://v8.1c.ru/8.2/roles" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Rights" version="2.20">
	<setForNewObjects>false</setForNewObjects>
` + strings.Join(objs, "") + `</Rights>
`)
	}
	obj := func(name string, rs ...string) string {
		s := "\t<object>\n\t\t<name>" + name + "</name>\n"
		for _, r := range rs {
			s += "\t\t<right>\n\t\t\t<name>" + r + "</name>\n\t\t\t<value>true</value>\n\t\t</right>\n"
		}
		return s + "\t</object>\n"
	}
	e := newEnv(t)
	ours := baseTree()
	ours["Roles/Пр_Чтение/Ext/Rights.xml"] = rights(obj("Document.Пр_Заказ", "Read"), obj("Catalog.Пр_Наш", "Read"))
	e.remember(repoExt, "main@1111111", ours)
	theirs := baseTree()
	theirs["Roles/Пр_Чтение/Ext/Rights.xml"] = rights(obj("Document.Пр_Заказ", "Read", "View"), obj("Catalog.Пр_Новый", "Read"))
	sp := e.object("extension", "Пр_Доработки", repoExt, ours, theirs, "rights")
	res := e.run("DR", nil, sp)
	if res.Pending != 0 {
		t.Fatalf("права без решений\n%s", renderReport(res))
	}
	out := readOut(t, sp, "Roles/Пр_Чтение/Ext/Rights.xml")
	for _, want := range []string{"<name>View</name>", "Catalog.Пр_Наш", "Catalog.Пр_Новый"} {
		if !strings.Contains(out, want) {
			t.Fatalf("нет %s в правах:\n%s", want, out)
		}
	}
	if _, err := parseXMLTree([]byte(out)); err != nil {
		t.Fatal(err)
	}
}

// Обработчик формы без метода в модуле - проблема в итоге.
func TestFormHandlers(t *testing.T) {
	form := dump(`
<?xml version="1.0" encoding="UTF-8"?>
<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" version="2.20">
	<Events>
		<Event name="OnCreateAtServer">ПриСозданииНаСервере</Event>
	</Events>
</Form>
`)
	e := newEnv(t)
	ours := tree{"Форма/Ext/Form.xml": form, "Форма/Ext/Form/Module.bsl": dump("\n&НаСервере\nПроцедура ПриСозданииНаСервере(Отказ, СтандартнаяОбработка)\nКонецПроцедуры\n")}
	e.remember("processings/Пр_Обр", "main@1111111", ours)
	theirs := tree{"Форма/Ext/Form.xml": strings.Replace(form, "</Events>", "\t<Event name=\"OnOpen\">ПриОткрытии</Event>\r\n\t</Events>", 1), "Форма/Ext/Form/Module.bsl": ours["Форма/Ext/Form/Module.bsl"]}
	sp := e.object("processing", "Пр_Обр", "processings/Пр_Обр", ours, theirs, "form")
	res := e.run("DF", nil, sp)
	if res.Pending != 1 || res.Objects[0].Decisions[0].Recommended != "theirs" {
		t.Fatalf("форма в первой поставке - решение\n%s", renderReport(res))
	}
	res = e.run("DF", map[string]string{res.Objects[0].Decisions[0].ID: "theirs"}, sp)
	if len(res.Objects[0].Problems) != 1 || !strings.Contains(res.Objects[0].Problems[0], "ПриОткрытии") {
		t.Fatalf("проблемы: %v\n%s", res.Objects[0].Problems, renderReport(res))
	}
}

// Удаление в повторной поставке своей же части подрядчика - вопрос; решение «оставить» запоминается.
func TestRemovedRemembered(t *testing.T) {
	e := newEnv(t)
	v0 := baseTree()
	e.remember(repoExt, "main@1111111", v0)
	d1 := baseTree()
	d1["Documents/Пр_Заказ/Ext/ObjectModule.bsl"] = mod(modBase, [2]string{"Функция Пр_Скидка(Сумма)\n\tВозврат 0;\nКонецФункции\n", "Функция Пр_Скидка(Сумма)\n\tВозврат 0;\nКонецФункции\n\nПроцедура Пр_Подрядчика()\nКонецПроцедуры\n"})
	e.remember(repoExt, "delivery:D1", d1)
	e.remember(repoExt, "main@2222222", d1)
	sp := e.object("extension", "Пр_Доработки", repoExt, d1, v0, "rm")
	res := e.run("D2", nil, sp)
	if res.Pending != 1 || res.Objects[0].Decisions[0].Kind != "removed" || res.Objects[0].Decisions[0].Recommended != "theirs" {
		t.Fatalf("удаление: %+v\n%s", res.Objects[0].Decisions, renderReport(res))
	}
	id := res.Objects[0].Decisions[0].ID
	res = e.run("D2", map[string]string{id: "ours"}, sp)
	if len(res.Objects[0].Rejected) != 1 || res.Objects[0].Rejected[0].Hash != "absent" {
		t.Fatalf("отказ от удаления не записан: %+v", res.Objects[0].Rejected)
	}
	e.ledger("D2.json", res.Objects[0].Rejected)
	sp3 := e.object("extension", "Пр_Доработки", repoExt, d1, v0, "rm3")
	res = e.run("D3", nil, sp3)
	if res.Pending != 0 {
		t.Fatalf("повторное удаление после отказа - без вопроса\n%s", renderReport(res))
	}
}

// Своя поставка уже лежит в истории (гейт кладёт её туда до объединения) - она не «прежняя версия».
func TestOwnDeliveryIgnored(t *testing.T) {
	e := newEnv(t)
	ours := baseTree()
	e.remember(repoExt, "main@1111111", ours)
	theirs := baseTree()
	theirs["Documents/Пр_Заказ/Ext/ObjectModule.bsl"] = mod(modBase, [2]string{"Возврат 0;", "Возврат 1;"})
	e.remember(repoExt, "delivery:DX", theirs)
	sp := e.object("extension", "Пр_Доработки", repoExt, ours, theirs, "own")
	res := e.run("DX", nil, sp)
	if !res.Objects[0].First || res.Pending != 1 {
		t.Fatalf("своя поставка повлияла на объединение\n%s", renderReport(res))
	}
}

func TestDiffPaths(t *testing.T) {
	dir := t.TempDir()
	a := writeTree(t, filepath.Join(dir, "a"), tree{"x.bsl": "1", "y.bsl": "2", "ConfigDumpInfo.xml": "z"})
	b := writeTree(t, filepath.Join(dir, "b"), tree{"x.bsl": "1", "y.bsl": "3", "z.bsl": "4"})
	got := strings.Join(diffPaths(a, b), ",")
	if got != "y.bsl,z.bsl" {
		t.Fatal(got)
	}
}

func TestDamagedHistoryNamesTheLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "history.jsonl")
	if err := os.WriteFile(path, []byte("{}\n\n{broken}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := loadHistory(path)
	if err == nil || !strings.Contains(err.Error(), path) || !strings.Contains(err.Error(), "строка 3") || !strings.Contains(err.Error(), "JSON") {
		t.Fatalf("причина не указывает файл и строку повреждённого JSON: %v", err)
	}
}
