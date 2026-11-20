package main

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"strings"
)

// XML выгрузки разбирается в дерево со смещениями байтов: объединение собирает файл из кусков исходного текста,
// поэтому всё, что не менялось, остаётся байт в байт как у конфигуратора.

type xel struct {
	Name        string
	Attrs       map[string]string
	Start, End  int // от '<' до конца закрывающего тега
	InStart     int // после '>' открывающего тега
	InEnd       int // до '</'
	SelfClosing bool
	Children    []*xel
	Text        string // текст без вложенных элементов (обрезанный)
}

// parseXMLTree разбирает документ. Смещения - от начала data (с BOM).
func parseXMLTree(data []byte) (*xel, error) {
	body, shift := stripBOM(data)
	d := xml.NewDecoder(bytes.NewReader(body))
	d.Strict = true
	d.CharsetReader = func(charset string, input io.Reader) (io.Reader, error) { return input, nil }
	var stack []*xel
	var root *xel
	var text strings.Builder
	for {
		pos := int(d.InputOffset())
		tok, err := d.RawToken()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		switch tk := tok.(type) {
		case xml.StartElement:
			el := &xel{Name: tk.Name.Local, Attrs: map[string]string{}, Start: pos + shift, InStart: int(d.InputOffset()) + shift}
			for _, a := range tk.Attr {
				el.Attrs[a.Name.Local] = a.Value
			}
			if el.InStart-shift >= 2 && string(body[el.InStart-shift-2:el.InStart-shift]) == "/>" {
				el.SelfClosing = true
			}
			if len(stack) > 0 {
				parent := stack[len(stack)-1]
				parent.Children = append(parent.Children, el)
			} else if root == nil {
				root = el
			}
			stack = append(stack, el)
			text.Reset()
		case xml.EndElement:
			if len(stack) == 0 {
				return nil, fmt.Errorf("лишний закрывающий тег %s", tk.Name.Local)
			}
			el := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			if el.SelfClosing {
				el.InEnd = el.InStart
				el.End = el.InStart
			} else {
				el.InEnd = pos + shift
				el.End = int(d.InputOffset()) + shift
			}
			if len(el.Children) == 0 {
				el.Text = strings.TrimSpace(text.String())
			}
			text.Reset()
		case xml.CharData:
			text.Write(tk)
		}
	}
	if root == nil {
		return nil, fmt.Errorf("в файле нет корневого элемента")
	}
	return root, nil
}

// block - строки элемента: от начала его строки (если перед ним только отступ) до перевода строки после него.
func block(data []byte, el *xel) (int, int) {
	s := el.Start
	for s > 0 && (data[s-1] == ' ' || data[s-1] == '\t') {
		s--
	}
	if s > 0 && data[s-1] != '\n' {
		s = el.Start
	}
	e := el.End
	for e < len(data) && (data[e] == ' ' || data[e] == '\t' || data[e] == '\r') {
		e++
	}
	if e < len(data) && data[e] == '\n' {
		e++
	} else {
		e = el.End
	}
	return s, e
}

func (el *xel) child(name string) *xel {
	for _, c := range el.Children {
		if c.Name == name {
			return c
		}
	}
	return nil
}

// propName - <Properties><Name> объекта метаданных.
func propName(el *xel) string {
	if p := el.child("Properties"); p != nil {
		if n := p.child("Name"); n != nil {
			return n.Text
		}
	}
	return ""
}

// Виды узлов дерева объединения.
const (
	ckLeaf      = iota // сравнивается целиком
	ckObject           // объект метаданных: InternalInfo, Properties, ChildObjects
	ckProps            // свойства: по тегу
	ckChildren         // подчинённые объекты: по UUID или по тексту
	ckRights           // права роли: по объекту
	ckRightsObj        // права на объект: по праву
)

var childTitles = map[string]string{
	"Attribute": "реквизит", "TabularSection": "табличная часть", "Form": "форма", "Command": "команда",
	"Template": "макет", "Dimension": "измерение", "Resource": "ресурс", "EnumValue": "значение перечисления",
	"AccountingFlag": "признак учёта", "ExtDimensionAccountingFlag": "признак учёта субконто", "Column": "графа",
	"AddressingAttribute": "реквизит адресации", "Operation": "операция", "URLTemplate": "шаблон URL",
	"Method": "метод", "Recalculation": "перерасчёт", "Parameter": "параметр",
}

