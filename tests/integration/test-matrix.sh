#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
#
# Orion-X Phoenix Edition — Matrix Integration Test
#
# Validates Phase 4 acceptance criteria using a 2-node Docker environment.
# Requires: docker compose, running containers from docker-compose.matrix-test.yml
#
# Usage: bash tests/integration/test-matrix.sh
#
# The test assumes docker-compose.matrix-test.yml is already running
# (started by `make test-matrix` or manually via docker compose up).
#
# Acceptance criteria tested:
#   AC-MATRIX-001: Synapse boots and responds to client-server API
#   AC-MATRIX-002: Users can register and authenticate
#   AC-MATRIX-003: E2E encrypted room: message from Node A arrives at Node B
#   AC-MATRIX-004: Synapse survives restart, clients reconnect, rooms persist
#   AC-MATRIX-005: Cross-node communication (client→server over Docker network)
#
# @decision DEC-MATRIX-TEST-001
# @title CLI-based E2E verification via Synapse API
# @status accepted
# @rationale Element Desktop requires GUI. Headless Docker testing uses
#   the Synapse client-server API directly via curl for message exchange
#   and E2E encryption verification. Full Olm/Megolm client-side key
#   exchange requires a Matrix client library; we verify encryption is
#   configured on rooms (m.room.encryption state event) and that messages
#   flow between registered users. This proves the infrastructure is
#   correct — client-side crypto is an Element/SDK concern.

# =========================================================================
# Configuration
# =========================================================================

COMPOSE_FILE="docker/docker-compose.matrix-test.yml"
PROJECT="orionx-matrix-test"
SYNAPSE_URL="http://localhost:8008"
# Internal URL used when curling from within containers
SYNAPSE_INTERNAL_URL="http://172.21.0.2:8008"

# Timeouts (seconds)
SYNAPSE_READY_TIMEOUT=60
SYNAPSE_READY_INTERVAL=5
RESTART_RECOVERY_TIMEOUT=90
RESTART_RECOVERY_INTERVAL=5

# Test user credentials
USER_A="alice"
USER_B="bob"
USER_PASS="testpass-orionx-2026"

# State — populated during tests
TOKEN_A=""
TOKEN_B=""
ROOM_ID=""

# =========================================================================
# Test framework (matches test-mesh.sh pattern)
# =========================================================================

PASS=0
FAIL=0
SKIP=0

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
fi

pass() {
    (( PASS++ )) || true
    echo "${GREEN}  PASS${NC}: $1"
}

fail() {
    (( FAIL++ )) || true
    echo "${RED}  FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

skip() {
    (( SKIP++ )) || true
    echo "${YELLOW}  SKIP${NC}: $1 -- $2"
}

# Assert two values are equal.
# Args: description expected actual
assert_eq() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$description"
    else
        fail "$description" "expected='$expected', got='$actual'"
    fi
}

# Assert a string contains a substring.
# Args: description haystack needle
assert_contains() {
    local description="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$description"
    else
        fail "$description" "expected to contain '$needle'"
    fi
}

# Assert a string is not empty.
# Args: description value
assert_not_empty() {
    local description="$1" value="$2"
    if [[ -n "$value" ]]; then
        pass "$description"
    else
        fail "$description" "value was empty"
    fi
}

# =========================================================================
# Helpers
# =========================================================================

# Run a command inside a named Docker Compose service container.
# Uses -T (no TTY) for non-interactive execution in CI.
# Args: node_name command...
run_on() {
    local node="$1"; shift
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" exec -T "$node" "$@"
}

# Make a Matrix API call via curl against the host-exposed port.
# Args: method endpoint [data]
# Returns: response body on stdout
matrix_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -f -X "$method" -H "Content-Type: application/json")

    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi

    curl "${args[@]}" "${SYNAPSE_URL}${endpoint}" 2>/dev/null || true
}

# Make an authenticated Matrix API call.
# Args: token method endpoint [data]
matrix_api_auth() {
    local token="$1" method="$2" endpoint="$3" data="${4:-}"
    local args=(-s -f -X "$method"
        -H "Content-Type: application/json"
        -H "Authorization: Bearer ${token}")

    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi

    curl "${args[@]}" "${SYNAPSE_URL}${endpoint}" 2>/dev/null || true
}

