#!/bin/bash

# Autoscaling Test Script
# Tests three autoscaling scenarios: CPU, Memory, and Health Check failures

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get Load Balancer public IP from app.env if available
if [ -f "app.env" ]; then
    source app.env
    
    if [ -n "$LB_OCID" ] && [ "$LB_OCID" != "null" ]; then
        echo -e "${BLUE}[INFO]${NC} Retrieving Load Balancer public IP from OCID..."
        LB_PUBLIC_IP=$(oci lb load-balancer get \
            --load-balancer-id "$LB_OCID" \
            --query 'data."ip-addresses"[0]."ip-address"' \
            --raw-output 2>/dev/null || echo "")
        
        if [ -n "$LB_PUBLIC_IP" ] && [ "$LB_PUBLIC_IP" != "null" ]; then
            DEFAULT_URL="http://${LB_PUBLIC_IP}"
            echo -e "${GREEN}[SUCCESS]${NC} Found Load Balancer IP: ${LB_PUBLIC_IP}"
        else
            DEFAULT_URL="http://localhost:8080"
            echo -e "${YELLOW}[WARNING]${NC} Could not retrieve Load Balancer IP, using default: $DEFAULT_URL"
        fi
    else
        DEFAULT_URL="http://localhost:8080"
        echo -e "${YELLOW}[WARNING]${NC} LB_OCID not found in app.env, using default: $DEFAULT_URL"
    fi
else
    DEFAULT_URL="http://localhost:8080"
    echo -e "${YELLOW}[WARNING]${NC} app.env not found, using default: $DEFAULT_URL"
fi

# Configuration
APP_URL="${1:-$DEFAULT_URL}"
SCENARIO_DURATION=600  # 10 minutes per scenario to allow scaling events
MONITOR_INTERVAL=30    # Check status every 30 seconds

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

count_container_instances() {
    if [ "$MONITOR_OCI" = true ] && [ -n "$DISPLAY_NAME_PREFIX" ]; then
        local count=$(oci container-instances container-instance list \
            --compartment-id "$COMPARTMENT_OCID" \
            --lifecycle-state ACTIVE \
            --query "length(data.items[?starts_with(\"display-name\", '$DISPLAY_NAME_PREFIX')])" \
            --raw-output 2>/dev/null || echo "0")
        echo "$count"
    else
        echo "N/A"
    fi
}

