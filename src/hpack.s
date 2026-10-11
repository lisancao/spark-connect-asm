# HPACK: Huffman decoding, the static and dynamic tables, header block decoding, and the
# integer/string encoder for request headers. Tables come from hpack_tables.s (RFC 7541).
	.include "src/layout.inc"
	.text
	.globl huff_build, hp_decode, hp_wint, hp_wstr, hp_err, hpack_reset, http_status, grpc_status, gmsg_ptr, gmsg_len

# ---- Huffman ------------------------------------------------------------------------
# build the decode tree at mem+HUFF_TREE: node = 8 bytes {left i32, right i32};
# a slot holds a child node address (offset from mem, < 0x80000000) or 0x80000000|symbol
huff_build:
	push %rbx
	push %r12
	push %r13
	push %r14
	lea mem(%rip), %r14
	movl $HUFF_TREE+8, huff_next(%rip)
	xor %r12d, %r12d                # sym
1:	lea huff_table(%rip), %rax
	mov (%rax,%r12,8), %ebx         # code
	mov 4(%rax,%r12,8), %r13d       # len
	mov $HUFF_TREE, %ecx            # node offset
2:	dec %r13d
	mov %ebx, %eax
	push %rcx
	mov %r13d, %ecx
	shr %cl, %eax
	pop %rcx
	and $1, %eax
	lea (%rcx,%rax,4), %edx         # slot offset
	test %r13d, %r13d
	jnz 3f
	mov %r12d, %eax
	or $0x80000000, %eax
	mov %eax, (%r14,%rdx)
	jmp 5f
3:	mov (%r14,%rdx), %eax
	test %eax, %eax
	jnz 4f
	mov huff_next(%rip), %eax
	addl $8, huff_next(%rip)
	movq $0, (%r14,%rax)
	mov %eax, (%r14,%rdx)
4:	mov %eax, %ecx
	jmp 2b
5:	inc %r12d
	cmp $257, %r12d
	jb 1b
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# huff_decode(src, n, dst, cap) -> eax decoded length (sets hp_err on a bad code)
huff_decode:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	mov %rdi, %rbx
	mov %esi, %r12d
	mov %rdx, %r13
	mov %ecx, %r14d
	xor %r15d, %r15d                # out
	mov $HUFF_TREE, %r8d            # node offset
	lea mem(%rip), %r9
1:	test %r12d, %r12d
	jz 9f
	movzbl (%rbx), %r10d
	mov $8, %r11d
2:	dec %r11d
	mov %r10d, %eax
	mov %r11d, %ecx
	shr %cl, %eax
	and $1, %eax
	lea (%r8,%rax,4), %edx
	mov (%r9,%rdx), %eax
	test $0x80000000, %eax
	jz 3f
	and $0xffff, %eax
	cmp %r14d, %r15d
	jae 21f
	mov %al, (%r13,%r15)
21:	inc %r15d
	mov $HUFF_TREE, %r8d
	jmp 4f
3:	test %eax, %eax
	jnz 31f
	movl $1, hp_err(%rip)
	jmp 9f
31:	mov %eax, %r8d
4:	test %r11d, %r11d
	jnz 2b
	inc %rbx
	dec %r12d
	jmp 1b
9:	mov %r15d, %eax
	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# ---- decoding primitives (hp_p / hp_end) ---------------------------------------------
# hp_int(prefix bits) -> eax
hp_int:
	mov %edi, %ecx
	mov $1, %r8d
	shl %cl, %r8d
	dec %r8d                        # mask
	mov hp_p(%rip), %rsi
	movzbl (%rsi), %eax
	inc %rsi
	mov %rsi, hp_p(%rip)
	and %r8d, %eax
	cmp %r8d, %eax
	jb 9f
	xor %ecx, %ecx                  # m
1:	cmp hp_end(%rip), %rsi
	jb 2f
	movl $1, hp_err(%rip)
	xor %eax, %eax
	ret
