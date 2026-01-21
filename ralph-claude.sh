#!/bin/bash

# Ralph Loop - Autonomous Agent Iteration System for TFE Setup
# This script orchestrates Claude Code agents to complete stories from prd.json

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MAX_ITERATIONS=${MAX_ITERATIONS:-20}
PAUSE_BETWEEN_ITERATIONS=2
PRD_FILE="prd.json"
PROMPT_FILE="prompt.md"
PROGRESS_FILE="progress.txt"
AGENTS_FILE="AGENTS.md"

# Functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v claude &> /dev/null; then
        error "Claude CLI not found. Please install it first."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        error "jq not found. Please install it first (brew install jq)."
        exit 1
    fi

    if [ ! -f "$PRD_FILE" ]; then
        error "$PRD_FILE not found. Please create it first."
        exit 1
    fi

    if [ ! -f "$PROMPT_FILE" ]; then
        error "$PROMPT_FILE not found. Please create it first."
        exit 1
    fi

    success "All prerequisites met."
}

# Count incomplete stories
count_incomplete_stories() {
    jq '[.stories[] | select(.passes == false)] | length' "$PRD_FILE"
}

# Get next incomplete story
get_next_story() {
    jq -r '.stories[] | select(.passes == false) | "\(.id): \(.title)"' "$PRD_FILE" | head -1
}

# Get next story details
get_next_story_details() {
    jq '.stories[] | select(.passes == false) | {id, title, description, acceptanceCriteria}' "$PRD_FILE" | head -20
}

# Run Claude agent for one iteration
run_agent() {
    local iteration=$1
    local story_info=$(get_next_story)

    info "Iteration $iteration: Working on $story_info"

    local prompt="You are an AI agent working on setting up TFE on Kubernetes.

CRITICAL: Read these files FIRST before doing anything:
1. prompt.md - Contains project requirements and context
2. progress.txt - Contains learnings from previous iterations
3. AGENTS.md - Contains patterns and gotchas to follow/avoid

Your task for this iteration:
1. Find the FIRST story in prd.json where 'passes' is false
2. Implement that story completely, meeting ALL acceptance criteria
3. Test and verify your implementation works
4. Update prd.json to set passes=true for the completed story
5. Append your learnings to progress.txt in this format:
   [ITERATION $iteration] Story-X: Title - COMPLETE
   -------------------------------------------
   What was implemented:
   - Key changes made

   Learnings/Gotchas:
   - Issues encountered and solutions

6. Update AGENTS.md if you discovered new patterns or gotchas

IMPORTANT RULES:
- Only mark a story as complete when ALL acceptance criteria are met
- Test everything before marking complete
- If you encounter errors, fix them before proceeding
- Document everything you learn in progress.txt
- Update AGENTS.md with new patterns you discover

Current story to implement:
$story_info

Story details:
$(get_next_story_details)"

    # Run Claude with retry logic for rate limiting
    local max_retries=5
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        info "Attempting to run Claude agent (attempt $((retry_count + 1))/$max_retries)..."

        if claude -p --dangerously-skip-permissions "$prompt" 2>&1; then
            success "Agent completed successfully"
            return 0
        else
            local exit_code=$?
            warning "Agent exited with code $exit_code"

            # Check if it's a rate limit error
            if [ $exit_code -eq 1 ]; then
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    warning "Possible rate limit. Waiting 60 seconds before retry..."
                    sleep 60
                fi
            else
                error "Agent failed with non-recoverable error"
                return 1
            fi
        fi
    done

    error "Max retries reached. Agent failed."
    return 1
}

# Main loop
main() {
    echo ""
    echo "========================================"
    echo "  Ralph Loop - TFE Setup Orchestrator  "
    echo "========================================"
    echo ""

    check_prerequisites

    local iteration=1

    while [ $iteration -le $MAX_ITERATIONS ]; do
        echo ""
        echo "----------------------------------------"
        echo "  Iteration $iteration of $MAX_ITERATIONS"
        echo "----------------------------------------"

        local incomplete=$(count_incomplete_stories)

        if [ "$incomplete" -eq 0 ]; then
            echo ""
            success "=========================================="
            success "  ALL STORIES COMPLETE!"
            success "  TFE Setup finished in $((iteration - 1)) iterations"
            success "=========================================="
            exit 0
        fi

        info "Remaining stories: $incomplete"
        info "Next story: $(get_next_story)"

        if run_agent $iteration; then
            success "Iteration $iteration completed"
        else
            error "Iteration $iteration failed"
            warning "You may need to manually fix issues and restart"
            exit 1
        fi

        iteration=$((iteration + 1))

        if [ $iteration -le $MAX_ITERATIONS ]; then
            info "Pausing $PAUSE_BETWEEN_ITERATIONS seconds before next iteration..."
            sleep $PAUSE_BETWEEN_ITERATIONS
        fi
    done

    warning "Max iterations ($MAX_ITERATIONS) reached"
    warning "Remaining incomplete stories: $(count_incomplete_stories)"
    exit 1
}

# Run main
main "$@"
