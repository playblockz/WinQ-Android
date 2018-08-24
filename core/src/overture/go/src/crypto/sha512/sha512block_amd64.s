// Copyright 2013 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "textflag.h"

// SHA512 block routine. See sha512block.go for Go equivalent.
//
// The algorithm is detailed in FIPS 180-4:
//
//  http://csrc.nist.gov/publications/fips/fips180-4/fips-180-4.pdf
//
// Wt = Mt; for 0 <= t <= 15
// Wt = SIGMA1(Wt-2) + SIGMA0(Wt-15) + Wt-16; for 16 <= t <= 79
//
// a = H0
// b = H1
// c = H2
// d = H3
// e = H4
// f = H5
// g = H6
// h = H7
//
// for t = 0 to 79 {
//    T1 = h + BIGSIGMA1(e) + Ch(e,f,g) + Kt + Wt
//    T2 = BIGSIGMA0(a) + Maj(a,b,c)
//    h = g
//    g = f
//    f = e
//    e = d + T1
//    d = c
//    c = b
//    b = a
//    a = T1 + T2
// }
//
// H0 = a + H0
// H1 = b + H1
// H2 = c + H2
// H3 = d + H3
// H4 = e + H4
// H5 = f + H5
// H6 = g + H6
// H7 = h + H7

// Wt = Mt; for 0 <= t <= 15
#define MSGSCHEDULE0(index) \
	MOVQ	(index*8)(SI), AX; \
	BSWAPQ	AX; \
	MOVQ	AX, (index*8)(BP)

// Wt = SIGMA1(Wt-2) + Wt-7 + SIGMA0(Wt-15) + Wt-16; for 16 <= t <= 79
//   SIGMA0(x) = ROTR(1,x) XOR ROTR(8,x) XOR SHR(7,x)
//   SIGMA1(x) = ROTR(19,x) XOR ROTR(61,x) XOR SHR(6,x)
#define MSGSCHEDULE1(index) \
	MOVQ	((index-2)*8)(BP), AX; \
	MOVQ	AX, CX; \
	RORQ	$19, AX; \
	MOVQ	CX, DX; \
	RORQ	$61, CX; \
	SHRQ	$6, DX; \
	MOVQ	((index-15)*8)(BP), BX; \
	XORQ	CX, AX; \
	MOVQ	BX, CX; \
	XORQ	DX, AX; \
	RORQ	$1, BX; \
	MOVQ	CX, DX; \
	SHRQ	$7, DX; \
	RORQ	$8, CX; \
	ADDQ	((index-7)*8)(BP), AX; \
	XORQ	CX, BX; \
	XORQ	DX, BX; \
	ADDQ	((index-16)*8)(BP), BX; \
	ADDQ	BX, AX; \
	MOVQ	AX, ((index)*8)(BP)

// Calculate T1 in AX - uses AX, CX and DX registers.
// h is also used as an accumulator. Wt is passed in AX.
//   T1 = h + BIGSIGMA1(e) + Ch(e, f, g) + Kt + Wt
//     BIGSIGMA1(x) = ROTR(14,x) XOR ROTR(18,x) XOR ROTR(41,x)
//     Ch(x, y, z) = (x AND y) XOR (NOT x AND z)
#define SHA512T1(const, e, f, g, h) \
	MOVQ	$const, DX; \
	ADDQ	AX, h; \
	MOVQ	e, AX; \
	ADDQ	DX, h; \
	MOVQ	e, CX; \
	RORQ	$14, AX; \
	MOVQ	e, DX; \
	RORQ	$18, CX; \
	XORQ	CX, AX; \
	MOVQ	e, CX; \
	RORQ	$41, DX; \
	ANDQ	f, CX; \
	XORQ	AX, DX; \
	MOVQ	e, AX; \
	NOTQ	AX; \
	ADDQ	DX, h; \
	ANDQ	g, AX; \
	XORQ	CX, AX; \
	ADDQ	h, AX

// Calculate T2 in BX - uses BX, CX, DX and DI registers.
//   T2 = BIGSIGMA0(a) + Maj(a, b, c)
//     BIGSIGMA0(x) = ROTR(28,x) XOR ROTR(34,x) XOR ROTR(39,x)
//     Maj(x, y, z) = (x AND y) XOR (x AND z) XOR (y AND z)
#define SHA512T2(a, b, c) \
	MOVQ	a, DI; \
	MOVQ	c, BX; \
	RORQ	$28, DI; \
	MOVQ	a, DX; \
	ANDQ	b, BX; \
	RORQ	$34, DX; \
	MOVQ	a, CX; \
	ANDQ	c, CX; \
	XORQ	DX, DI; \
	XORQ	CX, BX; \
	MOVQ	a, DX; \
	MOVQ	b, CX; \
	RORQ	$39, DX; \
	ANDQ	a, CX; \
	XORQ	CX, BX; \
	XORQ	DX, DI; \
	ADDQ	DI, BX

// Calculate T1 and T2, then e = d + T1 and a = T1 + T2.
// The values for e and a are stored in d and h, ready for rotation.
#define SHA512ROUND(index, const, a, b, c, d, e, f, g, h) \
	SHA512T1(const, e, f, g, h); \
	SHA512T2(a, b, c); \
	MOVQ	BX, h; \
	ADDQ	AX, d; \
	ADDQ	AX, h

#define SHA512ROUND0(index, const, a, b, c, d, e, f, g, h) \
	MSGSCHEDULE0(index); \
	SHA512ROUND(index, const, a, b, c, d, e, f, g, h)

#define SHA512ROUND1(index, const, a, b, c, d, e, f, g, h) \
	MSGSCHEDULE1(index); \
	SHA512ROUND(index, const, a, b, c, d, e, f, g, h)

