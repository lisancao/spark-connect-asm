# Text output: a 64 KiB buffer flushed to out_fd, and formatters for every cell type.
# Ported function for function from the wasm client's emit_* routines.
	.include "src/layout.inc"
	.text
	.globl flush, emit, emits, emit_u64_pad, emit_u64, emit_i64, emit_decimal, emit_f64
	.globl emit_date, emit_timestamp_us, emit_hex, emit_json_string, out_fd, out_len

flush:
	mov out_len(%rip), %edx
	test %edx, %edx
	jz 1f
	mov out_fd(%rip), %edi
	lea mem+OUT(%rip), %rsi
	call sys_write
	movl $0, out_len(%rip)
1:	ret

# emit(byte in dil)
emit:
	cmpl $OUT_CAP, out_len(%rip)
	jb 1f
	push %rdi
	call flush
	pop %rdi
1:	mov out_len(%rip), %eax
	lea mem+OUT(%rip), %rcx
	mov %dil, (%rcx,%rax)
	incl out_len(%rip)
	ret

# emits(ptr, n)
emits:
	push %rbx
	push %r12
	mov %rdi, %rbx
	mov %esi, %r12d
1:	test %r12d, %r12d
	jz 2f
	movzbl (%rbx), %edi
	call emit
	inc %rbx
	dec %r12d
	jmp 1b
2:	pop %r12
	pop %rbx
	ret

# emit_u64_pad(v, width): unsigned decimal, left-padded with zeros to width
emit_u64_pad:
	push %rbx
	push %r12
	push %r13
	mov %rdi, %rax
	mov %esi, %r13d                 # width
	lea mem+DIGITS_END(%rip), %r12  # p (fill backwards)
	xor %ebx, %ebx                  # n
	mov $10, %rcx
1:	xor %edx, %edx
	div %rcx
	add $48, %dl
	dec %r12
	mov %dl, (%r12)
	inc %ebx
	test %rax, %rax
	jnz 1b
2:	cmp %r13d, %ebx
	jae 3f
	dec %r12
	movb $48, (%r12)
	inc %ebx
	jmp 2b
3:	mov %r12, %rdi
	mov %ebx, %esi
	call emits
	pop %r13
	pop %r12
	pop %rbx
	ret

emit_u64:
	mov $1, %esi
	jmp emit_u64_pad

emit_i64:
	test %rdi, %rdi
	jns emit_u64
	push %rdi
	mov $45, %edi
	call emit
	pop %rdi
	neg %rdi
	jmp emit_u64

# emit_decimal(v signed, scale): digits with a point before the last `scale` of them
emit_decimal:
	push %rbx
	push %r12
	push %r13
	push %r14
	mov %rdi, %rbx
	mov %esi, %r13d                 # scale
	test %rbx, %rbx
	jns 1f
	mov $45, %edi
	call emit
	neg %rbx
1:	mov %rbx, %rax
	lea mem+DIGITS_END(%rip), %r12
	xor %r14d, %r14d                # n
	mov $10, %rcx
2:	xor %edx, %edx
	div %rcx
	add $48, %dl
	dec %r12
	mov %dl, (%r12)
	inc %r14d
	test %rax, %rax
	jnz 2b
	cmp %r13d, %r14d
	jbe 2b                          # at least scale+1 digits (rax is 0 here: pads zeros)
	mov %r12, %rdi
	mov %r14d, %esi
	sub %r13d, %esi
	call emits
	test %r13d, %r13d
	jz 3f
	mov $46, %edi
	call emit
	mov %r14d, %eax
	sub %r13d, %eax
	lea (%r12,%rax), %rdi
	mov %r13d, %esi
	call emits
3:	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# emit_f64(xmm0): 15 significant digits, trailing zeros trimmed, fixed for exponents in
# [-5, 15), otherwise d.dddE±x.
	.section .rodata
	.balign 8
