#!/bin/bash

# test-oauth.sh - Test the deployed Kubernetes MCP Server with OAuth authentication

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_oauth_status() {
    echo -e "${CYAN}[OAUTH]${NC} $1"
}

# Check if kubectl/oc is available
if command -v oc &> /dev/null; then
    KUBECTL_CMD="oc"
elif command -v kubectl &> /dev/null; then
    KUBECTL_CMD="kubectl"
else
    print_error "Neither kubectl nor oc command found. Please install one of them."
    exit 1
fi

# Get the current directory (project root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to project root
cd "$PROJECT_ROOT"

# Load .env file if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Get namespace from environment or use default
NAMESPACE="${DEPLOY_NAMESPACE:-kubernetes-mcp-server}"
print_status "Using namespace: $NAMESPACE"

# Get OAuth token
print_oauth_status "Getting OAuth token..."
if ! command -v oc &> /dev/null; then
    print_error "oc command not found. OAuth testing requires OpenShift CLI (oc) to get the authentication token."
    exit 1
fi

OAUTH_TOKEN=$(oc whoami -t 2>/dev/null)
if [ -z "$OAUTH_TOKEN" ]; then
    print_error "Failed to get OAuth token. Please ensure you are logged into OpenShift with 'oc login'"
    exit 1
fi

print_success "OAuth token obtained (${#OAUTH_TOKEN} characters)"

# Get the route URL
print_status "Getting route URL..."
ROUTE_URL=$($KUBECTL_CMD get route kubernetes-mcp-server -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || true)

if [ -z "$ROUTE_URL" ]; then
    print_error "Could not find route URL. Is the application deployed?"
    exit 1
fi

BASE_URL="https://$ROUTE_URL"
print_success "Found route: $BASE_URL"

# Test 1: Check if the server is responding without authentication
print_status "Test 1: Checking unauthenticated access (should be rejected)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/mcp" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    print_success "Unauthenticated access properly rejected (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "405" ]; then
    print_warning "Server responded without authentication (HTTP $HTTP_CODE) - OAuth might not be enforced"
else
    print_warning "Unexpected HTTP code for unauthenticated request: $HTTP_CODE"
fi

# Test 2: Check authenticated access with Bearer token
print_status "Test 2: Checking authenticated access with Bearer token..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $OAUTH_TOKEN" "$BASE_URL/mcp" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "405" ]; then
    print_success "Bearer token authentication successful (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "302" ]; then
    print_error "Bearer token returned redirect (HTTP $HTTP_CODE) - OAuth proxy not configured for Bearer token delegation"
    print_status "Checking if OAuth proxy is properly configured for --openshift-delegate-urls"
elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    print_error "Bearer token authentication failed (HTTP $HTTP_CODE) - Token may be invalid or insufficient permissions"
else
    print_error "Bearer token authentication failed (HTTP $HTTP_CODE)"
    print_status "This might indicate OAuth proxy configuration issues"
fi

# Test 2b: Check verbose response headers for debugging
print_status "Test 2b: Checking response headers for Bearer token authentication..."
RESPONSE_HEADERS=$(curl -s -I -H "Authorization: Bearer $OAUTH_TOKEN" "$BASE_URL/mcp" 2>/dev/null || echo "")
if echo "$RESPONSE_HEADERS" | grep -q "Location:"; then
    REDIRECT_LOCATION=$(echo "$RESPONSE_HEADERS" | grep "Location:" | head -1 | cut -d' ' -f2- | tr -d '\r\n')
    print_warning "Bearer token authentication redirected to: $REDIRECT_LOCATION"
    print_status "This indicates the OAuth proxy is not validating Bearer tokens properly"
fi

# Helper function to send MCP request with authentication
send_mcp_request() {
    local request="$1"
    local description="$2"
    local use_auth="${3:-true}"
    
    print_status "$description"
    
    local auth_header=""
    if [ "$use_auth" = "true" ]; then
        auth_header="-H \"Authorization: Bearer $OAUTH_TOKEN\""
    fi
    
    # Send request with streaming support
    if [ "$use_auth" = "true" ]; then
        response=$(echo "$request" | curl -s -X POST "$BASE_URL/mcp" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -H "Authorization: Bearer $OAUTH_TOKEN" \
            --data-binary @- \
            2>/dev/null || echo "{}")
    else
        response=$(echo "$request" | curl -s -X POST "$BASE_URL/mcp" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            --data-binary @- \
            2>/dev/null || echo "{}")
    fi
    
    echo "$response"
}

