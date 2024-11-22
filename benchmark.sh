#!/bin/bash

# Enable job control
set -m

# Trap Ctrl+C and cleanup
cleanup() {
  echo -e "\nCleaning up..."
  if [ -n "$SERVER_PID" ]; then
    echo "Killing server process $SERVER_PID"
    kill -9 "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  if [ -n "$CURRENT_PORT" ]; then
    echo "Cleaning up port $CURRENT_PORT"
    lsof -ti:"$CURRENT_PORT" | xargs kill -9 2>/dev/null
  fi
  exit 1
}
trap cleanup SIGINT SIGTERM

# Directories for requests and cold-starts tests
REQUESTS_DIR="./requests"
COLD_STARTS_DIR="./cold-starts"

# Output directory for results
RESULTS_DIR="./results-requests"
mkdir -p "$RESULTS_DIR"

# Function to get port from package.json, source files, or framework defaults
get_framework_port() {
  local FRAMEWORK_DIR=$(basename "$(pwd)")
  local DEFAULT_PORT=3000

  # Framework-specific port detection
  case "$FRAMEWORK_DIR" in
  "bun" | "bun-schema")
    DEFAULT_PORT=3040
    ;;

  "fastify" | "fastify-schema" | "fastify-v5" | "fastify-v5-schema")
    if [ -f "main.js" ]; then
      local PORT_IN_FILE
      PORT_IN_FILE=$(grep -E 'port:.*[0-9]+' main.js | grep -oE '[0-9]+')
      if [ -n "$PORT_IN_FILE" ]; then
        echo "$PORT_IN_FILE"
        return
      fi
    fi
    DEFAULT_PORT=3030
    ;;

  "express")
    if [ -f "main.js" ]; then
      local PORT_IN_FILE
      PORT_IN_FILE=$(grep -E 'port.*=.*[0-9]+' main.js | grep -oE '[0-9]+')
      if [ -n "$PORT_IN_FILE" ]; then
        echo "$PORT_IN_FILE"
        return
      fi
    fi
    DEFAULT_PORT=3030
    ;;

  "hono" | "hono-schema")
    if [ -f "src/index.ts" ]; then
      local PORT_IN_FILE
      PORT_IN_FILE=$(grep -E 'port:.*[0-9]+' src/index.ts | grep -oE '[0-9]+')
      if [ -n "$PORT_IN_FILE" ]; then
        echo "$PORT_IN_FILE"
        return
      fi
    fi
    DEFAULT_PORT=3000
    ;;

  "elysia" | "elysia-schema")
    if [ -f "src/index.ts" ]; then
      local PORT_IN_FILE
      PORT_IN_FILE=$(grep -E '\.listen\([0-9]+' src/index.ts | grep -oE '[0-9]+')
      if [ -n "$PORT_IN_FILE" ]; then
        echo "$PORT_IN_FILE"
        return
      fi
    fi
    DEFAULT_PORT=3000
    ;;

  "encore")
    DEFAULT_PORT=4000
    ;;

  "nestjs")
    if [ -f "src/main.ts" ]; then
      local PORT_IN_FILE
      PORT_IN_FILE=$(grep -E 'await app\.listen\([0-9]+' src/main.ts | grep -oE '[0-9]+')
      if [ -n "$PORT_IN_FILE" ]; then
        echo "$PORT_IN_FILE"
        return
      fi
    fi
    DEFAULT_PORT=3000
    ;;
  esac

  # Check package.json if exists
  if [ -f "package.json" ]; then
    local PORT_IN_START
    PORT_IN_START=$(jq -r '.scripts.start | select(. != null) | scan("PORT=([0-9]+)")[]' package.json 2>/dev/null)
    if [ -n "$PORT_IN_START" ]; then
      echo "$PORT_IN_START"
      return
    fi

    local PORT_IN_CONFIG
    PORT_IN_CONFIG=$(jq -r '.config.port | select(. != null)' package.json 2>/dev/null)
    if [ -n "$PORT_IN_CONFIG" ]; then
      echo "$PORT_IN_CONFIG"
      return
    fi
  fi

  echo "$DEFAULT_PORT"
}

# Function to ensure port is free
ensure_port_free() {
  local PORT=$1
  echo "Ensuring port $PORT is free..."
  lsof -ti:"$PORT" | xargs kill -9 2>/dev/null
  sleep 2
}

# Common load testing function
run_load_test() {
  local PORT=$1
  local ENDPOINT=$2
  local METHOD=$3
  local DATA=$4
  local FOLDER_NAME=$5
  local SCHEMA=$6

  echo "Running load test for $FOLDER_NAME with $SCHEMA validation on port $PORT..."
  if [ "$SCHEMA" == "schema" ]; then
    oha -c 150 -z 10s -m "$METHOD" -H 'Content-Type: application/json' -H 'x-foo: test' \
      "http://127.0.0.1:$PORT/$ENDPOINT?name=test&excitement=123" -d "$DATA" --latency-correction --disable-keepalive --json \
      >"$RESULTS_DIR/${FOLDER_NAME}_${SCHEMA}.json"
  else
    oha -c 150 -z 10s -m "$METHOD" "http://127.0.0.1:$PORT/$ENDPOINT" --latency-correction --disable-keepalive --json \
      >"$RESULTS_DIR/${FOLDER_NAME}_${SCHEMA}.json"
  fi
}

