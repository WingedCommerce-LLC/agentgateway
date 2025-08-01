#!/bin/bash

# AgentGateway Docker-based Fortio Traffic Testing Suite
# This version is designed to run inside the Docker container

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Docker environment paths
RESULTS_DIR="/benchmarks/results"
CONFIGS_DIR="/benchmarks/configs"
PAYLOADS_DIR="/benchmarks/payloads"

echo -e "${BLUE}🚀 AgentGateway Docker Fortio Traffic Testing Suite${NC}"
echo -e "${BLUE}=================================================${NC}"

# Configuration from environment variables
AGENTGATEWAY_URL=${AGENTGATEWAY_URL:-"http://agentgateway:8080"}
BACKEND_URL=${BACKEND_URL:-"http://test-server:3001"}
TEST_DURATION=60s
CONCURRENCY_LEVELS=(16 64 256 512)

# Parse command line arguments
PROTOCOLS="all"
BENCHMARK_TYPE="comprehensive"
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --protocols)
            PROTOCOLS="$2"
            shift 2
            ;;
        --type)
            BENCHMARK_TYPE="$2"
            shift 2
            ;;
        --duration)
            TEST_DURATION="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --protocols PROTO    Protocols to test: all, http, mcp, a2a"
            echo "  --type TYPE          Benchmark type: comprehensive, quick, latency, throughput"
            echo "  --duration DURATION  Test duration (default: 60s)"
            echo "  --verbose           Enable verbose output"
            echo "  --help              Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  AGENTGATEWAY_URL     AgentGateway URL (default: http://agentgateway:8080)"
            echo "  BACKEND_URL          Backend server URL (default: http://test-server:3001)"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Run all protocols, comprehensive tests"
            echo "  $0 --protocols http --type quick      # Quick HTTP tests only"
            echo "  $0 --protocols mcp --duration 30s     # MCP tests for 30 seconds"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Unknown option: $1${NC}"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

# Check if Fortio is installed
if ! command -v fortio &> /dev/null; then
    echo -e "${RED}❌ Fortio is not installed${NC}"
    exit 1
fi

# Create results directory
mkdir -p "$RESULTS_DIR"

echo -e "${YELLOW}📋 Configuration:${NC}"
echo "  Protocols: $PROTOCOLS"
echo "  Benchmark Type: $BENCHMARK_TYPE"
echo "  Test Duration: $TEST_DURATION"
echo "  AgentGateway URL: $AGENTGATEWAY_URL"
echo "  Backend URL: $BACKEND_URL"
echo "  Results Directory: $RESULTS_DIR"
echo ""

# Wait for services to be ready
wait_for_service() {
    local url=$1
    local service_name=$2
    local max_attempts=30
    local attempt=0
    
    echo -n "  Waiting for $service_name at $url"
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "$url/health" >/dev/null 2>&1 || \
           curl -s "$url" >/dev/null 2>&1; then
            echo -e " ${GREEN}✅${NC}"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    echo -e " ${RED}❌${NC}"
    echo -e "${RED}❌ $service_name failed to respond at $url${NC}"
    return 1
}

# Function to run HTTP proxy tests
run_http_tests() {
    echo -e "${YELLOW}=== HTTP Proxy Performance Tests ===${NC}"
    
    # Wait for services
    wait_for_service "$AGENTGATEWAY_URL" "AgentGateway proxy"
    wait_for_service "$BACKEND_URL" "Backend server"
    
    # Run tests based on benchmark type
    case $BENCHMARK_TYPE in
        "quick")
            CONCURRENCY_LEVELS=(16 64)
            ;;
        "latency")
            CONCURRENCY_LEVELS=(16 32 64)
            ;;
        "throughput")
            CONCURRENCY_LEVELS=(64 256 512)
            ;;
        "comprehensive")
            CONCURRENCY_LEVELS=(16 64 256 512)
            ;;
    esac
    
    for concurrency in "${CONCURRENCY_LEVELS[@]}"; do
        echo -e "${BLUE}📊 Testing HTTP proxy with concurrency: $concurrency${NC}"
        
        # Latency test
        echo "  Running latency test..."
        fortio load -c $concurrency -t $TEST_DURATION -a \
            -json "$RESULTS_DIR/http-latency-c${concurrency}.json" \
            "$AGENTGATEWAY_URL/test"
        
        # Throughput test (if not quick mode)
        if [ "$BENCHMARK_TYPE" != "quick" ]; then
            echo "  Running throughput test..."
            fortio load -c $concurrency -qps 0 -t $TEST_DURATION -a \
                -json "$RESULTS_DIR/http-throughput-c${concurrency}.json" \
                "$AGENTGATEWAY_URL/test"
        fi
        
        # Payload size tests (comprehensive mode only)
        if [ "$BENCHMARK_TYPE" = "comprehensive" ]; then
            for payload_size in 1024 10240 102400; do # 1KB, 10KB, 100KB
                echo "  Running payload test (${payload_size}B)..."
                fortio load -c $concurrency -t 30s -a \
                    -json "$RESULTS_DIR/http-payload-${payload_size}B-c${concurrency}.json" \
                    -payload-size $payload_size \
                    "$AGENTGATEWAY_URL/test"
            done
        fi
    done
    
    echo -e "${GREEN}✅ HTTP tests completed${NC}"
    echo ""
}

