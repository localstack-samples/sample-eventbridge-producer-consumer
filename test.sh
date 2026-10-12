#!/bin/bash
# Invoke the producer and check that each consumer received exactly the
# transactions its EventBridge rule matches (see atmProducer/events.js).
set -euo pipefail

STACK=sam-app
MAX_ATTEMPTS=${MAX_ATTEMPTS:-30}

fn_name() {
  lstk aws cloudformation describe-stack-resource --stack-name "$STACK" \
    --logical-resource-id "$1" --query 'StackResourceDetail.PhysicalResourceId' --output text
}

PRODUCER=$(fn_name atmProducerFn)
CASE1=$(fn_name atmConsumerCase1Fn)
CASE2=$(fn_name atmConsumerCase2Fn)
CASE3=$(fn_name atmConsumerCase3Fn)

# Only look at log events written after this point
START_MS=$(( $(date +%s) * 1000 ))

echo "Invoking $PRODUCER"
out=$(mktemp)
meta=$(lstk aws lambda invoke --function-name "$PRODUCER" "$out")
if echo "$meta" | jq -e 'has("FunctionError")' > /dev/null; then
  echo "Test failed: producer returned an error: $(cat "$out")"
  exit 1
fi

# Sorted transaction IDs a consumer logged since START_MS
received() {
  lstk aws logs filter-log-events --log-group-name "/aws/lambda/$1" \
    --start-time "$START_MS" --query 'events[].message' --output json 2>/dev/null \
    | jq -r '.[]' | grep -o '"transactionId": "[0-9]*"' | grep -o '[0-9]\+' | sort | tr '\n' ' ' || true
}

check() {
  local label=$1 fn=$2 expected=$3 got=""
  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    got=$(received "$fn")
    [ "$got" = "$expected" ] && break
    sleep 2
  done
  if [ "$got" != "$expected" ]; then
    echo "Test failed: $label consumer got [${got}], expected [${expected}]"
    exit 1
  fi
  echo "PASS: $label consumer got [${got}]"
}

check "approved" "$CASE1" "123456 123457 "
check "NY location" "$CASE2" "123457 123458 "
check "not approved" "$CASE3" "123458 "

echo "Test passed: every rule delivered the expected transactions"