2:	movzbl (%rsi), %edx
	inc %rsi
	mov %rsi, hp_p(%rip)
	mov %edx, %edi
	and $127, %edi
	shl %cl, %edi
	add %edi, %eax
	add $7, %ecx
	test $128, %dl
	jnz 1b
9:	ret

# hp_string(dst, cap) -> eax length stored (input always consumed)
hp_string:
	push %rbx
	push %r12
	push %r13
	mov %rdi, %rbx
	mov %esi, %r12d
	mov hp_p(%rip), %rax
	movzbl (%rax), %r13d
	and $0x80, %r13d                # huffman flag
	mov $7, %edi
	call hp_int
	mov hp_p(%rip), %rsi
	lea (%rsi,%rax), %rcx
	cmp hp_end(%rip), %rcx
	jbe 1f
	movl $1, hp_err(%rip)
	xor %eax, %eax
	jmp 9f
1:	mov %eax, %edx                  # n
	test %r13d, %r13d
	jz 2f
	mov %rsi, %rdi
	mov %edx, %esi
	push %rdx
	mov %rbx, %rdx
	mov %r12d, %ecx
	call huff_decode
	pop %rdx
	add %rdx, hp_p(%rip)
	cmp %r12d, %eax
	cmova %r12d, %eax
	jmp 9f
2:	mov %edx, %ecx
	cmp %r12d, %ecx
	cmova %r12d, %ecx
	mov %ecx, %eax
	push %rax
	mov %rbx, %rdi
	rep movsb
	pop %rax
	add %rdx, hp_p(%rip)
9:	pop %r13
	pop %r12
	pop %rbx
	ret

# tbl_entry(idx) -> rax entry address (E_* layout) or 0
tbl_entry:
	test %edi, %edi
	jz 8f
	cmp $61, %edi
	ja 1f
	dec %edi
	lea static_idx(%rip), %rax
	lea (%rax,%rdi,8), %rax
	lea static_str(%rip), %rcx
	lea mem+STATIC_REC(%rip), %rdx
	movzwl (%rax), %esi
	add %rcx, %rsi
	mov %rsi, E_NAME(%rdx)
	movzwl 2(%rax), %esi
	mov %esi, E_NLEN(%rdx)
	movzwl 4(%rax), %esi
	add %rcx, %rsi
	mov %rsi, E_VAL(%rdx)
	movzwl 6(%rax), %esi
	mov %esi, E_VLEN(%rdx)
	mov %rdx, %rax
	ret
1:	sub $62, %edi
	cmp dyn_count(%rip), %edi
	jae 8f
	mov dyn_head(%rip), %eax
	sub %edi, %eax
	and $127, %eax
	shl $5, %eax
	lea mem+DYN_TABLE(%rip), %rcx
	add %rcx, %rax
	ret
8:	xor %eax, %eax
	ret

tbl_name:
	call tbl_entry
	test %rax, %rax
	jz 1f
	mov E_NLEN(%rax), %ecx
	mov %ecx, name_len(%rip)
	mov E_NAME(%rax), %rsi
	lea mem+NAME_BUF(%rip), %rdi
	rep movsb
	ret
1:	movl $1, hp_err(%rip)
	ret

tbl_value:
	call tbl_entry
	test %rax, %rax
	jz 1f
	mov E_VLEN(%rax), %ecx
	mov %ecx, val_len(%rip)
	mov E_VAL(%rax), %rsi
	lea mem+VAL_BUF(%rip), %rdi
	rep movsb
	ret
1:	movl $1, hp_err(%rip)
	ret

# ---- dynamic table ------------------------------------------------------------------
dyn_oldest:                             # -> rax entry address of the oldest entry
	mov dyn_head(%rip), %eax
	sub dyn_count(%rip), %eax
	inc %eax
	and $127, %eax
	shl $5, %eax
	lea mem+DYN_TABLE(%rip), %rcx
	add %rcx, %rax
	ret

