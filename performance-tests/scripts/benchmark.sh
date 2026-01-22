#!/bin/bash
# QuickDown Performance Benchmark Script
# Measures cold start time for rendering test files

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/../files"
RESULTS_FILE="$SCRIPT_DIR/../benchmark-results.txt"

# Check QuickDown is installed
if ! [ -d "/Applications/QuickDown.app" ]; then
    echo "Error: QuickDown.app not found in /Applications"
    exit 1
fi

echo "QuickDown Performance Benchmark"
echo "================================"
echo "Date: $(date)"
echo ""

# Kill any running instance
pkill -x QuickDown 2>/dev/null || true
sleep 1

echo "Test Files:"
echo "-----------"
for f in "$FILES_DIR"/*.md; do
    name=$(basename "$f")
    lines=$(wc -l < "$f" | tr -d ' ')
    size=$(ls -lh "$f" | awk '{print $5}')
    echo "  $name: $lines lines, $size"
done
echo ""

echo "Cold Start Benchmarks:"
echo "----------------------"

# Function to measure cold start
benchmark_cold_start() {
    local file="$1"
    local name=$(basename "$file")

    # Kill any running instance
    pkill -x QuickDown 2>/dev/null || true
    sleep 0.5

    # Measure time to open
    local start=$(python3 -c 'import time; print(time.time())')
    open -a QuickDown "$file"

    # Wait for app to launch (check for process)
    while ! pgrep -x QuickDown > /dev/null; do
        sleep 0.05
    done

    # Wait a bit more for render (approximate)
    sleep 1.5

    local end=$(python3 -c 'import time; print(time.time())')
    local elapsed=$(python3 -c "print(f'{($end - $start):.2f}')")

    echo "  $name: ${elapsed}s"

    # Get memory usage
    local mem=$(ps -o rss= -p $(pgrep -x QuickDown) 2>/dev/null | awk '{print $1/1024}')
    if [ -n "$mem" ]; then
        echo "    Memory: ${mem}MB"
    fi
}

# Run benchmarks on each file
for f in "$FILES_DIR"/small.md "$FILES_DIR"/medium.md "$FILES_DIR"/large.md; do
    if [ -f "$f" ]; then
        benchmark_cold_start "$f"
        sleep 1
    fi
done

echo ""
echo "Note: These are rough measurements. For accurate profiling, use Instruments."
echo ""

# Cleanup
pkill -x QuickDown 2>/dev/null || true

echo "To run detailed profiling:"
echo "  instruments -t 'Time Profiler' -l 30000 -D profile.trace /Applications/QuickDown.app"
