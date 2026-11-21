package main

import (
	"reflect"
	"testing"
)

func TestPlacePayouts(t *testing.T) {
	attrs := map[string]string{
		"game_id":        "g1",
		"entrant_count":  "6",
		"distributed":    "60000000",
		"place_2_player": "b52bbb",
		"place_2_payout": "20000000",
		"place_1_player": "b52aaa",
		"place_1_payout": "40000000",
	}
	got := placePayouts(attrs)
	want := []PlacePayout{
		{Place: 1, Player: "b52aaa", Payout: 40000000},
		{Place: 2, Player: "b52bbb", Payout: 20000000},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("placePayouts = %+v, want %+v", got, want)
	}
}

func TestPlacePayoutsDropsBadPairs(t *testing.T) {
	attrs := map[string]string{
		"place_1_player": "b52aaa", // no payout attr
		"place_2_player": "",       // empty player
		"place_2_payout": "5",
		"place_x_player": "b52ccc", // unreadable place
		"place_3_player": "b52ddd",
		"place_3_payout": "oops", // unreadable payout
		"place_4_player": "b52eee",
		"place_4_payout": "7",
	}
	got := placePayouts(attrs)
	want := []PlacePayout{{Place: 4, Player: "b52eee", Payout: 7}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("placePayouts = %+v, want %+v", got, want)
	}
}

func TestPlacePayoutsEmpty(t *testing.T) {
	if got := placePayouts(map[string]string{"game_id": "g1"}); len(got) != 0 {
		t.Errorf("placePayouts on no places = %+v, want empty", got)
	}
}

func TestNullableInt(t *testing.T) {
	if got := nullableInt("42"); got != int64(42) {
		t.Errorf("nullableInt(42) = %v", got)
	}
	if got := nullableInt(""); got != nil {
		t.Errorf("nullableInt('') = %v, want nil", got)
	}
	if got := nullableInt("abc"); got != nil {
		t.Errorf("nullableInt(abc) = %v, want nil", got)
	}
}