# Load test settings
DATA='{"someKey": "test", "someOtherKey": 123, "requiredKey": [123, 456, 789], "nullableKey": null, "multipleTypesKey": true, "multipleRestrictedTypesKey": "test", "enumKey": "John"}'

# Function to install dependencies using npm or bun
install_dependencies() {
  if [ -f "package-lock.json" ]; then
    echo "Using npm to install dependencies"
    npm install
    return 0
  elif [ -f "bun.lockb" ]; then
    echo "Using bun to install dependencies"
    bun install
    return 0
  else
    echo "No lock file found. Skipping dependency installation."
    return 1
  fi
}

# Add these debug functions at the start
debug_file_check() {
  local dir=$1
  echo "DEBUG: Directory contents of $dir:"
  ls -la "$dir"
  echo "DEBUG: package.json content (if exists):"
  [ -f "package.json" ] && cat package.json
  echo "DEBUG: Directory tree structure:"
  tree -L 2 2>/dev/null || ls -R
}

start_server() {
  local SERVER_PID
  local TIMEOUT=30 # Timeout in seconds
  local START_TIME
  local CURRENT_TIME

  echo "DEBUG: Current directory before starting server: $(pwd)"
  debug_file_check "$(pwd)"

  # Get the port for this framework
  local FRAMEWORK_PORT
  FRAMEWORK_PORT=$(get_framework_port)
  export CURRENT_PORT=$FRAMEWORK_PORT

  echo "DEBUG: Attempting to start server on port: $FRAMEWORK_PORT"

  ensure_port_free "$FRAMEWORK_PORT"

  local FRAMEWORK_DIR=$(basename "$(pwd)")
  echo "DEBUG: Framework directory: $FRAMEWORK_DIR"

  if [ -f "bun.lockb" ]; then
    echo "DEBUG: Found bun.lockb, checking start scripts..."

    START_TIME=$(date +%s)

    # Create a temporary file for server output
    local TEMP_LOG
    TEMP_LOG=$(mktemp)
    echo "DEBUG: Created temp log file: $TEMP_LOG"

    if jq -e '.scripts.start' package.json >/dev/null 2>&1; then
      echo "DEBUG: Found 'start' script, running 'bun start'"
      PORT=$FRAMEWORK_PORT bun start >"$TEMP_LOG" 2>&1 &
    elif [ -f "src/index.ts" ]; then
      echo "DEBUG: Running 'bun run src/index.ts'"
      PORT=$FRAMEWORK_PORT bun run src/index.ts >"$TEMP_LOG" 2>&1 &
    elif [ -f "index.ts" ]; then
      echo "DEBUG: Running 'bun run index.ts'"
    else
      echo "DEBUG: No recognized entry point found"
      rm -f "$TEMP_LOG"
      return 1
    fi

    SERVER_PID=$!
    if [ -n "$SERVER_PID" ]; then
      echo "DEBUG: Server process started with PID: $SERVER_PID"
      # Wait a moment and check if process is still running
      sleep 2
      if kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "DEBUG: Server process is still running"
        # Check if the port is actually being listened to
        if lsof -i:"$FRAMEWORK_PORT" >/dev/null 2>&1; then
          echo "DEBUG: Port $FRAMEWORK_PORT is being listened to"
          # Only output the port number without debug messages
          echo "$FRAMEWORK_PORT"
          return 0
        else
          echo "DEBUG: Warning: Port $FRAMEWORK_PORT is not being listened to"
          return 1
        fi
      else
        echo "DEBUG: Server process failed to start or crashed immediately"
        return 1
      fi
    else
      echo "DEBUG: Failed to get server PID"
      return 1
    fi
  else
    echo "DEBUG: No bun.lockb found, start with npm or node"

    START_TIME=$(date +%s)

    # Create a temporary file for server output
    local TEMP_LOG
    TEMP_LOG=$(mktemp)
    echo "DEBUG: Created temp log file: $TEMP_LOG"

    if [ -f "encore.app" ]; then
      echo "DEBUG: Running 'ENCORE_LOG=off ENCORE_NOTRACE=1 ENCORE_RUNTIME_LOG=debug encore run'"
      PORT=$FRAMEWORK_PORT ENCORE_LOG=off ENCORE_NOTRACE=1 ENCORE_RUNTIME_LOG=debug encore run >"$TEMP_LOG" 2>&1 &
    elif [ -f "main.js" ]; then
      echo "DEBUG: Running 'node main.js'"
      PORT=$FRAMEWORK_PORT node main.js >"$TEMP_LOG" 2>&1 &
    fi

    SERVER_PID=$!
    if [ -n "$SERVER_PID" ]; then
      echo "DEBUG: Server process started with PID: $SERVER_PID"
      # Wait a moment and check if process is still running
      sleep 2
      if kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "DEBUG: Server process is still running"
        # Check if the port is actually being listened to
        if lsof -i:"$FRAMEWORK_PORT" >/dev/null 2>&1; then
          echo "DEBUG: Port $FRAMEWORK_PORT is being listened to"
          # Only output the port number without debug messages
          echo "$FRAMEWORK_PORT"
          return 0
        else
          echo "DEBUG: Warning: Port $FRAMEWORK_PORT is not being listened to"
          return 1
        fi
      else
        echo "DEBUG: Server process failed to start or crashed immediately"
        return 1
      fi
    else
      echo "DEBUG: Failed to get server PID"
      return 1
    fi
  fi
}
run_framework_tests() {
  local FRAMEWORK_PATH=$1
  local TEST_TYPE=$2
  local FRAMEWORK_NAME=$3
  local BASE_NAME=${FRAMEWORK_NAME%-schema}

  echo "==============================================="
  echo "DEBUG: Starting tests for framework at path: $FRAMEWORK_PATH"
  echo "DEBUG: Test type: $TEST_TYPE"
  echo "DEBUG: Framework name: $FRAMEWORK_NAME"
  echo "DEBUG: Base name: $BASE_NAME"

  cd "$FRAMEWORK_PATH" || {
    echo "DEBUG: Failed to change to directory: $FRAMEWORK_PATH"
    return
  }

  if ! install_dependencies; then
    echo "DEBUG: Dependency installation failed"
    cd - >/dev/null
    return
  fi

  # Capture only the last line of output which should be the port number
  local FRAMEWORK_PORT
  FRAMEWORK_PORT=$(start_server | tail -n 1)
  local START_STATUS=$?

  if [ $START_STATUS -ne 0 ] || ! [[ "$FRAMEWORK_PORT" =~ ^[0-9]+$ ]]; then
    echo "DEBUG: Server failed to start or invalid port number: $FRAMEWORK_PORT"
    cd - >/dev/null
    return
  fi

  echo "DEBUG: Server started successfully on port: $FRAMEWORK_PORT"

  cd - >/dev/null

  echo "DEBUG: Waiting 5 seconds for server to initialize..."
  sleep 5

  if [ "$TEST_TYPE" == "schema" ]; then
    echo "DEBUG: Running schema validation test"
    run_load_test "$FRAMEWORK_PORT" "schema" POST "$DATA" "$BASE_NAME" "schema"
  else
    echo "DEBUG: Running no-schema test"
    run_load_test "$FRAMEWORK_PORT" "hello" GET "" "$BASE_NAME" "no_schema"
  fi

  stop_server "$FRAMEWORK_NAME"
  echo "Tests completed for $FRAMEWORK_NAME with test type: $TEST_TYPE"
  echo "==============================================="
  sleep 2
}

