# Arrow IPC stream reader: flatbuffers accessors, the schema as a tree of field records,
# record batch buffer assignment, and printing of every value type (table or JSON).
	.include "src/layout.inc"
	.text
	.globl arrow_stream, nrows, json, raw, header_done, reset_output

# ---- flatbuffers (absolute addresses) ------------------------------------------------
# fb_root(base) -> rax
fb_root:
	mov (%rdi), %eax
	add %rdi, %rax
	ret

# fb_field(t, idx) -> rax: address of the field or 0
fb_field:
	movslq (%rdi), %rax
	mov %rdi, %rcx
	sub %rax, %rcx                  # vtable
	lea 4(,%rsi,2), %edx
	movzwl (%rcx), %eax
	cmp %eax, %edx
	jae 1f
	movzwl (%rcx,%rdx), %eax
	test %eax, %eax
	jz 1f
	add %rdi, %rax
	ret
1:	xor %eax, %eax
	ret

# fb_u8 / fb_i16 / fb_i32 / fb_i64 (t, idx, default)
fb_u8:
	push %rdx
	call fb_field
	pop %rdx
	test %rax, %rax
	jz 1f
	movzbl (%rax), %eax
	ret
1:	mov %edx, %eax
	ret
fb_i16:
	push %rdx
	call fb_field
	pop %rdx
	test %rax, %rax
	jz 1f
	movswl (%rax), %eax
	ret
1:	mov %edx, %eax
	ret
fb_i32:
	push %rdx
	call fb_field
	pop %rdx
	test %rax, %rax
	jz 1f
	mov (%rax), %eax
	ret
1:	mov %edx, %eax
	ret
fb_i64:
	push %rdx
	call fb_field
	pop %rdx
	test %rax, %rax
	jz 1f
	mov (%rax), %rax
	ret
1:	mov %rdx, %rax
	ret

# fb_ref(t, idx) -> rax: referenced table/vector/string or 0
fb_ref:
	call fb_field
	test %rax, %rax
	jz 1f
	mov (%rax), %ecx
	add %rcx, %rax
1:	ret

vec_len:
	xor %eax, %eax
	test %rdi, %rdi
	jz 1f
	mov (%rdi), %eax
1:	ret

# vec_tbl(v, i) -> rax
vec_tbl:
	lea 4(%rdi,%rsi,4), %rax
	mov (%rax), %ecx
	add %rcx, %rax
	ret

# ---- IPC stream ---------------------------------------------------------------------
# arrow_stream(p, n)
arrow_stream:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	mov %rdi, %rbx                  # pos
	lea (%rdi,%rsi), %r12           # lim
1:	lea 4(%rbx), %rax
	cmp %r12, %rax
	ja 9f
	mov (%rbx), %eax
	cmp $-1, %eax
	jne 2f
	mov 4(%rbx), %eax
	add $8, %rbx
	jmp 3f
2:	add $4, %rbx
3:	test %eax, %eax
	jz 9f
	mov %eax, %r13d                 # metadata length
	mov %rbx, %rdi
	call fb_root
	mov %rax, %r14                  # message table
	add %r13, %rbx
	mov %r14, %rdi
	mov $3, %esi
	xor %edx, %edx
	call fb_i64
	mov %rbx, %r15                  # body
	add %rax, %rbx                  # pos += bodyLength
	mov %r14, %rdi
	mov $1, %esi
	xor %edx, %edx
	call fb_u8
	mov %eax, %r13d                 # header type
	mov %r14, %rdi
	mov $2, %esi
	call fb_ref
	cmp $1, %r13d
	jne 4f
	mov %rax, %rdi
	call read_schema
	jmp 1b
4:	cmp $3, %r13d
	jne 1b
	mov %rax, %rdi
	mov %r15, %rsi
	call read_batch
	jmp 1b