// keyedChild - ключ подузла и его вид. Повторы одного ключа нумеруются.
func keyedChild(parentKind int, c *xel) (string, int, string) {
	switch parentKind {
	case ckObject:
		switch c.Name {
		case "InternalInfo":
			return "internal", ckLeaf, "служебные сведения (InternalInfo)"
		case "Properties":
			return "props", ckProps, "свойства"
		case "ChildObjects":
			return "children", ckChildren, "состав"
		}
		return "other:" + c.Name, ckLeaf, c.Name
	case ckProps:
		return "prop:" + c.Name, ckLeaf, "свойство " + c.Name
	case ckChildren:
		if uuid := c.Attrs["uuid"]; uuid != "" {
			title := childTitles[c.Name]
			if title == "" {
				title = c.Name
			}
			if name := propName(c); name != "" {
				title += " " + name
			}
			return "child:" + c.Name + ":" + uuid, ckObject, title
		}
		title := childTitles[c.Name]
		if title == "" {
			title = c.Name
		}
		return "item:" + c.Name + ":" + c.Text, ckLeaf, title + " " + c.Text
	case ckRights:
		if c.Name == "object" {
			if n := c.child("name"); n != nil {
				return "object:" + n.Text, ckRightsObj, "права на " + n.Text
			}
		}
		return "el:" + c.Name, ckLeaf, c.Name
	case ckRightsObj:
		if c.Name == "right" {
			if n := c.child("name"); n != nil {
				return "right:" + n.Text, ckLeaf, "право " + n.Text
			}
		}
		return "el:" + c.Name, ckLeaf, c.Name
	}
	return "el:" + c.Name, ckLeaf, c.Name
}

type xkid struct {
	Key   string
	Kind  int
	Title string
	El    *xel
}

func keyedChildren(kind int, el *xel) []xkid {
	var out []xkid
	count := map[string]int{}
	for _, c := range el.Children {
		key, k, title := keyedChild(kind, c)
		count[key]++
		if count[key] > 1 {
			key += "#" + itoa(count[key])
		}
		out = append(out, xkid{Key: key, Kind: k, Title: title, El: c})
	}
	return out
}

// xmlDoc - разобранный XML файла выгрузки: корень, узел объединения и его вид.
type xmlDoc struct {
	Data []byte
	Root *xel
	Top  *xel // объект метаданных (под MetaDataObject) или корень прав
	Kind int  // ckObject, ckRights или ckLeaf (файл целиком)
	Err  string
}

func parseXMLDoc(data []byte) *xmlDoc {
	doc := &xmlDoc{Data: data, Kind: ckLeaf}
	root, err := parseXMLTree(data)
	if err != nil {
		doc.Err = err.Error()
		return doc
	}
	doc.Root = root
	switch root.Name {
	case "MetaDataObject":
		if len(root.Children) == 1 && root.Children[0].Attrs["uuid"] != "" {
			doc.Top = root.Children[0]
			doc.Kind = ckObject
		}
	case "Rights":
		doc.Top = root
		doc.Kind = ckRights
	}
	return doc
}

// flatten - все узлы дерева объединения с ключами (через /) и текстом элемента: для поиска версий в истории.
func flatten(doc *xmlDoc) map[string]string {
	out := map[string]string{}
	if doc.Top == nil {
		return out
	}
	var walk func(prefix string, kind int, el *xel)
	walk = func(prefix string, kind int, el *xel) {
		for _, kid := range keyedChildren(kind, el) {
			key := kid.Key
			if prefix != "" {
				key = prefix + "/" + key
			}
			out[key] = string(doc.Data[kid.El.Start:kid.El.End])
			if kid.Kind != ckLeaf {
				walk(key, kid.Kind, kid.El)
			}
		}
	}
	walk("", doc.Kind, doc.Top)
	return out
}
