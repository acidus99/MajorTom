#!/usr/bin/env python3
"""XOR stdin against a repeating key, write result to stdout.

Usage:
    cat input.bin | ./xor.py "KEY" > output.bin

The key is taken as raw bytes (UTF-8). XOR is symmetric, so running the
output back through with the same key restores the original.
"""
import sys


def main():
    if len(sys.argv) != 2 or not sys.argv[1]:
        sys.exit(f"usage: {sys.argv[0]} KEY   (data on stdin, result on stdout)")

    key = sys.argv[1].encode("utf-8")
    data = sys.stdin.buffer.read()
    out = bytes(b ^ key[i % len(key)] for i, b in enumerate(data))
    sys.stdout.buffer.write(out)


if __name__ == "__main__":
    main()