# Test 3: Test MCP initialize without authentication (should fail)
print_oauth_status "Test 3: Testing MCP initialize without authentication..."
INIT_REQUEST='{
  "jsonrpc": "2.0",
  "id": "init-unauth",
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {
      "name": "test-client-unauth",
      "version": "1.0.0"
    }
  }
}'

INIT_RESPONSE_UNAUTH=$(send_mcp_request "$INIT_REQUEST" "Testing unauthenticated MCP initialize..." "false")

# Check if unauthenticated request is properly rejected
if echo "$INIT_RESPONSE_UNAUTH" | grep -q '"error"'; then
    print_success "Unauthenticated MCP initialize properly rejected"
    ERROR_MSG=$(echo "$INIT_RESPONSE_UNAUTH" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    echo "  Error message: $ERROR_MSG"
elif echo "$INIT_RESPONSE_UNAUTH" | grep -q '"protocolVersion"'; then
    print_warning "Unauthenticated MCP initialize succeeded - OAuth might not be enforced at MCP level"
else
    print_error "Unexpected response for unauthenticated initialize"
    echo "$INIT_RESPONSE_UNAUTH" | jq . 2>/dev/null || echo "$INIT_RESPONSE_UNAUTH"
fi

# Test 4: Initialize connection with authentication
print_oauth_status "Test 4: Testing authenticated MCP initialize..."
INIT_REQUEST_AUTH='{
  "jsonrpc": "2.0",
  "id": "init-auth",
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {
      "name": "test-client-auth",
      "version": "1.0.0"
    }
  }
}'

INIT_RESPONSE=$(send_mcp_request "$INIT_REQUEST_AUTH" "Initializing authenticated MCP connection...")

# Check if response contains expected fields
if echo "$INIT_RESPONSE" | grep -q '"protocolVersion"'; then
    print_success "Authenticated initialize successful"
    echo "  Protocol Version: $(echo "$INIT_RESPONSE" | grep -o '"protocolVersion":"[^"]*"' | cut -d'"' -f4)"
    SERVER_NAME=$(echo "$INIT_RESPONSE" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "  Server Name: $SERVER_NAME"
    SERVER_VERSION=$(echo "$INIT_RESPONSE" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "  Server Version: $SERVER_VERSION"
    
    # Check for OAuth capabilities or authentication info in response
    if echo "$INIT_RESPONSE" | grep -q -i "oauth\|auth"; then
        print_oauth_status "Authentication capabilities detected in server response"
    fi
else
    print_error "Authenticated initialize failed"
    echo "$INIT_RESPONSE" | jq . 2>/dev/null || echo "$INIT_RESPONSE"
fi

# Test 5: Test tools list without authentication
print_oauth_status "Test 5: Testing tools list without authentication..."
TOOLS_REQUEST='{
  "jsonrpc": "2.0",
  "id": "tools-unauth",
  "method": "tools/list",
  "params": {}
}'

TOOLS_RESPONSE_UNAUTH=$(send_mcp_request "$TOOLS_REQUEST" "Fetching tools without auth..." "false")

if echo "$TOOLS_RESPONSE_UNAUTH" | grep -q '"error"'; then
    print_success "Unauthenticated tools list properly rejected"
elif echo "$TOOLS_RESPONSE_UNAUTH" | grep -q '"name"'; then
    print_warning "Unauthenticated tools list succeeded - OAuth might not be enforced"
else
    print_status "Unauthenticated tools response unclear"
fi

# Test 6: List available tools with authentication
print_oauth_status "Test 6: Testing authenticated tools list..."
TOOLS_REQUEST_AUTH='{
  "jsonrpc": "2.0",
  "id": "tools-auth",
  "method": "tools/list",
  "params": {}
}'

TOOLS_RESPONSE=$(send_mcp_request "$TOOLS_REQUEST_AUTH" "Fetching available tools with authentication...")

# Count tools
TOOL_COUNT=$(echo "$TOOLS_RESPONSE" | grep -o '"name"' | wc -l)
if [ "$TOOL_COUNT" -gt 0 ]; then
    print_success "Found $TOOL_COUNT tools available with authentication"
    echo "  Sample tools:"
    echo "$TOOLS_RESPONSE" | grep -o '"name":"[^"]*"' | head -5 | while read -r tool; do
        echo "    - $(echo "$tool" | cut -d'"' -f4)"
    done
    if [ "$TOOL_COUNT" -gt 5 ]; then
        echo "    ... and $((TOOL_COUNT - 5)) more"
    fi
else
    print_error "No tools found with authentication or unexpected response"
    echo "$TOOLS_RESPONSE" | jq . 2>/dev/null || echo "$TOOLS_RESPONSE"
fi

# Test 7: Test tool execution without authentication
print_oauth_status "Test 7: Testing tool execution without authentication..."
NS_REQUEST_UNAUTH='{
  "jsonrpc": "2.0",
  "id": "call-unauth",
  "method": "tools/call",
  "params": {
    "name": "namespaces_list",
    "arguments": {}
  }
}'

