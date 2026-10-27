package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxRPCBody = 4 << 20
	maxFees    = 1440
)

type config struct {
	rpcURL            string
	rpcUser           string
	rpcPassword       string
	dashboardPassword string
	dataDir           string
	stateDir          string
	version           string
	port              string
}

type rpcClient struct {
	url      string
	user     string
	password string
	client   *http.Client
}

type rpcResponse struct {
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
}

func (r *rpcClient) call(ctx context.Context, method string, params any, out any) error {
	if params == nil {
		params = []any{}
	}
	body, err := json.Marshal(map[string]any{"jsonrpc": "1.0", "id": "go-dashboard", "method": method, "params": params})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.SetBasicAuth(r.user, r.password)
	req.Header.Set("Content-Type", "application/json")
	resp, err := r.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("RPC %s returned HTTP %d", method, resp.StatusCode)
	}
	responseBody, err := io.ReadAll(io.LimitReader(resp.Body, maxRPCBody+1))
	if err != nil {
		return fmt.Errorf("read RPC %s: %w", method, err)
	}
	if len(responseBody) > maxRPCBody {
		return fmt.Errorf("RPC %s response exceeds %d bytes", method, maxRPCBody)
	}
	var envelope rpcResponse
	if err := json.Unmarshal(responseBody, &envelope); err != nil {
		return fmt.Errorf("decode RPC %s: %w", method, err)
	}
	if len(envelope.Error) > 0 && string(envelope.Error) != "null" {
		return fmt.Errorf("RPC %s returned an error", method)
	}
	if len(envelope.Result) == 0 || string(envelope.Result) == "null" {
		return fmt.Errorf("RPC %s returned no result", method)
	}
	if err := json.Unmarshal(envelope.Result, out); err != nil {
		return fmt.Errorf("decode RPC %s result: %w", method, err)
	}
	return nil
}

type blockchainInfo struct {
	Blocks               int64   `json:"blocks"`
	Headers              int64   `json:"headers"`
	VerificationProgress float64 `json:"verificationprogress"`
	InitialBlockDownload bool    `json:"initialblockdownload"`
	Pruned               bool    `json:"pruned"`
	PruneTargetSize      int64   `json:"prune_target_size"`
	SizeOnDisk           int64   `json:"size_on_disk"`
}

type networkInfo struct {
	Subversion  string `json:"subversion"`
	Connections int64  `json:"connections"`
}

type peerInfo struct {
	Inbound bool `json:"inbound"`
}

type mempoolInfo struct {
	Size  int64 `json:"size"`
	Bytes int64 `json:"bytes"`
}

type feeEstimate struct {
	FeeRate *float64 `json:"feerate"`
}

type diskInfo struct {
	Total uint64
	Free  uint64
}

type pageData struct {
	Loading       bool
	Version       string
	CoreVersion   string
	Uptime        string
	Blocks        int64
	Headers       int64
	Progress      float64
	TotalPeers    int64
	Inbound       int
	Outbound      int
	Pruned        bool
	PruneTargetGB float64
	NodeGB        float64
	TotalGB       float64
	FreeGB        float64
	DiskWarn      bool
	DiskPercent   float64
	ShowMempool   bool
	MempoolTxs    int64
	MempoolMB     float64
	FeeNext       string
	Fee30m        string
	FeeHour       string
	NextBlock     int64
	LastUpdate    string
}

type app struct {
	cfg      config
	rpc      *rpcClient
	template *template.Template
	static   http.Handler
	feesMu   sync.RWMutex
	fees     []float64
	log      *log.Logger
}

func newApp(cfg config, rpc *rpcClient, templatePath, staticPath string, logger *log.Logger) (*app, error) {
	t, err := template.ParseFiles(templatePath)
	if err != nil {
		return nil, err
	}
	a := &app{cfg: cfg, rpc: rpc, template: t, static: http.StripPrefix("/static/", http.FileServer(http.Dir(staticPath))), log: logger}
	a.loadFees()
	return a, nil
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", a.index)
	mux.HandleFunc("/metrics", a.metrics)
	mux.HandleFunc("/api/fees", a.apiFees)
	mux.HandleFunc("/api/watch", a.apiWatch)
	mux.HandleFunc("/api/watch/", a.apiWatch)
	mux.HandleFunc("/api/upgrade", a.apiUpgrade)
	mux.Handle("/static/", a.static)
	return a.auth(a.readOnly(mux))
}

