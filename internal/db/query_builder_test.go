package db

import "testing"

func TestQueryBuilderBuild(t *testing.T) {
	cases := []struct {
		name       string
		build      func() *QueryBuilder
		wantSelect string
		wantFilter string
	}{
		{
			name:       "empty defaults to star select",
			build:      func() *QueryBuilder { return NewQueryBuilder() },
			wantSelect: "*",
			wantFilter: "",
		},
		{
			name: "select columns",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Select("id", "username", "created_at")
			},
			wantSelect: "id,username,created_at",
			wantFilter: "",
		},
		{
			name: "eq escapes ampersand equals space comma",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Eq("name", "a&b=c d,e")
			},
			wantSelect: "*",
			wantFilter: "name=eq.a%26b%3Dc%20d%2Ce",
		},
		{
			name: "eq escapes equals sign",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Eq("name", "a=b")
			},
			wantSelect: "*",
			wantFilter: "name=eq.a%3Db",
		},
		{
			name: "eq escapes space as percent twenty",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Eq("city", "san jose")
			},
			wantSelect: "*",
			wantFilter: "city=eq.san%20jose",
		},
		{
			name: "eq escapes comma in value",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Eq("tag", "a,b")
			},
			wantSelect: "*",
			wantFilter: "tag=eq.a%2Cb",
		},
		{
			name: "eq keeps dots unescaped",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Eq("key", "test.key")
			},
			wantSelect: "*",
			wantFilter: "key=eq.test.key",
		},
		{
			name: "neq gt gte lt lte",
			build: func() *QueryBuilder {
				return NewQueryBuilder().
					Neq("status", "draft").
					Gt("created_at", "2026-01-01").
					Gte("age", "18").
					Lt("score", "100").
					Lte("level", "5")
			},
			wantSelect: "*",
			wantFilter: "status=neq.draft&created_at=gt.2026-01-01&age=gte.18&score=lt.100&level=lte.5",
		},
		{
			name: "like keeps star wildcards",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Like("username", "*alice*")
			},
			wantSelect: "*",
			wantFilter: "username=like.*alice*",
		},
		{
			name: "ilike keeps star wildcards",
			build: func() *QueryBuilder {
				return NewQueryBuilder().ILike("username", "*alice*")
			},
			wantSelect: "*",
			wantFilter: "username=ilike.*alice*",
		},
		{
			name: "in list",
			build: func() *QueryBuilder {
				return NewQueryBuilder().In("id", "1", "2", "3")
			},
			wantSelect: "*",
			wantFilter: "id=in.(1,2,3)",
		},
		{
			name: "in list escapes commas inside values",
			build: func() *QueryBuilder {
				return NewQueryBuilder().In("tag", "a,b", "c")
			},
			wantSelect: "*",
			wantFilter: "tag=in.(a%2Cb,c)",
		},
		{
			name: "not is null",
			build: func() *QueryBuilder {
				return NewQueryBuilder().NotIsNull("banned_at")
			},
			wantSelect: "*",
			wantFilter: "banned_at=not.is.null",
		},
		{
			name: "order asc and desc",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Order("created_at", false).Order("name", true)
			},
			wantSelect: "*",
			wantFilter: "order=created_at.desc,name.asc",
		},
		{
			name: "filters then order",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Eq("user_id", "u1").Order("created_at", false)
			},
			wantSelect: "*",
			wantFilter: "user_id=eq.u1&order=created_at.desc",
		},
		{
			name: "injection attempt is neutralized",
			build: func() *QueryBuilder {
				return NewQueryBuilder().Eq("username", "x&status=eq.admin&foo=")
			},
			wantSelect: "*",
			wantFilter: "username=eq.x%26status%3Deq.admin%26foo%3D",
		},
		{
			name: "chainable select with filters and order",
			build: func() *QueryBuilder {
				return NewQueryBuilder().
					Select("id", "name").
					Eq("status", "active").
					Order("name", true)
			},
			wantSelect: "id,name",
			wantFilter: "status=eq.active&order=name.asc",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotSelect, gotFilter := tc.build().Build()
			if gotSelect != tc.wantSelect {
				t.Errorf("select: got %q, want %q", gotSelect, tc.wantSelect)
			}
			if gotFilter != tc.wantFilter {
				t.Errorf("filter: got %q, want %q", gotFilter, tc.wantFilter)
			}
		})
	}
}

func TestQueryBuilderLimitOffset(t *testing.T) {
	qb := NewQueryBuilder().Limit(10).Offset(5)
	if got := qb.limitN(); got != 10 {
		t.Errorf("limit: got %d, want 10", got)
	}
	if got := qb.offsetN(); got != 5 {
		t.Errorf("offset: got %d, want 5", got)
	}
}

func TestEscapeValue(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"plain", "plain"},
		{"with space", "with%20space"},
		{"amp&ersand", "amp%26ersand"},
		{"eq=sign", "eq%3Dsign"},
		{"comma,value", "comma%2Cvalue"},
		{"plus+sign", "plus%2Bsign"},
		{"percent%sign", "percent%25sign"},
		{"wild*card", "wild*card"},
		{"dot.value", "dot.value"},
		{"parens(x)", "parens%28x%29"},
	}
	for _, tc := range cases {
		if got := escapeValue(tc.in); got != tc.want {
			t.Errorf("escapeValue(%q): got %q, want %q", tc.in, got, tc.want)
		}
	}
}
