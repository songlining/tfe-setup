#!/bin/bash
set -e

echo "Setting up TFE Setup environment..."

# Create Claude Code config directory if it doesn't exist
mkdir -p ~/.claude

# Configure Claude Code settings for dangerously skip permissions mode
cat > ~/.claude/settings.json << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "Glob(*)",
      "Grep(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "TodoWrite(*)",
      "Task(*)",
      "NotebookEdit(*)"
    ],
    "deny": []
  },
  "autoApprove": true
}
EOF

# Verify installations
echo ""
echo "Verifying tool installations..."
echo ""

echo "Terraform version:"
terraform version

echo ""
echo "Kind version:"
kind version

echo ""
echo "kubectl version:"
kubectl version --client 2>/dev/null || echo "kubectl client installed"

echo ""
echo "=============================================="
echo "  TFE Setup Environment Ready!"
echo "=============================================="
echo ""
echo "Installed tools:"
echo "  - Terraform (latest)"
echo "  - Kind (Kubernetes in Docker)"
echo "  - kubectl"
echo "  - helm"
echo "  - Docker-in-Docker"
echo ""
echo "Environment variables set:"
echo "  CLAUDE_CODE_DANGEROUSLY_SKIP_PERMISSIONS=true"
echo ""
echo "To create a kind cluster:"
echo "  kind create cluster --name my-cluster"
echo ""
echo "To run Claude Code:"
echo "  claude --dangerously-skip-permissions"
echo ""
