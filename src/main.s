# Entry point: argument parsing, the socket, the read loop, exit status.
#   sparkc [-r sc://host:port] [--json|--schema|--explain] "SQL"
#   sparkc --replay file.s2c "SQL"   drive the HTTP/2 stack from recorded server bytes
#   sparkc --grpc file.grpc          decode recorded gRPC messages (no HTTP/2)
#   sparkc --fmt-test                exercise the formatters
	.include "src/layout.inc"
	.text
	.globl _start, sock_fd, mode

_start:
	mov (%rsp), %r12                # argc
	lea 8(%rsp), %r13               # argv
	call heap_init
	# defaults
	lea s_default_remote(%rip), %rax
	mov %rax, remote(%rip)
	mov $1, %ebx                    # argv index
1:	cmp %r12, %rbx
	jae 20f
	mov (%r13,%rbx,8), %r14         # arg
	lea s_opt_r(%rip), %rsi
	mov %r14, %rdi
	call streq
	test %eax, %eax
	jz 2f
	inc %rbx
	mov (%r13,%rbx,8), %rax
	mov %rax, remote(%rip)
	jmp 19f
2:	lea s_opt_replay(%rip), %rsi
	mov %r14, %rdi
	call streq
	test %eax, %eax
	jz 3f
	inc %rbx
	mov (%r13,%rbx,8), %rax
	mov %rax, replay_file(%rip)
	jmp 19f
3:	lea s_opt_grpc(%rip), %rsi
	mov %r14, %rdi
	call streq
	test %eax, %eax
	jz 4f
	inc %rbx
	mov (%r13,%rbx,8), %rax
	mov %rax, grpc_file(%rip)
	jmp 19f
4:	lea s_opt_json(%rip), %rsi
	mov %r14, %rdi
	call streq
	test %eax, %eax
	jz 5f
	movl $1, json(%rip)
	jmp 19f
5:	lea s_opt_schema(%rip), %rsi
	mov %r14, %rdi
	call streq
	test %eax, %eax
	jz 6f
	movl $6, analyze_kind(%rip)
	jmp 19f
6:	lea s_opt_explain(%rip), %rsi
	mov %r14, %rdi
	call streq
	test %eax, %eax
	jz 7f
	movl $5, analyze_kind(%rip)
	jmp 19f
7:	lea s_opt_fmt(%rip), %rsi
	mov %r14, %rdi
	call streq
	test %eax, %eax
	jz 71f
	call fmt_test
	jmp 90f
71:	lea s_opt_resolve(%rip), %rsi
	mov %r14, %rdi
	call streq
	test %eax, %eax
	jz 8f
	inc %rbx
	mov (%r13,%rbx,8), %rdi
	push %rdi
	call strlen
	pop %rdi
	mov %eax, %esi
	call resolve_host
	mov %eax, %ebx
	mov $4, %r12d
72:	movzbl %bl, %edi
	call emit_u64
	shr $8, %ebx
	dec %r12d
	jz 73f
	mov $46, %edi
	call emit
	jmp 72b
73:	mov $10, %edi
	call emit
	call flush
	jmp 90f
8:	mov %r14, sql(%rip)
19:	inc %rbx
	jmp 1b

20:	# --grpc: feed recorded gRPC messages straight into the splitter
	mov grpc_file(%rip), %rdi
	test %rdi, %rdi
	jz 21f
	xor %esi, %esi
	call sys_open
	mov %eax, %r15d
	movl $0, h2_mode(%rip)
	call feed_file_grpc
	call flush
	call report_rows
	jmp 90f

21:	mov sql(%rip), %rdi
	test %rdi, %rdi
	jnz 22f
	lea s_usage(%rip), %rsi
	mov $s_usage_len, %edx
	mov $2, %edi
	call sys_write
	mov $2, %edi
	call sys_exit

22:	# session uuid, request
	lea mem+SESSION(%rip), %rdi
	call uuid
	mov sql(%rip), %rdi
	call strlen
	mov sql(%rip), %rdi
	mov %eax, %esi
	mov analyze_kind(%rip), %edx
	test %edx, %edx
	jnz 23f
	call build_request                # table / json
	mov %eax, req_len(%rip)
	movl $0, h2_mode(%rip)
	lea s_path_exec(%rip), %rax
	mov %rax, path(%rip)
	movl $46, path_len(%rip)
	jmp 24f