9:	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# parse_field(f) -> rax record (see layout.inc F_*)
parse_field:
	push %rbx
	push %r12
	push %r13
	push %r14
	mov %rdi, %rbx
	mov $F_SIZE, %edi
	call alloc
	mov %rax, %r12
	mov %rbx, %rdi
	xor %esi, %esi
	call fb_ref                     # name
	lea 4(%rax), %rcx
	mov %rcx, F_NAME(%r12)
	mov %rax, %rdi
	call vec_len
	mov %eax, F_NLEN(%r12)
	mov %rbx, %rdi
	mov $2, %esi
	xor %edx, %edx
	call fb_u8
	mov %eax, %r13d                 # type_type
	mov %rbx, %rdi
	mov $4, %esi
	call fb_ref                     # dictionary -> unsupported
	test %rax, %rax
	jz 1f
	mov $-1, %r13d
1:	mov %r13d, F_TT(%r12)
	mov %rbx, %rdi
	mov $3, %esi
	call fb_ref
	mov %rax, %r14                  # type table
	test %r14, %r14
	jz 8f
	cmp $2, %r13d
	jne 2f
	mov %r14, %rdi
	xor %esi, %esi
	xor %edx, %edx
	call fb_i32
	mov %eax, F_P0(%r12)
	mov %r14, %rdi
	mov $1, %esi
	xor %edx, %edx
	call fb_u8
	mov %eax, F_P1(%r12)
	jmp 8f
2:	cmp $3, %r13d
	jne 3f
	mov %r14, %rdi
	xor %esi, %esi
	xor %edx, %edx
	call fb_i16
	mov %eax, F_P0(%r12)
	jmp 8f
3:	cmp $7, %r13d
	jne 4f
	mov %r14, %rdi
	mov $2, %esi
	mov $128, %edx
	call fb_i32
	mov %eax, F_P0(%r12)
	mov %r14, %rdi
	mov $1, %esi
	xor %edx, %edx
	call fb_i32
	mov %eax, F_P1(%r12)
	jmp 8f
4:	cmp $8, %r13d
	jne 5f
	mov %r14, %rdi
	xor %esi, %esi
	mov $1, %edx
	call fb_i16
	mov %eax, F_P0(%r12)
	jmp 8f
5:	cmp $10, %r13d
	jne 6f
	mov %r14, %rdi
	xor %esi, %esi
	xor %edx, %edx
	call fb_i16
	mov %eax, F_P0(%r12)
	jmp 8f
6:	cmp $16, %r13d
	jne 8f
	mov %r14, %rdi
	xor %esi, %esi
	xor %edx, %edx
	call fb_i32
	mov %eax, F_P0(%r12)
8:	# children
	mov %rbx, %rdi
	mov $5, %esi
	call fb_ref
	mov %rax, %r13                  # kids vector
	mov %rax, %rdi
	call vec_len
	mov %eax, F_NKIDS(%r12)
	mov %eax, %r14d
	lea 0(,%rax,8), %rdi
	call alloc
	mov %rax, F_KIDS(%r12)
	xor %ebx, %ebx
9:	cmp %r14d, %ebx
	jae 10f
	mov %r13, %rdi
	mov %ebx, %esi
	call vec_tbl
	mov %rax, %rdi
	call parse_field
	mov F_KIDS(%r12), %rcx
	mov %rax, (%rcx,%rbx,8)
	inc %ebx
	jmp 9b
10:	mov %r12, %rax
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# field(i) -> rax top-level record
field:
	mov fields(%rip), %rax
	mov (%rax,%rdi,8), %rax
	ret

# read_schema(s)
read_schema:
	push %rbx
	push %r12
	push %r13
	mov %rdi, %rbx
	mov $1, %esi
	call fb_ref
	mov %rax, %r12                  # fields vector
	mov %rax, %rdi
	call vec_len
	mov %eax, nfields(%rip)
	mov %eax, %r13d
	lea 0(,%rax,8), %rdi
	call alloc
	mov %rax, fields(%rip)
	xor %ebx, %ebx
1:	cmp %r13d, %ebx
	jae 2f
	mov %r12, %rdi
	mov %ebx, %esi
	call vec_tbl
	mov %rax, %rdi
	call parse_field
	mov fields(%rip), %rcx
	mov %rax, (%rcx,%rbx,8)
	inc %ebx
	jmp 1b
2:	# header once, table mode only
	cmpl $0, header_done(%rip)
	jne 9f
	mov raw(%rip), %eax
	or json(%rip), %eax
	jnz 9f
	movl $1, header_done(%rip)
	xor %ebx, %ebx