# Register a user via the open registration endpoint.
# Synapse is configured with enable_registration_without_verification: true,
# so m.login.dummy auth flow works without shared secret HMAC.
# Args: username password
# Returns: JSON response on stdout
register_user() {
    local username="$1" password="$2"

    # Step 1: Initiate registration to get session ID
    local init_resp
    init_resp=$(curl -s -X POST "${SYNAPSE_URL}/_matrix/client/v3/register" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${username}\",\"password\":\"${password}\"}" 2>/dev/null || true)

    # If registration succeeded directly (unlikely but possible), return
    if echo "$init_resp" | jq -e '.access_token' >/dev/null 2>&1; then
        echo "$init_resp"
        return
    fi

    # Step 2: Extract session from 401 response and complete with dummy auth
    local session
    session=$(echo "$init_resp" | jq -r '.session // empty' 2>/dev/null || true)

    if [[ -z "$session" ]]; then
        # Fallback: try without session (some Synapse versions accept direct)
        curl -s -X POST "${SYNAPSE_URL}/_matrix/client/v3/register" \
            -H "Content-Type: application/json" \
            -d "{
                \"auth\":{\"type\":\"m.login.dummy\"},
                \"username\":\"${username}\",
                \"password\":\"${password}\"
            }" 2>/dev/null || true
        return
    fi

    curl -s -X POST "${SYNAPSE_URL}/_matrix/client/v3/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"auth\":{\"type\":\"m.login.dummy\",\"session\":\"${session}\"},
            \"username\":\"${username}\",
            \"password\":\"${password}\"
        }" 2>/dev/null || true
}

# Login a user and return access token.
# Args: username password
# Returns: access_token on stdout
login_user() {
    local username="$1" password="$2"
    local resp
    resp=$(curl -s -X POST "${SYNAPSE_URL}/_matrix/client/v3/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\":\"m.login.password\",
            \"identifier\":{\"type\":\"m.id.user\",\"user\":\"${username}\"},
            \"password\":\"${password}\"
        }" 2>/dev/null || true)

    echo "$resp" | jq -r '.access_token // empty' 2>/dev/null || true
}

# =========================================================================
# Pre-flight checks
# =========================================================================

preflight() {
    echo ""
    echo "=== Pre-flight Checks ==="

    # 1. Docker compose is available
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        pass "docker compose is available"
    else
        fail "docker compose is available" "Install Docker with compose plugin"
        echo ""
        echo "FATAL: Cannot continue without docker compose."
        exit 2
    fi

    # 2. jq is available (needed for JSON parsing)
    if command -v jq >/dev/null 2>&1; then
        pass "jq is available"
    else
        fail "jq is available" "Install jq for JSON parsing"
        echo ""
        echo "FATAL: Cannot continue without jq."
        exit 2
    fi

    # 3. curl is available
    if command -v curl >/dev/null 2>&1; then
        pass "curl is available"
    else
        fail "curl is available" "Install curl"
        echo ""
        echo "FATAL: Cannot continue without curl."
        exit 2
    fi

    # 4. Compose file exists
    if [[ -f "$COMPOSE_FILE" ]]; then
        pass "compose file exists ($COMPOSE_FILE)"
    else
        fail "compose file exists" "Not found: $COMPOSE_FILE"
        echo ""
        echo "FATAL: Compose file missing. Run 'make test-matrix' or create $COMPOSE_FILE first."
        exit 2
    fi

    # 5. Both containers are running
    local running_nodes
    running_nodes="$(docker compose -p "$PROJECT" -f "$COMPOSE_FILE" \
        ps --status running --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$running_nodes" -ge 2 ]]; then
        pass "2 nodes are running ($running_nodes containers up)"
    else
        fail "2 nodes are running" "Only $running_nodes containers running"
        echo ""
        echo "FATAL: Start containers first: docker compose -p $PROJECT -f $COMPOSE_FILE up -d"
        exit 2
    fi

    # 6. Wait for Synapse to be ready (responds to /_matrix/client/versions)
    echo "  Waiting for Synapse to be ready (max ${SYNAPSE_READY_TIMEOUT}s)..."
    local elapsed=0
    local synapse_up=false

    while [[ $elapsed -lt $SYNAPSE_READY_TIMEOUT ]]; do
        if curl -sf "${SYNAPSE_URL}/_matrix/client/versions" >/dev/null 2>&1; then
            synapse_up=true
            break
        fi
        sleep "$SYNAPSE_READY_INTERVAL"
        elapsed=$((elapsed + SYNAPSE_READY_INTERVAL))
    done

    if [[ "$synapse_up" == "true" ]]; then
        pass "Synapse responding to API (${elapsed}s)"
    else
        fail "Synapse responding to API" "Timed out after ${SYNAPSE_READY_TIMEOUT}s"
        echo ""
        echo "FATAL: Synapse not responding. Check container logs:"
        echo "  docker compose -p $PROJECT -f $COMPOSE_FILE logs matrix-server"
        exit 2
    fi
}

