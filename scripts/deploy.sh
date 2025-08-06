#!/bin/bash

# deploy.sh - Deploy the Kubernetes MCP Server to OpenShift/Kubernetes

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
    print_status "Using OpenShift CLI (oc)"
elif command -v kubectl &> /dev/null; then
    KUBECTL_CMD="kubectl"
    print_status "Using Kubernetes CLI (kubectl)"
else
    print_error "Neither kubectl nor oc command found. Please install one of them."
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

# Deploy to Kubernetes/OpenShift
print_status "Deploying to $NAMESPACE namespace..."
# Replace the namespace placeholder in ClusterRoleBinding and apply with namespace
sed "s/NAMESPACE_PLACEHOLDER/$NAMESPACE/g" k8s/deployment.yaml | $KUBECTL_CMD apply -n $NAMESPACE -f -
if [ $? -eq 0 ]; then
    print_success "Application deployed successfully"
else
    print_error "Failed to deploy application"
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

# Get route URL if on OpenShift
if [ "$KUBECTL_CMD" = "oc" ]; then
    ROUTE_URL=$($KUBECTL_CMD get route kubernetes-mcp-server -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ ! -z "$ROUTE_URL" ]; then
        print_success "Application accessible at: https://$ROUTE_URL"
    fi
fi

print_success "Deployment completed successfully!"
print_status "You can view logs with: $KUBECTL_CMD logs -f deployment/kubernetes-mcp-server -n $NAMESPACE"
print_status "You can check status with: $KUBECTL_CMD get pods -n $NAMESPACE"