f_ten:	.double 10.0
f_one:	.double 1.0
f_1e14:	.double 1e14
f_inf:	.quad 0x7ff0000000000000
f_absmask: .quad 0x7fffffffffffffff
s_nan:	.ascii "NaN"
s_inf:	.ascii "Infinity"
s_ninf:	.ascii "-Infinity"
	.text
emit_f64:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	sub $16, %rsp
	ucomisd %xmm0, %xmm0
	jnp 1f
	lea s_nan(%rip), %rdi
	mov $3, %esi
	call emits
	jmp 9f
1:	movsd f_inf(%rip), %xmm1
	ucomisd %xmm1, %xmm0
	jne 2f
	lea s_inf(%rip), %rdi
	mov $8, %esi
	call emits
	jmp 9f
2:	xorpd %xmm1, %xmm1
	subsd f_inf(%rip), %xmm1
	ucomisd %xmm1, %xmm0
	jne 3f
	lea s_ninf(%rip), %rdi
	mov $9, %esi
	call emits
	jmp 9f
3:	xorpd %xmm1, %xmm1
	ucomisd %xmm1, %xmm0
	jne 4f
	lea s_zero(%rip), %rdi
	mov $3, %esi
	call emits
	jmp 9f
4:	movsd %xmm0, (%rsp)
	xorpd %xmm1, %xmm1
	ucomisd %xmm0, %xmm1
	jbe 5f                          # x >= 0
	mov $45, %edi
	call emit
5:	movsd (%rsp), %xmm0
	andpd f_absmask(%rip), %xmm0    # a = |x|
	xor %ebx, %ebx                  # e
	movsd f_ten(%rip), %xmm2
	movsd f_one(%rip), %xmm3
6:	ucomisd %xmm2, %xmm0            # while a >= 10
	jb 7f
	divsd %xmm2, %xmm0
	inc %ebx
	jmp 6b
7:	ucomisd %xmm3, %xmm0            # while a < 1
	jae 8f
	mulsd %xmm2, %xmm0
	dec %ebx
	jmp 7b
8:	mulsd f_1e14(%rip), %xmm0
	roundsd $8, %xmm0, %xmm0        # nearest even
	cvttsd2si %xmm0, %rax           # m
	mov $1000000000000000, %rcx
	cmp %rcx, %rax
	jl 10f
	xor %edx, %edx
	mov $10, %rcx
	div %rcx
	inc %ebx
10:	# 15 digits into DIGITS..DIGITS+14
	lea mem+DIGITS+14(%rip), %r12
	mov $10, %rcx
11:	xor %edx, %edx
	div %rcx
	add $48, %dl
	mov %dl, (%r12)
	dec %r12
	lea mem+DIGITS(%rip), %rdx
	cmp %rdx, %r12
	jae 11b
	# n = significant digits after trimming trailing zeros (>= 1)
	mov $15, %r13d
	lea mem+DIGITS(%rip), %r12
12:	cmp $1, %r13d
	jbe 13f
	cmpb $48, -1(%r12,%r13)
	jne 13f
	dec %r13d
	jmp 12b
13:	cmp $-5, %ebx
	jl 30f
	cmp $15, %ebx
	jge 30f
	test %ebx, %ebx
	js 20f
	# fixed, e >= 0: integer part is digits 0..e (zeros past 15), then "." and the rest
	lea 1(%rbx), %r14d              # intd
	xor %r15d, %r15d
14:	cmp %r14d, %r15d
	jae 15f
	mov $48, %edi
	cmp $15, %r15d
	jae 16f
	movzbl (%r12,%r15), %edi
16:	call emit
	inc %r15d
	jmp 14b
15:	mov $46, %edi
	call emit
	cmp %r14d, %r13d
	jbe 17f
	lea (%r12,%r14), %rdi
	mov %r13d, %esi
	sub %r14d, %esi
	call emits
	jmp 9f
17:	mov $48, %edi
	call emit
	jmp 9f
20:	# fixed, e < 0: 0.000ddd
	mov $48, %edi
	call emit
	mov $46, %edi
	call emit
	mov $-1, %r15d
	sub %ebx, %r15d                 # zeros = -1 - e