3:	cmp %r13d, %ebx
	jae 4f
	test %ebx, %ebx
	jz 5f
	lea s_bar(%rip), %rdi
	mov $3, %esi
	call emits
5:	mov %ebx, %edi
	call field
	mov F_NAME(%rax), %rdi
	mov F_NLEN(%rax), %esi
	call emits
	inc %ebx
	jmp 3b
4:	mov $10, %edi
	call emit
9:	pop %r13
	pop %r12
	pop %rbx
	ret

# nbuffers(tt) -> eax
nbuffers:
	cmp $1, %edi
	je 0f
	cmp $4, %edi
	je 3f
	cmp $5, %edi
	je 3f
	cmp $19, %edi
	je 3f
	cmp $20, %edi
	je 3f
	cmp $13, %edi
	je 1f
	cmp $16, %edi
	je 1f
	mov $2, %eax
	ret
0:	xor %eax, %eax
	ret
1:	mov $1, %eax
	ret
3:	mov $3, %eax
	ret

# assign(rec, nodes, bufs, body): pre-order walk consuming nodes and buffers
assign:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	mov %rdi, %rbx
	mov %rsi, %r12
	mov %rdx, %r13
	mov %rcx, %r14
	mov ni(%rip), %eax
	shl $4, %eax
	mov 4(%r12,%rax), %rax
	mov %eax, F_LEN(%rbx)
	incl ni(%rip)
	mov F_TT(%rbx), %edi
	call nbuffers
	mov %eax, %r15d
	test %eax, %eax
	jz 3f
	mov bi(%rip), %eax
	shl $4, %eax
	lea 4(%r13,%rax), %rcx          # buffer struct {offset, length}
	cmpq $0, 8(%rcx)
	je 1f
	mov (%rcx), %rax
	add %r14, %rax
	mov %rax, F_VALID(%rbx)
1:	cmp $2, %r15d
	jb 3f
	mov 16(%rcx), %rax
	add %r14, %rax
	mov %rax, F_BUFA(%rbx)
	cmp $3, %r15d
	jne 3f
	mov 32(%rcx), %rax
	add %r14, %rax
	mov %rax, F_BUFB(%rbx)
3:	add %r15d, bi(%rip)
	xor %r15d, %r15d
4:	cmp F_NKIDS(%rbx), %r15d
	jae 9f
	mov F_KIDS(%rbx), %rax
	mov (%rax,%r15,8), %rdi
	mov %r12, %rsi
	mov %r13, %rdx
	mov %r14, %rcx
	call assign
	inc %r15d
	jmp 4b
9:	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# read_batch(rb, body)
read_batch:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	mov %rdi, %rbx
	mov %rsi, %r12
	mov $3, %esi
	call fb_ref                     # compression
	test %rax, %rax
	jz 1f
	lea s_compressed(%rip), %rdi
	mov $s_compressed_len, %esi
	call emits
	jmp 9f
1:	mov %rbx, %rdi
	xor %esi, %esi
	xor %edx, %edx
	call fb_i64
	mov %eax, %r13d                 # nrows in this batch
	mov %rbx, %rdi
	mov $1, %esi
	call fb_ref
	mov %rax, %r14                  # nodes
	mov %rbx, %rdi
	mov $2, %esi
	call fb_ref
	mov %rax, %r15                  # buffers
	movl $0, ni(%rip)
	movl $0, bi(%rip)
	xor %ebx, %ebx
2:	cmp nfields(%rip), %ebx
	jae 3f
	mov %ebx, %edi
	call field
	mov %rax, %rdi
	mov %r14, %rsi
	mov %r15, %rdx
	mov %r12, %rcx
	call assign
	inc %ebx
	jmp 2b
3:	xor %r14d, %r14d                # r
4:	cmp %r13d, %r14d
	jae 9f
	cmpl $0, json(%rip)
	je 5f
	mov $123, %edi
	call emit
5:	xor %ebx, %ebx
6:	cmp nfields(%rip), %ebx
	jae 8f
	mov %ebx, %edi
	call field
	mov %rax, %r15
	cmpl $0, json(%rip)
	je 7f
	test %ebx, %ebx
	jz 61f
	mov $44, %edi
	call emit
