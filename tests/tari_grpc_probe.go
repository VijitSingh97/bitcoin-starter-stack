package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

type proofAuth struct {
	user string
	pass string
}

func (a proofAuth) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	encoded := base64.StdEncoding.EncodeToString([]byte(a.user + ":" + a.pass))
	return map[string]string{"authorization": "Basic " + encoded}, nil
}

func (proofAuth) RequireTransportSecurity() bool { return false }

func main() {
	endpoint := os.Getenv("TARI_PROOF_ENDPOINT")
	user := os.Getenv("TARI_PROOF_USER")
	pass := os.Getenv("TARI_PROOF_PASSWORD")
	if endpoint == "" || user == "" || pass == "" {
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	plain, err := grpc.NewClient(endpoint, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		os.Exit(1)
	}
	_, unauthErr := NewWalletClient(plain).GetVersion(ctx, &TariGetVersionRequest{})
	plain.Close()
	if status.Code(unauthErr) != codes.Unauthenticated {
		os.Exit(1)
	}
	authed, err := grpc.NewClient(endpoint, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithPerRPCCredentials(proofAuth{user: user, pass: pass}))
	if err != nil {
		os.Exit(1)
	}
	defer authed.Close()
	client := NewWalletClient(authed)
	version, versionErr := client.GetVersion(ctx, &TariGetVersionRequest{})
	address, addressErr := client.GetCompleteAddress(ctx, &TariWalletEmpty{})
	balance, balanceErr := client.GetBalance(ctx, &TariGetBalanceRequest{})
	state, stateErr := client.GetState(ctx, &TariGetStateRequest{})
	versionOK := versionErr == nil && strings.TrimSpace(version.GetVersion()) != ""
	addressOK := addressErr == nil && (address.GetInteractiveAddressBase58() != "" || address.GetOneSidedAddressBase58() != "")
	if !versionOK || !addressOK || balanceErr != nil || balance == nil || stateErr != nil || state == nil {
		os.Exit(1)
	}
	fmt.Println("PASS: Tari wallet gRPC rejects unauthenticated calls and accepts authenticated dashboard methods")
}
