#!/bin/bash

# cleanup.sh - Remove the Kubernetes MCP Server deployment from OpenShift/Kubernetes

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

# Delete resources
print_status "Deleting resources from namespace '$NAMESPACE'..."
sed "s/NAMESPACE_PLACEHOLDER/$NAMESPACE/g" k8s/deployment.yaml | $KUBECTL_CMD delete -n $NAMESPACE -f - --ignore-not-found=true
if [ $? -eq 0 ]; then
    print_success "Resources deleted successfully"
else
    print_warning "Some resources may not have been deleted"
fi

# Delete namespace
print_status "Deleting namespace '$NAMESPACE'..."
if $KUBECTL_CMD delete namespace $NAMESPACE --ignore-not-found=true; then
    print_success "Namespace deleted"
else
    print_warning "Failed to delete namespace"
fi

print_success "Cleanup completed!"