#!/bin/sh

echo Content-type: text/html
echo
cat bigtest.txt
sleep 4
cat bigtest.txt
sleep 2
cat bigtest.txt
sleep 2
echo -n chunk4
sleep 2
echo chunk5
