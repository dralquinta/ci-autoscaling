#!/bin/bash

# Autoscaling Test Script
# Tests three autoscaling scenarios: CPU, Memory, and Health Check failures

set -e

# Configuration
APP_URL="${1:-http://localhost:8080}"
SCENARIO_DURATION=300  # 5 minutes per scenario
MONITOR_INTERVAL=30    # Check status every 30 seconds

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
    echo ""
}

check_app_health() {
    if curl -sf "$APP_URL/api/health" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

get_scenario_status() {
    curl -sf "$APP_URL/api/scenario/status" 2>/dev/null || echo '{"error":"unable to fetch status"}'
}

# Main script
print_header "Autoscaling Test Suite"
log_info "Application URL: $APP_URL"
log_info "Scenario Duration: ${SCENARIO_DURATION}s"
echo ""

# Verify application is running
log_info "Checking if application is accessible..."
if check_app_health; then
    log_success "Application is healthy and accessible"
else
    log_error "Application is not accessible at $APP_URL"
    exit 1
fi

# =============================================================================
# TEST 1: CPU-Based Autoscaling
# =============================================================================
print_header "TEST 1: CPU-Based Autoscaling (Target: >60%)"

log_info "Starting CPU load scenario at 75% for ${SCENARIO_DURATION}s..."
response=$(curl -sf -X POST "$APP_URL/api/scenario/cpu/start?targetCpuPercent=75&durationSeconds=$SCENARIO_DURATION")
echo "$response" | jq . 2>/dev/null || echo "$response"

if [[ $response == *"started"* ]] || [[ $response == *"already running"* ]]; then
    log_success "CPU load scenario initiated"
    
    log_info "Monitoring for 2 minutes. Watch for scaling events..."
    for i in {1..4}; do
        sleep $MONITOR_INTERVAL
        log_info "Status check $i/4:"
        get_scenario_status | jq '{cpu_active: .cpu_scenario_active, cpu_cores: .current_cpu_cores, memory_percent: .current_memory_percent}' 2>/dev/null || get_scenario_status
    done
    
    log_info "Stopping CPU load scenario..."
    curl -sf -X POST "$APP_URL/api/scenario/cpu/stop" | jq . 2>/dev/null || echo "Stopped"
    log_success "CPU scenario completed"
else
    log_error "Failed to start CPU scenario"
fi

log_info "Waiting 60 seconds for scale-down stabilization..."
sleep 60

# =============================================================================
# TEST 2: Memory-Based Autoscaling
# =============================================================================
print_header "TEST 2: Memory-Based Autoscaling (Target: >60%)"

log_info "Starting memory load scenario at 75% for ${SCENARIO_DURATION}s..."
response=$(curl -sf -X POST "$APP_URL/api/scenario/memory/start?targetMemoryPercent=75&durationSeconds=$SCENARIO_DURATION")
echo "$response" | jq . 2>/dev/null || echo "$response"

if [[ $response == *"started"* ]] || [[ $response == *"already running"* ]]; then
    log_success "Memory load scenario initiated"
    
    log_info "Monitoring for 2 minutes. Watch for scaling events..."
    for i in {1..4}; do
        sleep $MONITOR_INTERVAL
        log_info "Status check $i/4:"
        get_scenario_status | jq '{memory_active: .memory_scenario_active, memory_used_mb: .current_memory_used_mb, memory_max_mb: .current_memory_max_mb, memory_percent: .current_memory_percent}' 2>/dev/null || get_scenario_status
    done
    
    log_info "Stopping memory load scenario..."
    curl -sf -X POST "$APP_URL/api/scenario/memory/stop" | jq . 2>/dev/null || echo "Stopped"
    log_success "Memory scenario completed"
else
    log_error "Failed to start memory scenario"
fi

log_info "Waiting 60 seconds for scale-down stabilization..."
sleep 60

# =============================================================================
# TEST 3: Health Check Failure-Based Autoscaling
# =============================================================================
print_header "TEST 3: Health Check Failure (Non-200 responses)"

log_info "Triggering health check failures for ${SCENARIO_DURATION}s..."
response=$(curl -sf -X POST "$APP_URL/api/scenario/health/fail?durationSeconds=$SCENARIO_DURATION")
echo "$response" | jq . 2>/dev/null || echo "$response"

if [[ $response == *"failing"* ]]; then
    log_success "Health check failure scenario initiated"
    
    log_info "Waiting 30 seconds for health checks to fail..."
    sleep 30
    
    log_info "Testing health endpoint (should return non-200):"
    health_status=$(curl -sw "\nHTTP Status: %{http_code}\n" "$APP_URL/api/scenario/health/status" 2>/dev/null || echo "Failed to connect")
    echo "$health_status"
    
    if [[ $health_status == *"503"* ]] || [[ $health_status == *"500"* ]]; then
        log_success "Health check is correctly failing"
    else
        log_warning "Health check may not be failing as expected"
    fi
    
    log_info "Monitoring for 90 seconds. Watch for pod restarts..."
    for i in {1..3}; do
        sleep 30
        log_info "Check $i/3: Pods should be marked unhealthy"
    done
    
    log_info "Recovering health checks..."
    curl -sf -X POST "$APP_URL/api/scenario/health/recover" | jq . 2>/dev/null || echo "Recovered"
    
    log_info "Verifying health recovered..."
    sleep 5
    if check_app_health; then
        log_success "Health checks restored successfully"
    else
        log_warning "Health may still be recovering..."
    fi
else
    log_error "Failed to start health failure scenario"
fi

# =============================================================================
# Final Status
# =============================================================================
print_header "Test Suite Completed"

log_info "Final scenario status:"
get_scenario_status | jq . 2>/dev/null || get_scenario_status

echo ""
log_success "All autoscaling tests completed!"
echo ""
log_info "Next steps:"
echo "  1. Check your orchestrator for scaling events:"
echo "     - Kubernetes: kubectl get hpa -w"
echo "     - Kubernetes: kubectl get pods -l app=autoscaling-demo"
echo "     - Docker: docker stats"
echo ""
echo "  2. View application metrics:"
echo "     curl $APP_URL/actuator/prometheus"
echo ""
echo "  3. Check application logs for scenario events"
echo ""
