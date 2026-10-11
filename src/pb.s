# Protobuf: the two requests this client sends, the response walker, and gRPC message framing.
	.include "src/layout.inc"
	.text
	.globl build_request, build_analyze, on_message, analyze_string, grpc_feed, h2_mode

# ---- writer (wp = write pointer) -------------------------------------------------------
# vlen(v) -> eax: bytes a varint takes
vlen:
	mov $1, %eax
1:	cmp $128, %edi
	jb 2f
	shr $7, %edi
	inc %eax
	jmp 1b
2:	ret

wr_varint:
	mov wp(%rip), %rax
1:	cmp $128, %edi
	jb 2f
	mov %edi, %ecx
	and $127, %ecx
	or $128, %ecx
	mov %cl, (%rax)
	inc %rax
	shr $7, %edi
	jmp 1b
2:	mov %dil, (%rax)
	inc %rax
	mov %rax, wp(%rip)
	ret

# wr_bytes(ptr, n)
wr_bytes:
	mov wp(%rip), %rax
	mov %esi, %ecx
	test %ecx, %ecx
	jz 2f
1:	movzbl (%rdi), %edx
	mov %dl, (%rax)
	inc %rdi
	inc %rax
	dec %ecx
	jnz 1b
2:	mov %rax, wp(%rip)
	ret

# wr_str(field, ptr, n): tag, length, bytes
wr_str:
	push %rsi
	push %rdx
	shl $3, %edi
	or $2, %edi
	call wr_varint
	mov (%rsp), %edi
	call wr_varint
	pop %rsi
	pop %rdi
	jmp wr_bytes

# session_id=1, user_context=2{user_id=1:"wasm"}
wr_session:
	mov $1, %edi
	lea mem+SESSION(%rip), %rsi
	mov $36, %edx
	call wr_str
	mov $0x12, %edi
	call wr_varint
	mov $6, %edi
	call wr_varint
	mov $1, %edi
	lea s_user(%rip), %rsi
	mov $4, %edx
	jmp wr_str

# plan{ root: Relation{ sql: SQL{ query } } } as field `field` of the current message.
# Lengths are arithmetic over the fixed shape.
#   lsql = 1 + vlen(n) + n; lrel = 1 + vlen(lsql) + lsql; lplan = 1 + vlen(lrel) + lrel
# wr_plan(field, sql, n)
wr_plan:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	mov %edi, %r12d
	mov %rsi, %r13
	mov %edx, %r14d
	mov %r14d, %edi
	call vlen
	lea 1(%rax,%r14), %r15d         # lsql
	mov %r15d, %edi
	call vlen
	lea 1(%rax,%r15), %ebx          # lrel
	mov %ebx, %edi
	call vlen
	lea 1(%rax,%rbx), %eax          # lplan
	push %rax
	mov %r12d, %edi
	shl $3, %edi
	or $2, %edi
	call wr_varint
	pop %rdi
	call wr_varint                  # plan {
	mov $0x0a, %edi
	call wr_varint
	mov %ebx, %edi
	call wr_varint                  #  root {
	mov $0x52, %edi
	call wr_varint
	mov %r15d, %edi
	call wr_varint                  #   sql {
	mov $1, %edi
	mov %r13, %rsi
	mov %r14d, %edx
	call wr_str                     #    query }}}
	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# build_request(sql, n) -> eax length; ExecutePlanRequest at mem+REQ
build_request:
	push %rbx
	push %r12
	mov %rdi, %rbx
	mov %esi, %r12d
	lea mem+OPID(%rip), %rdi
	call uuid
	lea mem+REQ(%rip), %rax
	mov %rax, wp(%rip)
	call wr_session
	mov $3, %edi
	mov %rbx, %rsi
	mov %r12d, %edx
	call wr_plan
	mov $4, %edi
	lea s_client(%rip), %rsi
	mov $21, %edx
	call wr_str
	mov $6, %edi
	lea mem+OPID(%rip), %rsi
	mov $36, %edx
	call wr_str
	mov wp(%rip), %rax
	lea mem+REQ(%rip), %rcx
	sub %ecx, %eax
	pop %r12
	pop %rbx
	ret

