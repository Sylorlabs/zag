x = 17
checksum = 0
for _ in range(__ITERATIONS__):
    x = (x * 109 + 1021) % 65521
    checksum = (checksum + x) % 1_000_000_007
print(checksum)