21:	test %r15d, %r15d
	jz 22f
	mov $48, %edi
	call emit
	dec %r15d
	jmp 21b
22:	mov %r12, %rdi
	mov %r13d, %esi
	call emits
	jmp 9f
30:	# exponent form
	movzbl (%r12), %edi
	call emit
	mov $46, %edi
	call emit
	cmp $1, %r13d
	jbe 31f
	lea 1(%r12), %rdi
	lea -1(%r13), %esi
	call emits
	jmp 32f
31:	mov $48, %edi
	call emit
32:	mov $69, %edi
	call emit
	movslq %ebx, %rdi
	call emit_i64
9:	add $16, %rsp
	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret
	.section .rodata
s_zero:	.ascii "0.0"
	.text

# emit_date(days since 1970-01-01): yyyy-mm-dd, Howard Hinnant's civil_from_days
emit_date:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	add $719468, %rdi               # z
	mov %rdi, %rax
	test %rax, %rax
	jns 1f
	sub $146096, %rax
1:	cqo
	mov $146097, %rcx
	idiv %rcx                       # era
	mov %rax, %r12
	imul $146097, %r12, %rax
	mov %rdi, %rbx
	sub %rax, %rbx                  # doe
	# yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
	mov %rbx, %rax
	cqo
	mov $1460, %rcx
	idiv %rcx
	mov %rbx, %r13
	sub %rax, %r13
	mov %rbx, %rax
	cqo
	mov $36524, %rcx
	idiv %rcx
	add %rax, %r13
	mov %rbx, %rax
	cqo
	mov $146096, %rcx
	idiv %rcx
	sub %rax, %r13
	mov %r13, %rax
	cqo
	mov $365, %rcx
	idiv %rcx
	mov %rax, %r13                  # yoe
	imul $400, %r12, %r14
	add %r13, %r14                  # y = yoe + era*400
	# doy = doe - (365*yoe + yoe/4 - yoe/100)
	imul $365, %r13, %r15
	mov %r13, %rax
	cqo
	mov $4, %rcx
	idiv %rcx
	add %rax, %r15
	mov %r13, %rax
	cqo
	mov $100, %rcx
	idiv %rcx
	sub %rax, %r15
	mov %rbx, %rax
	sub %r15, %rax                  # doy
	mov %rax, %rbx
	# mp = (5*doy + 2) / 153
	lea 2(%rax,%rax,4), %rax
	cqo
	mov $153, %rcx
	idiv %rcx
	mov %rax, %r15                  # mp
	# d = doy - (153*mp + 2)/5 + 1
	imul $153, %r15, %rax
	add $2, %rax
	cqo
	mov $5, %rcx
	idiv %rcx
	sub %rax, %rbx
	inc %rbx                        # d
	# m = mp < 10 ? mp + 3 : mp - 9
	lea 3(%r15), %r12
	cmp $10, %r15
	jl 2f
	lea -9(%r15), %r12
2:	cmp $2, %r12
	jg 3f
	inc %r14
3:	test %r14, %r14
	jns 4f
	mov $45, %edi
	call emit
	neg %r14
4:	mov %r14, %rdi
	mov $4, %esi
	call emit_u64_pad
	mov $45, %edi
	call emit
	mov %r12, %rdi
	mov $2, %esi
	call emit_u64_pad
	mov $45, %edi
	call emit
	mov %rbx, %rdi
	mov $2, %esi
	call emit_u64_pad
	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# emit_timestamp_us(us since epoch): "yyyy-mm-dd hh:mm:ss[.ffffff]"
emit_timestamp_us:
	push %rbx
	push %r12
	push %r13
	mov %rdi, %rax
	cqo
	mov $86400000000, %rcx
	idiv %rcx                       # rax days, rdx sod
	mov %rax, %rbx
	mov %rdx, %r12
	test %r12, %r12
	jns 1f
	dec %rbx
	add %rcx, %r12
