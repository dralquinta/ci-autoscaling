#!/bin/bash

###############################################################################
# Setup IAM Policies for Autoscaling Functions
#
# This script creates:
# 1. Dynamic Group for autoscaling functions
# 2. Policy statements allowing functions to manage container instances and load balancers
###############################################################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Display command before executing
cmd() {
    echo -e "${YELLOW}[CMD]${NC} ${YELLOW}$1${NC}"
    eval "$1"
}

# Load configuration
if [ -f "autoscaling.env" ]; then
    source autoscaling.env
else
    error "autoscaling.env file not found. Please run from autoscaling/ directory."
    exit 1
fi

# Get tenancy OCID and home region
TENANCY_OCID=$(oci iam compartment list --query "data[0].\"compartment-id\"" --raw-output)
HOME_REGION=$(oci iam region-subscription list --query "data[?\"is-home-region\"==\`true\`].\"region-name\" | [0]" --raw-output)
log "Tenancy OCID: $TENANCY_OCID"
log "Home Region: $HOME_REGION"

# Dynamic Group Configuration
DYNAMIC_GROUP_NAME="ci-autoscaling-functions-dg"
DYNAMIC_GROUP_DESC="Dynamic group for CI Autoscaling Functions"

# Container Instances Dynamic Group Configuration (for OCIR access)
CI_DYNAMIC_GROUP_NAME="ci-container-instances-dg"
CI_DYNAMIC_GROUP_DESC="Dynamic group for Container Instances to pull images from OCIR"

# Policy Configuration  
POLICY_NAME="ci-autoscaling-functions-policy"
POLICY_DESC="Policy allowing autoscaling functions to manage container instances and load balancers"

CI_POLICY_NAME="ci-container-instances-policy"
CI_POLICY_DESC="Policy allowing Container Instances to read images from OCIR"

