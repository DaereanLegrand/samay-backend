package db

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
)

func List[T any](ctx context.Context, client *DBClient, table string, qb *QueryBuilder) ([]T, error) {
	selectParams, filterQuery := qb.Build()
	filter := selectParams
	if filterQuery != "" {
		filter += "&" + filterQuery
	}
	body, err := selectRows(ctx, client, table, filter, qb.limitN(), qb.offsetN())
	if err != nil {
		return nil, fmt.Errorf("list %s: %w", table, err)
	}
	var rows []T
	if err := json.Unmarshal(body, &rows); err != nil {
		return nil, fmt.Errorf("unmarshal %s: %w", table, err)
	}
	return rows, nil
}

func GetByID[T any](ctx context.Context, client *DBClient, table, id string, qb *QueryBuilder) (*T, error) {
	if id != "" {
		qb = qb.Eq("id", id)
	}
	qb = qb.Limit(1)
	rows, err := List[T](ctx, client, table, qb)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		if id != "" {
			return nil, fmt.Errorf("%s not found: %s", table, id)
		}
		return nil, fmt.Errorf("%s not found", table)
	}
	return &rows[0], nil
}

func Insert[T any](ctx context.Context, client *DBClient, table string, row T, qb *QueryBuilder) (*T, error) {
	selectParams, _ := qb.Build()
	b, err := json.Marshal(row)
	if err != nil {
		return nil, fmt.Errorf("insert %s: json marshal: %w", table, err)
	}
	body, err := insertRow(ctx, client, table, selectParams, b)
	if err != nil {
		return nil, fmt.Errorf("insert %s: %w", table, err)
	}
	var created T
	if len(body) > 0 {
		if err := json.Unmarshal(body, &created); err != nil {
			return nil, fmt.Errorf("insert %s: unmarshal: %w", table, err)
		}
	}
	return &created, nil
}

func Update(ctx context.Context, client *DBClient, table string, qb *QueryBuilder, patch map[string]any) error {
	_, filterQuery := qb.Build()
	if filterQuery == "" {
		return fmt.Errorf("update %s: refused: no filter constraints", table)
	}
	if _, err := updateRows(ctx, client, table, filterQuery, patch); err != nil {
		return fmt.Errorf("update %s: %w", table, err)
	}
	return nil
}

func Delete(ctx context.Context, client *DBClient, table string, qb *QueryBuilder) error {
	_, filterQuery := qb.Build()
	if filterQuery == "" {
		return fmt.Errorf("delete %s: refused: no filter constraints", table)
	}
	if _, err := deleteRows(ctx, client, table, filterQuery); err != nil {
		return fmt.Errorf("delete %s: %w", table, err)
	}
	return nil
}

func selectRows(ctx context.Context, client *DBClient, table, filter string, limit, offset int) ([]byte, error) {
	return client.Select(ctx, table, filter, limit, offset)
}

func insertRow(ctx context.Context, client *DBClient, table, selectParams string, body []byte) ([]byte, error) {
	path := "/rest/v1/" + table + "?select=" + selectParams
	return client.request(ctx, "POST", path, bytes.NewReader(body))
}

func updateRows(ctx context.Context, client *DBClient, table, filter string, patch any) ([]byte, error) {
	return client.Update(ctx, table, filter, patch)
}

func deleteRows(ctx context.Context, client *DBClient, table, filter string) ([]byte, error) {
	return client.Delete(ctx, table, filter)
}