# Function to run MCP protocol tests
run_mcp_tests() {
    echo -e "${YELLOW}=== MCP Protocol Performance Tests ===${NC}"
    
    # Test different MCP message types
    local mcp_messages=("initialize" "list_resources" "call_tool" "get_prompt")
    
    for msg_type in "${mcp_messages[@]}"; do
        echo -e "${BLUE}📊 Testing MCP message type: $msg_type${NC}"
        
        # Check if payload file exists
        local payload_file="$PAYLOADS_DIR/mcp-${msg_type}.json"
        if [ -f "$payload_file" ]; then
            fortio load -c 64 -t 30s -a \
                -json "$RESULTS_DIR/mcp-${msg_type}.json" \
                -payload "@$payload_file" \
                -H "Content-Type: application/json" \
                "$AGENTGATEWAY_URL/mcp"
        else
            echo "  Warning: Payload file not found: $payload_file"
            # Run without payload
            fortio load -c 64 -t 30s -a \
                -json "$RESULTS_DIR/mcp-${msg_type}.json" \
                -H "Content-Type: application/json" \
                "$AGENTGATEWAY_URL/mcp"
        fi
    done
    
    # Concurrent session test
    if [ "$BENCHMARK_TYPE" = "comprehensive" ]; then
        echo -e "${BLUE}📊 Testing MCP concurrent sessions${NC}"
        local init_payload="$PAYLOADS_DIR/mcp-initialize.json"
        if [ -f "$init_payload" ]; then
            fortio load -c 128 -t $TEST_DURATION -a \
                -json "$RESULTS_DIR/mcp-concurrent-sessions.json" \
                -payload "@$init_payload" \
                -H "Content-Type: application/json" \
                "$AGENTGATEWAY_URL/mcp"
        else
            fortio load -c 128 -t $TEST_DURATION -a \
                -json "$RESULTS_DIR/mcp-concurrent-sessions.json" \
                -H "Content-Type: application/json" \
                "$AGENTGATEWAY_URL/mcp"
        fi
    fi
    
    echo -e "${GREEN}✅ MCP tests completed${NC}"
    echo ""
}

# Function to run A2A protocol tests
run_a2a_tests() {
    echo -e "${YELLOW}=== A2A Protocol Performance Tests ===${NC}"
    
    # Test different A2A operations
    local a2a_operations=("discovery" "capability_exchange" "message_routing")
    
    for operation in "${a2a_operations[@]}"; do
        echo -e "${BLUE}📊 Testing A2A operation: $operation${NC}"
        
        local payload_file="$PAYLOADS_DIR/a2a-${operation}.json"
        if [ -f "$payload_file" ]; then
            fortio load -c 64 -t 30s -a \
                -json "$RESULTS_DIR/a2a-${operation}.json" \
                -payload "@$payload_file" \
                -H "Content-Type: application/json" \
                "$AGENTGATEWAY_URL/a2a"
        else
            echo "  Warning: Payload file not found: $payload_file"
            fortio load -c 64 -t 30s -a \
                -json "$RESULTS_DIR/a2a-${operation}.json" \
                -H "Content-Type: application/json" \
                "$AGENTGATEWAY_URL/a2a"
        fi
    done
    
    # Multi-hop communication test
    if [ "$BENCHMARK_TYPE" = "comprehensive" ]; then
        echo -e "${BLUE}📊 Testing A2A multi-hop communication${NC}"
        local routing_payload="$PAYLOADS_DIR/a2a-message_routing.json"
        if [ -f "$routing_payload" ]; then
            fortio load -c 32 -t $TEST_DURATION -a \
                -json "$RESULTS_DIR/a2a-multi-hop.json" \
                -payload "@$routing_payload" \
                -H "Content-Type: application/json" \
                "$AGENTGATEWAY_URL/a2a"
        else
            fortio load -c 32 -t $TEST_DURATION -a \
                -json "$RESULTS_DIR/a2a-multi-hop.json" \
                -H "Content-Type: application/json" \
                "$AGENTGATEWAY_URL/a2a"
        fi
    fi
    
    echo -e "${GREEN}✅ A2A tests completed${NC}"
    echo ""
}

# Main execution
echo -e "${YELLOW}🏃 Starting Docker-based Fortio traffic tests...${NC}"

case $PROTOCOLS in
    "http")
        run_http_tests
        ;;
    "mcp")
        run_mcp_tests
        ;;
    "a2a")
        run_a2a_tests
        ;;
    "all")
        run_http_tests
        run_mcp_tests
        run_a2a_tests
        ;;
    *)
        echo -e "${RED}❌ Unknown protocol: $PROTOCOLS${NC}"
        echo "Valid protocols: all, http, mcp, a2a"
        exit 1
        ;;
esac

# Summary
echo ""
echo -e "${GREEN}🎉 Docker-based Fortio traffic testing completed!${NC}"
echo -e "${BLUE}📁 Results saved to: $RESULTS_DIR${NC}"

if [ "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
    echo -e "${BLUE}📊 Generated reports:${NC}"
    ls -la "$RESULTS_DIR"/*.json 2>/dev/null | sed 's/^/  /' || echo "  No JSON files found"
    
    # Show summary statistics
    echo ""
    echo -e "${BLUE}📈 Quick Summary:${NC}"
    for json_file in "$RESULTS_DIR"/*.json; do
        if [ -f "$json_file" ]; then
            local filename=$(basename "$json_file")
            local p95=$(jq -r '.DurationHistogram.Percentiles[] | select(.Percentile == 95) | .Value' "$json_file" 2>/dev/null || echo "N/A")
            local qps=$(jq -r '.ActualQPS' "$json_file" 2>/dev/null || echo "N/A")
            echo "  $filename: p95=${p95}s, QPS=${qps}"
        fi
    done
else
    echo -e "${YELLOW}⚠️  No results found in $RESULTS_DIR${NC}"
fi

echo ""
echo -e "${BLUE}🔗 Results ready for report generation${NC}"
