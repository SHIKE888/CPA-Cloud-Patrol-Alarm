#!/bin/sh
curl -s -m 5 http://127.0.0.1:9012/ > /tmp/p3.html
echo "metrics blocks : $(grep -c 'class="metrics"' /tmp/p3.html)"
echo "mini bars      : $(grep -c 'id="p_' /tmp/p3.html)"
echo "old chips      : $(grep -c 'chips' /tmp/p3.html)"
echo "tab-sys        : $(grep -c 'tab-sys' /tmp/p3.html)"
echo "mgroup labels  : $(grep -c 'class="mgroup"' /tmp/p3.html)"
