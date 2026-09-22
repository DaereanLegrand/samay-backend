package loadtest

import (
	"context"
	"fmt"
	"math/rand"
	"strconv"
	"time"
)

// Run executes the configured phases and returns the aggregated report.
func Run(ctx context.Context, cfg *Config, logf func(string, ...any)) (*Report, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	client := NewClient(cfg)
	if err := client.Health(ctx); err != nil {
		return nil, fmt.Errorf("target health check failed: %w", err)
	}

	rng := rand.New(rand.NewSource(cfg.Seed))
	ds := &Dataset{Password: defaultPassword}
	for i := 0; i < cfg.Users; i++ {
		ds.Users = append(ds.Users, &Identity{
			Index:    i,
			ID:       uuidFor(cfg.RunID, "user", strconv.Itoa(i)),
			Username: cfg.username(i),
			Email:    cfg.email(i),
			Password: defaultPassword,
		})
	}

	rep := &Report{
		URL:          cfg.URL,
		RunID:        cfg.RunID,
		StartedAt:    time.Now(),
		MaxErrorRate: cfg.MaxErrorRate,
	}

	seedPhase := !cfg.LoadOnly && !cfg.RealtimeOnly
	if seedPhase {
		logf("seed phase…")
		res, err := Seed(ctx, cfg, client, ds, rng, logf)
		rep.Seed = res
		rep.Duration = time.Since(rep.StartedAt)
		if err != nil {
			return rep, err
		}
	}

	if !cfg.SeedOnly {
		acquireTokens(ctx, cfg, client, ds, logf)
	}

	if !cfg.SeedOnly && !cfg.RealtimeOnly {
		rec := NewRecorder()
		logf("load phase: %d workers for %s…", cfg.Workers, cfg.Duration)
		RunLoad(ctx, cfg, client, ds, rec, logf)
		rep.Load = rec.Snapshot()
		rep.TotalOps = rec.Total()
		rep.TotalErrors = rec.Errors()
	}

	if !cfg.SeedOnly && !cfg.LoadOnly {
		logf("realtime phase: %d clients for %s…", cfg.Realtime, cfg.Duration)
		rt := RunRealtime(ctx, cfg, client, ds, rng, logf)
		rep.Realtime = &rt
	}

	rep.Duration = time.Since(rep.StartedAt)
	if rep.TotalOps > 0 {
		rep.ErrorRate = float64(rep.TotalErrors) / float64(rep.TotalOps)
	}
	if len(rep.Load) == 0 && rep.Seed == nil {
		return rep, fmt.Errorf("nothing to do: enable a seed, load, or realtime phase")
	}
	rep.Passed = rep.ErrorRate <= cfg.MaxErrorRate && (rep.Seed == nil || len(rep.Seed.Errors) == 0)
	return rep, nil
}

// acquireTokens populates user JWTs, minting locally when a JWT secret is
// available (no GoTrue login), otherwise logging in through GoTrue.
func acquireTokens(ctx context.Context, cfg *Config, c *Client, ds *Dataset, logf func(string, ...any)) {
	if len(ds.Users) == 0 || cfg.SeedOnly {
		return
	}
	if cfg.JWTSecret != "" {
		ok := 0
		for _, u := range ds.Users {
			tok, err := mintJWT(cfg.JWTSecret, u.ID, u.Email, 12*time.Hour)
			if err == nil {
				u.Token = tok
				ok++
			}
		}
		logf("tokens: minted %d/%d locally from --jwt-secret", ok, len(ds.Users))
		return
	}
	logf("tokens: no --jwt-secret; logging in %d users via GoTrue (rate limits may throttle)…", len(ds.Users))
	errs := runParallel(ctx, len(ds.Users), 6, func(i int) error {
		u := ds.Users[i]
		access, refresh, err := c.PasswordLogin(ctx, u.Email, u.Password)
		if err != nil {
			return err
		}
		u.Token, u.Refresh = access, refresh
		return nil
	})
	ok := 0
	for _, err := range errs {
		if err == nil {
			ok++
		}
	}
	logf("tokens: %d/%d logged in", ok, len(ds.Users))
	if ok < len(ds.Users) {
		logf("tokens: some logins failed (likely GoTrue sign-in rate limit); load falls back to the service key for those users")
	}
}