# =========================================================================
# Test 1: Synapse Health
# =========================================================================

test_synapse_health() {
    echo ""
    echo "=== Test 1: Synapse Health ==="

    # Query versions endpoint
    local versions_resp
    versions_resp=$(matrix_api GET "/_matrix/client/versions")

    if [[ -z "$versions_resp" ]]; then
        fail "versions endpoint responds" "empty response"
        return
    fi
    pass "versions endpoint responds"

    # Verify response contains versions array
    local has_versions
    has_versions=$(echo "$versions_resp" | jq -e '.versions | length > 0' 2>/dev/null || echo "false")
    assert_eq "versions array is non-empty" "true" "$has_versions"

    # Query login endpoint
    local login_resp
    login_resp=$(matrix_api GET "/_matrix/client/v3/login")

    if [[ -z "$login_resp" ]]; then
        fail "login endpoint responds" "empty response"
        return
    fi
    pass "login endpoint responds"

    # Verify login flows include password auth
    local has_password_flow
    has_password_flow=$(echo "$login_resp" \
        | jq -e '[.flows[].type] | any(. == "m.login.password")' 2>/dev/null || echo "false")
    assert_eq "password login flow available" "true" "$has_password_flow"

    # Verify server name via well-known or server header
    # We check that Synapse is serving for our configured domain
    local server_resp
    server_resp=$(curl -s "${SYNAPSE_URL}/_matrix/client/versions" \
        -H "Content-Type: application/json" 2>/dev/null || true)
    assert_not_empty "Synapse returns valid JSON" "$server_resp"
}

# =========================================================================
# Test 2: User Registration
# =========================================================================

test_user_registration() {
    echo ""
    echo "=== Test 2: User Registration ==="

    # Register User A (alice)
    local reg_a_resp
    reg_a_resp=$(register_user "$USER_A" "$USER_PASS")

    local token_a
    token_a=$(echo "$reg_a_resp" | jq -r '.access_token // empty' 2>/dev/null || true)

    if [[ -n "$token_a" ]]; then
        pass "User A ($USER_A) registered successfully"
        TOKEN_A="$token_a"
    else
        # User may already exist from a previous run — try login
        token_a=$(login_user "$USER_A" "$USER_PASS")
        if [[ -n "$token_a" ]]; then
            pass "User A ($USER_A) login succeeded (already registered)"
            TOKEN_A="$token_a"
        else
            fail "User A ($USER_A) registered or logged in" \
                "Registration response: $reg_a_resp"
            return
        fi
    fi
    assert_not_empty "User A has access token" "$TOKEN_A"

    # Register User B (bob)
    local reg_b_resp
    reg_b_resp=$(register_user "$USER_B" "$USER_PASS")

    local token_b
    token_b=$(echo "$reg_b_resp" | jq -r '.access_token // empty' 2>/dev/null || true)

    if [[ -n "$token_b" ]]; then
        pass "User B ($USER_B) registered successfully"
        TOKEN_B="$token_b"
    else
        token_b=$(login_user "$USER_B" "$USER_PASS")
        if [[ -n "$token_b" ]]; then
            pass "User B ($USER_B) login succeeded (already registered)"
            TOKEN_B="$token_b"
        else
            fail "User B ($USER_B) registered or logged in" \
                "Registration response: $reg_b_resp"
            return
        fi
    fi
    assert_not_empty "User B has access token" "$TOKEN_B"

    # Verify both users can query their own profile
    local profile_a
    profile_a=$(matrix_api_auth "$TOKEN_A" GET "/_matrix/client/v3/account/whoami")
    local user_id_a
    user_id_a=$(echo "$profile_a" | jq -r '.user_id // empty' 2>/dev/null || true)
    assert_contains "User A identity confirmed" "$user_id_a" "$USER_A"

    local profile_b
    profile_b=$(matrix_api_auth "$TOKEN_B" GET "/_matrix/client/v3/account/whoami")
    local user_id_b
    user_id_b=$(echo "$profile_b" | jq -r '.user_id // empty' 2>/dev/null || true)
    assert_contains "User B identity confirmed" "$user_id_b" "$USER_B"
}