61:	mov F_NAME(%r15), %rdi
	mov F_NLEN(%r15), %esi
	call emit_json_string
	mov $58, %edi
	call emit
	jmp 71f
7:	test %ebx, %ebx
	jz 71f
	cmpl $0, raw(%rip)
	jne 71f
	lea s_bar(%rip), %rdi
	mov $3, %esi
	call emits
71:	mov %r15, %rdi
	mov %r14d, %esi
	call emit_value
	inc %ebx
	jmp 6b
8:	cmpl $0, json(%rip)
	je 81f
	mov $125, %edi
	call emit
81:	cmpl $0, raw(%rip)
	jne 82f
	mov $10, %edi
	call emit
82:	incq nrows(%rip)
	inc %r14d
	jmp 4b
9:	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# bit(p, i) -> eax
bit:
	mov %esi, %eax
	shr $3, %eax
	movzbl (%rdi,%rax), %eax
	mov %esi, %ecx
	and $7, %ecx
	shr %cl, %eax
	and $1, %eax
	ret

emit_sep:
	cmpl $0, json(%rip)
	je 1f
	mov $44, %edi
	jmp emit
1:	lea s_comma(%rip), %rdi
	mov $2, %esi
	jmp emits

quote:
	cmpl $0, json(%rip)
	je 1f
	mov $34, %edi
	jmp emit
1:	ret

emit_null:
	cmpl $0, json(%rip)
	je 1f
	lea s_null(%rip), %rdi
	mov $4, %esi
	jmp emits
1:	lea s_NULL(%rip), %rdi
	mov $4, %esi
	jmp emits

# emit_value(rec, r)
#   rbx rec, r12d r, r13d tt, r14 data (bufA), r15 scratch
emit_value:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	sub $16, %rsp
	mov %rdi, %rbx
	mov %esi, %r12d
	mov F_TT(%rbx), %r13d
	mov F_BUFA(%rbx), %r14
	cmp $1, %r13d
	je 1f
	mov F_VALID(%rbx), %rdi
	test %rdi, %rdi
	jz 2f
	mov %r12d, %esi
	call bit
	test %eax, %eax
	jnz 2f
1:	call emit_null
	jmp 99f
2:	cmp $2, %r13d
	jne 20f
	# ---- Int
	mov F_P0(%rbx), %eax
	mov F_P1(%rbx), %ecx            # signed?
	cmp $8, %eax
	jne 3f
	test %ecx, %ecx
	jz 31f
	movsbq (%r14,%r12), %rdi
	call emit_i64
	jmp 99f
31:	movzbq (%r14,%r12), %rdi
	call emit_u64
	jmp 99f
3:	cmp $16, %eax
	jne 4f
	test %ecx, %ecx
	jz 41f
	movswq (%r14,%r12,2), %rdi
	call emit_i64
	jmp 99f
41:	movzwq (%r14,%r12,2), %rdi
	call emit_u64
	jmp 99f
4:	cmp $32, %eax
	jne 5f
	test %ecx, %ecx
	jz 51f
	movslq (%r14,%r12,4), %rdi
	call emit_i64
	jmp 99f
51:	mov (%r14,%r12,4), %edi
	call emit_u64
	jmp 99f
5:	mov (%r14,%r12,8), %rdi
	test %ecx, %ecx
	jz 52f
	call emit_i64
	jmp 99f
52:	call emit_u64
	jmp 99f
20:	cmp $3, %r13d
	jne 30f
	# ---- FloatingPoint
	mov F_P0(%rbx), %eax
	cmp $2, %eax
	jne 21f
	movsd (%r14,%r12,8), %xmm0
	jmp 23f
21:	cmp $1, %eax
	jne 22f
	cvtss2sd (%r14,%r12,4), %xmm0
	jmp 23f
22:	call quote
	lea s_f16(%rip), %rdi
	mov $5, %esi
	call emits
	call quote
	jmp 99f
23:	movsd %xmm0, (%rsp)
	cmpl $0, json(%rip)
	je 25f
	ucomisd %xmm0, %xmm0
	jp 24f
	andpd f_absmask(%rip), %xmm0
	ucomisd f_inf(%rip), %xmm0
	jne 25f
