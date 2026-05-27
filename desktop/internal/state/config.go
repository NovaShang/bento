package state

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
)

// Config is persisted to ~/.bento/config.json. It binds this daemon to a
// relay endpoint and (after first login) to a Nova Auth account.
type Config struct {
	RelayURL  string `json:"relay_url"`            // e.g. https://relay.bento.novashang.com
	DaemonID  string `json:"daemon_id,omitempty"`  // assigned by relay on first registration
	AccountID string `json:"account_id,omitempty"` // Nova Auth subject
	SSHPort   int    `json:"ssh_port,omitempty"`   // loopback port the embedded SSH server bound to
}

// LoadConfig reads ~/.bento/config.json. Missing file returns a zero Config + nil error.
func LoadConfig() (Config, error) {
	p, err := ConfigPath()
	if err != nil {
		return Config{}, err
	}
	b, err := os.ReadFile(p)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Config{}, nil
		}
		return Config{}, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return Config{}, err
	}
	return c, nil
}

// SaveConfig atomically writes ~/.bento/config.json with 0600 perms.
func SaveConfig(c Config) error {
	p, err := ConfigPath()
	if err != nil {
		return err
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}