NS_RESPONSE_UNAUTH=$(send_mcp_request "$NS_REQUEST_UNAUTH" "Testing unauthenticated namespace list..." "false")

if echo "$NS_RESPONSE_UNAUTH" | grep -q '"error"'; then
    print_success "Unauthenticated tool execution properly rejected"
    ERROR_MSG=$(echo "$NS_RESPONSE_UNAUTH" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    echo "  Error message: $ERROR_MSG"
elif echo "$NS_RESPONSE_UNAUTH" | grep -q '"content"'; then
    print_warning "Unauthenticated tool execution succeeded - OAuth might not be enforced"
else
    print_status "Unauthenticated tool execution response unclear"
fi

# Test 8: Test authenticated tool call (list namespaces)
print_oauth_status "Test 8: Testing authenticated tool call (listing namespaces)..."
NS_REQUEST='{
  "jsonrpc": "2.0",
  "id": "call-auth",
  "method": "tools/call",
  "params": {
    "name": "namespaces_list",
    "arguments": {}
  }
}'

NS_RESPONSE=$(send_mcp_request "$NS_REQUEST" "Calling namespaces_list tool with authentication...")

# Check if we got namespace data
if echo "$NS_RESPONSE" | grep -q '"content"'; then
    print_success "Authenticated tool call successful"
    # Try to extract and show some namespaces
    if echo "$NS_RESPONSE" | grep -q 'kubernetes-mcp-server\|default\|kube-system'; then
        echo "  Found namespaces in cluster:"
        echo "$NS_RESPONSE" | grep -o '\(kubernetes-mcp-server\|default\|kube-system\|kube-public\|openshift\)' | sort -u | head -5 | while read -r ns; do
            echo "    - $ns"
        done
    fi
else
    print_error "Authenticated tool call failed"
    echo "$NS_RESPONSE" | jq . 2>/dev/null || echo "$NS_RESPONSE" | head -5
fi

# Test 9: Test pods list in our namespace with authentication
print_oauth_status "Test 9: Testing authenticated pods list in $NAMESPACE namespace..."
PODS_REQUEST='{
  "jsonrpc": "2.0",
  "id": "call-pods",
  "method": "tools/call",
  "params": {
    "name": "pods_list_in_namespace",
    "arguments": {
      "namespace": "'"$NAMESPACE"'"
    }
  }
}'

PODS_RESPONSE=$(send_mcp_request "$PODS_REQUEST" "Listing pods in $NAMESPACE namespace with authentication...")

# Check if we got pod data
if echo "$PODS_RESPONSE" | grep -q '"content"'; then
    print_success "Authenticated pod list successful"
    if echo "$PODS_RESPONSE" | grep -q 'kubernetes-mcp-server'; then
        echo "  Found MCP server pod running in namespace"
    fi
else
    print_error "Authenticated pod list failed"
    echo "$PODS_RESPONSE" | jq . 2>/dev/null || echo "$PODS_RESPONSE" | head -5
fi

# Test 10: Test with invalid token
print_oauth_status "Test 10: Testing with invalid OAuth token..."
INVALID_TOKEN="invalid-token-$(date +%s)"
INVALID_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $INVALID_TOKEN" "$BASE_URL/mcp" 2>/dev/null || echo "000")

if [ "$INVALID_HTTP_CODE" = "401" ] || [ "$INVALID_HTTP_CODE" = "403" ]; then
    print_success "Invalid token properly rejected (HTTP $INVALID_HTTP_CODE)"
else
    print_warning "Invalid token response unexpected (HTTP $INVALID_HTTP_CODE)"
fi