dyn_evict_oldest:
	call dyn_oldest
	mov E_NLEN(%rax), %ecx
	add E_VLEN(%rax), %ecx
	add $32, %ecx
	sub %ecx, dyn_size(%rip)
	decl dyn_count(%rip)
	ret

# dyn_evict_to(limit)
dyn_evict_to:
	push %rbx
	mov %edi, %ebx
1:	cmp %ebx, dyn_size(%rip)
	jbe 2f
	cmpl $0, dyn_count(%rip)
	je 2f
	call dyn_evict_oldest
	jmp 1b
2:	pop %rbx
	ret

# copy live strings into the other arena half, oldest first
arena_compact:
	push %rbx
	push %r12
	push %r13
	mov $ARENA_B, %r12d
	cmpl $ARENA_A, arena_base(%rip)
	je 1f
	mov $ARENA_A, %r12d
1:	lea mem(%rip), %rax
	add %rax, %r12                  # new base (absolute)
	mov %r12, %r13                  # wp
	xor %ebx, %ebx                  # k
2:	cmp dyn_count(%rip), %ebx
	jae 5f
	mov dyn_head(%rip), %eax
	sub dyn_count(%rip), %eax
	inc %eax
	add %ebx, %eax
	and $127, %eax
	shl $5, %eax
	lea mem+DYN_TABLE(%rip), %rcx
	add %rcx, %rax                  # entry
	mov E_NLEN(%rax), %ecx
	mov E_NAME(%rax), %rsi
	mov %r13, %rdi
	mov %r13, E_NAME(%rax)
	rep movsb
	mov %rdi, %r13
	mov E_VLEN(%rax), %ecx
	mov E_VAL(%rax), %rsi
	mov %r13, %rdi
	mov %r13, E_VAL(%rax)
	rep movsb
	mov %rdi, %r13
	inc %ebx
	jmp 2b
5:	lea mem(%rip), %rax
	sub %rax, %r12
	mov %r12d, arena_base(%rip)
	sub %rax, %r13
	mov %r13d, arena_wp(%rip)
	pop %r13
	pop %r12
	pop %rbx
	ret

# dyn_add: insert the header in NAME_BUF/VAL_BUF
dyn_add:
	push %rbx
	mov name_len(%rip), %ebx
	add val_len(%rip), %ebx
	add $32, %ebx                   # size
	cmp dyn_max(%rip), %ebx
	jbe 1f
	movl $0, dyn_count(%rip)
	movl $0, dyn_size(%rip)
	jmp 9f
1:	mov dyn_max(%rip), %edi
	sub %ebx, %edi
	call dyn_evict_to
	mov arena_wp(%rip), %eax
	lea -32(%rax,%rbx), %eax
	mov arena_base(%rip), %ecx
	add $0x2000, %ecx
	cmp %ecx, %eax
	jbe 2f
	call arena_compact
2:	mov dyn_head(%rip), %eax
	inc %eax
	and $127, %eax
	mov %eax, dyn_head(%rip)
	incl dyn_count(%rip)
	add %ebx, dyn_size(%rip)
	shl $5, %eax
	lea mem+DYN_TABLE(%rip), %rdx
	add %rax, %rdx                  # entry
	lea mem(%rip), %r8
	mov arena_wp(%rip), %edi
	add %r8, %rdi
	mov %rdi, E_NAME(%rdx)
	mov name_len(%rip), %ecx
	mov %ecx, E_NLEN(%rdx)
	lea mem+NAME_BUF(%rip), %rsi
	rep movsb
	mov %rdi, E_VAL(%rdx)
	mov val_len(%rip), %ecx
	mov %ecx, E_VLEN(%rdx)
	lea mem+VAL_BUF(%rip), %rsi
	rep movsb
	sub %r8, %rdi
	mov %edi, arena_wp(%rip)
9:	pop %rbx
	ret