24:	mov $34, %edi
	call emit
	movsd (%rsp), %xmm0
	call emit_f64
	mov $34, %edi
	call emit
	jmp 99f
25:	movsd (%rsp), %xmm0
	call emit_f64
	jmp 99f
30:	cmp $4, %r13d
	je 32f
	cmp $5, %r13d
	je 32f
	cmp $19, %r13d
	je 32f
	cmp $20, %r13d
	jne 40f
32:	# ---- Utf8 / Binary / Large variants: offsets in bufA, data in bufB
	cmp $19, %r13d
	jae 33f
	mov (%r14,%r12,4), %r15d        # s
	mov 4(%r14,%r12,4), %eax        # e
	jmp 34f
33:	mov (%r14,%r12,8), %r15
	mov 8(%r14,%r12,8), %rax
34:	sub %r15d, %eax
	mov %eax, %esi
	mov F_BUFB(%rbx), %rdi
	add %r15, %rdi
	cmp $5, %r13d
	je 35f
	cmp $20, %r13d
	je 35f
	push %rdi
	push %rsi
	call quote
	pop %rsi
	pop %rdi
	call emit_hex
	call quote
	jmp 99f
35:	cmpl $0, json(%rip)
	je 36f
	call emit_json_string
	jmp 99f
36:	call emits
	jmp 99f
40:	cmp $6, %r13d
	jne 50f
	# ---- Bool
	mov %r14, %rdi
	mov %r12d, %esi
	call bit
	test %eax, %eax
	jz 42f
	lea s_true(%rip), %rdi
	mov $4, %esi
	call emits
	jmp 99f
42:	lea s_false(%rip), %rdi
	mov $5, %esi
	call emits
	jmp 99f
50:	cmp $7, %r13d
	jne 60f
	# ---- Decimal128 fitting in 64 bits
	cmpl $128, F_P0(%rbx)
	jne 53f
	mov %r12d, %eax
	shl $4, %eax
	mov (%r14,%rax), %rdi           # lo
	mov 8(%r14,%rax), %rsi          # hi
	mov F_P1(%rbx), %edx
	call emit_decimal128
	jmp 99f
53:	call quote
	lea s_bigdec(%rip), %rdi
	mov $16, %esi
	call emits
	call quote
	jmp 99f
60:	cmp $8, %r13d
	jne 70f
	# ---- Date
	call quote
	cmpl $0, F_P0(%rbx)
	je 61f
	mov (%r14,%r12,8), %rax
	cqo
	mov $86400000, %rcx
	idiv %rcx
	mov %rax, %rdi
	jmp 62f
61:	movslq (%r14,%r12,4), %rdi
62:	call emit_date
	call quote
	jmp 99f
70:	cmp $10, %r13d
	jne 80f
	# ---- Timestamp
	mov (%r14,%r12,8), %rdi
	mov F_P0(%rbx), %eax
	cmp $0, %eax
	jne 71f
	imul $1000000, %rdi
	jmp 74f
71:	cmp $1, %eax
	jne 72f
	imul $1000, %rdi
	jmp 74f
72:	cmp $3, %eax
	jne 74f
	mov %rdi, %rax
	cqo
	mov $1000, %rcx
	idiv %rcx
	mov %rax, %rdi
74:	mov %rdi, (%rsp)
	call quote
	mov (%rsp), %rdi
	call emit_timestamp_us
	call quote
	jmp 99f
80:	cmp $12, %r13d
	je 81f
	cmp $21, %r13d
	je 81f
	cmp $16, %r13d
	jne 90f
81:	# ---- List / LargeList / FixedSizeList: child 0 over [s, e)
	cmp $12, %r13d
	jne 82f
	mov (%r14,%r12,4), %r15d
	mov 4(%r14,%r12,4), %eax
	jmp 84f
82:	cmp $21, %r13d
	jne 83f
	mov (%r14,%r12,8), %r15d
	mov 8(%r14,%r12,8), %eax
	jmp 84f
83:	mov F_P0(%rbx), %eax
	imul %r12d, %eax
	mov %eax, %r15d
	add F_P0(%rbx), %eax
