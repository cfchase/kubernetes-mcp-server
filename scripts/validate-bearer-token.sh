#!/bin/bash

# validate-bearer-token.sh - Simple Bearer token validation script
# 
# This script performs a focused test of Bearer token authentication
# against the OAuth proxy configuration.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if oc is available
if ! command -v oc &> /dev/null; then
    print_error "oc command not found. This script requires OpenShift CLI."
    exit 1
fi

# Get namespace
NAMESPACE="${DEPLOY_NAMESPACE:-kubernetes-mcp-server}"
print_status "Using namespace: $NAMESPACE"

# Get OAuth token
print_status "Getting OAuth token..."
OAUTH_TOKEN=$(oc whoami -t 2>/dev/null)
if [ -z "$OAUTH_TOKEN" ]; then
    print_error "Failed to get OAuth token. Please login with 'oc login'"
    exit 1
fi

print_success "OAuth token obtained"

# Get route URL
ROUTE_URL=$(oc get route kubernetes-mcp-server -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -z "$ROUTE_URL" ]; then
    print_error "Could not find route. Is the application deployed?"
    exit 1
fi

BASE_URL="https://$ROUTE_URL"
print_success "Route found: $BASE_URL"

# Test Bearer token authentication
print_status "Testing Bearer token authentication..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $OAUTH_TOKEN" "$BASE_URL/mcp" 2>/dev/null || echo "000")

case "$HTTP_CODE" in
    200|405)
        print_success "Bearer token authentication WORKING (HTTP $HTTP_CODE)"
        echo "✅ OAuth proxy is properly configured for Bearer token delegation"
        ;;
    302)
        print_error "Bearer token authentication FAILING (HTTP $HTTP_CODE - Redirect)"
        echo "❌ OAuth proxy is redirecting instead of validating Bearer tokens"
        echo "   Check --openshift-delegate-urls and --pass-user-bearer-token configuration"
        ;;
    401|403)
        print_error "Bearer token authentication FAILING (HTTP $HTTP_CODE - Unauthorized)"
        echo "❌ Bearer token is rejected. Check user permissions or OAuth proxy SAR configuration"
        ;;
    *)
        print_error "Bearer token authentication FAILING (HTTP $HTTP_CODE - Unexpected)"
        echo "❌ Unexpected response code. Check OAuth proxy configuration and deployment status"
        ;;
esac

# Check user permissions
print_status "Checking user permissions for delegate-urls..."
CAN_LIST_NS=$(oc auth can-i list namespaces 2>/dev/null || echo "no")
if [ "$CAN_LIST_NS" = "yes" ]; then
    print_success "User has required 'list namespaces' permission"
else
    print_error "User lacks 'list namespaces' permission required by delegate-urls"
fi

# Summary
echo ""
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "405" ]; then
    print_success "Bearer token authentication is working correctly!"
    echo "MCP clients can now authenticate using OAuth Bearer tokens."
    exit 0
else
    print_error "Bearer token authentication needs to be fixed."
    echo "Review the OAuth proxy configuration and permissions."
    exit 1
fi