# str_eq(a, alen, b, blen) -> eax
str_eq:
	cmp %esi, %ecx
	jne 2f
	mov %esi, %ecx
	mov %rdx, %rsi
	repe cmpsb
	jne 2f
	mov $1, %eax
	ret
2:	xor %eax, %eax
	ret

# parse_int(p, n) -> eax
parse_int:
	xor %eax, %eax
1:	test %esi, %esi
	jz 9f
	movzbl (%rdi), %ecx
	sub $48, %ecx
	cmp $9, %ecx
	ja 9f
	imul $10, %eax
	add %ecx, %eax
	inc %rdi
	dec %esi
	jmp 1b
9:	ret

# hexval(c) -> eax or -1
hexval:
	lea -48(%rdi), %eax
	cmp $9, %eax
	jbe 1f
	or $32, %edi
	lea -97(%rdi), %eax
	cmp $5, %eax
	ja 2f
	add $10, %eax
	ret
2:	mov $-1, %eax
1:	ret

# decode_message: percent-decode VAL_BUF into a fresh heap buffer (gmsg_ptr/gmsg_len)
decode_message:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	mov val_len(%rip), %edi
	call alloc
	mov %rax, %r12                  # out
	mov %rax, gmsg_ptr(%rip)
	lea mem+VAL_BUF(%rip), %rbx     # in
	xor %r13d, %r13d                # o
	xor %r14d, %r14d                # i
1:	cmp val_len(%rip), %r14d
	jae 9f
	movzbl (%rbx,%r14), %r15d
	cmp $37, %r15d
	jne 5f
	lea 2(%r14), %eax
	cmp val_len(%rip), %eax
	jae 5f
	movzbl 1(%rbx,%r14), %edi
	call hexval
	test %eax, %eax
	js 5f
	mov %eax, %ecx
	shl $4, %ecx
	push %rcx
	movzbl 2(%rbx,%r14), %edi
	call hexval
	pop %rcx
	test %eax, %eax
	js 5f
	or %eax, %ecx
	mov %ecx, %r15d
	add $2, %r14d
5:	mov %r15b, (%r12,%r13)
	inc %r13d
	inc %r14d
	jmp 1b
9:	mov %r13d, gmsg_len(%rip)
	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# on_header: keep :status, grpc-status, grpc-message
on_header:
	lea mem+NAME_BUF(%rip), %rdi
	mov name_len(%rip), %esi
	lea s_status(%rip), %rdx
	mov $7, %ecx
	call str_eq
	test %eax, %eax
	jz 1f
	lea mem+VAL_BUF(%rip), %rdi
	mov val_len(%rip), %esi
	call parse_int
	mov %eax, http_status(%rip)
	ret
1:	lea mem+NAME_BUF(%rip), %rdi
	mov name_len(%rip), %esi
	lea s_grpc_status(%rip), %rdx
	mov $11, %ecx
	call str_eq
	test %eax, %eax
	jz 2f
	lea mem+VAL_BUF(%rip), %rdi
	mov val_len(%rip), %esi
	call parse_int
	mov %eax, grpc_status(%rip)
	ret
2:	lea mem+NAME_BUF(%rip), %rdi
	mov name_len(%rip), %esi
	lea s_grpc_message(%rip), %rdx
	mov $12, %ecx
	call str_eq
	test %eax, %eax
	jz 3f
	jmp decode_message
3:	ret

# hp_decode(p, end)
hp_decode:
	push %rbx
	mov %rdi, hp_p(%rip)
	mov %rsi, hp_end(%rip)
	movl $0, hp_err(%rip)
1:	mov hp_p(%rip), %rax
	cmp hp_end(%rip), %rax
	jae 9f
	cmpl $0, hp_err(%rip)
	jne 9f
	movzbl (%rax), %ebx
	test $0x80, %bl
	jz 2f
	mov $7, %edi                    # indexed
	call hp_int
	mov %eax, %ebx
	mov %eax, %edi
	call tbl_name
	mov %ebx, %edi
	call tbl_value
	cmpl $0, hp_err(%rip)
	jne 1b
	call on_header
	jmp 1b