func (a *app) readOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "read-only prototype", http.StatusMethodNotAllowed)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *app) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if a.cfg.dashboardPassword == "" {
			next.ServeHTTP(w, r)
			return
		}
		_, password, ok := r.BasicAuth()
		valid := ok && len(password) == len(a.cfg.dashboardPassword) && subtle.ConstantTimeCompare([]byte(password), []byte(a.cfg.dashboardPassword)) == 1
		if !valid {
			w.Header().Set("WWW-Authenticate", `Basic realm="Bitcoin Node Status"`)
			http.Error(w, "Authentication required", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *app) index(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	var chain blockchainInfo
	if err := a.rpc.call(ctx, "getblockchaininfo", []any{}, &chain); err != nil {
		a.render(w, pageData{Loading: true, Version: versionLabel(a.cfg.version)})
		return
	}
	var network networkInfo
	var peers []peerInfo
	var uptime float64
	_ = a.rpc.call(ctx, "getnetworkinfo", []any{}, &network)
	_ = a.rpc.call(ctx, "getpeerinfo", []any{}, &peers)
	_ = a.rpc.call(ctx, "uptime", []any{}, &uptime)

	inbound := 0
	for _, peer := range peers {
		if peer.Inbound {
			inbound++
		}
	}
	disk := diskUsage(a.cfg.dataDir)
	data := pageData{
		Version: versionLabel(a.cfg.version), CoreVersion: network.Subversion, Uptime: formatUptime(uptime),
		Blocks: chain.Blocks, Headers: chain.Headers, Progress: chain.VerificationProgress * 100,
		TotalPeers: network.Connections, Inbound: inbound, Outbound: len(peers) - inbound,
		Pruned: chain.Pruned, PruneTargetGB: gib(chain.PruneTargetSize), NodeGB: gib(chain.SizeOnDisk),
		TotalGB: gibU(disk.Total), FreeGB: gibU(disk.Free), DiskWarn: disk.Free < 50*1024*1024*1024,
		NextBlock: chain.Blocks + 1, LastUpdate: time.Now().Format("15:04:05"),
		FeeNext: "—", Fee30m: "—", FeeHour: "—",
	}
	if disk.Total > 0 {
		data.DiskPercent = float64(chain.SizeOnDisk) / float64(disk.Total) * 100
	}
	if !chain.InitialBlockDownload {
		var mempool mempoolInfo
		if a.rpc.call(ctx, "getmempoolinfo", []any{}, &mempool) == nil {
			data.ShowMempool = true
			data.MempoolTxs = mempool.Size
			data.MempoolMB = float64(mempool.Bytes) / (1024 * 1024)
		}
		data.FeeNext = a.fee(ctx, 1)
		data.Fee30m = a.fee(ctx, 3)
		data.FeeHour = a.fee(ctx, 6)
	}
	a.render(w, data)
}

func (a *app) render(w http.ResponseWriter, data pageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := a.template.ExecuteTemplate(w, "index.html", data); err != nil {
		a.log.Printf("render dashboard: %v", err)
	}
}

func (a *app) fee(ctx context.Context, blocks int) string {
	var estimate feeEstimate
	if err := a.rpc.call(ctx, "estimatesmartfee", []any{blocks}, &estimate); err != nil || estimate.FeeRate == nil || *estimate.FeeRate == 0 {
		return "—"
	}
	value := float64(int(*estimate.FeeRate*1000000+0.5)) / 10
	return strconv.FormatFloat(value, 'f', -1, 64)
}

func (a *app) metrics(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	var chain blockchainInfo
	if err := a.rpc.call(ctx, "getblockchaininfo", []any{}, &chain); err != nil {
		fmt.Fprint(w, "# TYPE bitcoin_node_up gauge\nbitcoin_node_up 0\n")
		return
	}
	var network networkInfo
	var peers []peerInfo
	var uptime float64
	_ = a.rpc.call(ctx, "getnetworkinfo", []any{}, &network)
	_ = a.rpc.call(ctx, "getpeerinfo", []any{}, &peers)
	_ = a.rpc.call(ctx, "uptime", []any{}, &uptime)
	inbound := 0
	for _, peer := range peers {
		if peer.Inbound {
			inbound++
		}
	}
	disk := diskUsage(a.cfg.dataDir)
	gauge := func(name string, value any) { fmt.Fprintf(w, "# TYPE %s gauge\n%s %v\n", name, name, value) }
	gauge("bitcoin_node_up", 1)
	gauge("bitcoin_blocks", chain.Blocks)
	gauge("bitcoin_headers", chain.Headers)
	gauge("bitcoin_verification_progress", chain.VerificationProgress)
	gauge("bitcoin_pruned", boolInt(chain.Pruned))
	gauge("bitcoin_size_on_disk_bytes", chain.SizeOnDisk)
	gauge("bitcoin_disk_free_bytes", disk.Free)
	gauge("bitcoin_uptime_seconds", uptime)
	gauge("bitcoin_connections", network.Connections)
	fmt.Fprintf(w, "# TYPE bitcoin_peers gauge\nbitcoin_peers{direction=\"in\"} %d\nbitcoin_peers{direction=\"out\"} %d\n", inbound, len(peers)-inbound)
	if !chain.InitialBlockDownload {
		var mempool mempoolInfo
		if a.rpc.call(ctx, "getmempoolinfo", []any{}, &mempool) == nil {
			gauge("bitcoin_mempool_txs", mempool.Size)
			gauge("bitcoin_mempool_bytes", mempool.Bytes)
		}
		fmt.Fprintln(w, "# TYPE bitcoin_fee_sat_vb gauge")
		for _, blocks := range []int{1, 3, 6} {
			if fee := a.fee(ctx, blocks); fee != "—" {
				fmt.Fprintf(w, "bitcoin_fee_sat_vb{blocks=\"%d\"} %s\n", blocks, fee)
			}
		}
	}
}

func (a *app) apiFees(w http.ResponseWriter, _ *http.Request) {
	a.feesMu.RLock()
	fees := append([]float64(nil), a.fees...)
	a.feesMu.RUnlock()
	writeJSON(w, map[string]any{"fee": fees})
}

func (a *app) apiWatch(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, map[string]any{"wallets": []any{}, "total": "0", "show_total": false, "has_password": a.cfg.dashboardPassword != "", "read_only": true})
}