1:	mov %rbx, %rdi
	call emit_date
	mov $32, %edi
	call emit
	mov %r12, %rax
	xor %edx, %edx
	mov $1000000, %rcx
	div %rcx
	mov %rdx, %r13                  # frac
	mov %rax, %r12                  # seconds of day
	xor %edx, %edx
	mov $3600, %rcx
	div %rcx
	mov %rax, %rdi
	mov $2, %esi
	call emit_u64_pad
	mov $58, %edi
	call emit
	mov %r12, %rax
	xor %edx, %edx
	mov $60, %rcx
	div %rcx
	xor %edx, %edx
	div %rcx
	mov %rdx, %rdi
	mov $2, %esi
	call emit_u64_pad
	mov $58, %edi
	call emit
	mov %r12, %rax
	xor %edx, %edx
	mov $60, %rcx
	div %rcx
	mov %rdx, %rdi
	mov $2, %esi
	call emit_u64_pad
	test %r13, %r13
	jz 3f
	mov $46, %edi
	call emit
	mov $6, %ebx
2:	mov %r13, %rax
	xor %edx, %edx
	mov $10, %rcx
	div %rcx
	test %rdx, %rdx
	jnz 4f
	mov %rax, %r13
	dec %ebx
	jmp 2b
4:	mov %r13, %rdi
	mov %ebx, %esi
	call emit_u64_pad
3:	pop %r13
	pop %r12
	pop %rbx
	ret

# emit_hex(ptr, n): uppercase hex
	.section .rodata
hexdigits: .ascii "0123456789ABCDEF"
hexlower:  .ascii "0123456789abcdef"
	.text
	.globl hexlower
emit_hex:
	push %rbx
	push %r12
	mov %rdi, %rbx
	mov %esi, %r12d
1:	test %r12d, %r12d
	jz 2f
	movzbl (%rbx), %eax
	shr $4, %eax
	lea hexdigits(%rip), %rcx
	movzbl (%rcx,%rax), %edi
	call emit
	movzbl (%rbx), %eax
	and $15, %eax
	lea hexdigits(%rip), %rcx
	movzbl (%rcx,%rax), %edi
	call emit
	inc %rbx
	dec %r12d
	jmp 1b
2:	pop %r12
	pop %rbx
	ret

# emit_json_string(ptr, n): quoted and escaped
emit_json_string:
	push %rbx
	push %r12
	mov %rdi, %rbx
	mov %esi, %r12d
	mov $34, %edi
	call emit
1:	test %r12d, %r12d
	jz 9f
	movzbl (%rbx), %eax
	xor %ecx, %ecx
	cmp $10, %al
	jne 2f
	mov $110, %ecx
2:	cmp $13, %al
	jne 3f
	mov $114, %ecx
3:	cmp $9, %al
	jne 4f
	mov $116, %ecx
4:	cmp $34, %al
	je 5f
	cmp $92, %al
	jne 6f
5:	mov %eax, %ecx
6:	test %ecx, %ecx
	jz 7f
	push %rcx
	mov $92, %edi
	call emit
	pop %rdi
	call emit
	jmp 8f
7:	cmp $32, %al
	jae 10f
	push %rax
	lea s_u00(%rip), %rdi
	mov $4, %esi
	call emits
	pop %rax
	push %rax
	shr $4, %eax
	lea hexlower(%rip), %rcx
	movzbl (%rcx,%rax), %edi
	call emit
	pop %rax
	and $15, %eax
	lea hexlower(%rip), %rcx
	movzbl (%rcx,%rax), %edi
	call emit
	jmp 8f
10:	mov %eax, %edi
	call emit
8:	inc %rbx
	dec %r12d
	jmp 1b
9:	mov $34, %edi
	call emit
	pop %r12
	pop %rbx
	ret
	.section .rodata
s_u00:	.ascii "\\u00"

	.data
out_fd:	.long 1
	.bss
out_len: .long 0
