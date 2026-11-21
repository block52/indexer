package gql

import "testing"

// Transfers (sql/10-transfers.sql): one wallet's money in and out, told apart by msg_type.
func TestTransfersMoneyInAndOut(t *testing.T) {
	db := testDB(t)
	clean := func() { db.Exec(`DELETE FROM transfers WHERE sender LIKE 'gqltest-%' OR recipient LIKE 'gqltest-%'`) }
	clean()
	t.Cleanup(clean)
	if _, err := db.Exec(`INSERT INTO transfers (block_height, block_time, tx_hash, tx_index, event_index, msg_index, msg_type, sender, recipient, amount, denom) VALUES
		(10, '2026-11-18T00:24:41Z', 'AA', 0, 6, 0, '/cosmos.bank.v1beta1.MsgSend', 'gqltest-funder', 'gqltest-dog', 100000, 'usdc'),
		(20, '2026-11-18T00:41:59Z', 'BB', 0, 6, 0, '/pokerchain.poker.v1.MsgJoinGame', 'gqltest-dog', 'gqltest-poker', 100000, 'usdc'),
		(30, '2026-11-18T00:45:10Z', 'CC', 1, 6, 0, '/pokerchain.poker.v1.MsgLeaveGame', 'gqltest-poker', 'gqltest-dog', 90000, 'usdc'),
		(40, '2026-11-18T01:00:00Z', 'DD', 0, 6, 0, '/cosmos.bank.v1beta1.MsgSend', 'gqltest-dog', 'gqltest-elsewhere', 50000, 'usdc'),
		(40, '2026-11-18T01:00:00Z', 'DD', 0, 2, NULL, '', 'gqltest-dog', 'gqltest-fees', 7, 'stake')`); err != nil {
		t.Fatal(err)
	}
	svc := testService(t, db)

	got := run(t, svc, `{ transfers(where: {_or: [{sender: {_eq: "gqltest-dog"}}, {recipient: {_eq: "gqltest-dog"}}], denom: {_eq: "usdc"}}, order_by: {block_height: asc}) { block_height tx_hash msg_type sender recipient amount } }`, nil)
	expectJSON(t, got, `{"transfers":[
		{"block_height":10,"tx_hash":"AA","msg_type":"/cosmos.bank.v1beta1.MsgSend","sender":"gqltest-funder","recipient":"gqltest-dog","amount":100000},
		{"block_height":20,"tx_hash":"BB","msg_type":"/pokerchain.poker.v1.MsgJoinGame","sender":"gqltest-dog","recipient":"gqltest-poker","amount":100000},
		{"block_height":30,"tx_hash":"CC","msg_type":"/pokerchain.poker.v1.MsgLeaveGame","sender":"gqltest-poker","recipient":"gqltest-dog","amount":90000},
		{"block_height":40,"tx_hash":"DD","msg_type":"/cosmos.bank.v1beta1.MsgSend","sender":"gqltest-dog","recipient":"gqltest-elsewhere","amount":50000}]}`)

	// Deposits and withdrawals only (bank sends), summed, over a time window.
	got = run(t, svc, `{
		in: transfers_aggregate(where: {recipient: {_eq: "gqltest-dog"}, msg_type: {_eq: "/cosmos.bank.v1beta1.MsgSend"}, block_time: {_gte: "2026-11-18T00:00:00Z"}}) { aggregate { count sum { amount } } }
		out: transfers_aggregate(where: {sender: {_eq: "gqltest-dog"}, msg_type: {_eq: "/cosmos.bank.v1beta1.MsgSend"}, denom: {_eq: "usdc"}}) { aggregate { count sum { amount } } }
	}`, nil)
	expectJSON(t, got, `{"in":{"aggregate":{"count":1,"sum":{"amount":100000}}},"out":{"aggregate":{"count":1,"sum":{"amount":50000}}}}`)
}