func (a *app) apiUpgrade(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, map[string]any{"enabled": false, "update": "", "pending": false})
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

func (a *app) loadFees() {
	b, err := os.ReadFile(filepath.Join(a.cfg.stateDir, "fee_history.json"))
	if err == nil && json.Unmarshal(b, &a.fees) == nil && len(a.fees) > maxFees {
		a.fees = a.fees[len(a.fees)-maxFees:]
	}
}

func (a *app) recordFee(value float64) {
	a.feesMu.Lock()
	a.fees = append(a.fees, value)
	if len(a.fees) > maxFees {
		a.fees = a.fees[len(a.fees)-maxFees:]
	}
	b, err := json.Marshal(a.fees)
	a.feesMu.Unlock()
	if err != nil {
		return
	}
	if err := os.MkdirAll(a.cfg.stateDir, 0o700); err != nil {
		a.log.Printf("create state directory: %v", err)
		return
	}
	path := filepath.Join(a.cfg.stateDir, "fee_history.json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		a.log.Printf("save fee history: %v", err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		a.log.Printf("save fee history: %v", err)
	}
}

func (a *app) startBackground(ctx context.Context) {
	go a.every(ctx, time.Minute, func(ctx context.Context) {
		var chain blockchainInfo
		var network networkInfo
		_ = a.rpc.call(ctx, "getblockchaininfo", []any{}, &chain)
		_ = a.rpc.call(ctx, "getnetworkinfo", []any{}, &network)
	})
	go a.every(ctx, time.Minute, func(ctx context.Context) {
		var chain blockchainInfo
		if a.rpc.call(ctx, "getblockchaininfo", []any{}, &chain) != nil || chain.InitialBlockDownload {
			return
		}
		var estimate feeEstimate
		if a.rpc.call(ctx, "estimatesmartfee", []any{1}, &estimate) == nil && estimate.FeeRate != nil {
			a.recordFee(float64(int(*estimate.FeeRate*1000000+0.5)) / 10)
		}
	})
	go a.every(ctx, 10*time.Minute, func(context.Context) {})
}

