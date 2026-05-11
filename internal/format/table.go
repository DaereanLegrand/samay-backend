package format

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/jedib0t/go-pretty/v6/table"
)

func RenderTable(headers []string, rows [][]string) {
	t := table.NewWriter()
	t.SetOutputMirror(os.Stdout)
	t.SetStyle(table.StyleLight)

	headerRow := make(table.Row, len(headers))
	for i, h := range headers {
		headerRow[i] = h
	}
	t.AppendHeader(headerRow)

	for _, r := range rows {
		row := make(table.Row, len(r))
		for i, v := range r {
			row[i] = v
		}
		t.AppendRow(row)
	}

	t.Render()
}

func RenderJSON(data interface{}) {
	b, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "error marshaling JSON: %v\n", err)
		return
	}
	fmt.Println(string(b))
}

func Output(data interface{}, jsonFlag bool, tableBuilder func(interface{}) ([]string, [][]string)) {
	if jsonFlag {
		RenderJSON(data)
		return
	}
	headers, rows := tableBuilder(data)
	RenderTable(headers, rows)
}