# build_analyze(sql, n, kind, mode) -> eax length; AnalyzePlanRequest at mem+REQ
#   kind 5 explain{plan=1, explain_mode=2}, kind 6 tree_string{plan=1}
build_analyze:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	mov %rdi, %rbx
	mov %esi, %r12d
	mov %edx, %r13d
	mov %ecx, %r14d
	lea mem+REQ(%rip), %rax
	mov %rax, wp(%rip)
	call wr_session
	mov $3, %edi
	lea s_client(%rip), %rsi
	mov $21, %edx
	call wr_str
	# size of the kind body: plan field + (explain ? 2 : 0)
	mov %r12d, %edi
	call vlen
	lea 1(%rax,%r12), %r15d         # lsql
	mov %r15d, %edi
	call vlen
	lea 1(%rax,%r15), %r15d         # lrel
	mov %r15d, %edi
	call vlen
	lea 1(%rax,%r15), %r15d         # lplan
	mov %r15d, %edi
	call vlen
	lea 1(%rax,%r15), %r15d         # field-1 plan message size
	cmp $5, %r13d
	jne 1f
	add $2, %r15d
1:	mov %r13d, %edi
	shl $3, %edi
	or $2, %edi
	call wr_varint
	mov %r15d, %edi
	call wr_varint                  # kind {
	mov $1, %edi
	mov %rbx, %rsi
	mov %r12d, %edx
	call wr_plan                    #   plan
	cmp $5, %r13d
	jne 2f
	mov $0x10, %edi
	call wr_varint
	mov %r14d, %edi
	call wr_varint                  #   explain_mode
2:	mov wp(%rip), %rax
	lea mem+REQ(%rip), %rcx
	sub %ecx, %eax
	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# ---- reader (cur, end) ------------------------------------------------------------------
rd_varint:
	xor %eax, %eax
	xor %ecx, %ecx                  # shift
	mov cur(%rip), %rsi
1:	movzbl (%rsi), %edx
	inc %rsi
	mov %edx, %edi
	and $127, %edi
	shl %cl, %rdi
	or %rdi, %rax
	add $7, %ecx
	test $128, %dl
	jz 2f
	cmp $64, %ecx
	jb 1b
2:	mov %rsi, cur(%rip)
	ret

rd_len:
	call rd_varint
	ret

# skip(wire)
skip:
	cmp $0, %edi
	jne 1f
	jmp rd_varint
1:	cmp $1, %edi
	jne 2f
	addq $8, cur(%rip)
	ret
2:	cmp $2, %edi
	jne 3f
	call rd_len
	add %rax, cur(%rip)
	ret
3:	cmp $5, %edi
	jne 4f
	addq $4, cur(%rip)
	ret
4:	ud2

# on_message(p, n): ExecutePlanResponse; arrow_batch (2) is decoded as it arrives
on_message:
	push %rbx
	push %r12
	mov %rdi, cur(%rip)
	lea (%rdi,%rsi), %rax
	mov %rax, end(%rip)
1:	mov cur(%rip), %rax
	cmp end(%rip), %rax
	jae 9f
	call rd_len
	cmp $0x12, %eax
	jne 2f
	call rd_len
	mov end(%rip), %r12             # save end
	mov cur(%rip), %rbx
	add %rax, %rbx
	mov %rbx, end(%rip)
	call arrow_batch
	mov %rbx, cur(%rip)
	mov %r12, end(%rip)
	jmp 1b
2:	mov %eax, %edi
	and $7, %edi
	call skip
	jmp 1b
9:	call flush
	pop %r12
	pop %rbx
	ret

# ArrowBatch: data (2) is an Arrow IPC stream
arrow_batch:
	push %rbx