func (a *app) every(ctx context.Context, interval time.Duration, fn func(context.Context)) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			callCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			fn(callCtx)
			cancel()
		}
	}
}

func diskUsage(path string) diskInfo {
	var stat syscall.Statfs_t
	if syscall.Statfs(path, &stat) != nil {
		return diskInfo{}
	}
	return diskInfo{Total: uint64(stat.Blocks) * uint64(stat.Bsize), Free: uint64(stat.Bavail) * uint64(stat.Bsize)}
}

func gib(v int64) float64   { return float64(v) / (1024 * 1024 * 1024) }
func gibU(v uint64) float64 { return float64(v) / (1024 * 1024 * 1024) }
func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func formatUptime(seconds float64) string {
	total := int64(seconds)
	days, rem := total/86400, total%86400
	hours, minutes := rem/3600, rem%3600/60
	if days > 0 {
		return fmt.Sprintf("%dd %dh %dm", days, hours, minutes)
	}
	return fmt.Sprintf("%dh %dm", hours, minutes)
}

func versionLabel(version string) string {
	if version == "" || version == "dev" {
		return "go-prototype"
	}
	parts := strings.Split(version, ".")
	if len(parts) == 3 {
		for _, part := range parts {
			if _, err := strconv.Atoi(part); err != nil {
				return version + "-go-prototype"
			}
		}
		return "v" + version + "-go-prototype"
	}
	return version + "-go-prototype"
}

func envConfig() (config, error) {
	cfg := config{
		rpcURL: os.Getenv("RPC_URL"), rpcUser: os.Getenv("RPC_USER"), rpcPassword: os.Getenv("RPC_PASSWORD"),
		dashboardPassword: os.Getenv("DASHBOARD_PASSWORD"), dataDir: os.Getenv("DATA_DIR"), stateDir: os.Getenv("STATE_DIR"), version: os.Getenv("STACK_VERSION"), port: os.Getenv("PORT"),
	}
	if cfg.rpcURL == "" {
		cfg.rpcURL = "http://127.0.0.1:18443"
	}
	if cfg.dataDir == "" {
		cfg.dataDir = "/data"
	}
	if cfg.stateDir == "" {
		cfg.stateDir = "/state"
	}
	if cfg.port == "" {
		cfg.port = "8000"
	}
	portNumber, err := strconv.Atoi(cfg.port)
	if err != nil || portNumber < 1 || portNumber > 65535 {
		return config{}, errors.New("PORT must be between 1 and 65535")
	}
	if cfg.version == "" {
		cfg.version = "dev"
	}
	if cfg.rpcUser == "" || cfg.rpcPassword == "" || cfg.dashboardPassword == "" {
		return config{}, errors.New("RPC_USER, RPC_PASSWORD, and DASHBOARD_PASSWORD are required")
	}
	return cfg, nil
}

func main() {
	cfg, err := envConfig()
	if err != nil {
		log.Fatal(err)
	}
	logger := log.New(os.Stderr, "go-dashboard: ", log.LstdFlags)
	rpc := &rpcClient{url: cfg.rpcURL, user: cfg.rpcUser, password: cfg.rpcPassword, client: &http.Client{Timeout: 3 * time.Second}}
	a, err := newApp(cfg, rpc, "/app/index.html", "/app/static", logger)
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	a.startBackground(ctx)
	server := &http.Server{Addr: ":" + cfg.port, Handler: a.routes(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 35 * time.Second, IdleTimeout: 60 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	logger.Printf("read-only prototype listening on :%s", cfg.port)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
