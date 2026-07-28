package files

import (
	"os"
	"time"

	"github.com/google/uuid"
)

func newTransferID() string { return uuid.NewString() }

func nowMillis() int64 { return time.Now().UnixMilli() }

func statSize(path string) (int64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}

// progressThrottle keeps a fast transfer from flooding the UI bridge with an
// event per 256 KiB chunk, which costs more than the transfer itself.
type progressThrottle struct {
	last time.Time
}

func newProgressThrottle() *progressThrottle { return &progressThrottle{} }

func (p *progressThrottle) should(done, total int64) bool {
	if done >= total {
		return true
	}
	if time.Since(p.last) < 120*time.Millisecond {
		return false
	}
	p.last = time.Now()
	return true
}
