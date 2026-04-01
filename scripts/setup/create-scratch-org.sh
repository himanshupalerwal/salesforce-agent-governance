#!/bin/bash
# AgentGov - Scratch Org Setup Script
# Usage: ./scripts/setup/create-scratch-org.sh
set -e

echo "============================================"
echo "  AgentGov - Scratch Org Setup"
echo "============================================"

# Create scratch org
echo ""
echo "1. Creating scratch org..."
sf org create scratch -f config/project-scratch-def.json -a AgentGov -d 30 -w 10

# Deploy source
echo ""
echo "2. Deploying source..."
sf project deploy start -o AgentGov

# Assign permission set
echo ""
echo "3. Assigning AgentGov_Admin permission set..."
sf org assign permset -n AgentGov_Admin -o AgentGov

# Load sample data
echo ""
echo "4. Loading sample data..."
sf apex run -f scripts/setup/load-sample-data.apex -o AgentGov

# Open the org
echo ""
echo "5. Opening org..."
sf org open -o AgentGov -p lightning/n/AgentGov_Registration__c

echo ""
echo "============================================"
echo "  Setup Complete!"
echo ""
echo "  Org alias: AgentGov"
echo "  Permission set: AgentGov_Admin (assigned)"
echo "  Sample data: Loaded"
echo ""
echo "  Open the AgentGov app in App Launcher"
echo "  to see the dashboard."
echo "============================================"