84:	mov %eax, 8(%rsp)               # e
	mov %r15d, 12(%rsp)             # s
	mov $91, %edi
	call emit
85:	cmp 8(%rsp), %r15d
	jae 86f
	cmp 12(%rsp), %r15d
	je 87f
	call emit_sep
87:	mov F_KIDS(%rbx), %rax
	mov (%rax), %rdi
	mov %r15d, %esi
	call emit_value
	inc %r15d
	jmp 85b
86:	mov $93, %edi
	call emit
	jmp 99f
90:	cmp $13, %r13d
	jne 95f
	# ---- Struct
	mov $123, %edi
	call emit
	xor %r15d, %r15d
91:	cmp F_NKIDS(%rbx), %r15d
	jae 93f
	test %r15d, %r15d
	jz 92f
	call emit_sep
92:	mov F_KIDS(%rbx), %rax
	mov (%rax,%r15,8), %r14
	cmpl $0, json(%rip)
	je 921f
	mov F_NAME(%r14), %rdi
	mov F_NLEN(%r14), %esi
	call emit_json_string
	mov $58, %edi
	call emit
921:	mov %r14, %rdi
	mov %r12d, %esi
	call emit_value
	inc %r15d
	jmp 91b
93:	mov $125, %edi
	call emit
	jmp 99f
95:	cmp $17, %r13d
	jne 98f
	# ---- Map: entries struct is child 0; its children are key and value
	mov (%r14,%r12,4), %r15d        # s
	mov 4(%r14,%r12,4), %eax
	mov %eax, 8(%rsp)               # e
	mov %r15d, 12(%rsp)
	mov F_KIDS(%rbx), %rax
	mov (%rax), %rax                # entries record
	mov F_KIDS(%rax), %r14          # [key rec, value rec]
	mov $123, %edi
	call emit
951:	cmp 8(%rsp), %r15d
	jae 957f
	cmp 12(%rsp), %r15d
	je 952f
	call emit_sep
952:	cmpl $0, json(%rip)
	je 955f
	# JSON keys are strings: a utf8 key prints as is, anything else goes inside quotes
	mov (%r14), %rdi
	cmpl $5, F_TT(%rdi)
	je 953f
	movl $0, json(%rip)
	mov $34, %edi
	call emit
	mov (%r14), %rdi
	mov %r15d, %esi
	call emit_value
	mov $34, %edi
	call emit
	movl $1, json(%rip)
	jmp 954f
953:	mov %r15d, %esi
	call emit_value
954:	mov $58, %edi
	call emit
	jmp 956f
955:	mov (%r14), %rdi
	mov %r15d, %esi
	call emit_value
	lea s_arrow(%rip), %rdi
	mov $4, %esi
	call emits
956:	mov 8(%r14), %rdi
	mov %r15d, %esi
	call emit_value
	inc %r15d
	jmp 951b
957:	mov $125, %edi
	call emit
	jmp 99f
98:	# ---- anything else
	call quote
	lea s_type(%rip), %rdi
	mov $6, %esi
	call emits
	mov %r13d, %edi
	call emit_u64
	mov $62, %edi
	call emit
	call quote
99:	add $16, %rsp
	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

reset_output:
	movl $0, header_done(%rip)
	movq $0, nrows(%rip)
	ret

	.section .rodata
	.balign 8
f_inf:	.quad 0x7ff0000000000000
f_absmask: .quad 0x7fffffffffffffff
s_bar:	.ascii " | "
s_comma: .ascii ", "
s_null:	.ascii "null"
s_NULL:	.ascii "NULL"
s_true:	.ascii "true"
s_false: .ascii "false"
s_f16:	.ascii "<f16>"
s_bigdec: .ascii "<decimal256>    "
s_arrow: .ascii " -> "
s_type:	.ascii "<type "
s_compressed: .ascii "<compressed batch: unsupported>\n"
	.set s_compressed_len, .-s_compressed

	.bss
	.balign 8
fields:	.quad 0
nrows:	.quad 0
nfields: .long 0
ni:	.long 0
bi:	.long 0
json:	.long 0
raw:	.long 0
header_done: .long 0