23:	mov $1, %ecx                      # explain mode: simple
	call build_analyze
	mov %eax, req_len(%rip)
	movl $1, h2_mode(%rip)
	lea s_path_analyze(%rip), %rax
	mov %rax, path(%rip)
	movl $46, path_len(%rip)
24:	# transport: a socket, or a recorded byte stream
	mov replay_file(%rip), %rdi
	test %rdi, %rdi
	jz 30f
	xor %esi, %esi
	call sys_open
	mov %eax, %r15d                   # read fd
	movl $-1, sock_fd(%rip)           # sends are dropped
	lea s_replay_auth(%rip), %rdi
	mov $15, %esi
	jmp 40f
30:	call resolve_remote               # fills sockaddr, authority; returns authority len in eax
	mov %eax, %r14d
	mov $2, %edi
	mov $1, %esi
	xor %edx, %edx
	call sys_socket
	test %eax, %eax
	js 80f
	mov %eax, %r15d
	mov %eax, sock_fd(%rip)
	mov %eax, %edi
	lea sockaddr(%rip), %rsi
	mov $16, %edx
	call sys_connect
	test %eax, %eax
	js 80f
	lea mem+AUTHORITY+0x80(%rip), %rdi  # authority text was staged past the AUTHORITY slot
	mov %r14d, %esi
40:	xor %edx, %edx                    # tls = 0
	call h2_connect
	mov path(%rip), %rdi
	mov path_len(%rip), %esi
	lea mem+REQ(%rip), %rdx
	mov req_len(%rip), %ecx
	mov h2_mode(%rip), %r8d
	call h2_request
	# read loop
	mov readbuf_ptr(%rip), %rbx
	test %rbx, %rbx
	jnz 41f
	mov $65536, %edi
	call alloc
	mov %rax, readbuf_ptr(%rip)
	mov %rax, %rbx
41:	cmpl $3, h2_phase(%rip)
	je 50f
	mov %r15d, %edi
	mov %rbx, %rsi
	mov $65536, %edx
	call sys_read
	test %rax, %rax
	jle 45f
	mov %rbx, %rdi
	mov %eax, %esi
	call on_bytes
	jmp 41b
45:	call flush
	lea s_closed(%rip), %rsi
	mov $s_closed_len, %edx
	mov $2, %edi
	call sys_write
	mov $1, %edi
	call sys_exit
50:	call flush
	mov done_code(%rip), %eax
	test %eax, %eax
	jnz 60f
	cmpl $0, h2_mode(%rip)
	jne 90f
	call report_rows
	jmp 90f
60:	# grpc error N: message
	movl $2, out_fd(%rip)
	lea s_grpc_error(%rip), %rdi
	mov $11, %esi
	call emits
	mov done_code(%rip), %edi
	call emit_u64
	mov $58, %edi
	call emit
	mov $32, %edi
	call emit
	mov done_msg(%rip), %rdi
	mov done_len(%rip), %esi
	call emits
	mov $10, %edi
	call emit
	call flush
	mov $1, %edi
	call sys_exit
80:	lea s_connect(%rip), %rsi
	mov $s_connect_len, %edx
	mov $2, %edi
	call sys_write
	mov $1, %edi
	call sys_exit
90:	xor %edi, %edi
	call sys_exit

# "<rows> row(s)" on stderr
report_rows:
	movl $2, out_fd(%rip)
	mov nrows(%rip), %rdi
	call emit_u64
	lea s_rows(%rip), %rdi
	mov $8, %esi
	call emits
	call flush
	movl $1, out_fd(%rip)
	ret

# feed a recorded gRPC byte stream (length-prefixed messages) through grpc_feed
feed_file_grpc:
	push %rbx
	mov $65536, %edi
	call alloc
	mov %rax, %rbx
