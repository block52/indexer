#!/bin/bash
# Poker Hand Distribution Analysis Runner
# Usage: ./run-analysis.sh [command]

set -e

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_USER=${DB_USER:-poker}
DB_PASS=${DB_PASS:-poker_indexer_dev}
DB_NAME=${DB_NAME:-poker_hands}

PSQL="PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"

case "${1:-report}" in
    report)
        echo "=== Poker Hand Distribution Randomness Report ==="
        echo ""
        $PSQL -c "SELECT * FROM generate_randomness_report();"
        ;;

    summary)
        echo "=== Summary Statistics ==="
        $PSQL -c "SELECT * FROM total_hands_summary;"
        ;;

    cards)
        echo "=== Card Frequency Analysis ==="
        $PSQL -c "SELECT * FROM card_frequency_analysis ORDER BY total_appearances DESC;"
        ;;

    outliers)
        echo "=== Outlier Cards (>1% deviation) ==="
        $PSQL -c "SELECT * FROM outlier_cards;"
        ;;

    suits)
        echo "=== Suit Distribution ==="
        $PSQL -c "SELECT * FROM suit_distribution;"
        echo ""
        echo "=== Suit Chi-Squared Test ==="
        $PSQL -c "SELECT * FROM suit_chi_squared();"
        ;;

    ranks)
        echo "=== Rank Distribution ==="
        $PSQL -c "SELECT * FROM rank_distribution;"
        echo ""
        echo "=== Rank Chi-Squared Test ==="
        $PSQL -c "SELECT * FROM rank_chi_squared();"
        ;;

    chi-squared)
        echo "=== Chi-Squared Test Results ==="
        $PSQL -c "SELECT * FROM calculate_chi_squared();"
        ;;

    seeds)
        echo "=== Deck Seed Analysis ==="
        echo "Checking for duplicate seeds..."
        $PSQL -c "SELECT * FROM seed_entropy_analysis LIMIT 20;"
        ;;

    timeline)
        echo "=== Distribution Over Time ==="
        $PSQL -c "SELECT * FROM distribution_over_time ORDER BY block_range_start DESC LIMIT 20;"
        ;;

    full)
        echo "========================================"
        echo "   FULL RANDOMNESS ANALYSIS REPORT"
        echo "========================================"
        echo ""

        echo "--- Summary ---"
        $PSQL -c "SELECT * FROM total_hands_summary;"
        echo ""

        echo "--- Randomness Tests ---"
        $PSQL -c "SELECT * FROM generate_randomness_report();"
        echo ""

        echo "--- Card Distribution ---"
        $PSQL -c "SELECT * FROM card_frequency_analysis ORDER BY deviation_percentage DESC LIMIT 10;"
        echo ""

        echo "--- Suit Distribution ---"
        $PSQL -c "SELECT * FROM suit_distribution;"
        echo ""

        echo "--- Rank Distribution ---"
        $PSQL -c "SELECT * FROM rank_distribution;"
        ;;

    refresh-stats)
        echo "Refreshing card distribution statistics..."
        $PSQL -c "SELECT update_card_distribution_stats();"
        echo "Done."
        ;;

    *)
        echo "Poker Hand Distribution Analysis"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  report       - Run comprehensive randomness report (default)"
        echo "  summary      - Show basic statistics"
        echo "  cards        - Show card frequency analysis"
        echo "  outliers     - Show cards with significant deviation"
        echo "  suits        - Show suit distribution and chi-squared test"
        echo "  ranks        - Show rank distribution and chi-squared test"
        echo "  chi-squared  - Run chi-squared test"
        echo "  seeds        - Analyze deck seeds for duplicates"
        echo "  timeline     - Show distribution over block ranges"
        echo "  full         - Run all analyses"
        echo "  refresh-stats - Manually refresh statistics"
        ;;
esac
