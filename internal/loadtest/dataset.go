package loadtest

import (
	"context"
	"sync"
)

// Identity is one generated user plus its credentials/token.
type Identity struct {
	Index     int
	ID        string
	Username  string
	Email     string
	Password  string
	AvatarURL string
	Token     string
	Refresh   string
}

// Dataset is everything the seed phase produced, shared with the load and
// realtime phases.
type Dataset struct {
	Users         []*Identity
	Groups        []string
	Events        []string
	Matches       []string
	ActiveMatches []string
	Chats         []string
	UserChats     map[string][]string
	Edges         [][2]int
	Password      string
}

// userByIndex is a convenience accessor.
func (d *Dataset) userByIndex(i int) *Identity {
	if len(d.Users) == 0 {
		return nil
	}
	return d.Users[((i%len(d.Users))+len(d.Users))%len(d.Users)]
}

// SeedResult reports what the seed phase created.
type SeedResult struct {
	Users        int      `json:"users"`
	Avatars      int      `json:"avatars"`
	Friendships  int      `json:"friendships"`
	Groups       int      `json:"groups"`
	GroupBanners int      `json:"group_banners"`
	GroupMembers int      `json:"group_members"`
	Events       int      `json:"events"`
	EventPhotos  int      `json:"event_photos"`
	Chats        int      `json:"chats"`
	Messages     int      `json:"messages"`
	Matches      int      `json:"matches"`
	GameStates   int      `json:"game_states"`
	Reactions    int      `json:"reactions"`
	Results      int      `json:"results"`
	Errors       []string `json:"errors"`
}

func (r *SeedResult) addError(op string, err error) {
	const maxErrors = 50
	if err == nil || len(r.Errors) >= maxErrors {
		return
	}
	r.Errors = append(r.Errors, op+": "+err.Error())
}

// runParallel executes fn(i) for i in [0,n) using at most workers goroutines.
// It returns the per-index error (nil on success) and stops early if ctx ends.
func runParallel(ctx context.Context, n, workers int, fn func(i int) error) []error {
	if n <= 0 {
		return nil
	}
	if workers < 1 {
		workers = 1
	}
	if workers > n {
		workers = n
	}
	errs := make([]error, n)
	ch := make(chan int)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range ch {
				errs[i] = fn(i)
			}
		}()
	}
	for i := 0; i < n; i++ {
		select {
		case ch <- i:
		case <-ctx.Done():
			close(ch)
			wg.Wait()
			return errs
		}
	}
	close(ch)
	wg.Wait()
	return errs
}