1:	mov %r15d, %edi
	mov %rbx, %rsi
	mov $65536, %edx
	call sys_read
	test %rax, %rax
	jle 2f
	mov %rbx, %rdi
	mov %eax, %esi
	call grpc_feed
	jmp 1b
2:	pop %rbx
	ret

# streq(a, b) -> eax 1 if equal C strings
streq:
1:	movzbl (%rdi), %eax
	movzbl (%rsi), %ecx
	cmp %al, %cl
	jne 2f
	test %al, %al
	jz 3f
	inc %rdi
	inc %rsi
	jmp 1b
2:	xor %eax, %eax
	ret
3:	mov $1, %eax
	ret

# strlen(s) -> eax
	.globl strlen
strlen:
	xor %eax, %eax
1:	cmpb $0, (%rdi,%rax)
	je 2f
	inc %eax
	jmp 1b
2:	ret

# resolve_remote: parse remote "sc://host:port" (IPv4 literal or localhost) into sockaddr and
# the authority string at mem+AUTHORITY+0x80; returns its length
resolve_remote:
	push %rbx
	push %r12
	mov remote(%rip), %rbx
	# skip "sc://"
	cmpb $'s', (%rbx)
	jne 1f
	cmpb $'c', 1(%rbx)
	jne 1f
	cmpb $':', 2(%rbx)
	jne 1f
	add $5, %rbx
1:	# copy authority text up to '?' or NUL
	lea mem+AUTHORITY+0x80(%rip), %rdi
	xor %r12d, %r12d
2:	movzbl (%rbx,%r12), %eax
	test %al, %al
	jz 3f
	cmp $'?', %al
	je 3f
	mov %al, (%rdi,%r12)
	inc %r12d
	cmp $120, %r12d
	jb 2b
3:	# host: everything before ':' (or the end), through resolve_host
	movw $2, sockaddr(%rip)           # AF_INET
	xor %ecx, %ecx
31:	movzbl (%rbx,%rcx), %eax
	test %al, %al
	jz 32f
	cmp $':', %al
	je 32f
	cmp $'?', %al
	je 32f
	inc %ecx
	jmp 31b
32:	mov %rbx, %rdi
	mov %ecx, %esi
	call resolve_host
	test %eax, %eax
	jnz 33f
	lea s_noresolve(%rip), %rsi
	mov $s_noresolve_len, %edx
	mov $2, %edi
	call sys_write
	mov $1, %edi
	call sys_exit
33:	mov %eax, sockaddr+4(%rip)
5:	# port after ':'
	mov $15002, %eax
	mov %rbx, %rsi
6:	movzbl (%rsi), %edx
	test %dl, %dl
	jz 8f
	cmp $':', %dl
	je 7f
	inc %rsi
	jmp 6b
7:	inc %rsi
	xor %eax, %eax
71:	movzbl (%rsi), %edx
	cmp $'0', %dl
	jb 8f
	cmp $'9', %dl
	ja 8f
	imul $10, %eax
	sub $'0', %edx
	add %edx, %eax
	inc %rsi
	jmp 71b
8:	xchg %al, %ah                     # network byte order
	mov %ax, sockaddr+2(%rip)
	mov %r12d, %eax
	pop %r12
	pop %rbx
	ret

# uuid(dst): version 4 uuid as 36 ascii bytes
	.globl uuid
uuid:
	push %rbx
	push %r12
	push %r13
	mov %rdi, %r12
	lea mem+UUIDRAW(%rip), %rdi
	mov $16, %esi
	call sys_getrandom
	lea mem+UUIDRAW(%rip), %rbx
	andb $0x0f, 6(%rbx)
	orb $0x40, 6(%rbx)
	andb $0x3f, 8(%rbx)
	orb $0x80, 8(%rbx)
	xor %ecx, %ecx                    # i
	xor %r13d, %r13d                  # o
1:	cmp $4, %ecx
	je 2f
	cmp $6, %ecx
	je 2f
	cmp $8, %ecx
	je 2f
	cmp $10, %ecx
	jne 3f
2:	movb $45, (%r12,%r13)
	inc %r13d