# Test 11: Test Bearer token delegation validation
print_oauth_status "Test 11: Testing Bearer token delegation validation..."
CURRENT_USER=$(oc whoami 2>/dev/null || echo "unknown")
print_status "Current authenticated user: $CURRENT_USER"

# Test if the user has the required permissions for the delegate-urls
print_status "Checking if user has 'list namespaces' permission (required by delegate-urls)..."
CAN_LIST_NS=$(oc auth can-i list namespaces 2>/dev/null || echo "unknown")
if [ "$CAN_LIST_NS" = "yes" ]; then
    print_success "User can list namespaces - Bearer token delegation should work"
elif [ "$CAN_LIST_NS" = "no" ]; then
    print_error "User cannot list namespaces - Bearer token delegation will fail"
    print_status "The OAuth proxy is configured to require 'list namespaces' permission"
else
    print_warning "Cannot determine namespace list permissions"
fi

# Check if the server can access resources with this token
USER_REQUEST='{
  "jsonrpc": "2.0",
  "id": "user-test",
  "method": "tools/call",
  "params": {
    "name": "configuration_view",
    "arguments": {
      "minified": true
    }
  }
}'

USER_RESPONSE=$(send_mcp_request "$USER_REQUEST" "Testing configuration access with current user token...")

if echo "$USER_RESPONSE" | grep -q '"content"'; then
    print_success "User context properly validated - can access cluster configuration"
    # Try to extract current context
    if echo "$USER_RESPONSE" | grep -q 'current-context'; then
        CURRENT_CONTEXT=$(echo "$USER_RESPONSE" | grep -o 'current-context: [^[:space:]]*' | cut -d' ' -f2)
        echo "  Current context: $CURRENT_CONTEXT"
    fi
elif echo "$USER_RESPONSE" | grep -q '"error"'; then
    ERROR_MSG=$(echo "$USER_RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    print_warning "Configuration access failed: $ERROR_MSG"
    print_status "This might indicate RBAC restrictions for the current user"
else
    print_status "Configuration access response unclear"
fi

# Summary
echo ""
print_success "OAuth Testing completed!"
print_oauth_status "OAuth Authentication Summary:"
echo "  - OAuth token: ${GREEN}✓${NC} Successfully obtained (${#OAUTH_TOKEN} chars)"
echo "  - User context: $CURRENT_USER"
echo "  - Unauthenticated access: $([ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ] && echo "${GREEN}✓${NC} Properly rejected" || echo "${YELLOW}⚠${NC} May not be enforced")"
echo "  - Authenticated access: $([ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "405" ] && echo "${GREEN}✓${NC} Successful" || echo "${RED}✗${NC} Failed")"
echo "  - Invalid token rejection: $([ "$INVALID_HTTP_CODE" = "401" ] || [ "$INVALID_HTTP_CODE" = "403" ] && echo "${GREEN}✓${NC} Properly rejected" || echo "${YELLOW}⚠${NC} May not be enforced")"

print_status "MCP Protocol Summary:"
echo "  - Server accessible at: $BASE_URL/mcp"
echo "  - MCP initialize: $(echo "$INIT_RESPONSE" | grep -q '"protocolVersion"' && echo "${GREEN}✓${NC} Working with auth" || echo "${RED}✗${NC} Failed")"
echo "  - Tools available: $([ "$TOOL_COUNT" -gt 0 ] && echo "${GREEN}✓${NC} $TOOL_COUNT tools" || echo "${RED}✗${NC} None found")"
echo "  - Tool execution: $(echo "$NS_RESPONSE" | grep -q '"content"' && echo "${GREEN}✓${NC} Functional" || echo "${RED}✗${NC} Failed")"
echo "  - Kubernetes API access: $(echo "$PODS_RESPONSE" | grep -q '"content"' && echo "${GREEN}✓${NC} Functional" || echo "${RED}✗${NC} Failed")"

echo ""
print_status "For detailed logs, run: $KUBECTL_CMD logs -f deployment/kubernetes-mcp-server -n $NAMESPACE"
print_status "To test with different users, run 'oc login' with different credentials and re-run this script"

# Exit with appropriate code based on critical tests
if echo "$INIT_RESPONSE" | grep -q '"protocolVersion"' && [ "$TOOL_COUNT" -gt 0 ] && echo "$NS_RESPONSE" | grep -q '"content"'; then
    print_success "All critical OAuth tests passed!"
    exit 0
else
    print_error "Some critical OAuth tests failed!"
    exit 1
fi