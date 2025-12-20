#!/bin/bash
# Player Statistics & VIP Analysis
# Usage: ./run-player-stats.sh [command]

set -e

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_USER=${DB_USER:-poker}
DB_PASS=${DB_PASS:-poker_indexer_dev}
DB_NAME=${DB_NAME:-poker_hands}

# Use docker exec if available, otherwise use psql directly
if docker exec poker-indexer-db pg_isready -U "$DB_USER" > /dev/null 2>&1; then
    PSQL="docker exec -i poker-indexer-db psql -U $DB_USER -d $DB_NAME"
else
    PSQL="PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
fi

case "${1:-summary}" in
    summary)
        echo "=== Player Statistics Summary ==="
        echo ""
        $PSQL -c "SELECT * FROM player_summary;" 2>/dev/null || echo "Run 'init' first to create tables"
        ;;

    init)
        echo "=== Initializing Player Stats Tables ==="
        $PSQL -f sql/player_stats.sql
        echo "Done. Tables created."
        ;;

    refresh)
        echo "=== Refreshing All Player Stats ==="
        $PSQL -c "SELECT refresh_all_player_stats();"
        echo "Done."
        ;;

    leaderboard | top)
        echo "=== Top Players by Profit ==="
        $PSQL -c "SELECT * FROM leaderboard_profit LIMIT 20;"
        ;;

    volume)
        echo "=== Top Players by Volume ==="
        $PSQL -c "SELECT * FROM leaderboard_volume LIMIT 20;"
        ;;

    aggression)
        echo "=== Most Aggressive Players ==="
        $PSQL -c "SELECT * FROM leaderboard_aggression LIMIT 20;"
        ;;

    vip)
        echo "=== VIP Tier Distribution ==="
        $PSQL -c "SELECT * FROM vip_distribution;"
        ;;

    player)
        if [ -z "$2" ]; then
            echo "Usage: $0 player <address>"
            exit 1
        fi
        echo "=== Player Profile: $2 ==="
        $PSQL -c "SELECT * FROM player_profiles WHERE player_address = '$2';"
        echo ""
        echo "=== Recent Actions ==="
        $PSQL -c "SELECT action, amount, block_height, indexed_at FROM player_actions WHERE player_address = '$2' ORDER BY block_height DESC LIMIT 20;"
        ;;

    actions)
        echo "=== Action Distribution ==="
        $PSQL -c "
            SELECT
                action,
                COUNT(*) as count,
                ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () * 100, 2) as percentage
            FROM player_actions
            GROUP BY action
            ORDER BY count DESC;
        "
        ;;

    sessions)
        echo "=== Player Sessions ==="
        $PSQL -c "
            SELECT
                player_address,
                game_id,
                join_block,
                leave_block,
                buy_in_amount / 1000000.0 as buy_in_usd,
                cash_out_amount / 1000000.0 as cash_out_usd,
                (cash_out_amount - buy_in_amount) / 1000000.0 as profit_usd
            FROM player_sessions
            ORDER BY join_block DESC
            LIMIT 20;
        "
        ;;

    update-vip)
        echo "=== Updating VIP Tiers ==="
        $PSQL -c "SELECT update_vip_tiers();"
        echo "Done."
        ;;

    monthly)
        echo "=== Monthly Leaderboard ==="
        $PSQL -c "SELECT * FROM leaderboard_monthly LIMIT 20;"
        ;;

    export-csv)
        echo "=== Exporting Player Stats to CSV ==="
        $PSQL -c "\COPY (SELECT * FROM player_profiles) TO 'player_stats.csv' WITH CSV HEADER"
        echo "Exported to player_stats.csv"
        ;;

    full)
        echo "========================================"
        echo "   FULL PLAYER STATISTICS REPORT"
        echo "========================================"
        echo ""

        echo "--- Summary ---"
        $PSQL -c "SELECT * FROM player_summary;" 2>/dev/null || echo "No data yet"
        echo ""

        echo "--- VIP Distribution ---"
        $PSQL -c "SELECT * FROM vip_distribution;" 2>/dev/null || echo "No data yet"
        echo ""

        echo "--- Top 10 by Profit ---"
        $PSQL -c "SELECT * FROM leaderboard_profit LIMIT 10;" 2>/dev/null || echo "No data yet"
        echo ""

        echo "--- Top 10 by Volume ---"
        $PSQL -c "SELECT * FROM leaderboard_volume LIMIT 10;" 2>/dev/null || echo "No data yet"
        echo ""

        echo "--- Action Distribution ---"
        $PSQL -c "
            SELECT action, COUNT(*) as count
            FROM player_actions
            GROUP BY action
            ORDER BY count DESC;
        " 2>/dev/null || echo "No data yet"
        ;;

    *)
        echo "Player Statistics & VIP Analysis"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  summary        - Show overall player statistics (default)"
        echo "  init           - Initialize player stats tables"
        echo "  refresh        - Refresh all player stats from actions"
        echo "  leaderboard    - Top players by profit"
        echo "  volume         - Top players by hands played"
        echo "  aggression     - Most aggressive players"
        echo "  vip            - VIP tier distribution"
        echo "  player <addr>  - Show specific player profile"
        echo "  actions        - Action type distribution"
        echo "  sessions       - Recent player sessions"
        echo "  update-vip     - Update VIP tiers based on rake"
        echo "  monthly        - Monthly leaderboard"
        echo "  export-csv     - Export stats to CSV"
        echo "  full           - Full statistics report"
        ;;
esac