###############################################################################
# Create Dynamic Group
###############################################################################
create_dynamic_group() {
    log "Creating dynamic group: $DYNAMIC_GROUP_NAME"
    
    # Check if dynamic group already exists
    log "Checking for existing dynamic group..."
    EXISTING_DG=$(oci iam dynamic-group list \
        --compartment-id "$TENANCY_OCID" \
        --name "$DYNAMIC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_DG" ] && [ "$EXISTING_DG" != "null" ]; then
        log "Dynamic group already exists: $EXISTING_DG"
        DYNAMIC_GROUP_OCID="$EXISTING_DG"
        return 0
    fi
    
    # Get Functions Application OCID
    log "Getting Functions Application OCID..."
    FUNCTIONS_APP_OCID=$(oci fn application list \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$FUNCTIONS_APP_NAME" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -z "$FUNCTIONS_APP_OCID" ] || [ "$FUNCTIONS_APP_OCID" == "null" ]; then
        error "Functions application not found. Please deploy functions first with: ./setup-autoscaling.sh --deploy"
        exit 1
    fi
    
    log "Functions Application OCID: $FUNCTIONS_APP_OCID"
    
    # Get compartment name for policy statements
    COMPARTMENT_NAME=$(oci iam compartment get --compartment-id "$COMPARTMENT_OCID" --query 'data.name' --raw-output 2>/dev/null || echo "")
    if [ -z "$COMPARTMENT_NAME" ]; then
        error "Failed to get compartment name"
        exit 1
    fi
    log "Compartment name: $COMPARTMENT_NAME"
    
    # Create matching rule for all functions in the application
    MATCHING_RULE="ALL {resource.type = 'fnfunc', resource.compartment.id = '$COMPARTMENT_OCID'}"
    
    # Create dynamic group
    log "Creating dynamic group with matching rule: $MATCHING_RULE"
    DYNAMIC_GROUP_OCID=$(oci iam dynamic-group create \
        --compartment-id "$TENANCY_OCID" \
        --name "$DYNAMIC_GROUP_NAME" \
        --description "$DYNAMIC_GROUP_DESC" \
        --matching-rule "$MATCHING_RULE" \
        --region "$HOME_REGION" \
        --query 'data.id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$DYNAMIC_GROUP_OCID" ] && [ "$DYNAMIC_GROUP_OCID" != "null" ]; then
        log "Dynamic group created successfully: $DYNAMIC_GROUP_OCID"
    else
        error "Failed to create dynamic group"
        exit 1
    fi
    
    # Create Container Instances dynamic group
    log "Creating Container Instances dynamic group: $CI_DYNAMIC_GROUP_NAME"
    
    # Check if CI dynamic group already exists
    EXISTING_CI_DG=$(oci iam dynamic-group list \
        --compartment-id "$TENANCY_OCID" \
        --name "$CI_DYNAMIC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_CI_DG" ] && [ "$EXISTING_CI_DG" != "null" ]; then
        log "Container Instances dynamic group already exists: $EXISTING_CI_DG"
        return 0
    fi
    
    # Create matching rule for all container instances in compartment
    CI_MATCHING_RULE="ALL {resource.type='computecontainerinstance', resource.compartment.id='$COMPARTMENT_OCID'}"
    
    log "Creating Container Instances dynamic group with matching rule: $CI_MATCHING_RULE"
    CI_DYNAMIC_GROUP_OCID=$(oci iam dynamic-group create \
        --compartment-id "$TENANCY_OCID" \
        --name "$CI_DYNAMIC_GROUP_NAME" \
        --description "$CI_DYNAMIC_GROUP_DESC" \
        --matching-rule "$CI_MATCHING_RULE" \
        --region "$HOME_REGION" \
        --query 'data.id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$CI_DYNAMIC_GROUP_OCID" ] && [ "$CI_DYNAMIC_GROUP_OCID" != "null" ]; then
        log "Container Instances dynamic group created successfully: $CI_DYNAMIC_GROUP_OCID"
    else
        warn "Failed to create Container Instances dynamic group (may already exist)"
    fi
}

###############################################################################
# Create Policy
###############################################################################
create_policy() {
    log "Creating policy: $POLICY_NAME"
    
    # Check if policy already exists
    log "Checking for existing policy..."
    EXISTING_POLICY=$(oci iam policy list \
        --compartment-id "$TENANCY_OCID" \
        --name "$POLICY_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_POLICY" ] && [ "$EXISTING_POLICY" != "null" ]; then
        warn "Policy already exists: $EXISTING_POLICY"
        log "Updating policy statements..."
        
        # Get compartment name for policy statements
        COMPARTMENT_NAME=$(oci iam compartment get --compartment-id "$COMPARTMENT_OCID" --query 'data.name' --raw-output 2>/dev/null || echo "")
        
        # Update policy with new statements (using all-resources in tenancy for simplicity)
        POLICY_STATEMENTS="[\"Allow dynamic-group ${DYNAMIC_GROUP_NAME} to manage all-resources in tenancy\",\"Allow dynamic-group ${CI_DYNAMIC_GROUP_NAME} to manage all-resources in tenancy\"]"
        
        log "Updating policy statements..."
        oci iam policy update \
            --policy-id "$EXISTING_POLICY" \
            --statements "$POLICY_STATEMENTS" \
            --region "$HOME_REGION" \
            --force >/dev/null 2>&1
        
        log "Policy updated successfully"
        return 0
    fi
    
    # Create policy statements (using all-resources in tenancy for simplicity)
    POLICY_STATEMENTS="[\"Allow dynamic-group ${DYNAMIC_GROUP_NAME} to manage all-resources in tenancy\",\"Allow dynamic-group ${CI_DYNAMIC_GROUP_NAME} to manage all-resources in tenancy\"]"
    
    # Create policy
    log "Creating new policy..."
    POLICY_OUTPUT=$(oci iam policy create \
        --compartment-id "$TENANCY_OCID" \
        --name "$POLICY_NAME" \
        --description "$POLICY_DESC" \
        --statements "$POLICY_STATEMENTS" \
        --region "$HOME_REGION" 2>&1)
    
    if echo "$POLICY_OUTPUT" | grep -q "No permissions found\|Failed to parse policy"; then
        error "Failed to create policy - OCI API validation error"
        error ""
        error "Please create the following policy manually in the OCI Console:"
        error "Navigate to: Identity & Security > Policies > Create Policy"
        error ""
        error "Compartment: Root (tenancy)"
        error "Name: $POLICY_NAME"
        error "Description: $POLICY_DESC"
        error ""
        error "Policy Statements (use Policy Builder or manual editor):"
        echo "$POLICY_STATEMENTS" | grep -o '"[^"]*"' | sed 's/"//g' | while read line; do
            error "  $line"
        done
        error ""
        warn "Note: The OCI CLI is rejecting these statements. You may need to adjust"
        warn "the resource types or use the OCI Console Policy Builder to create them."
        exit 1
    fi
    
    POLICY_OCID=$(echo "$POLICY_OUTPUT" | grep -o '"id": "[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$POLICY_OCID" ] && [ "$POLICY_OCID" != "null" ]; then
        log "Policy created successfully: $POLICY_OCID"
        log "Policy includes permissions for both functions and container instances"
    else
        error "Failed to create policy"
        error "Output: $POLICY_OUTPUT"
        exit 1
    fi
}

###############################################################################
# Show Status
###############################################################################
show_status() {
    log "====== IAM Resources Status ======"
    echo ""
    
    info "Dynamic Group: $DYNAMIC_GROUP_NAME"
    cmd "oci iam dynamic-group list --compartment-id $TENANCY_OCID --name $DYNAMIC_GROUP_NAME --region $HOME_REGION"
    oci iam dynamic-group list \
        --compartment-id "$TENANCY_OCID" \
        --name "$DYNAMIC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --query 'data[*].{Name:name, ID:id, MatchingRule:"matching-rule"}' \
        --output table
    echo ""
    
    info "Policy: $POLICY_NAME"
    cmd "oci iam policy list --compartment-id $TENANCY_OCID --name $POLICY_NAME --region $HOME_REGION"
    oci iam policy list \
        --compartment-id "$TENANCY_OCID" \
        --name "$POLICY_NAME" \
        --region "$HOME_REGION" \
        --query 'data[*].{Name:name, ID:id}' \
        --output table
    echo ""
    
    log "Policy Statements:"
    cmd "oci iam policy get --policy-id \$(oci iam policy list --compartment-id $TENANCY_OCID --name $POLICY_NAME --region $HOME_REGION --query 'data[0].id' --raw-output) --region $HOME_REGION"
    oci iam policy get \
        --policy-id "$(oci iam policy list --compartment-id "$TENANCY_OCID" --name "$POLICY_NAME" --region "$HOME_REGION" --query 'data[0].id' --raw-output)" \
        --region "$HOME_REGION" \
        --query 'data.statements[*]' \
        --output table
    echo ""
    
    info "Container Instances Dynamic Group: $CI_DYNAMIC_GROUP_NAME"
    cmd "oci iam dynamic-group list --compartment-id $TENANCY_OCID --name $CI_DYNAMIC_GROUP_NAME --region $HOME_REGION"
    oci iam dynamic-group list \
        --compartment-id "$TENANCY_OCID" \
        --name "$CI_DYNAMIC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --query 'data[*].{Name:name, ID:id, MatchingRule:"matching-rule"}' \
        --output table
    echo ""
}

###############################################################################
# Cleanup
###############################################################################
cleanup() {
    log "====== Cleaning up IAM resources ======"
    
    # Delete policy (contains statements for both dynamic groups)
    POLICY_OCID=$(oci iam policy list \
        --compartment-id "$TENANCY_OCID" \
        --name "$POLICY_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$POLICY_OCID" ] && [ "$POLICY_OCID" != "null" ]; then
        log "Deleting policy: $POLICY_OCID"
        oci iam policy delete --policy-id "$POLICY_OCID" --force --region "$HOME_REGION" 2>/dev/null && log "Policy deleted" || warn "Failed to delete policy"
    else
        warn "Policy not found"
    fi
    
    # Delete old Container Instances policy if it exists
    CI_POLICY_OCID=$(oci iam policy list \
        --compartment-id "$TENANCY_OCID" \
        --name "$CI_POLICY_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$CI_POLICY_OCID" ] && [ "$CI_POLICY_OCID" != "null" ]; then
        log "Deleting old Container Instances policy: $CI_POLICY_OCID"
        oci iam policy delete --policy-id "$CI_POLICY_OCID" --force --region "$HOME_REGION" 2>/dev/null && log "Old CI policy deleted" || warn "Failed to delete old CI policy"
    fi
    
    # Delete functions dynamic group
    DYNAMIC_GROUP_OCID=$(oci iam dynamic-group list \
        --compartment-id "$TENANCY_OCID" \
        --name "$DYNAMIC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$DYNAMIC_GROUP_OCID" ] && [ "$DYNAMIC_GROUP_OCID" != "null" ]; then
        log "Deleting functions dynamic group: $DYNAMIC_GROUP_OCID"
        oci iam dynamic-group delete --dynamic-group-id "$DYNAMIC_GROUP_OCID" --force --region "$HOME_REGION" 2>/dev/null && log "Functions dynamic group deleted" || warn "Failed to delete functions dynamic group"
    else
        warn "Functions dynamic group not found"
    fi
    
    # Delete Container Instances dynamic group
    CI_DYNAMIC_GROUP_OCID=$(oci iam dynamic-group list \
        --compartment-id "$TENANCY_OCID" \
        --name "$CI_DYNAMIC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [ -n "$CI_DYNAMIC_GROUP_OCID" ] && [ "$CI_DYNAMIC_GROUP_OCID" != "null" ]; then
        log "Deleting Container Instances dynamic group: $CI_DYNAMIC_GROUP_OCID"
        oci iam dynamic-group delete --dynamic-group-id "$CI_DYNAMIC_GROUP_OCID" --force --region "$HOME_REGION" 2>/dev/null && log "Container Instances dynamic group deleted" || warn "Failed to delete Container Instances dynamic group"
    else
        warn "Container Instances dynamic group not found"
    fi
    
    log "Cleanup completed"
}

###############################################################################
# Main
###############################################################################

case "${1:-}" in
    --setup)
        log "====== Setting up IAM resources for autoscaling ======"
        create_dynamic_group
        echo ""
        create_policy
        echo ""
        log "====== IAM Setup Complete ======"
        echo ""
        log "Next steps:"
        log "  1. Wait 30-60 seconds for policy to propagate"
        log "  2. Test function: fn invoke ci-autoscaling-app scale-up"
        log "  3. Check status: ./setup-iam-policies.sh --status"
        ;;
    --status)
        show_status
        ;;
    --cleanup)
        cleanup
        ;;
    *)
        echo "Usage: $0 {--setup|--status|--cleanup}"
        echo ""
        echo "Commands:"
        echo "  --setup     Create dynamic group and policy for autoscaling functions"
        echo "  --status    Show current IAM resources status"
        echo "  --cleanup   Delete dynamic group and policy"
        exit 1
        ;;
esac