# Function to stop server
stop_server() {
  local FRAMEWORK=$1
  if [ -n "$SERVER_PID" ]; then
    echo "Stopping server for $FRAMEWORK..."
    kill -9 "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    unset SERVER_PID
    if [ -n "$CURRENT_PORT" ]; then
      ensure_port_free "$CURRENT_PORT"
      unset CURRENT_PORT
    fi
  fi
}

# Function to find base name
get_base_name() {
  local NAME=$1
  # Return the name as is without removing the version suffix
  echo "$NAME"
}

# Process frameworks in requests directory
for FRAMEWORK_PATH in "$REQUESTS_DIR"/*; do
  if [ -d "$FRAMEWORK_PATH" ]; then
    FRAMEWORK=$(basename "$FRAMEWORK_PATH")
    BASE_FRAMEWORK=$(get_base_name "$FRAMEWORK")

    # Skip if this is a schema version or versioned framework
    if [[ ! "$FRAMEWORK" =~ -schema ]] && [[ ! "$FRAMEWORK" =~ -v[0-9]+ ]]; then
      SCHEMA_VERSION="${BASE_FRAMEWORK}-schema"
      SCHEMA_PATH="$REQUESTS_DIR/$SCHEMA_VERSION"

      if [ -d "$SCHEMA_PATH" ]; then
        # We have a schema version, use it for schema tests
        echo "Found schema version for $BASE_FRAMEWORK"
        run_framework_tests "$SCHEMA_PATH" "schema" "$BASE_FRAMEWORK"
        run_framework_tests "$FRAMEWORK_PATH" "no_schema" "$BASE_FRAMEWORK"
      else
        # No schema version, test both on the same framework
        echo "No schema version found for $BASE_FRAMEWORK, running both test types"
        run_framework_tests "$FRAMEWORK_PATH" "schema" "$BASE_FRAMEWORK"
        run_framework_tests "$FRAMEWORK_PATH" "no_schema" "$BASE_FRAMEWORK"
      fi
    fi
  fi
done

echo "All tests completed. Results are saved in the $RESULTS_DIR directory."
