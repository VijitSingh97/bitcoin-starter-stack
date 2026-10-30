package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"
)

func newTorHTTPClient(proxy string) *http.Client {
	transport := &http.Transport{
		Proxy:                 nil,
		DialContext:           socks5DialContext(proxy),
		ForceAttemptHTTP2:     true,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		IdleConnTimeout:       90 * time.Second,
	}
	return &http.Client{
		Transport: transport,
		Timeout:   30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func socks5DialContext(proxy string) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		if network != "tcp" && network != "tcp4" && network != "tcp6" {
			return nil, errors.New("SOCKS5 only supports TCP")
		}
		conn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", proxy)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, errors.New("SOCKS5 proxy unavailable")
		}
		handshakeDeadline := time.Now().Add(10 * time.Second)
		if deadline, ok := ctx.Deadline(); ok && deadline.Before(handshakeDeadline) {
			handshakeDeadline = deadline
		}
		_ = conn.SetDeadline(handshakeDeadline)
		stopCancel := context.AfterFunc(ctx, func() { conn.Close() })
		if err := socks5Connect(conn, address); err != nil {
			stopCancel()
			conn.Close()
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, err
		}
		if !stopCancel() || ctx.Err() != nil {
			conn.Close()
			return nil, ctx.Err()
		}
		_ = conn.SetDeadline(time.Time{})
		return conn, nil
	}
}

func socks5Connect(conn net.Conn, address string) error {
	if _, err := conn.Write([]byte{5, 1, 0}); err != nil {
		return errors.New("SOCKS5 handshake failed")
	}
	response := make([]byte, 2)
	if _, err := io.ReadFull(conn, response); err != nil || response[0] != 5 || response[1] != 0 {
		return errors.New("SOCKS5 handshake failed")
	}
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return errors.New("SOCKS5 destination invalid")
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil {
		return errors.New("SOCKS5 destination invalid")
	}
	request := []byte{5, 1, 0}
	if ip := net.ParseIP(host); ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			request = append(request, 1)
			request = append(request, ip4...)
		} else {
			request = append(request, 4)
			request = append(request, ip.To16()...)
		}
	} else {
		if len(host) == 0 || len(host) > 255 {
			return errors.New("SOCKS5 destination invalid")
		}
		request = append(request, 3, byte(len(host)))
		request = append(request, host...)
	}
	request = binary.BigEndian.AppendUint16(request, uint16(port))
	if _, err := conn.Write(request); err != nil {
		return errors.New("SOCKS5 connect failed")
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(conn, header); err != nil || header[0] != 5 || header[2] != 0 {
		return errors.New("SOCKS5 connect failed")
	}
	if header[1] != 0 {
		return fmt.Errorf("SOCKS5 connect failed (code %d)", header[1])
	}
	var addressLength int
	switch header[3] {
	case 1:
		addressLength = 4
	case 3:
		length := make([]byte, 1)
		if _, err := io.ReadFull(conn, length); err != nil {
			return errors.New("SOCKS5 connect failed")
		}
		addressLength = int(length[0])
	case 4:
		addressLength = 16
	default:
		return errors.New("SOCKS5 connect failed")
	}
	if _, err := io.CopyN(io.Discard, conn, int64(addressLength+2)); err != nil {
		return errors.New("SOCKS5 connect failed")
	}
	return nil
}
