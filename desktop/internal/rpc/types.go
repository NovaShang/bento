// Package rpc holds the wire types shared between bento-daemon and CLI/menubar.
// Transport is HTTP over the Unix socket at state.SocketPath().
package rpc

const (
	PathStatus       = "/v1/status"
	PathPairBegin    = "/v1/pair/begin"
	PathPairCancel   = "/v1/pair/cancel"
	PathDeviceList   = "/v1/devices"
	PathDeviceRevoke = "/v1/devices/revoke"
	PathRelayStatus  = "/v1/relay/status"
)

// StatusResp is the daemon health summary.
type StatusResp struct {
	Version       string `json:"version"`
	PID           int    `json:"pid"`
	UptimeSec     int64  `json:"uptime_sec"`
	RelayURL      string `json:"relay_url,omitempty"`
	RelayConn     bool   `json:"relay_connected"`
	DaemonID      string `json:"daemon_id,omitempty"`
	PairedDevices int    `json:"paired_devices"`

	// ExePath / ExeHash identify the exact binary this process is running,
	// fingerprinted at startup — so replacing the file on disk does NOT
	// change them. Replacing the .app rewrites the embedded helper but the
	// running daemon keeps executing the old inode, and `tunnel start`
	// no-ops while a daemon is alive, so nothing else would ever notice.
	// The Mac app compares ExeHash against the helper it would launch to
	// spot exactly that. Hashes rather than Version because every local
	// build carries the same version string.
	ExePath string `json:"exe_path,omitempty"`
	ExeHash string `json:"exe_hash,omitempty"`

	// LiveAgents / BusyAgents price a restart: it kills every hosted agent,
	// so the UI can say what is at stake instead of asking blind.
	LiveAgents int `json:"live_agents"`
	BusyAgents int `json:"busy_agents"`
}

// PairBeginResp is returned when the operator (Mac App / CLI) starts a
// pairing window. The 6-digit code is displayed to the user; the iOS device
// types it back. Codes expire after TTL seconds.
type PairBeginResp struct {
	Code      string `json:"code"`
	TTLSec    int    `json:"ttl_sec"`
	ExpiresAt int64  `json:"expires_at"`
}

// DeviceSummary describes one paired iOS device.
type DeviceSummary struct {
	DeviceID    string `json:"device_id"`
	Label       string `json:"label,omitempty"`
	PairedAt    int64  `json:"paired_at"`
	LastSeen    int64  `json:"last_seen,omitempty"`
	KeyFingerSP string `json:"key_fingerprint"`
}

// DeviceListResp lists all paired devices.
type DeviceListResp struct {
	Devices []DeviceSummary `json:"devices"`
}

// DeviceRevokeReq removes a device from authorized_keys.
type DeviceRevokeReq struct {
	DeviceID string `json:"device_id"`
}

// RelayStatusResp is just the relay-connection slice of StatusResp.
type RelayStatusResp struct {
	Connected bool   `json:"connected"`
	URL       string `json:"url,omitempty"`
	DaemonID  string `json:"daemon_id,omitempty"`
	LastError string `json:"last_error,omitempty"`
}

// ErrorResp is the body of non-2xx responses.
type ErrorResp struct {
	Error string `json:"error"`
}