2:	mov %ebx, %eax
	and $0xC0, %eax
	cmp $0x40, %eax
	jne 3f
	mov $6, %edi                    # literal with incremental indexing
	call hp_int
	call read_name
	lea mem+VAL_BUF(%rip), %rdi
	mov $VAL_CAP, %esi
	call hp_string
	mov %eax, val_len(%rip)
	cmpl $0, hp_err(%rip)
	jne 1b
	call dyn_add
	call on_header
	jmp 1b
3:	mov %ebx, %eax
	and $0xE0, %eax
	cmp $0x20, %eax
	jne 4f
	mov $5, %edi                    # table size update
	call hp_int
	mov %eax, dyn_max(%rip)
	mov %eax, %edi
	call dyn_evict_to
	jmp 1b
4:	mov $4, %edi                    # literal without / never indexed
	call hp_int
	call read_name
	lea mem+VAL_BUF(%rip), %rdi
	mov $VAL_CAP, %esi
	call hp_string
	mov %eax, val_len(%rip)
	cmpl $0, hp_err(%rip)
	jne 1b
	call on_header
	jmp 1b
9:	pop %rbx
	ret

# read_name(idx in eax): from the table, or a string literal
read_name:
	test %eax, %eax
	jz 1f
	mov %eax, %edi
	jmp tbl_name
1:	lea mem+NAME_BUF(%rip), %rdi
	mov $NAME_CAP, %esi
	call hp_string
	mov %eax, name_len(%rip)
	ret

# ---- encoding (writes at wp2) --------------------------------------------------------
# hp_wint(prefix, first byte bits, value)
hp_wint:
	mov %edi, %ecx
	mov $1, %eax
	shl %cl, %eax
	dec %eax                        # mask
	mov wp2(%rip), %rcx
	cmp %eax, %edx
	jae 1f
	or %edx, %esi
	mov %sil, (%rcx)
	inc %rcx
	mov %rcx, wp2(%rip)
	ret
1:	or %eax, %esi
	mov %sil, (%rcx)
	inc %rcx
	sub %eax, %edx
2:	cmp $128, %edx
	jb 3f
	mov %edx, %eax
	and $127, %eax
	or $128, %eax
	mov %al, (%rcx)
	inc %rcx
	shr $7, %edx
	jmp 2b
3:	mov %dl, (%rcx)
	inc %rcx
	mov %rcx, wp2(%rip)
	ret

# hp_wstr(ptr, n): length with 7-bit prefix, then raw bytes
hp_wstr:
	push %rdi
	push %rsi
	mov %esi, %edx
	mov $7, %edi
	xor %esi, %esi
	call hp_wint
	pop %rcx
	pop %rsi
	mov wp2(%rip), %rdi
	rep movsb
	mov %rdi, wp2(%rip)
	ret

hpack_reset:
	movl $0, dyn_count(%rip)
	movl $0, dyn_head(%rip)
	movl $0, dyn_size(%rip)
	movl $4096, dyn_max(%rip)
	movl $ARENA_A, arena_base(%rip)
	movl $ARENA_A, arena_wp(%rip)
	ret

	.section .rodata
s_status: .ascii ":status"
s_grpc_status: .ascii "grpc-status"
s_grpc_message: .ascii "grpc-message"

	.bss
	.balign 8
	.globl wp2
hp_p:	.quad 0
hp_end:	.quad 0
wp2:	.quad 0
gmsg_ptr: .quad 0
gmsg_len: .long 0
hp_err:	.long 0
name_len: .long 0
val_len: .long 0
dyn_count: .long 0
dyn_head: .long 0
dyn_size: .long 0
dyn_max: .long 0
arena_base: .long 0
arena_wp: .long 0
huff_next: .long 0
http_status: .long 0
grpc_status: .long 0
