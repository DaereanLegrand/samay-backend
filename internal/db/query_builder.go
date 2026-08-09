package db

import (
	"net/url"
	"strings"
)

type QueryBuilder struct {
	selects []string
	filters []string
	orders  []string
	limit   int
	offset  int
}

func NewQueryBuilder() *QueryBuilder {
	return &QueryBuilder{}
}

func (q *QueryBuilder) Select(columns ...string) *QueryBuilder {
	q.selects = append(q.selects, columns...)
	return q
}

func (q *QueryBuilder) Eq(col, val string) *QueryBuilder {
	q.filters = append(q.filters, col+"=eq."+escapeValue(val))
	return q
}

func (q *QueryBuilder) Neq(col, val string) *QueryBuilder {
	q.filters = append(q.filters, col+"=neq."+escapeValue(val))
	return q
}

func (q *QueryBuilder) Gt(col, val string) *QueryBuilder {
	q.filters = append(q.filters, col+"=gt."+escapeValue(val))
	return q
}

func (q *QueryBuilder) Gte(col, val string) *QueryBuilder {
	q.filters = append(q.filters, col+"=gte."+escapeValue(val))
	return q
}

func (q *QueryBuilder) Lt(col, val string) *QueryBuilder {
	q.filters = append(q.filters, col+"=lt."+escapeValue(val))
	return q
}

func (q *QueryBuilder) Lte(col, val string) *QueryBuilder {
	q.filters = append(q.filters, col+"=lte."+escapeValue(val))
	return q
}

func (q *QueryBuilder) Like(col, pattern string) *QueryBuilder {
	q.filters = append(q.filters, col+"=like."+escapeValue(pattern))
	return q
}

func (q *QueryBuilder) ILike(col, pattern string) *QueryBuilder {
	q.filters = append(q.filters, col+"=ilike."+escapeValue(pattern))
	return q
}

func (q *QueryBuilder) In(col string, values ...string) *QueryBuilder {
	escaped := make([]string, len(values))
	for i, v := range values {
		escaped[i] = escapeValue(v)
	}
	q.filters = append(q.filters, col+"=in.("+strings.Join(escaped, ",")+")")
	return q
}

func (q *QueryBuilder) NotIsNull(col string) *QueryBuilder {
	q.filters = append(q.filters, col+"=not.is.null")
	return q
}

func (q *QueryBuilder) Order(col string, asc bool) *QueryBuilder {
	dir := "asc"
	if !asc {
		dir = "desc"
	}
	q.orders = append(q.orders, col+"."+dir)
	return q
}

func (q *QueryBuilder) Limit(n int) *QueryBuilder {
	q.limit = n
	return q
}

func (q *QueryBuilder) Offset(n int) *QueryBuilder {
	q.offset = n
	return q
}

func (q *QueryBuilder) Build() (selectParams, filterQuery string) {
	selectParams = strings.Join(q.selects, ",")
	if selectParams == "" {
		selectParams = "*"
	}
	parts := append([]string{}, q.filters...)
	if len(q.orders) > 0 {
		parts = append(parts, "order="+strings.Join(q.orders, ","))
	}
	return selectParams, strings.Join(parts, "&")
}

func (q *QueryBuilder) limitN() int  { return q.limit }
func (q *QueryBuilder) offsetN() int { return q.offset }

func escapeValue(v string) string {
	esc := url.QueryEscape(v)
	esc = strings.ReplaceAll(esc, "%2A", "*")
	esc = strings.ReplaceAll(esc, "+", "%20")
	return esc
}
