#!/bin/bash

# test-autoscaling.sh - Test autoscaling by generating load
# Usage: ./test-autoscaling.sh [load-balancer-ip]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Get load balancer IP
LB_IP="${1:-}"

if [ -z "$LB_IP" ]; then
    error "Usage: ./test-autoscaling.sh [load-balancer-ip]

Example: ./test-autoscaling.sh 129.213.xxx.xxx"
fi

# Test connectivity
log "Testing connectivity to load balancer..."
if ! curl -sf "http://${LB_IP}${HEALTH_CHECK_PATH:-/health}" > /dev/null; then
    error "Cannot reach load balancer at http://${LB_IP}"
fi

log "✅ Load balancer is reachable"

# Generate load
log "Generating load to trigger autoscaling..."
info "This will send continuous requests for 10 minutes"
info "Monitor the OCI Console to see new instances being created"
echo ""

# Check if Apache Bench is installed
if command -v ab &> /dev/null; then
    info "Using Apache Bench (ab) for load testing"
    
    # Run for 10 minutes with 50 concurrent requests
    ab -n 100000 -c 50 -t 600 "http://${LB_IP}/"
    
elif command -v hey &> /dev/null; then
    info "Using hey for load testing"
    
    # Run for 10 minutes with 50 workers
    hey -c 50 -z 10m "http://${LB_IP}/"
    
else
    warn "Neither 'ab' nor 'hey' found. Using curl in a loop (less effective)"
    info "Install Apache Bench for better load testing:"
    info "  Ubuntu/Debian: sudo apt-get install apache2-utils"
    info "  macOS: brew install httpd"
    info "  Or install hey: go install github.com/rakyll/hey@latest"
    echo ""
    
    # Fallback to curl loop
    for i in {1..1000}; do
        for j in {1..10}; do
            curl -s "http://${LB_IP}/" > /dev/null &
        done
        sleep 1
        if [ $((i % 10)) -eq 0 ]; then
            info "Sent $((i * 10)) requests..."
        fi
    done
    wait
fi

log "✅ Load test completed"
info "Check the OCI Console to see if new instances were created"
info "It may take 5-10 minutes for autoscaling to trigger"
