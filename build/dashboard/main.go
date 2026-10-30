package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
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
	settingsPort      string
	control           bool
}

func envConfig() (config, error) {
	cfg := config{
		rpcURL: os.Getenv("RPC_URL"), rpcUser: os.Getenv("RPC_USER"), rpcPassword: os.Getenv("RPC_PASSWORD"),
		dashboardPassword: os.Getenv("DASHBOARD_PASSWORD"), dataDir: os.Getenv("DATA_DIR"), stateDir: os.Getenv("STATE_DIR"), version: strings.TrimSpace(os.Getenv("STACK_VERSION")), port: os.Getenv("PORT"), settingsPort: os.Getenv("SETTINGS_PORT"),
	}
	if cfg.rpcURL == "" {
		cfg.rpcURL = "http://172.29.0.26:8332"
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
	if cfg.settingsPort != "" {
		settingsPortNumber, err := strconv.Atoi(cfg.settingsPort)
		if err != nil || settingsPortNumber < 1 || settingsPortNumber > 65535 {
			return config{}, errors.New("SETTINGS_PORT must be between 1 and 65535")
		}
		if settingsPortNumber == portNumber {
			return config{}, errors.New("SETTINGS_PORT must differ from PORT")
		}
	}
	if cfg.version == "" {
		cfg.version = readVersionFile("VERSION")
		if cfg.version == "" {
			cfg.version = "dev"
		}
	}
	cfg.control = enabled(os.Getenv("DASHBOARD_CONTROL"))
	if cfg.rpcUser == "" || cfg.rpcPassword == "" {
		return config{}, errors.New("RPC_USER and RPC_PASSWORD are required")
	}
	return cfg, nil
}

func serveHTTPServers(ctx context.Context, servers []*http.Server) error {
	listeners := make([]net.Listener, 0, len(servers))
	for _, server := range servers {
		listener, err := net.Listen("tcp", server.Addr)
		if err != nil {
			for _, opened := range listeners {
				_ = opened.Close()
			}
			return err
		}
		listeners = append(listeners, listener)
	}

	errorsByServer := make(chan error, len(servers))
	for i, server := range servers {
		go func(server *http.Server, listener net.Listener) {
			errorsByServer <- server.Serve(listener)
		}(server, listeners[i])
	}

	var firstErr error
	consumed := false
	select {
	case <-ctx.Done():
	case err := <-errorsByServer:
		consumed = true
		if !errors.Is(err, http.ErrServerClosed) {
			firstErr = err
		}
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, server := range servers {
		_ = server.Shutdown(shutdownCtx)
	}
	remaining := len(servers)
	if consumed {
		remaining--
	}
	for range remaining {
		if err := <-errorsByServer; firstErr == nil && !errors.Is(err, http.ErrServerClosed) {
			firstErr = err
		}
	}
	return firstErr
}

func runDashboardServers(ctx context.Context, stop func(), a *app, servers []*http.Server) error {
	backgroundDone := a.startBackground(ctx)
	err := serveHTTPServers(ctx, servers)
	stop()
	<-backgroundDone
	return err
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		client := &http.Client{Timeout: 5 * time.Second}
		response, err := client.Get("http://127.0.0.1:" + envOr("PORT", "8000") + "/api/fees")
		if err != nil {
			os.Exit(1)
		}
		response.Body.Close()
		return
	}
	cfg, err := envConfig()
	if err != nil {
		log.Fatal(err)
	}
	logger := log.New(os.Stderr, "go-dashboard: ", log.LstdFlags)
	rpc := &rpcClient{url: cfg.rpcURL, user: cfg.rpcUser, password: cfg.rpcPassword, client: &http.Client{Timeout: 3 * time.Second}}
	a, err := newApp(cfg, rpc, "index.html", "static", logger)
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	handler := a.routes()
	servers := []*http.Server{{Addr: ":" + cfg.port, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 6 * time.Minute, IdleTimeout: 60 * time.Second}}
	if cfg.settingsPort != "" {
		servers = append(servers, &http.Server{Addr: ":" + cfg.settingsPort, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 6 * time.Minute, IdleTimeout: 60 * time.Second})
		logger.Printf("onion settings listener enabled on :%s", cfg.settingsPort)
	}
	logger.Printf("dashboard listening on :%s", cfg.port)
	if err := runDashboardServers(ctx, stop, a, servers); err != nil {
		log.Fatal(err)
	}
}