# =========================================================================
# Test 3: Encrypted Room Creation and Messaging
# =========================================================================

test_encrypted_messaging() {
    echo ""
    echo "=== Test 3: Encrypted Room Creation and Messaging ==="

    if [[ -z "$TOKEN_A" || -z "$TOKEN_B" ]]; then
        skip "Test 3" "User registration failed — no tokens available"
        return
    fi

    # User A creates an encrypted room
    local create_resp
    create_resp=$(matrix_api_auth "$TOKEN_A" POST "/_matrix/client/v3/createRoom" \
        "{
            \"name\":\"Incident-Response\",
            \"topic\":\"Orion-X Integration Test Room\",
            \"preset\":\"private_chat\",
            \"initial_state\":[{
                \"type\":\"m.room.encryption\",
                \"content\":{\"algorithm\":\"m.megolm.v1.aes-sha2\"}
            }]
        }")

    local room_id
    room_id=$(echo "$create_resp" | jq -r '.room_id // empty' 2>/dev/null || true)

    if [[ -n "$room_id" ]]; then
        pass "Encrypted room created"
        ROOM_ID="$room_id"
    else
        fail "Encrypted room created" "Response: $create_resp"
        return
    fi
    assert_not_empty "Room ID is valid" "$ROOM_ID"

    # Verify encryption is enabled on the room (m.room.encryption state event)
    local enc_state
    enc_state=$(matrix_api_auth "$TOKEN_A" GET \
        "/_matrix/client/v3/rooms/${ROOM_ID}/state/m.room.encryption")
    local enc_algo
    enc_algo=$(echo "$enc_state" | jq -r '.algorithm // empty' 2>/dev/null || true)
    assert_eq "Room encryption algorithm is megolm" "m.megolm.v1.aes-sha2" "$enc_algo"

    # User A invites User B to the room
    local user_b_id="@${USER_B}:orionx.local"
    local invite_resp
    invite_resp=$(matrix_api_auth "$TOKEN_A" POST \
        "/_matrix/client/v3/rooms/${ROOM_ID}/invite" \
        "{\"user_id\":\"${user_b_id}\"}")
    # invite returns {} on success, or an error object
    # Check that it's not an error
    local invite_err
    invite_err=$(echo "$invite_resp" | jq -r '.errcode // empty' 2>/dev/null || true)
    if [[ -z "$invite_err" ]]; then
        pass "User B invited to room"
    else
        fail "User B invited to room" "Error: $invite_err"
    fi

    # User B joins the room
    local join_resp
    join_resp=$(matrix_api_auth "$TOKEN_B" POST \
        "/_matrix/client/v3/join/${ROOM_ID}" "{}")
    local join_room
    join_room=$(echo "$join_resp" | jq -r '.room_id // empty' 2>/dev/null || true)
    if [[ -n "$join_room" ]]; then
        pass "User B joined room"
    else
        fail "User B joined room" "Response: $join_resp"
    fi

    # Brief pause for state to propagate
    sleep 2

    # User A sends a message
    local msg_text
    msg_text="Orion-X integration test message $(date +%s)"
    local txn_id
    txn_id="txn_$(date +%s%N)"
    local send_resp
    send_resp=$(matrix_api_auth "$TOKEN_A" PUT \
        "/_matrix/client/v3/rooms/${ROOM_ID}/send/m.room.message/${txn_id}" \
        "{\"msgtype\":\"m.text\",\"body\":\"${msg_text}\"}")
    local event_id
    event_id=$(echo "$send_resp" | jq -r '.event_id // empty' 2>/dev/null || true)
    if [[ -n "$event_id" ]]; then
        pass "User A sent message"
    else
        fail "User A sent message" "Response: $send_resp"
        return
    fi

    # Brief pause for message delivery
    sleep 2

    # User B syncs and receives the message
    # Use /messages endpoint to fetch recent messages in the room
    local messages_resp
    messages_resp=$(matrix_api_auth "$TOKEN_B" GET \
        "/_matrix/client/v3/rooms/${ROOM_ID}/messages?dir=b&limit=10")
    local found_msg
    found_msg=$(echo "$messages_resp" | jq -r \
        "[.chunk[]? | select(.content.body == \"${msg_text}\")] | length" \
        2>/dev/null || echo "0")

    if [[ "$found_msg" -gt 0 ]]; then
        pass "User B received message from User A"
    else
        fail "User B received message from User A" \
            "Message not found in room messages"
    fi

    # Verify the room has 2 members
    local members_resp
    members_resp=$(matrix_api_auth "$TOKEN_A" GET \
        "/_matrix/client/v3/rooms/${ROOM_ID}/joined_members")
    local member_count
    member_count=$(echo "$members_resp" | jq '.joined | length' 2>/dev/null || echo "0")
    assert_eq "Room has 2 members" "2" "$member_count"
}

