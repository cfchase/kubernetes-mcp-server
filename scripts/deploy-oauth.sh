#!/bin/bash

# deploy-oauth.sh - Deploy the Kubernetes MCP Server with OAuth proxy to OpenShift

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

# Function to generate secure random string
generate_cookie_secret() {
    # Generate exactly 24 random bytes and base64 encode them (32 chars)
    # OAuth proxy expects a base64-encoded 24-byte secret for AES-192
    # This produces exactly 32 base64 characters without padding
    openssl rand -base64 24 | tr -d '\n'
}

# Check if kubectl/oc is available
if command -v oc &> /dev/null; then
    KUBECTL_CMD="oc"
    print_status "Using OpenShift CLI (oc)"
elif command -v kubectl &> /dev/null; then
    KUBECTL_CMD="kubectl"
    print_status "Using Kubernetes CLI (kubectl)"
    print_warning "OAuth proxy requires OpenShift. This deployment may not work on plain Kubernetes."
else
    print_error "Neither kubectl nor oc command found. Please install one of them."
    exit 1
fi

# Check if openssl is available for generating cookie secret
if ! command -v openssl &> /dev/null; then
    print_error "openssl command not found. Required for generating secure cookie secret."
    exit 1
fi

# Check if we can connect to the cluster
print_status "Checking cluster connectivity..."
if ! $KUBECTL_CMD cluster-info &> /dev/null; then
    print_error "Cannot connect to Kubernetes/OpenShift cluster. Please check your kubeconfig."
    exit 1
fi

print_success "Connected to cluster"

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

# Create namespace if it doesn't exist
print_status "Creating namespace '$NAMESPACE' if it doesn't exist..."
if $KUBECTL_CMD get namespace $NAMESPACE &> /dev/null; then
    print_status "Namespace '$NAMESPACE' already exists"
else
    if $KUBECTL_CMD create namespace $NAMESPACE; then
        print_success "Namespace '$NAMESPACE' created"
    else
        print_error "Failed to create namespace"
        exit 1
    fi
fi

# Generate secure cookie secret
print_status "Generating secure cookie secret..."
COOKIE_SECRET=$(generate_cookie_secret)
if [ -z "$COOKIE_SECRET" ]; then
    print_error "Failed to generate cookie secret"
    exit 1
fi
print_success "Cookie secret generated (${#COOKIE_SECRET} characters)"

# Deploy to OpenShift with OAuth
print_status "Deploying OAuth-protected application to $NAMESPACE namespace..."

# Replace placeholders and apply deployment
sed -e "s|NAMESPACE_PLACEHOLDER|$NAMESPACE|g" \
    -e "s|--cookie-secret=SECRET|--cookie-secret=$COOKIE_SECRET|g" \
    k8s/deployment-oauth.yaml | $KUBECTL_CMD apply -n $NAMESPACE -f -

if [ $? -eq 0 ]; then
    print_success "OAuth-protected application deployed successfully"
else
    print_error "Failed to deploy OAuth-protected application"
    exit 1
fi

# Wait for deployment to be ready
print_status "Waiting for deployment to be ready..."
if $KUBECTL_CMD wait --for=condition=available --timeout=300s deployment/kubernetes-mcp-server -n $NAMESPACE; then
    print_success "Deployment is ready"
else
    print_warning "Deployment may not be fully ready yet. Check status with: $KUBECTL_CMD get pods -n $NAMESPACE"
fi

# Show deployment status
print_status "Deployment status:"
$KUBECTL_CMD get all -n $NAMESPACE

# Get route URL (OAuth-protected)
print_status "Getting OAuth-protected route URL..."
ROUTE_URL=$($KUBECTL_CMD get route kubernetes-mcp-server -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || true)

if [ ! -z "$ROUTE_URL" ]; then
    print_success "OAuth-protected application accessible at: https://$ROUTE_URL"
    echo
    print_status "OAuth Authentication Information:"
    echo "  • This application is protected by OpenShift OAuth"
    echo "  • Users must authenticate with their OpenShift credentials"
    echo "  • Access is granted based on OpenShift RBAC permissions"
    echo "  • Sessions expire after 24 hours with 1-hour refresh window"
    echo
    print_status "To access the application:"
    echo "  1. Navigate to: https://$ROUTE_URL"
    echo "  2. You will be redirected to OpenShift login"
    echo "  3. Authenticate with your OpenShift credentials"
    echo "  4. You will be redirected back to the application"
    echo
    print_status "Cookie Settings:"
    echo "  • SameSite: Strict (enhanced security)"
    echo "  • HttpOnly: True (XSS protection)"
    echo "  • Secure: True (HTTPS only)"
    echo "  • Expire: 24 hours"
    echo "  • Refresh: 1 hour"
else
    print_warning "Could not retrieve route URL. The route may not be created yet."
    print_status "Check route status with: $KUBECTL_CMD get route -n $NAMESPACE"
fi

print_success "OAuth deployment completed successfully!"
print_status "Useful commands:"
echo "  View logs: $KUBECTL_CMD logs -f deployment/kubernetes-mcp-server -c kubernetes-mcp-server -n $NAMESPACE"
echo "  OAuth proxy logs: $KUBECTL_CMD logs -f deployment/kubernetes-mcp-server -c oauth-proxy -n $NAMESPACE"
echo "  Check pods: $KUBECTL_CMD get pods -n $NAMESPACE"
echo "  Check route: $KUBECTL_CMD get route -n $NAMESPACE"
echo "  Debug OAuth: $KUBECTL_CMD describe route kubernetes-mcp-server -n $NAMESPACE"