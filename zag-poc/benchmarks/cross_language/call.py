def advance(x):
    return (x * 109 + 1021) % 65521

def accumulate(checksum, x):
    return (checksum + x * 7 + 3) % 1000000007

x, checksum = 17, 0
for _ in range(__ITERATIONS__):
    x = advance(x)
    checksum = accumulate(checksum, x)
print(checksum)
