#!/bin/bash

echo "Checking duplicate server names..."

nginx -T 2>/dev/null | \
grep "server_name" | \
awk '{for(i=2;i<=NF;i++) print $i}' | \
sed 's/;//' | \
sort | uniq -c | \
awk '$1>1 {print}'