TEXT ·blockAMD64(SB),0,$648-32
	MOVQ	p_base+8(FP), SI
	MOVQ	p_len+16(FP), DX
	SHRQ	$7, DX
	SHLQ	$7, DX

	LEAQ	(SI)(DX*1), DI
	MOVQ	DI, 640(SP)
	CMPQ	SI, DI
	JEQ	end

	MOVQ	dig+0(FP), BP
	MOVQ	(0*8)(BP), R8		// a = H0
	MOVQ	(1*8)(BP), R9		// b = H1
	MOVQ	(2*8)(BP), R10		// c = H2
	MOVQ	(3*8)(BP), R11		// d = H3
	MOVQ	(4*8)(BP), R12		// e = H4
	MOVQ	(5*8)(BP), R13		// f = H5
	MOVQ	(6*8)(BP), R14		// g = H6
	MOVQ	(7*8)(BP), R15		// h = H7

loop:
	MOVQ	SP, BP			// message schedule

	SHA512ROUND0(0, 0x428a2f98d728ae22, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND0(1, 0x7137449123ef65cd, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND0(2, 0xb5c0fbcfec4d3b2f, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND0(3, 0xe9b5dba58189dbbc, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND0(4, 0x3956c25bf348b538, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND0(5, 0x59f111f1b605d019, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND0(6, 0x923f82a4af194f9b, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND0(7, 0xab1c5ed5da6d8118, R9, R10, R11, R12, R13, R14, R15, R8)
	SHA512ROUND0(8, 0xd807aa98a3030242, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND0(9, 0x12835b0145706fbe, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND0(10, 0x243185be4ee4b28c, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND0(11, 0x550c7dc3d5ffb4e2, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND0(12, 0x72be5d74f27b896f, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND0(13, 0x80deb1fe3b1696b1, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND0(14, 0x9bdc06a725c71235, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND0(15, 0xc19bf174cf692694, R9, R10, R11, R12, R13, R14, R15, R8)

	SHA512ROUND1(16, 0xe49b69c19ef14ad2, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND1(17, 0xefbe4786384f25e3, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND1(18, 0x0fc19dc68b8cd5b5, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND1(19, 0x240ca1cc77ac9c65, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND1(20, 0x2de92c6f592b0275, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND1(21, 0x4a7484aa6ea6e483, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND1(22, 0x5cb0a9dcbd41fbd4, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND1(23, 0x76f988da831153b5, R9, R10, R11, R12, R13, R14, R15, R8)
	SHA512ROUND1(24, 0x983e5152ee66dfab, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND1(25, 0xa831c66d2db43210, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND1(26, 0xb00327c898fb213f, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND1(27, 0xbf597fc7beef0ee4, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND1(28, 0xc6e00bf33da88fc2, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND1(29, 0xd5a79147930aa725, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND1(30, 0x06ca6351e003826f, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND1(31, 0x142929670a0e6e70, R9, R10, R11, R12, R13, R14, R15, R8)
	SHA512ROUND1(32, 0x27b70a8546d22ffc, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND1(33, 0x2e1b21385c26c926, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND1(34, 0x4d2c6dfc5ac42aed, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND1(35, 0x53380d139d95b3df, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND1(36, 0x650a73548baf63de, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND1(37, 0x766a0abb3c77b2a8, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND1(38, 0x81c2c92e47edaee6, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND1(39, 0x92722c851482353b, R9, R10, R11, R12, R13, R14, R15, R8)
	SHA512ROUND1(40, 0xa2bfe8a14cf10364, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND1(41, 0xa81a664bbc423001, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND1(42, 0xc24b8b70d0f89791, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND1(43, 0xc76c51a30654be30, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND1(44, 0xd192e819d6ef5218, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND1(45, 0xd69906245565a910, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND1(46, 0xf40e35855771202a, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND1(47, 0x106aa07032bbd1b8, R9, R10, R11, R12, R13, R14, R15, R8)
	SHA512ROUND1(48, 0x19a4c116b8d2d0c8, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND1(49, 0x1e376c085141ab53, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND1(50, 0x2748774cdf8eeb99, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND1(51, 0x34b0bcb5e19b48a8, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND1(52, 0x391c0cb3c5c95a63, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND1(53, 0x4ed8aa4ae3418acb, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND1(54, 0x5b9cca4f7763e373, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND1(55, 0x682e6ff3d6b2b8a3, R9, R10, R11, R12, R13, R14, R15, R8)
	SHA512ROUND1(56, 0x748f82ee5defb2fc, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND1(57, 0x78a5636f43172f60, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND1(58, 0x84c87814a1f0ab72, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND1(59, 0x8cc702081a6439ec, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND1(60, 0x90befffa23631e28, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND1(61, 0xa4506cebde82bde9, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND1(62, 0xbef9a3f7b2c67915, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND1(63, 0xc67178f2e372532b, R9, R10, R11, R12, R13, R14, R15, R8)
	SHA512ROUND1(64, 0xca273eceea26619c, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND1(65, 0xd186b8c721c0c207, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND1(66, 0xeada7dd6cde0eb1e, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND1(67, 0xf57d4f7fee6ed178, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND1(68, 0x06f067aa72176fba, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND1(69, 0x0a637dc5a2c898a6, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND1(70, 0x113f9804bef90dae, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND1(71, 0x1b710b35131c471b, R9, R10, R11, R12, R13, R14, R15, R8)
	SHA512ROUND1(72, 0x28db77f523047d84, R8, R9, R10, R11, R12, R13, R14, R15)
	SHA512ROUND1(73, 0x32caab7b40c72493, R15, R8, R9, R10, R11, R12, R13, R14)
	SHA512ROUND1(74, 0x3c9ebe0a15c9bebc, R14, R15, R8, R9, R10, R11, R12, R13)
	SHA512ROUND1(75, 0x431d67c49c100d4c, R13, R14, R15, R8, R9, R10, R11, R12)
	SHA512ROUND1(76, 0x4cc5d4becb3e42b6, R12, R13, R14, R15, R8, R9, R10, R11)
	SHA512ROUND1(77, 0x597f299cfc657e2a, R11, R12, R13, R14, R15, R8, R9, R10)
	SHA512ROUND1(78, 0x5fcb6fab3ad6faec, R10, R11, R12, R13, R14, R15, R8, R9)
	SHA512ROUND1(79, 0x6c44198c4a475817, R9, R10, R11, R12, R13, R14, R15, R8)

	MOVQ	dig+0(FP), BP
	ADDQ	(0*8)(BP), R8	// H0 = a + H0
	MOVQ	R8, (0*8)(BP)
	ADDQ	(1*8)(BP), R9	// H1 = b + H1
	MOVQ	R9, (1*8)(BP)
	ADDQ	(2*8)(BP), R10	// H2 = c + H2
	MOVQ	R10, (2*8)(BP)
	ADDQ	(3*8)(BP), R11	// H3 = d + H3
	MOVQ	R11, (3*8)(BP)
	ADDQ	(4*8)(BP), R12	// H4 = e + H4
	MOVQ	R12, (4*8)(BP)
	ADDQ	(5*8)(BP), R13	// H5 = f + H5
	MOVQ	R13, (5*8)(BP)
	ADDQ	(6*8)(BP), R14	// H6 = g + H6
	MOVQ	R14, (6*8)(BP)
	ADDQ	(7*8)(BP), R15	// H7 = h + H7
	MOVQ	R15, (7*8)(BP)

	ADDQ	$128, SI
	CMPQ	SI, 640(SP)
	JB	loop

end:
	RET

// Version below is based on "Fast SHA512 Implementations on Intel
// Architecture Processors" White-paper
// http://www.intel.com/content/dam/www/public/us/en/documents/white-papers/fast-sha512-implementations-ia-processors-paper.pdf
// AVX2 version by Intel, same algorithm in Linux kernel:
// https://github.com/torvalds/linux/blob/master/arch/x86/crypto/sha512-avx2-asm.S

// James Guilford <james.guilford@intel.com>
// Kirk Yap <kirk.s.yap@intel.com>
// Tim Chen <tim.c.chen@linux.intel.com>
// David Cote <david.m.cote@intel.com>
// Aleksey Sidorov <aleksey.sidorov@intel.com>

#define YFER_SIZE (4*8)
#define SRND_SIZE (1*8)
#define INP_SIZE (1*8)

#define frame_YFER (0)
#define frame_SRND (frame_YFER + YFER_SIZE)
#define frame_INP (frame_SRND + SRND_SIZE)
#define frame_INPEND (frame_INP + INP_SIZE)

#define addm(p1, p2) \
	ADDQ p1, p2; \
	MOVQ p2, p1

#define COPY_YMM_AND_BSWAP(p1, p2, p3) \
	VMOVDQU p2, p1;    \
	VPSHUFB p3, p1, p1

#define MY_VPALIGNR(YDST, YSRC1, YSRC2, RVAL) \
	VPERM2F128 $0x3, YSRC2, YSRC1, YDST; \
	VPALIGNR   $RVAL, YSRC2, YDST, YDST

DATA PSHUFFLE_BYTE_FLIP_MASK<>+0x00(SB)/8, $0x0001020304050607
DATA PSHUFFLE_BYTE_FLIP_MASK<>+0x08(SB)/8, $0x08090a0b0c0d0e0f
DATA PSHUFFLE_BYTE_FLIP_MASK<>+0x10(SB)/8, $0x1011121314151617
DATA PSHUFFLE_BYTE_FLIP_MASK<>+0x18(SB)/8, $0x18191a1b1c1d1e1f

GLOBL PSHUFFLE_BYTE_FLIP_MASK<>(SB), (NOPTR+RODATA), $32

DATA MASK_YMM_LO<>+0x00(SB)/8, $0x0000000000000000
DATA MASK_YMM_LO<>+0x08(SB)/8, $0x0000000000000000
DATA MASK_YMM_LO<>+0x10(SB)/8, $0xFFFFFFFFFFFFFFFF
DATA MASK_YMM_LO<>+0x18(SB)/8, $0xFFFFFFFFFFFFFFFF

GLOBL MASK_YMM_LO<>(SB), (NOPTR+RODATA), $32

TEXT ·blockAVX2(SB), NOSPLIT, $56-32
	MOVQ dig+0(FP), SI
	MOVQ p_base+8(FP), DI
	MOVQ p_len+16(FP), DX

	SHRQ $7, DX
	SHLQ $7, DX

	JZ   done_hash
	ADDQ DI, DX
	MOVQ DX, frame_INPEND(SP)

	MOVQ (0*8)(SI), AX
	MOVQ (1*8)(SI), BX
	MOVQ (2*8)(SI), CX
	MOVQ (3*8)(SI), R8
	MOVQ (4*8)(SI), DX
	MOVQ (5*8)(SI), R9
	MOVQ (6*8)(SI), R10
	MOVQ (7*8)(SI), R11

	VMOVDQU PSHUFFLE_BYTE_FLIP_MASK<>(SB), Y9

loop0:
	MOVQ ·_K+0(SB), BP

	// byte swap first 16 dwords
	COPY_YMM_AND_BSWAP(Y4, (0*32)(DI), Y9)
	COPY_YMM_AND_BSWAP(Y5, (1*32)(DI), Y9)
	COPY_YMM_AND_BSWAP(Y6, (2*32)(DI), Y9)
	COPY_YMM_AND_BSWAP(Y7, (3*32)(DI), Y9)

	MOVQ DI, frame_INP(SP)

	// schedule 64 input dwords, by doing 12 rounds of 4 each
	MOVQ $4, frame_SRND(SP)

loop1:
	VPADDQ  (BP), Y4, Y0
	VMOVDQU Y0, frame_YFER(SP)

	MY_VPALIGNR(Y0, Y7, Y6, 8)

	VPADDQ Y4, Y0, Y0

	MY_VPALIGNR(Y1, Y5, Y4, 8)

	VPSRLQ $1, Y1, Y2
	VPSLLQ $(64-1), Y1, Y3
	VPOR   Y2, Y3, Y3

	VPSRLQ $7, Y1, Y8

	MOVQ  AX, DI
	RORXQ $41, DX, R13
	RORXQ $18, DX, R14
	ADDQ  frame_YFER(SP), R11
	ORQ   CX, DI
	MOVQ  R9, R15
	RORXQ $34, AX, R12

	XORQ  R14, R13
	XORQ  R10, R15
	RORXQ $14, DX, R14

	ANDQ  DX, R15
	XORQ  R14, R13
	RORXQ $39, AX, R14
	ADDQ  R11, R8

	ANDQ  BX, DI
	XORQ  R12, R14
	RORXQ $28, AX, R12

	XORQ R10, R15
	XORQ R12, R14
	MOVQ AX, R12
	ANDQ CX, R12

	ADDQ R13, R15
	ORQ  R12, DI
	ADDQ R14, R11

	ADDQ R15, R8

	ADDQ R15, R11
	ADDQ DI, R11

	VPSRLQ $8, Y1, Y2
	VPSLLQ $(64-8), Y1, Y1
	VPOR   Y2, Y1, Y1

	VPXOR Y8, Y3, Y3
	VPXOR Y1, Y3, Y1

	VPADDQ Y1, Y0, Y0

	VPERM2F128 $0x0, Y0, Y0, Y4

	VPAND MASK_YMM_LO<>(SB), Y0, Y0

	VPERM2F128 $0x11, Y7, Y7, Y2
	VPSRLQ     $6, Y2, Y8

	MOVQ  R11, DI
	RORXQ $41, R8, R13
	RORXQ $18, R8, R14
	ADDQ  1*8+frame_YFER(SP), R10
	ORQ   BX, DI

	MOVQ  DX, R15
	RORXQ $34, R11, R12
	XORQ  R14, R13
	XORQ  R9, R15

	RORXQ $14, R8, R14
	XORQ  R14, R13
	RORXQ $39, R11, R14
	ANDQ  R8, R15
	ADDQ  R10, CX

	ANDQ AX, DI
	XORQ R12, R14

	RORXQ $28, R11, R12
	XORQ  R9, R15

	XORQ R12, R14
	MOVQ R11, R12
	ANDQ BX, R12
	ADDQ R13, R15

	ORQ  R12, DI
	ADDQ R14, R10

	ADDQ R15, CX
	ADDQ R15, R10
	ADDQ DI, R10

	VPSRLQ $19, Y2, Y3
	VPSLLQ $(64-19), Y2, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8
	VPSRLQ $61, Y2, Y3
	VPSLLQ $(64-61), Y2, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8

	VPADDQ Y8, Y4, Y4

	VPSRLQ $6, Y4, Y8

	MOVQ  R10, DI
	RORXQ $41, CX, R13
	ADDQ  2*8+frame_YFER(SP), R9

	RORXQ $18, CX, R14
	ORQ   AX, DI
	MOVQ  R8, R15
	XORQ  DX, R15

	RORXQ $34, R10, R12
	XORQ  R14, R13
	ANDQ  CX, R15

	RORXQ $14, CX, R14
	ADDQ  R9, BX
	ANDQ  R11, DI

	XORQ  R14, R13
	RORXQ $39, R10, R14
	XORQ  DX, R15

	XORQ  R12, R14
	RORXQ $28, R10, R12

	XORQ R12, R14
	MOVQ R10, R12
	ANDQ AX, R12
	ADDQ R13, R15

	ORQ  R12, DI
	ADDQ R14, R9
	ADDQ R15, BX
	ADDQ R15, R9

	ADDQ DI, R9

	VPSRLQ $19, Y4, Y3
	VPSLLQ $(64-19), Y4, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8
	VPSRLQ $61, Y4, Y3
	VPSLLQ $(64-61), Y4, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8

	VPADDQ Y8, Y0, Y2

	VPBLENDD $0xF0, Y2, Y4, Y4

	MOVQ  R9, DI
	RORXQ $41, BX, R13
	RORXQ $18, BX, R14
	ADDQ  3*8+frame_YFER(SP), DX
	ORQ   R11, DI

	MOVQ  CX, R15
	RORXQ $34, R9, R12
	XORQ  R14, R13
	XORQ  R8, R15

	RORXQ $14, BX, R14
	ANDQ  BX, R15
	ADDQ  DX, AX
	ANDQ  R10, DI

	XORQ R14, R13
	XORQ R8, R15

	RORXQ $39, R9, R14
	ADDQ  R13, R15

	XORQ R12, R14
	ADDQ R15, AX

	RORXQ $28, R9, R12

	XORQ R12, R14
	MOVQ R9, R12
	ANDQ R11, R12
	ORQ  R12, DI

	ADDQ R14, DX
	ADDQ R15, DX
	ADDQ DI, DX

	VPADDQ  1*32(BP), Y5, Y0
	VMOVDQU Y0, frame_YFER(SP)

	MY_VPALIGNR(Y0, Y4, Y7, 8)

	VPADDQ Y5, Y0, Y0

	MY_VPALIGNR(Y1, Y6, Y5, 8)

	VPSRLQ $1, Y1, Y2
	VPSLLQ $(64-1), Y1, Y3
	VPOR   Y2, Y3, Y3

	VPSRLQ $7, Y1, Y8

	MOVQ  DX, DI
	RORXQ $41, AX, R13
	RORXQ $18, AX, R14
	ADDQ  frame_YFER(SP), R8
	ORQ   R10, DI
	MOVQ  BX, R15
	RORXQ $34, DX, R12

	XORQ  R14, R13
	XORQ  CX, R15
	RORXQ $14, AX, R14

	ANDQ  AX, R15
	XORQ  R14, R13
	RORXQ $39, DX, R14
	ADDQ  R8, R11

	ANDQ  R9, DI
	XORQ  R12, R14
	RORXQ $28, DX, R12

	XORQ CX, R15
	XORQ R12, R14
	MOVQ DX, R12
	ANDQ R10, R12

	ADDQ R13, R15
	ORQ  R12, DI
	ADDQ R14, R8

	ADDQ R15, R11

	ADDQ R15, R8
	ADDQ DI, R8

	VPSRLQ $8, Y1, Y2
	VPSLLQ $(64-8), Y1, Y1
	VPOR   Y2, Y1, Y1

	VPXOR Y8, Y3, Y3
	VPXOR Y1, Y3, Y1

	VPADDQ Y1, Y0, Y0

	VPERM2F128 $0x0, Y0, Y0, Y5

	VPAND MASK_YMM_LO<>(SB), Y0, Y0

	VPERM2F128 $0x11, Y4, Y4, Y2
	VPSRLQ     $6, Y2, Y8

	MOVQ  R8, DI
	RORXQ $41, R11, R13
	RORXQ $18, R11, R14
	ADDQ  1*8+frame_YFER(SP), CX
	ORQ   R9, DI

	MOVQ  AX, R15
	RORXQ $34, R8, R12
	XORQ  R14, R13
	XORQ  BX, R15

	RORXQ $14, R11, R14
	XORQ  R14, R13
	RORXQ $39, R8, R14
	ANDQ  R11, R15
	ADDQ  CX, R10

	ANDQ DX, DI
	XORQ R12, R14

	RORXQ $28, R8, R12
	XORQ  BX, R15

	XORQ R12, R14
	MOVQ R8, R12
	ANDQ R9, R12
	ADDQ R13, R15

	ORQ  R12, DI
	ADDQ R14, CX

	ADDQ R15, R10
	ADDQ R15, CX
	ADDQ DI, CX

	VPSRLQ $19, Y2, Y3
	VPSLLQ $(64-19), Y2, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8
	VPSRLQ $61, Y2, Y3
	VPSLLQ $(64-61), Y2, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8

	VPADDQ Y8, Y5, Y5

	VPSRLQ $6, Y5, Y8

	MOVQ  CX, DI
	RORXQ $41, R10, R13
	ADDQ  2*8+frame_YFER(SP), BX

	RORXQ $18, R10, R14
	ORQ   DX, DI
	MOVQ  R11, R15
	XORQ  AX, R15

	RORXQ $34, CX, R12
	XORQ  R14, R13
	ANDQ  R10, R15

	RORXQ $14, R10, R14
	ADDQ  BX, R9
	ANDQ  R8, DI

	XORQ  R14, R13
	RORXQ $39, CX, R14
	XORQ  AX, R15

	XORQ  R12, R14
	RORXQ $28, CX, R12

	XORQ R12, R14
	MOVQ CX, R12
	ANDQ DX, R12
	ADDQ R13, R15

	ORQ  R12, DI
	ADDQ R14, BX
	ADDQ R15, R9
	ADDQ R15, BX

	ADDQ DI, BX

	VPSRLQ $19, Y5, Y3
	VPSLLQ $(64-19), Y5, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8
	VPSRLQ $61, Y5, Y3
	VPSLLQ $(64-61), Y5, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8

	VPADDQ Y8, Y0, Y2

	VPBLENDD $0xF0, Y2, Y5, Y5

	MOVQ  BX, DI
	RORXQ $41, R9, R13
	RORXQ $18, R9, R14
	ADDQ  3*8+frame_YFER(SP), AX
	ORQ   R8, DI

	MOVQ  R10, R15
	RORXQ $34, BX, R12
	XORQ  R14, R13
	XORQ  R11, R15

	RORXQ $14, R9, R14
	ANDQ  R9, R15
	ADDQ  AX, DX
	ANDQ  CX, DI

	XORQ R14, R13
	XORQ R11, R15

	RORXQ $39, BX, R14
	ADDQ  R13, R15

	XORQ R12, R14
	ADDQ R15, DX

	RORXQ $28, BX, R12

	XORQ R12, R14
	MOVQ BX, R12
	ANDQ R8, R12
	ORQ  R12, DI

	ADDQ R14, AX
	ADDQ R15, AX
	ADDQ DI, AX

	VPADDQ  2*32(BP), Y6, Y0
	VMOVDQU Y0, frame_YFER(SP)

	MY_VPALIGNR(Y0, Y5, Y4, 8)

	VPADDQ Y6, Y0, Y0

	MY_VPALIGNR(Y1, Y7, Y6, 8)

	VPSRLQ $1, Y1, Y2
	VPSLLQ $(64-1), Y1, Y3
	VPOR   Y2, Y3, Y3

	VPSRLQ $7, Y1, Y8

	MOVQ  AX, DI
	RORXQ $41, DX, R13
	RORXQ $18, DX, R14
	ADDQ  frame_YFER(SP), R11
	ORQ   CX, DI
	MOVQ  R9, R15
	RORXQ $34, AX, R12

	XORQ  R14, R13
	XORQ  R10, R15
	RORXQ $14, DX, R14

	ANDQ  DX, R15
	XORQ  R14, R13
	RORXQ $39, AX, R14
	ADDQ  R11, R8

	ANDQ  BX, DI
	XORQ  R12, R14
	RORXQ $28, AX, R12

	XORQ R10, R15
	XORQ R12, R14
	MOVQ AX, R12
	ANDQ CX, R12

	ADDQ R13, R15
	ORQ  R12, DI
	ADDQ R14, R11

	ADDQ R15, R8

	ADDQ R15, R11
	ADDQ DI, R11

	VPSRLQ $8, Y1, Y2
	VPSLLQ $(64-8), Y1, Y1
	VPOR   Y2, Y1, Y1

	VPXOR Y8, Y3, Y3
	VPXOR Y1, Y3, Y1

	VPADDQ Y1, Y0, Y0

	VPERM2F128 $0x0, Y0, Y0, Y6

	VPAND MASK_YMM_LO<>(SB), Y0, Y0

	VPERM2F128 $0x11, Y5, Y5, Y2
	VPSRLQ     $6, Y2, Y8

	MOVQ  R11, DI
	RORXQ $41, R8, R13
	RORXQ $18, R8, R14
	ADDQ  1*8+frame_YFER(SP), R10
	ORQ   BX, DI

	MOVQ  DX, R15
	RORXQ $34, R11, R12
	XORQ  R14, R13
	XORQ  R9, R15

	RORXQ $14, R8, R14
	XORQ  R14, R13
	RORXQ $39, R11, R14
	ANDQ  R8, R15
	ADDQ  R10, CX

	ANDQ AX, DI
	XORQ R12, R14

	RORXQ $28, R11, R12
	XORQ  R9, R15

	XORQ R12, R14
	MOVQ R11, R12
	ANDQ BX, R12
	ADDQ R13, R15

	ORQ  R12, DI
	ADDQ R14, R10

	ADDQ R15, CX
	ADDQ R15, R10
	ADDQ DI, R10

	VPSRLQ $19, Y2, Y3
	VPSLLQ $(64-19), Y2, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8
	VPSRLQ $61, Y2, Y3
	VPSLLQ $(64-61), Y2, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8

	VPADDQ Y8, Y6, Y6

	VPSRLQ $6, Y6, Y8

	MOVQ  R10, DI
	RORXQ $41, CX, R13
	ADDQ  2*8+frame_YFER(SP), R9

	RORXQ $18, CX, R14
	ORQ   AX, DI
	MOVQ  R8, R15
	XORQ  DX, R15

	RORXQ $34, R10, R12
	XORQ  R14, R13
	ANDQ  CX, R15

	RORXQ $14, CX, R14
	ADDQ  R9, BX
	ANDQ  R11, DI

	XORQ  R14, R13
	RORXQ $39, R10, R14
	XORQ  DX, R15

	XORQ  R12, R14
	RORXQ $28, R10, R12

	XORQ R12, R14
	MOVQ R10, R12
	ANDQ AX, R12
	ADDQ R13, R15

	ORQ  R12, DI
	ADDQ R14, R9
	ADDQ R15, BX
	ADDQ R15, R9

	ADDQ DI, R9

	VPSRLQ $19, Y6, Y3
	VPSLLQ $(64-19), Y6, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8
	VPSRLQ $61, Y6, Y3
	VPSLLQ $(64-61), Y6, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8

	VPADDQ Y8, Y0, Y2

	VPBLENDD $0xF0, Y2, Y6, Y6

	MOVQ  R9, DI
	RORXQ $41, BX, R13
	RORXQ $18, BX, R14
	ADDQ  3*8+frame_YFER(SP), DX
	ORQ   R11, DI

	MOVQ  CX, R15
	RORXQ $34, R9, R12
	XORQ  R14, R13
	XORQ  R8, R15

	RORXQ $14, BX, R14
	ANDQ  BX, R15
	ADDQ  DX, AX
	ANDQ  R10, DI

	XORQ R14, R13
	XORQ R8, R15

	RORXQ $39, R9, R14
	ADDQ  R13, R15

	XORQ R12, R14
	ADDQ R15, AX

	RORXQ $28, R9, R12

	XORQ R12, R14
	MOVQ R9, R12
	ANDQ R11, R12
	ORQ  R12, DI

	ADDQ R14, DX
	ADDQ R15, DX
	ADDQ DI, DX

	VPADDQ  3*32(BP), Y7, Y0
	VMOVDQU Y0, frame_YFER(SP)
	ADDQ    $(4*32), BP

	MY_VPALIGNR(Y0, Y6, Y5, 8)

	VPADDQ Y7, Y0, Y0

	MY_VPALIGNR(Y1, Y4, Y7, 8)

	VPSRLQ $1, Y1, Y2
	VPSLLQ $(64-1), Y1, Y3
	VPOR   Y2, Y3, Y3

	VPSRLQ $7, Y1, Y8

	MOVQ  DX, DI
	RORXQ $41, AX, R13
	RORXQ $18, AX, R14
	ADDQ  frame_YFER(SP), R8
	ORQ   R10, DI
	MOVQ  BX, R15
	RORXQ $34, DX, R12

	XORQ  R14, R13
	XORQ  CX, R15
	RORXQ $14, AX, R14

	ANDQ  AX, R15
	XORQ  R14, R13
	RORXQ $39, DX, R14
	ADDQ  R8, R11

	ANDQ  R9, DI
	XORQ  R12, R14
	RORXQ $28, DX, R12

	XORQ CX, R15
	XORQ R12, R14
	MOVQ DX, R12
	ANDQ R10, R12

	ADDQ R13, R15
	ORQ  R12, DI
	ADDQ R14, R8

	ADDQ R15, R11

	ADDQ R15, R8
	ADDQ DI, R8

	VPSRLQ $8, Y1, Y2
	VPSLLQ $(64-8), Y1, Y1
	VPOR   Y2, Y1, Y1

	VPXOR Y8, Y3, Y3
	VPXOR Y1, Y3, Y1

	VPADDQ Y1, Y0, Y0

	VPERM2F128 $0x0, Y0, Y0, Y7

	VPAND MASK_YMM_LO<>(SB), Y0, Y0

	VPERM2F128 $0x11, Y6, Y6, Y2
	VPSRLQ     $6, Y2, Y8

	MOVQ  R8, DI
	RORXQ $41, R11, R13
	RORXQ $18, R11, R14
	ADDQ  1*8+frame_YFER(SP), CX
	ORQ   R9, DI

	MOVQ  AX, R15
	RORXQ $34, R8, R12
	XORQ  R14, R13
	XORQ  BX, R15

	RORXQ $14, R11, R14
	XORQ  R14, R13
	RORXQ $39, R8, R14
	ANDQ  R11, R15
	ADDQ  CX, R10

	ANDQ DX, DI
	XORQ R12, R14

	RORXQ $28, R8, R12
	XORQ  BX, R15

	XORQ R12, R14
	MOVQ R8, R12
	ANDQ R9, R12
	ADDQ R13, R15

	ORQ  R12, DI
	ADDQ R14, CX

	ADDQ R15, R10
	ADDQ R15, CX
	ADDQ DI, CX

	VPSRLQ $19, Y2, Y3
	VPSLLQ $(64-19), Y2, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8
	VPSRLQ $61, Y2, Y3
	VPSLLQ $(64-61), Y2, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8

	VPADDQ Y8, Y7, Y7

	VPSRLQ $6, Y7, Y8

	MOVQ  CX, DI
	RORXQ $41, R10, R13
	ADDQ  2*8+frame_YFER(SP), BX

	RORXQ $18, R10, R14
	ORQ   DX, DI
	MOVQ  R11, R15
	XORQ  AX, R15

	RORXQ $34, CX, R12
	XORQ  R14, R13
	ANDQ  R10, R15

	RORXQ $14, R10, R14
	ADDQ  BX, R9
	ANDQ  R8, DI

	XORQ  R14, R13
	RORXQ $39, CX, R14
	XORQ  AX, R15

	XORQ  R12, R14
	RORXQ $28, CX, R12

	XORQ R12, R14
	MOVQ CX, R12
	ANDQ DX, R12
	ADDQ R13, R15

	ORQ  R12, DI
	ADDQ R14, BX
	ADDQ R15, R9
	ADDQ R15, BX

	ADDQ DI, BX

	VPSRLQ $19, Y7, Y3
	VPSLLQ $(64-19), Y7, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8
	VPSRLQ $61, Y7, Y3
	VPSLLQ $(64-61), Y7, Y1
	VPOR   Y1, Y3, Y3
	VPXOR  Y3, Y8, Y8

	VPADDQ Y8, Y0, Y2

	VPBLENDD $0xF0, Y2, Y7, Y7

	MOVQ  BX, DI
	RORXQ $41, R9, R13
	RORXQ $18, R9, R14
	ADDQ  3*8+frame_YFER(SP), AX
	ORQ   R8, DI

	MOVQ  R10, R15
	RORXQ $34, BX, R12
	XORQ  R14, R13
	XORQ  R11, R15

	RORXQ $14, R9, R14
	ANDQ  R9, R15
	ADDQ  AX, DX
	ANDQ  CX, DI

	XORQ R14, R13
	XORQ R11, R15

	RORXQ $39, BX, R14
	ADDQ  R13, R15

	XORQ R12, R14
	ADDQ R15, DX

	RORXQ $28, BX, R12

	XORQ R12, R14
	MOVQ BX, R12
	ANDQ R8, R12
	ORQ  R12, DI

	ADDQ R14, AX
	ADDQ R15, AX
	ADDQ DI, AX

	SUBQ $1, frame_SRND(SP)
	JNE  loop1

	MOVQ $2, frame_SRND(SP)

loop2:
	VPADDQ  (BP), Y4, Y0
	VMOVDQU Y0, frame_YFER(SP)

	MOVQ  R9, R15
	RORXQ $41, DX, R13
	RORXQ $18, DX, R14
	XORQ  R10, R15

	XORQ  R14, R13
	RORXQ $14, DX, R14
	ANDQ  DX, R15

	XORQ  R14, R13
	RORXQ $34, AX, R12
	XORQ  R10, R15
	RORXQ $39, AX, R14
	MOVQ  AX, DI

	XORQ  R12, R14
	RORXQ $28, AX, R12
	ADDQ  frame_YFER(SP), R11
	ORQ   CX, DI

	XORQ R12, R14
	MOVQ AX, R12
	ANDQ BX, DI
	ANDQ CX, R12
	ADDQ R13, R15

	ADDQ R11, R8
	ORQ  R12, DI
	ADDQ R14, R11

	ADDQ R15, R8

	ADDQ  R15, R11
	MOVQ  DX, R15
	RORXQ $41, R8, R13
	RORXQ $18, R8, R14
	XORQ  R9, R15

	XORQ  R14, R13
	RORXQ $14, R8, R14
	ANDQ  R8, R15
	ADDQ  DI, R11

	XORQ  R14, R13
	RORXQ $34, R11, R12
	XORQ  R9, R15
	RORXQ $39, R11, R14
	MOVQ  R11, DI

	XORQ  R12, R14
	RORXQ $28, R11, R12
	ADDQ  8*1+frame_YFER(SP), R10
	ORQ   BX, DI

	XORQ R12, R14
	MOVQ R11, R12
	ANDQ AX, DI
	ANDQ BX, R12
	ADDQ R13, R15

	ADDQ R10, CX
	ORQ  R12, DI
	ADDQ R14, R10

	ADDQ R15, CX

	ADDQ  R15, R10
	MOVQ  R8, R15
	RORXQ $41, CX, R13
	RORXQ $18, CX, R14
	XORQ  DX, R15

	XORQ  R14, R13
	RORXQ $14, CX, R14
	ANDQ  CX, R15
	ADDQ  DI, R10

	XORQ  R14, R13
	RORXQ $34, R10, R12
	XORQ  DX, R15
	RORXQ $39, R10, R14
	MOVQ  R10, DI

	XORQ  R12, R14
	RORXQ $28, R10, R12
	ADDQ  8*2+frame_YFER(SP), R9
	ORQ   AX, DI

	XORQ R12, R14
	MOVQ R10, R12
	ANDQ R11, DI
	ANDQ AX, R12
	ADDQ R13, R15

	ADDQ R9, BX
	ORQ  R12, DI
	ADDQ R14, R9

	ADDQ R15, BX

	ADDQ  R15, R9
	MOVQ  CX, R15
	RORXQ $41, BX, R13
	RORXQ $18, BX, R14
	XORQ  R8, R15

	XORQ  R14, R13
	RORXQ $14, BX, R14
	ANDQ  BX, R15
	ADDQ  DI, R9

	XORQ  R14, R13
	RORXQ $34, R9, R12
	XORQ  R8, R15
	RORXQ $39, R9, R14
	MOVQ  R9, DI

	XORQ  R12, R14
	RORXQ $28, R9, R12
	ADDQ  8*3+frame_YFER(SP), DX
	ORQ   R11, DI

	XORQ R12, R14
	MOVQ R9, R12
	ANDQ R10, DI
	ANDQ R11, R12
	ADDQ R13, R15

	ADDQ DX, AX
	ORQ  R12, DI
	ADDQ R14, DX

	ADDQ R15, AX

	ADDQ R15, DX

	ADDQ DI, DX

	VPADDQ  1*32(BP), Y5, Y0
	VMOVDQU Y0, frame_YFER(SP)
	ADDQ    $(2*32), BP

	MOVQ  BX, R15
	RORXQ $41, AX, R13
	RORXQ $18, AX, R14
	XORQ  CX, R15

	XORQ  R14, R13
	RORXQ $14, AX, R14
	ANDQ  AX, R15

	XORQ  R14, R13
	RORXQ $34, DX, R12
	XORQ  CX, R15
	RORXQ $39, DX, R14
	MOVQ  DX, DI

	XORQ  R12, R14
	RORXQ $28, DX, R12
	ADDQ  frame_YFER(SP), R8
	ORQ   R10, DI

	XORQ R12, R14
	MOVQ DX, R12
	ANDQ R9, DI
	ANDQ R10, R12
	ADDQ R13, R15

	ADDQ R8, R11
	ORQ  R12, DI
	ADDQ R14, R8

	ADDQ R15, R11

	ADDQ  R15, R8
	MOVQ  AX, R15
	RORXQ $41, R11, R13
	RORXQ $18, R11, R14
	XORQ  BX, R15

	XORQ  R14, R13
	RORXQ $14, R11, R14
	ANDQ  R11, R15
	ADDQ  DI, R8

	XORQ  R14, R13
	RORXQ $34, R8, R12
	XORQ  BX, R15
	RORXQ $39, R8, R14
	MOVQ  R8, DI

	XORQ  R12, R14
	RORXQ $28, R8, R12
	ADDQ  8*1+frame_YFER(SP), CX
	ORQ   R9, DI

	XORQ R12, R14
	MOVQ R8, R12
	ANDQ DX, DI
	ANDQ R9, R12
	ADDQ R13, R15

	ADDQ CX, R10
	ORQ  R12, DI
	ADDQ R14, CX

	ADDQ R15, R10

	ADDQ  R15, CX
	MOVQ  R11, R15
	RORXQ $41, R10, R13
	RORXQ $18, R10, R14
	XORQ  AX, R15

	XORQ  R14, R13
	RORXQ $14, R10, R14
	ANDQ  R10, R15
	ADDQ  DI, CX

	XORQ  R14, R13
	RORXQ $34, CX, R12
	XORQ  AX, R15
	RORXQ $39, CX, R14
	MOVQ  CX, DI

	XORQ  R12, R14
	RORXQ $28, CX, R12
	ADDQ  8*2+frame_YFER(SP), BX
	ORQ   DX, DI

	XORQ R12, R14
	MOVQ CX, R12
	ANDQ R8, DI
	ANDQ DX, R12
	ADDQ R13, R15

	ADDQ BX, R9
	ORQ  R12, DI
	ADDQ R14, BX

	ADDQ R15, R9

	ADDQ  R15, BX
	MOVQ  R10, R15
	RORXQ $41, R9, R13
	RORXQ $18, R9, R14
	XORQ  R11, R15

	XORQ  R14, R13
	RORXQ $14, R9, R14
	ANDQ  R9, R15
	ADDQ  DI, BX

	XORQ  R14, R13
	RORXQ $34, BX, R12
	XORQ  R11, R15
	RORXQ $39, BX, R14
	MOVQ  BX, DI

	XORQ  R12, R14
	RORXQ $28, BX, R12
	ADDQ  8*3+frame_YFER(SP), AX
	ORQ   R8, DI

	XORQ R12, R14
	MOVQ BX, R12
	ANDQ CX, DI
	ANDQ R8, R12
	ADDQ R13, R15

	ADDQ AX, DX
	ORQ  R12, DI
	ADDQ R14, AX

	ADDQ R15, DX

	ADDQ R15, AX

	ADDQ DI, AX

	VMOVDQU Y6, Y4
	VMOVDQU Y7, Y5

	SUBQ $1, frame_SRND(SP)
	JNE  loop2

	addm(8*0(SI),AX)
	addm(8*1(SI),BX)
	addm(8*2(SI),CX)
	addm(8*3(SI),R8)
	addm(8*4(SI),DX)
	addm(8*5(SI),R9)
	addm(8*6(SI),R10)
	addm(8*7(SI),R11)

	MOVQ frame_INP(SP), DI
	ADDQ $128, DI
	CMPQ DI, frame_INPEND(SP)
	JNE  loop0

done_hash:
	VZEROUPPER
	RET