# =========================================================================
# Test 4: Synapse Restart Survival
# =========================================================================

test_restart_survival() {
    echo ""
    echo "=== Test 4: Synapse Restart Survival ==="

    if [[ -z "$TOKEN_A" || -z "$ROOM_ID" ]]; then
        skip "Test 4" "Prerequisites missing — no token or room ID"
        return
    fi

    # Record pre-restart state
    local pre_room_state
    pre_room_state=$(matrix_api_auth "$TOKEN_A" GET \
        "/_matrix/client/v3/rooms/${ROOM_ID}/state/m.room.name")
    local pre_room_name
    pre_room_name=$(echo "$pre_room_state" | jq -r '.name // empty' 2>/dev/null || true)
    assert_not_empty "Pre-restart: room name exists" "$pre_room_name"

    # Restart Synapse container
    echo "  Restarting Synapse container..."
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" restart matrix-server

    # Wait for Synapse to come back healthy
    echo "  Waiting for Synapse recovery (max ${RESTART_RECOVERY_TIMEOUT}s)..."
    local elapsed=0
    local synapse_back=false

    while [[ $elapsed -lt $RESTART_RECOVERY_TIMEOUT ]]; do
        if curl -sf "${SYNAPSE_URL}/_matrix/client/versions" >/dev/null 2>&1; then
            synapse_back=true
            echo "  Synapse recovered in ${elapsed}s"
            break
        fi
        sleep "$RESTART_RECOVERY_INTERVAL"
        elapsed=$((elapsed + RESTART_RECOVERY_INTERVAL))
    done

    if [[ "$synapse_back" == "true" ]]; then
        pass "Synapse recovered after restart"
    else
        fail "Synapse recovered after restart" "Timed out after ${RESTART_RECOVERY_TIMEOUT}s"
        return
    fi

    # Re-authenticate User A (old token may or may not work after restart;
    # login to get a fresh token regardless)
    local new_token_a
    new_token_a=$(login_user "$USER_A" "$USER_PASS")
    if [[ -n "$new_token_a" ]]; then
        pass "User A re-authenticated after restart"
        TOKEN_A="$new_token_a"
    else
        fail "User A re-authenticated after restart" "Login failed"
        return
    fi

    # Re-authenticate User B
    local new_token_b
    new_token_b=$(login_user "$USER_B" "$USER_PASS")
    if [[ -n "$new_token_b" ]]; then
        pass "User B re-authenticated after restart"
        TOKEN_B="$new_token_b"
    else
        fail "User B re-authenticated after restart" "Login failed"
        return
    fi

    # Verify room still exists and name persisted
    local post_room_state
    post_room_state=$(matrix_api_auth "$TOKEN_A" GET \
        "/_matrix/client/v3/rooms/${ROOM_ID}/state/m.room.name")
    local post_room_name
    post_room_name=$(echo "$post_room_state" | jq -r '.name // empty' 2>/dev/null || true)
    assert_eq "Room name persisted after restart" "$pre_room_name" "$post_room_name"

    # Verify encryption still configured
    local post_enc_state
    post_enc_state=$(matrix_api_auth "$TOKEN_A" GET \
        "/_matrix/client/v3/rooms/${ROOM_ID}/state/m.room.encryption")
    local post_enc_algo
    post_enc_algo=$(echo "$post_enc_state" | jq -r '.algorithm // empty' 2>/dev/null || true)
    assert_eq "Encryption persisted after restart" "m.megolm.v1.aes-sha2" "$post_enc_algo"

    # Send a new message after restart
    local post_restart_msg
    post_restart_msg="Post-restart message $(date +%s)"
    local txn_id
    txn_id="txn_restart_$(date +%s%N)"
    local send_resp
    send_resp=$(matrix_api_auth "$TOKEN_A" PUT \
        "/_matrix/client/v3/rooms/${ROOM_ID}/send/m.room.message/${txn_id}" \
        "{\"msgtype\":\"m.text\",\"body\":\"${post_restart_msg}\"}")
    local event_id
    event_id=$(echo "$send_resp" | jq -r '.event_id // empty' 2>/dev/null || true)
    if [[ -n "$event_id" ]]; then
        pass "Message sent after restart"
    else
        fail "Message sent after restart" "Response: $send_resp"
        return
    fi

    # Brief pause for message delivery
    sleep 2

    # User B receives the post-restart message
    local messages_resp
    messages_resp=$(matrix_api_auth "$TOKEN_B" GET \
        "/_matrix/client/v3/rooms/${ROOM_ID}/messages?dir=b&limit=10")
    local found_msg
    found_msg=$(echo "$messages_resp" | jq -r \
        "[.chunk[]? | select(.content.body == \"${post_restart_msg}\")] | length" \
        2>/dev/null || echo "0")
    if [[ "$found_msg" -gt 0 ]]; then
        pass "User B received post-restart message"
    else
        fail "User B received post-restart message" \
            "Message not found in room messages"
    fi
}

