#!/usr/bin/env python3
"""Prove a discv5 node is alive by making it answer.

Discovery runs over UDP, where a connect proves nothing: there is no handshake,
so `nc -zu` reports success against a black hole. This sends a real discv5 v5.1
packet instead. Its masking key is the *recipient's* node id, keccak256 of the
public key in the ENR, so only a node that agrees its id is that can unmask the
packet -- and it must reply WHOAREYOU. That reply binds the key in the record to
whatever is listening.

Usage: discv5_probe.py <ip> <udp-port> <compressed-secp256k1-pubkey-hex>
Exit:  0 alive, 2 no answer, 3 answer was not discv5.

Keccak-256 and AES-128-CTR are implemented below rather than pulled in: this
sends one packet in CI, and neither touches a secret here.
"""
import os
import socket
import sys

# --- Keccak-256 (padding 0x01, unlike SHA3-256) ---
RC=[0x0000000000000001,0x0000000000008082,0x800000000000808A,0x8000000080008000,
0x000000000000808B,0x0000000080000001,0x8000000080008081,0x8000000000008009,
0x000000000000008A,0x0000000000000088,0x0000000080008009,0x000000008000000A,
0x000000008000808B,0x800000000000008B,0x8000000000008089,0x8000000000008003,
0x8000000000008002,0x8000000000000080,0x000000000000800A,0x800000008000000A,
0x8000000080008081,0x8000000000008080,0x0000000080000001,0x8000000080008008]
ROT=[[0,36,3,41,18],[1,44,10,45,2],[62,6,43,15,61],[28,55,25,21,56],[27,20,39,8,14]]
M=(1<<64)-1
def rol(x,n): return ((x<<n)|(x>>(64-n)))&M
def keccak_f(A):
    for rnd in range(24):
        C=[A[x][0]^A[x][1]^A[x][2]^A[x][3]^A[x][4] for x in range(5)]
        D=[C[(x-1)%5]^rol(C[(x+1)%5],1) for x in range(5)]
        for x in range(5):
            for y in range(5): A[x][y]^=D[x]
        B=[[0]*5 for _ in range(5)]
        for x in range(5):
            for y in range(5): B[y][(2*x+3*y)%5]=rol(A[x][y],ROT[x][y])
        for x in range(5):
            for y in range(5): A[x][y]=B[x][y]^((~B[(x+1)%5][y])&B[(x+2)%5][y])
        A[0][0]^=RC[rnd]
    return A
def keccak256(data):
    rate=136; A=[[0]*5 for _ in range(5)]
    p=bytearray(data); p.append(0x01)
    while len(p)%rate: p.append(0)
    p[-1]^=0x80
    for off in range(0,len(p),rate):
        blk=p[off:off+rate]
        for i in range(rate//8):
            v=int.from_bytes(blk[i*8:i*8+8],"little"); A[i%5][i//5]^=v
        A=keccak_f(A)
    out=b""
    for i in range(4): out+=A[i%5][i//5].to_bytes(8,"little")
    return out[:32]

# --- AES-128 encrypt, CTR mode ---
SBOX=bytes.fromhex(
"637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0"
"b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
"09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf"
"d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
"cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb"
"e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
"ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e"
"e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16")
def xt(a): return ((a<<1)^0x1b)&0xff if a&0x80 else a<<1
def expand(key):
    w=[list(key[i*4:i*4+4]) for i in range(4)]; rcon=1
    for i in range(4,44):
        t=list(w[i-1])
        if i%4==0:
            t=t[1:]+t[:1]; t=[SBOX[b] for b in t]; t[0]^=rcon; rcon=xt(rcon)
        w.append([w[i-4][j]^t[j] for j in range(4)])
    return w
def encrypt_block(key,blk):
    w=expand(key); s=[list(blk[i::4]) for i in range(4)]
    def ark(r):
        for c in range(4):
            for r2 in range(4): s[r2][c]^=w[r*4+c][r2]
    ark(0)
    for rnd in range(1,11):
        for r in range(4):
            for c in range(4): s[r][c]=SBOX[s[r][c]]
        for r in range(1,4): s[r]=s[r][r:]+s[r][:r]
        if rnd!=10:
            for c in range(4):
                a=[s[r][c] for r in range(4)]
                s[0][c]=xt(a[0])^(xt(a[1])^a[1])^a[2]^a[3]
                s[1][c]=a[0]^xt(a[1])^(xt(a[2])^a[2])^a[3]
                s[2][c]=a[0]^a[1]^xt(a[2])^(xt(a[3])^a[3])
                s[3][c]=(xt(a[0])^a[0])^a[1]^a[2]^xt(a[3])
        ark(rnd)
    return bytes(s[r][c] for c in range(4) for r in range(4))
def aes_ctr(key,iv,data):
    out=bytearray(); ctr=int.from_bytes(iv,"big")
    for off in range(0,len(data),16):
        ks=encrypt_block(key,ctr.to_bytes(16,"big"))
        blk=data[off:off+16]
        out+=bytes(a^b for a,b in zip(blk,ks)); ctr=(ctr+1)%(1<<128)
    return bytes(out)

# --- secp256k1 point decompression ---
P=2**256-2**32-977
def decompress(c):
    x=int.from_bytes(c[1:],"big")
    y=pow((pow(x,3,P)+7)%P,(P+1)//4,P)
    if (y&1)!=(c[0]&1): y=P-y
    return x.to_bytes(32,"big")+y.to_bytes(32,"big")

# --- probe -------------------------------------------------------------------
def probe(ip, port, pub_hex, timeout=6.0):
    """Send one masked discv5 packet; return True if WHOAREYOU comes back."""
    node_id = keccak256(decompress(bytes.fromhex(pub_hex)))
    masking_iv = os.urandom(16)
    src_id = os.urandom(32)
    header = b"discv5" + b"\x00\x01" + b"\x00" + os.urandom(12) \
        + (32).to_bytes(2, "big") + src_id
    packet = masking_iv + aes_ctr(node_id[:16], masking_iv, header) + os.urandom(24)

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(packet, (ip, port))
        data, _ = s.recvfrom(2048)
    except (socket.timeout, OSError):
        return None, node_id
    finally:
        s.close()
    # The reply is masked with the source id we made up.
    hdr = aes_ctr(src_id[:16], data[:16], data[16:16 + 23])
    return hdr, node_id


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    ip, port, pub_hex = sys.argv[1], int(sys.argv[2]), sys.argv[3]

    # UDP has no retransmission; one lost datagram is not a dead node.
    for attempt in range(3):
        hdr, node_id = probe(ip, port, pub_hex)
        if hdr is not None:
            break
    else:
        print(f"    no discv5 answer from {ip}:{port} after 3 tries "
              f"(node id {node_id.hex()[:16]}…)")
        return 2

    if hdr[:6] != b"discv5":
        print(f"    {ip}:{port} answered, but not with a discv5 packet")
        return 3
    kind = "WHOAREYOU" if hdr[8] == 1 else f"discv5 packet (flag {hdr[8]})"
    print(f"    {ip}:{port} answered {kind}; node id {node_id.hex()[:16]}… "
          f"matches the ENR key")
    return 0


if __name__ == "__main__":
    sys.exit(main())
