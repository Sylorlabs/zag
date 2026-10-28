x, checksum = 17, 0
for _ in range(__ITERATIONS__):
    x = (x * 109 + 1021) % 65521
    if x % 4 == 0:
        checksum = (checksum + x * 7 + 3) % 1000000007
    elif x % 4 == 1:
        checksum = (checksum + x * 11 + 5) % 1000000007
    elif x % 4 == 2:
        checksum = (checksum + x * 13 + 7) % 1000000007
    else:
        checksum = (checksum + x * 17 + 9) % 1000000007
print(checksum)
