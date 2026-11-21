package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"
)

// Real blocks from the chain (testdata/, read from a node's RPC): a USDC send to a player (1117436),
// that player buying in to a table (1117629) and cashing out (1117659).
const (
	player      = "b521x7u4h2yn6hg604j6ntlzj06u4kwtwmyg0vs2dm"
	funder      = "b521s8aug28r6vned2xm767xhgrkg90wfef2hfg4mg"
	pokerModule = "b521lw3w4slwgllhsxgw4w9vlssks624ujhdue8qxv"
)

func loadBlock(t *testing.T, height int64) *BlockInfo {
	t.Helper()
	var br BlockResultsResponse
	var b BlockResult
	for file, into := range map[string]interface{}{"testdata/block_results_%d.json": &br, "testdata/block_%d.json": &b} {
		raw, err := os.ReadFile(fmt.Sprintf(file, height))
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(raw, into); err != nil {
			t.Fatal(err)
		}
	}
	info, _ := blockInfoFrom(height, &br, &b)
	return info
}

func usdcFor(ts []Transfer, addr string) []Transfer {
	var out []Transfer
	for _, t := range ts {
		if t.Denom == "usdc" && (t.Sender == addr || t.Recipient == addr) {
			out = append(out, t)
		}
	}
	return out
}

func TestTransfersSendToPlayer(t *testing.T) {
	got := usdcFor(extractTransfers(loadBlock(t, 1117436)), player)
	if len(got) != 1 {
		t.Fatalf("want 1 USDC transfer for the player, got %d: %+v", len(got), got)
	}
	tr := got[0]
	if tr.Sender != funder || tr.Recipient != player || tr.Amount != 100000 {
		t.Errorf("transfer = %s -> %s %d, want %s -> %s 100000", tr.Sender, tr.Recipient, tr.Amount, funder, player)
	}
	if tr.MsgType != "/cosmos.bank.v1beta1.MsgSend" || tr.MsgIndex == nil || *tr.MsgIndex != 0 {
		t.Errorf("msg = %q #%v, want MsgSend #0", tr.MsgType, tr.MsgIndex)
	}
	// The hash the chain and explorers show for this transaction.
	if tr.TxHash != "B23D0D1E352E5F638E4B1AD5EBB51463EE3BC6A3352FCBAA71E9BC81D7DBA4C0" {
		t.Errorf("tx hash = %s", tr.TxHash)
	}
	if tr.TxIndex != 0 || tr.BlockHeight != 1117436 || tr.BlockTime.IsZero() {
		t.Errorf("position = tx %d at %d (%s)", tr.TxIndex, tr.BlockHeight, tr.BlockTime)
	}
}

func TestTransfersBuyInAndCashOut(t *testing.T) {
	in := usdcFor(extractTransfers(loadBlock(t, 1117629)), player)
	if len(in) != 1 || in[0].Recipient != pokerModule || in[0].MsgType != "/pokerchain.poker.v1.MsgJoinGame" {
		t.Fatalf("buy-in = %+v, want the player -> poker module with MsgJoinGame", in)
	}
	out := usdcFor(extractTransfers(loadBlock(t, 1117659)), player)
	if len(out) != 1 || out[0].Sender != pokerModule || out[0].MsgType != "/pokerchain.poker.v1.MsgLeaveGame" || out[0].Amount != 100000 {
		t.Fatalf("cash-out = %+v, want poker module -> the player, 100000, MsgLeaveGame", out)
	}
}

func TestTransfersBlockLevelWithoutAmountAreSkipped(t *testing.T) {
	// Block 1117436's finalize events have mint/distribution transfers with an empty amount.
	for _, tr := range extractTransfers(loadBlock(t, 1117436)) {
		if tr.TxIndex == -1 && tr.Amount == 0 {
			t.Errorf("stored an empty block-level transfer: %+v", tr)
		}
	}
}

func TestParseCoins(t *testing.T) {
	got := parseCoins("5usdc,7stake, 9ibc/ABC123")
	want := []coin{{5, "usdc"}, {7, "stake"}, {9, "ibc/ABC123"}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("coin %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	if len(parseCoins("")) != 0 || len(parseCoins("usdc")) != 0 {
		t.Error("an empty or amount-less coin should give nothing")
	}
	if len(parseCoins("99999999999999999999999usdc")) != 0 {
		t.Error("a coin too big for 64 bits should be skipped")
	}
}

func TestTransfersWithBase64Attributes(t *testing.T) {
	// Older nodes base64 the attribute keys and values.
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	ev := func(typ string, kv ...string) Event {
		e := Event{Type: typ}
		for i := 0; i < len(kv); i += 2 {
			e.Attributes = append(e.Attributes, struct {
				Key   string `json:"key"`
				Value string `json:"value"`
				Index bool   `json:"index"`
			}{Key: b64(kv[i]), Value: b64(kv[i+1])})
		}
		return e
	}
	events := []Event{
		ev("message", "action", "/cosmos.bank.v1beta1.MsgSend", "msg_index", "0"),
		ev("transfer", "recipient", player, "sender", funder, "amount", "42usdc", "msg_index", "0"),
		ev("transfer", "recipient", "b521feecollector", "sender", funder, "amount", "1usdc"),
	}
	got := transfersFrom(events, 7, time.Time{}, "H", 0)
	if len(got) != 2 || got[0].Amount != 42 || got[0].MsgType != "/cosmos.bank.v1beta1.MsgSend" {
		t.Fatalf("got %+v", got)
	}
	// A fee (no msg_index) has no message type.
	if got[1].MsgIndex != nil || got[1].MsgType != "" || got[1].EventIndex != 2 {
		t.Errorf("fee = %+v", got[1])
	}
}