generate_load() {
    local endpoint=$1
    local concurrent=$2
    local duration=$3
    
    log_info "Generating load: $concurrent concurrent requests to $endpoint for ${duration}s"
    
    local end_time=$(($(date +%s) + duration))
    for ((i=1; i<=concurrent; i++)); do
        (
            while [ $(date +%s) -lt $end_time ]; do
                curl -sf "$APP_URL$endpoint" > /dev/null 2>&1
                sleep 0.1
            done
        ) &
    done
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

# Clean up any running scenarios from previous tests
log_info "Stopping any active scenarios from previous tests..."
curl -sf -X POST "$APP_URL/api/scenario/cpu/stop" > /dev/null 2>&1 || true
curl -sf -X POST "$APP_URL/api/scenario/memory/stop" > /dev/null 2>&1 || true
curl -sf -X POST "$APP_URL/api/scenario/health/recover" > /dev/null 2>&1 || true
sleep 2
log_success "Previous scenarios cleaned up"
echo ""

# Show initial application info
log_info "Current application configuration:"
curl -sf "$APP_URL/api/info" | jq . 2>/dev/null || curl -sf "$APP_URL/api/info"
echo ""

# Source app.env if not already sourced (for OCI monitoring)
if [ -z "$OCI_COMPARTMENT_OCID" ] && [ -f "app.env" ]; then
    log_info "Sourcing app.env for OCI monitoring configuration..."
    source app.env
fi

# Use OCI_COMPARTMENT_OCID from app.env
COMPARTMENT_OCID="${COMPARTMENT_OCID:-$OCI_COMPARTMENT_OCID}"

# Check if we have access to OCI CLI for monitoring
if command -v oci &> /dev/null && [ -n "$COMPARTMENT_OCID" ] && [ -n "$DISPLAY_NAME_PREFIX" ]; then
    log_info "OCI CLI detected - will monitor container instances with prefix: $DISPLAY_NAME_PREFIX"
    MONITOR_OCI=true
else
    if ! command -v oci &> /dev/null; then
        log_warning "OCI CLI not available - skipping instance monitoring"
    elif [ -z "$COMPARTMENT_OCID" ]; then
        log_warning "COMPARTMENT_OCID not set - skipping instance monitoring (source app.env first)"
    elif [ -z "$DISPLAY_NAME_PREFIX" ]; then
        log_warning "DISPLAY_NAME_PREFIX not set - using DISPLAY_NAME from app.env"
        DISPLAY_NAME_PREFIX="${DISPLAY_NAME}"
        if [ -n "$DISPLAY_NAME_PREFIX" ]; then
            MONITOR_OCI=true
        else
            log_warning "No display name found - skipping instance monitoring"
            MONITOR_OCI=false
        fi
    fi
    
    if [ "$MONITOR_OCI" != true ]; then
        MONITOR_OCI=false
    fi
fi
echo ""

# =============================================================================
# TEST 1: CPU-Based Autoscaling
# =============================================================================
print_header "TEST 1: CPU-Based Autoscaling (Target: >60%)"

log_info "Starting CPU load scenario at 90% for ${SCENARIO_DURATION}s..."
response=$(curl -sf -X POST "$APP_URL/api/scenario/cpu/start?targetCpuPercent=90&durationSeconds=$SCENARIO_DURATION")
echo "$response" | jq . 2>/dev/null || echo "$response"

if [[ $response == *"started"* ]] || [[ $response == *"already running"* ]]; then
    log_success "CPU load scenario initiated"
    
    # Generate additional load with direct API calls
    log_info "Adding parallel load generation (10 concurrent workers)..."
    generate_load "/api/cpu?iterations=5000" 10 $((SCENARIO_DURATION / 2))
    
    log_info "Monitoring for 5 minutes. Watch for scaling events..."
    log_warning "Alarms take ~5 minutes to trigger. New instances take ~2-3 minutes to deploy."
    for i in {1..10}; do
        sleep $MONITOR_INTERVAL
        instance_count=$(count_container_instances)
        log_info "Status check $i/10 ($(($i * $MONITOR_INTERVAL))s elapsed) - Instances: $instance_count"
        get_scenario_status | jq '{cpu_active: .cpu_scenario_active, cpu_cores: .current_cpu_cores, memory_percent: .current_memory_percent}' 2>/dev/null || get_scenario_status
    done
    
    # Stop background load generation
    pkill -P $$ curl 2>/dev/null || true
    
    log_info "Stopping CPU load scenario..."
    curl -sf -X POST "$APP_URL/api/scenario/cpu/stop" | jq . 2>/dev/null || echo "Stopped"
    log_success "CPU scenario completed"
else
    log_error "Failed to start CPU scenario"
fi

log_info "Waiting 2 minutes for scale-down stabilization..."
log_warning "Scale-down alarms need time to detect reduced load and trigger scale-down."
sleep 120

# =============================================================================
# TEST 2: Memory-Based Autoscaling
# =============================================================================
print_header "TEST 2: Memory-Based Autoscaling (Target: >60%)"

log_info "Starting memory load scenario at 85% for ${SCENARIO_DURATION}s..."
response=$(curl -sf -X POST "$APP_URL/api/scenario/memory/start?targetMemoryPercent=85&durationSeconds=$SCENARIO_DURATION")
echo "$response" | jq . 2>/dev/null || echo "$response"

if [[ $response == *"started"* ]] || [[ $response == *"already running"* ]]; then
    log_success "Memory load scenario initiated"
    
    # Generate additional load with direct memory allocations
    log_info "Adding parallel memory load (8 concurrent workers)..."
    generate_load "/api/memory?sizeMB=50" 8 $((SCENARIO_DURATION / 2))
    
    log_info "Monitoring for 5 minutes. Watch for scaling events..."
    log_warning "Alarms take ~5 minutes to trigger. New instances take ~2-3 minutes to deploy."
    for i in {1..10}; do
        sleep $MONITOR_INTERVAL
        instance_count=$(count_container_instances)
        log_info "Status check $i/10 ($(($i * $MONITOR_INTERVAL))s elapsed) - Instances: $instance_count"
        get_scenario_status | jq '{memory_active: .memory_scenario_active, memory_used_mb: .current_memory_used_mb, memory_max_mb: .current_memory_max_mb, memory_percent: .current_memory_percent}' 2>/dev/null || get_scenario_status
    done
    
    # Stop background load generation
    pkill -P $$ curl 2>/dev/null || true
    
    log_info "Stopping memory load scenario..."
    curl -sf -X POST "$APP_URL/api/scenario/memory/stop" | jq . 2>/dev/null || echo "Stopped"
    log_success "Memory scenario completed"
else
    log_error "Failed to start memory scenario"
fi

log_info "Waiting 2 minutes for scale-down stabilization..."
log_warning "Scale-down alarms need time to detect reduced load and trigger scale-down."
sleep 120

# =============================================================================
# TEST 3: Health Check Failure-Based Autoscaling
# =============================================================================
print_header "TEST 3: Health Check Failure (Non-200 responses)"

log_info "Triggering health check failures for ${SCENARIO_DURATION}s..."
response=$(curl -sf -X POST "$APP_URL/api/scenario/health/fail?durationSeconds=$SCENARIO_DURATION")
echo "$response" | jq . 2>/dev/null || echo "$response"

if [[ $response == *"failing"* ]]; then
    log_success "Health check failure scenario initiated"
    
    log_info "Waiting 60 seconds for health checks to fail..."
    log_warning "Load balancer health checks run every 10 seconds with 3 retries."
    sleep 60
    
    log_info "Testing health endpoint (should return non-200):"
    health_status=$(curl -sw "\nHTTP Status: %{http_code}\n" "$APP_URL/api/scenario/health/status" 2>/dev/null || echo "Failed to connect")
    echo "$health_status"
    
    if [[ $health_status == *"503"* ]] || [[ $health_status == *"500"* ]]; then
        log_success "Health check is correctly failing"
    else
        log_warning "Health check may not be failing as expected"
    fi
    
    log_info "Monitoring for 3 minutes. Watch for backend failures and scaling..."
    log_warning "Alarms trigger when >50% of backends are unhealthy."
    for i in {1..6}; do
        sleep 30
        instance_count=$(count_container_instances)
        log_info "Check $i/6 ($(($i * 30))s elapsed) - Instances: $instance_count - Backends should be marked unhealthy"
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