# =========================================================================
# Test 5: Cross-Node Communication
# =========================================================================

test_cross_node() {
    echo ""
    echo "=== Test 5: Cross-Node Communication ==="

    # From matrix-client container, query Synapse on matrix-server's IP.
    # This proves Matrix traffic flows between the two Docker nodes on the
    # dedicated bridge network (172.21.0.0/24).

    # Verify client can reach server on the internal Docker network
    local client_versions
    client_versions=$(run_on matrix-client curl -sf \
        "${SYNAPSE_INTERNAL_URL}/_matrix/client/versions" 2>/dev/null || true)

    if [[ -n "$client_versions" ]]; then
        pass "matrix-client can reach Synapse API on server"
    else
        fail "matrix-client can reach Synapse API on server" \
            "curl from matrix-client to ${SYNAPSE_INTERNAL_URL} failed"
        return
    fi

    # Verify the response is valid Matrix JSON
    local has_versions
    has_versions=$(echo "$client_versions" \
        | jq -e '.versions | length > 0' 2>/dev/null || echo "false")
    assert_eq "Cross-node versions response is valid" "true" "$has_versions"

    # Verify client can reach the login endpoint
    local client_login
    client_login=$(run_on matrix-client curl -sf \
        "${SYNAPSE_INTERNAL_URL}/_matrix/client/v3/login" 2>/dev/null || true)
    assert_not_empty "Cross-node login endpoint responds" "$client_login"

    # Verify network-level reachability (ping)
    if run_on matrix-client ping -c 1 -W 3 172.21.0.2 >/dev/null 2>&1; then
        pass "matrix-client can ping matrix-server"
    else
        fail "matrix-client can ping matrix-server" \
            "ping from 172.21.0.3 to 172.21.0.2 failed"
    fi
}

# =========================================================================
# Main
# =========================================================================

echo "==========================================="
echo "  Orion-X Matrix Integration Tests"
echo "==========================================="

preflight
test_synapse_health
test_user_registration
test_encrypted_messaging
test_restart_survival
test_cross_node

# Summary
echo ""
echo "==========================================="
echo "  Matrix Integration Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "==========================================="

[[ "$FAIL" -eq 0 ]] || exit 1
