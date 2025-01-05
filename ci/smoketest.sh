#!/bin/sh
set -eux

./zig-out/bin/awtfdb-manage create
echo "among us" > among.txt
./zig-out/bin/ainclude -t amongi among.txt
afind_output=$(./zig-out/bin/afind amongi)
echo "$afind_output" | grep 'among.txt' -
amongi_hash=$(./zig-out/bin/atags search --hash amongi | cut -d ' ' -f 2 | head -n 1)
./zig-out/bin/atags create another_tag
./zig-out/bin/atags create --alias "$amongi_hash" another_tag