3:	movzbl (%rbx,%rcx), %eax
	mov %eax, %edx
	shr $4, %eax
	and $15, %edx
	lea hexlower(%rip), %rsi
	movzbl (%rsi,%rax), %eax
	mov %al, (%r12,%r13)
	movzbl (%rsi,%rdx), %eax
	mov %al, 1(%r12,%r13)
	add $2, %r13d
	inc %ecx
	cmp $16, %ecx
	jb 1b
	pop %r13
	pop %r12
	pop %rbx
	ret

# fmt_test: a handful of values through every formatter
fmt_test:
	lea s_fmt(%rip), %rdi
	mov $s_fmt_len, %esi
	call emits
	mov $-9223372036854775808, %rdi
	call emit_i64
	mov $10, %edi
	call emit
	mov $123456789012345678, %rdi
	call emit_u64
	mov $10, %edi
	call emit
	mov $-1234567, %rdi
	mov $3, %esi
	call emit_decimal
	mov $10, %edi
	call emit
	mov $5, %edi
	mov $3, %esi
	call emit_decimal
	mov $10, %edi
	call emit
	mov $19782, %rdi                  # 2024-02-29
	call emit_date
	mov $10, %edi
	call emit
	mov $-1, %rdi                     # 1969-12-31
	call emit_date
	mov $10, %edi
	call emit
	mov $1709251198500000, %rdi       # 2024-02-29 23:59:58.5
	call emit_timestamp_us
	mov $10, %edi
	call emit
	lea f_tests(%rip), %rbx
	mov $12, %r12d
1:	movsd (%rbx), %xmm0
	call emit_f64
	mov $10, %edi
	call emit
	add $8, %rbx
	dec %r12d
	jnz 1b
	lea s_hexin(%rip), %rdi
	mov $3, %esi
	call emit_hex
	mov $10, %edi
	call emit
	lea s_jsonin(%rip), %rdi
	mov $11, %esi
	call emit_json_string
	mov $10, %edi
	call emit
	call flush
	ret

	.section .rodata
	.balign 8
f_tests: .double 0.1, 2.5, 100.0, 0.333333333333333333, 1e20, 1e-7, 1234567.125, -0.5, 1e15, 123456789.0, 0.0, 1e300
s_fmt:	.ascii "fmt-test\n"
	.set s_fmt_len, .-s_fmt
s_hexin: .byte 0x0a, 0x0b, 0xff
s_jsonin: .ascii "a\"b\\c\n\t\x01xyz"
s_default_remote: .asciz "sc://localhost:15002"
s_opt_r: .asciz "-r"
s_opt_replay: .asciz "--replay"
s_opt_grpc: .asciz "--grpc"
s_opt_json: .asciz "--json"
s_opt_schema: .asciz "--schema"
s_opt_explain: .asciz "--explain"
s_opt_fmt: .asciz "--fmt-test"
s_usage: .ascii "usage: sparkc [-r sc://host:port] [--json|--schema|--explain] \"SQL\"\n"
	.set s_usage_len, .-s_usage
s_closed: .ascii "connection closed before the response completed\n"
	.set s_closed_len, .-s_closed
s_connect: .ascii "connect failed\n"
	.set s_connect_len, .-s_connect
s_noresolve: .ascii "cannot resolve host\n"
	.set s_noresolve_len, .-s_noresolve
s_opt_resolve: .asciz "--resolve"
	.set s_connect_len, .-s_connect
s_grpc_error: .ascii "grpc error "
s_rows:	.ascii " row(s)\n"
s_replay_auth: .ascii "127.0.0.1:15003"
	.globl s_path_exec, s_path_analyze
s_path_exec:    .ascii "/spark.connect.SparkConnectService/ExecutePlan"
s_path_analyze: .ascii "/spark.connect.SparkConnectService/AnalyzePlan"

	.bss
remote:	.quad 0
replay_file: .quad 0
grpc_file: .quad 0
sql:	.quad 0
path:	.quad 0
path_len: .long 0
req_len: .long 0
readbuf_ptr: .quad 0
analyze_kind: .long 0
sock_fd: .long 0
mode:	.long 0
	.balign 4
sockaddr: .space 16