1:	mov cur(%rip), %rax
	cmp end(%rip), %rax
	jae 9f
	call rd_len
	cmp $0x12, %eax
	jne 2f
	call rd_len
	mov cur(%rip), %rdi
	mov %eax, %esi
	mov %rax, %rbx
	call arrow_stream
	add %rbx, cur(%rip)
	jmp 1b
2:	mov %eax, %edi
	and $7, %edi
	call skip
	jmp 1b
9:	pop %rbx
	ret

# analyze_string(p, n): AnalyzePlanResponse; print the string in explain=3 or tree_string=4
analyze_string:
	mov %rdi, cur(%rip)
	lea (%rdi,%rsi), %rax
	mov %rax, end(%rip)
1:	mov cur(%rip), %rax
	cmp end(%rip), %rax
	jae 9f
	call rd_len
	cmp $0x1a, %eax
	je 2f
	cmp $0x22, %eax
	je 2f
	mov %eax, %edi
	and $7, %edi
	call skip
	jmp 1b
2:	call rd_len                     # outer length
	call rd_len                     # inner tag
	push %rax
	call rd_len                     # inner length
	pop %rcx
	cmp $0x0a, %ecx
	jne 9f
	mov cur(%rip), %rdi
	mov %eax, %esi
	call emits
9:	jmp flush

# ---- gRPC framing -----------------------------------------------------------------------
# grpc_feed(p, n): append DATA bytes, dispatch every complete 5-byte-prefixed message
grpc_feed:
	push %rbx
	push %r12
	push %r13
	mov %rdi, %r12
	mov %esi, %r13d
	mov gm_len(%rip), %eax
	add %r13d, %eax
	cmp gm_cap(%rip), %eax
	jbe 2f
	# grow: max(2*cap, len+n, 64 KiB)
	mov gm_cap(%rip), %ecx
	add %ecx, %ecx
	cmp %eax, %ecx
	cmovb %eax, %ecx
	cmp $65536, %ecx
	jae 1f
	mov $65536, %ecx
1:	mov %ecx, %ebx
	mov %rcx, %rdi
	call alloc
	mov %rax, %rdi                  # copy old contents
	mov gm_buf(%rip), %rsi
	mov gm_len(%rip), %ecx
	rep movsb
	mov %rax, gm_buf(%rip)
	mov %ebx, gm_cap(%rip)
2:	mov gm_buf(%rip), %rdi
	mov gm_len(%rip), %eax
	add %rax, %rdi
	mov %r12, %rsi
	mov %r13d, %ecx
	rep movsb
	add %r13d, gm_len(%rip)
3:	cmpl $5, gm_len(%rip)
	jb 9f
	mov gm_buf(%rip), %rsi
	mov 1(%rsi), %eax
	bswap %eax                      # message length
	lea 5(%rax), %ecx
	cmp gm_len(%rip), %ecx
	ja 9f
	mov %eax, %ebx                  # mlen
	lea 5(%rsi), %rdi
	mov %ebx, %esi
	call dispatch
	# shift the remainder down
	mov gm_buf(%rip), %rdi
	lea 5(%rdi,%rbx), %rsi
	mov gm_len(%rip), %ecx
	sub $5, %ecx
	sub %ebx, %ecx
	mov %ecx, gm_len(%rip)
	rep movsb
	jmp 3b
9:	pop %r13
	pop %r12
	pop %rbx
	ret

dispatch:
	mov h2_mode(%rip), %eax
	test %eax, %eax
	jz on_message
	cmp $1, %eax
	je analyze_string
	ret

	.section .rodata
s_user:	.ascii "wasm"
s_client: .ascii "spark-connect-asm/0.1"

	.bss
	.balign 8
cur:	.quad 0
end:	.quad 0
wp:	.quad 0
gm_buf:	.quad 0
gm_cap:	.long 0
gm_len:	.long 0
h2_mode: .long 0
