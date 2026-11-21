package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"log"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Transfer is one coin of one bank `transfer` event (sql/10-transfers.sql).
type Transfer struct {
	BlockHeight int64
	BlockTime   time.Time
	TxHash      string
	TxIndex     int // -1 for a block-level transfer
	EventIndex  int
	MsgIndex    *int // nil for fees and block-level transfers
	MsgType     string
	Sender      string
	Recipient   string
	Amount      int64
	Denom       string
}

// txHash is a transaction's hash as the chain shows it: upper-case hex SHA-256 of its bytes.
func txHash(b64 string) string {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(raw)
	return strings.ToUpper(hex.EncodeToString(sum[:]))
}

var coinRE = regexp.MustCompile(`^([0-9]+)([a-zA-Z][a-zA-Z0-9/:._-]*)$`)

type coin struct {
	amount int64
	denom  string
}

// parseCoins reads "100000usdc" or "5usdc,7stake". A coin too big for 64 bits is skipped and logged:
// the column is BIGINT like every other amount the indexer keeps.
func parseCoins(s string) []coin {
	var out []coin
	for _, part := range strings.Split(s, ",") {
		m := coinRE.FindStringSubmatch(strings.TrimSpace(part))
		if m == nil {
			continue
		}
		n, ok := new(big.Int).SetString(m[1], 10)
		if !ok || !n.IsInt64() {
			log.Printf("Warning: transfer amount %s%s doesn't fit in 64 bits; skipped", m[1], m[2])
			continue
		}
		out = append(out, coin{amount: n.Int64(), denom: m[2]})
	}
	return out
}

func attrsOf(e Event) map[string]string {
	attrs := make(map[string]string, len(e.Attributes))
	for _, a := range e.Attributes {
		attrs[decodeIfBase64(a.Key)] = decodeIfBase64(a.Value)
	}
	return attrs
}

// transfersFrom turns one list of events (a transaction's, or the block's finalize events) into transfers.
// msg_type comes from the `message` event with the same msg_index (it carries `action`).
func transfersFrom(events []Event, height int64, at time.Time, hash string, txIndex int) []Transfer {
	actions := map[string]string{}
	for _, e := range events {
		if e.Type != "message" {
			continue
		}
		a := attrsOf(e)
		if a["action"] != "" {
			actions[a["msg_index"]] = a["action"]
		}
	}
	var out []Transfer
	for i, e := range events {
		if e.Type != "transfer" {
			continue
		}
		a := attrsOf(e)
		if a["sender"] == "" || a["recipient"] == "" {
			continue
		}
		var msgIndex *int
		msgType := ""
		if mi, ok := a["msg_index"]; ok && mi != "" {
			if n, err := strconv.Atoi(mi); err == nil {
				msgIndex = &n
				msgType = actions[mi]
			}
		}
		for _, c := range parseCoins(a["amount"]) {
			out = append(out, Transfer{
				BlockHeight: height, BlockTime: at, TxHash: hash, TxIndex: txIndex, EventIndex: i,
				MsgIndex: msgIndex, MsgType: msgType, Sender: a["sender"], Recipient: a["recipient"],
				Amount: c.amount, Denom: c.denom,
			})
		}
	}
	return out
}

// extractTransfers reads every bank transfer in a block: each transaction's (hash from its bytes, in the same
// order as txs_results) and the block-level ones from finalize_block_events.
func extractTransfers(b *BlockInfo) []Transfer {
	var out []Transfer
	for i, events := range b.TxEvents {
		hash := ""
		if i < len(b.Txs) {
			hash = txHash(b.Txs[i])
		}
		out = append(out, transfersFrom(events, b.Height, b.Time, hash, i)...)
	}
	out = append(out, transfersFrom(b.FinalizeEvents, b.Height, b.Time, "", -1)...)
	return out
}

// recordTransfers stores a block's transfers. Indexing a block again adds nothing (the table's unique key).
func (idx *Indexer) recordTransfers(ts []Transfer) {
	for _, t := range ts {
		if _, err := idx.db.Exec(`
			INSERT INTO transfers (block_height, block_time, tx_hash, tx_index, event_index, msg_index, msg_type, sender, recipient, amount, denom)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
			ON CONFLICT (block_height, tx_index, event_index, denom) DO NOTHING
		`, t.BlockHeight, t.BlockTime, t.TxHash, t.TxIndex, t.EventIndex, t.MsgIndex, t.MsgType, t.Sender, t.Recipient, t.Amount, t.Denom); err != nil {
			log.Printf("Warning: failed to record transfer at block %d: %v", t.BlockHeight, err)
		}
	}
}
