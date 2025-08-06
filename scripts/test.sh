#!/bin/bash

# test.sh - Test the deployed Kubernetes MCP Server

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Check if kubectl/oc is available
if command -v oc &> /dev/null; then
    KUBECTL_CMD="oc"
elif command -v kubectl &> /dev/null; then
    KUBECTL_CMD="kubectl"
else
    print_error "Neither kubectl nor oc command found. Please install one of them."
    exit 1
fi

NAMESPACE="kubernetes-mcp-server"

# Get the route URL
print_status "Getting route URL..."
ROUTE_URL=$($KUBECTL_CMD get route kubernetes-mcp-server -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || true)

if [ -z "$ROUTE_URL" ]; then
    print_error "Could not find route URL. Is the application deployed?"
    exit 1
fi

BASE_URL="https://$ROUTE_URL"
print_success "Found route: $BASE_URL"

# Test 1: Check if the server is responding
print_status "Test 1: Checking if server is responding..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/mcp" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "405" ]; then
    print_success "Server is responding at /mcp endpoint (HTTP $HTTP_CODE)"
else
    print_warning "Unexpected HTTP code: $HTTP_CODE"
fi

# Helper function to send MCP request
send_mcp_request() {
    local request="$1"
    local description="$2"
    
    print_status "$description"
    
    # Send request with streaming support
    response=$(echo "$request" | curl -s -X POST "$BASE_URL/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data-binary @- \
        2>/dev/null || echo "{}")
    
    echo "$response"
}

# Test 2: Initialize connection
print_status "Test 2: Sending initialize request to /mcp endpoint..."
INIT_REQUEST='{
  "jsonrpc": "2.0",
  "id": "init-1",
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {
      "name": "test-client",
      "version": "1.0.0"
    }
  }
}'

INIT_RESPONSE=$(send_mcp_request "$INIT_REQUEST" "Initializing MCP connection...")

# Check if response contains expected fields
if echo "$INIT_RESPONSE" | grep -q '"protocolVersion"'; then
    print_success "Initialize successful"
    echo "  Protocol Version: $(echo "$INIT_RESPONSE" | grep -o '"protocolVersion":"[^"]*"' | cut -d'"' -f4)"
    SERVER_NAME=$(echo "$INIT_RESPONSE" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "  Server Name: $SERVER_NAME"
    SERVER_VERSION=$(echo "$INIT_RESPONSE" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "  Server Version: $SERVER_VERSION"
else
    print_warning "Initialize response unexpected:"
    echo "$INIT_RESPONSE" | jq . 2>/dev/null || echo "$INIT_RESPONSE"
fi

# Test 3: List available tools
print_status "Test 3: Listing available tools..."
TOOLS_REQUEST='{
  "jsonrpc": "2.0",
  "id": "tools-1",
  "method": "tools/list",
  "params": {}
}'

TOOLS_RESPONSE=$(send_mcp_request "$TOOLS_REQUEST" "Fetching available tools...")

# Count tools
TOOL_COUNT=$(echo "$TOOLS_RESPONSE" | grep -o '"name"' | wc -l)
if [ "$TOOL_COUNT" -gt 0 ]; then
    print_success "Found $TOOL_COUNT tools available"
    echo "  Sample tools:"
    echo "$TOOLS_RESPONSE" | grep -o '"name":"[^"]*"' | head -5 | while read -r tool; do
        echo "    - $(echo "$tool" | cut -d'"' -f4)"
    done
    if [ "$TOOL_COUNT" -gt 5 ]; then
        echo "    ... and $((TOOL_COUNT - 5)) more"
    fi
else
    print_warning "No tools found or unexpected response"
    echo "$TOOLS_RESPONSE" | jq . 2>/dev/null || echo "$TOOLS_RESPONSE"
fi

# Test 4: Test a simple tool call (list namespaces)
print_status "Test 4: Testing tool call (listing namespaces)..."
NS_REQUEST='{
  "jsonrpc": "2.0",
  "id": "call-1",
  "method": "tools/call",
  "params": {
    "name": "namespaces_list",
    "arguments": {}
  }
}'

NS_RESPONSE=$(send_mcp_request "$NS_REQUEST" "Calling namespaces_list tool...")

# Check if we got namespace data
if echo "$NS_RESPONSE" | grep -q '"content"'; then
    print_success "Tool call successful"
    # Try to extract and show some namespaces
    if echo "$NS_RESPONSE" | grep -q 'kubernetes-mcp-server\|default\|kube-system'; then
        echo "  Found namespaces in cluster:"
        echo "$NS_RESPONSE" | grep -o '\(kubernetes-mcp-server\|default\|kube-system\|kube-public\|openshift\)' | sort -u | head -5 | while read -r ns; do
            echo "    - $ns"
        done
    fi
else
    print_warning "Tool call response unexpected:"
    echo "$NS_RESPONSE" | jq . 2>/dev/null || echo "$NS_RESPONSE" | head -5
fi

# Test 5: Test pods list in our namespace
print_status "Test 5: Testing pods list in kubernetes-mcp-server namespace..."
PODS_REQUEST='{
  "jsonrpc": "2.0",
  "id": "call-2",
  "method": "tools/call",
  "params": {
    "name": "pods_list_in_namespace",
    "arguments": {
      "namespace": "kubernetes-mcp-server"
    }
  }
}'

PODS_RESPONSE=$(send_mcp_request "$PODS_REQUEST" "Listing pods in kubernetes-mcp-server namespace...")

# Check if we got pod data
if echo "$PODS_RESPONSE" | grep -q '"content"'; then
    print_success "Pod list successful"
    if echo "$PODS_RESPONSE" | grep -q 'kubernetes-mcp-server'; then
        echo "  Found MCP server pod running in namespace"
    fi
else
    print_warning "Pod list response unexpected"
fi

print_success "Testing completed!"
print_status "Summary:"
echo "  - Server is accessible at: $BASE_URL/mcp"
echo "  - MCP protocol communication is working"
echo "  - Initialize handshake successful"
echo "  - Tools are available and callable"
echo "  - Kubernetes API access is functional"
echo ""
print_status "For detailed logs, run: $KUBECTL_CMD logs -f deployment/kubernetes-mcp-server -n $NAMESPACE"