# Name resolution without libc: dotted quads, localhost, /etc/hosts, then a UDP query to the
# first nameserver in /etc/resolv.conf.
	.include "src/layout.inc"
	.text
	.globl resolve_host

# read_file(path) -> rax buffer (NUL-terminated), edx length; 0 if unreadable
read_file:
	push %rbx
	push %r12
	xor %esi, %esi
	call sys_open
	test %eax, %eax
	js 9f
	mov %eax, %r12d
	mov $65536, %edi
	call alloc
	mov %rax, %rbx
	mov %r12d, %edi
	mov %rbx, %rsi
	mov $65535, %edx
	call sys_read
	test %rax, %rax
	js 9f
	movb $0, (%rbx,%rax)
	mov %eax, %edx
	mov %rbx, %rax
	pop %r12
	pop %rbx
	ret
9:	xor %eax, %eax
	xor %edx, %edx
	pop %r12
	pop %rbx
	ret

# parse_ipv4(ptr, len) -> eax address in network order, or 0 when not a dotted quad
	.globl parse_ipv4
parse_ipv4:
	push %rbx
	xor %ebx, %ebx                  # result
	xor %ecx, %ecx                  # octets done
	xor %eax, %eax                  # current
	xor %r8d, %r8d                  # digits in current
1:	test %esi, %esi
	jz 3f
	movzbl (%rdi), %edx
	inc %rdi
	dec %esi
	cmp $'.', %dl
	je 2f
	sub $'0', %edx
	cmp $9, %edx
	ja 8f
	imul $10, %eax
	add %edx, %eax
	cmp $255, %eax
	ja 8f
	inc %r8d
	jmp 1b
2:	test %r8d, %r8d
	jz 8f
	cmp $3, %ecx
	jae 8f
	shl $8, %ebx
	or %eax, %ebx
	inc %ecx
	xor %eax, %eax
	xor %r8d, %r8d
	jmp 1b
3:	cmp $3, %ecx
	jne 8f
	test %r8d, %r8d
	jz 8f
	shl $8, %ebx
	or %eax, %ebx
	mov %ebx, %eax
	bswap %eax
	pop %rbx
	ret
8:	xor %eax, %eax
	pop %rbx
	ret

# token helpers over a NUL-terminated buffer: skip spaces/tabs; token length
skip_ws:
1:	movzbl (%rdi), %eax
	cmp $' ', %al
	je 2f
	cmp $'\t', %al
	jne 3f
2:	inc %rdi
	jmp 1b
3:	ret
tok_len:                                # -> eax
	xor %eax, %eax
1:	movzbl (%rdi,%rax), %ecx
	test %cl, %cl
	jz 2f
	cmp $' ', %cl
	je 2f
	cmp $'\t', %cl
	je 2f
	cmp $'\n', %cl
	je 2f
	cmp $'\r', %cl
	je 2f
	cmp $'#', %cl
	je 2f
	inc %eax
	jmp 1b
2:	ret
next_line:                              # rdi -> after the next '\n' (or at NUL)
1:	movzbl (%rdi), %eax
	test %al, %al
	jz 2f
	inc %rdi
	cmp $'\n', %al
	jne 1b
2:	ret

# memeq(a, b, n) -> eax
memeq:
	mov %edx, %ecx
	repe cmpsb
	sete %al
	movzbl %al, %eax
	ret

# hosts_lookup(name, len) -> eax address or 0
hosts_lookup:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	mov %rdi, %r12
	mov %esi, %r13d
	lea s_hosts(%rip), %rdi
	call read_file
	test %rax, %rax
	jz 8f
	mov %rax, %rbx
1:	cmpb $0, (%rbx)
	je 8f
	mov %rbx, %rdi
	call skip_ws
	mov %rdi, %rbx
	cmpb $'#', (%rbx)
	je 7f
	mov %rbx, %rdi
	call tok_len
	test %eax, %eax
	jz 7f
	mov %rbx, %rdi
	mov %eax, %esi
	mov %eax, %r14d
	call parse_ipv4
	mov %eax, %r15d                 # address of this line
	add %r14, %rbx
	test %r15d, %r15d
	jz 7f
2:	mov %rbx, %rdi                  # names on the line
	call skip_ws
	mov %rdi, %rbx
	mov %rbx, %rdi
	call tok_len
	test %eax, %eax
	jz 7f
	mov %eax, %r14d
	cmp %r13d, %eax
	jne 3f
	mov %rbx, %rdi
	mov %r12, %rsi
	mov %r13d, %edx
	call memeq
	test %eax, %eax
	jz 3f
	mov %r15d, %eax
	jmp 9f
3:	add %r14, %rbx
	jmp 2b
7:	mov %rbx, %rdi
	call next_line
	mov %rdi, %rbx
	jmp 1b
8:	xor %eax, %eax
9:	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# nameserver() -> eax: first "nameserver a.b.c.d" in /etc/resolv.conf, or 0
nameserver:
	push %rbx
	lea s_resolv(%rip), %rdi
	call read_file
	test %rax, %rax
	jz 8f
	mov %rax, %rbx
1:	cmpb $0, (%rbx)
	je 8f
	mov %rbx, %rdi
	call skip_ws
	mov %rdi, %rbx
	mov %rbx, %rdi
	lea s_nameserver(%rip), %rsi
	mov $11, %edx
	call memeq
	test %eax, %eax
	jz 7f
	lea 11(%rbx), %rdi
	call skip_ws
	mov %rdi, %rbx
	call tok_len
	mov %rbx, %rdi
	mov %eax, %esi
	call parse_ipv4
	test %eax, %eax
	jnz 9f
7:	mov %rbx, %rdi
	call next_line
	mov %rdi, %rbx
	jmp 1b
8:	xor %eax, %eax
9:	pop %rbx
	ret

# dns_query(name, len, server) -> eax address or 0: one A query over UDP, 5 s timeout
dns_query:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	sub $32, %rsp
	mov %rdi, %r12
	mov %esi, %r13d
	mov %edx, %r14d
	mov $1024, %edi
	call alloc
	mov %rax, %rbx                  # packet buffer
	# header: id, flags 0x0100 (RD), qdcount 1
	lea mem+UUIDRAW(%rip), %rdi
	mov $2, %esi
	call sys_getrandom
	mov mem+UUIDRAW(%rip), %ax
	mov %ax, (%rbx)
	movw $0x0001, 2(%rbx)           # 0x0100 big-endian
	movw $0x0100, 4(%rbx)           # qdcount = 1
	movl $0, 6(%rbx)
	movw $0, 10(%rbx)
	# question: labels
	lea 12(%rbx), %rdi              # write pointer
	xor %ecx, %ecx                  # consumed
1:	mov %rdi, %r15                  # length byte slot
	inc %rdi
	xor %edx, %edx                  # label length
2:	cmp %r13d, %ecx
	jae 3f
	movzbl (%r12,%rcx), %eax
	cmp $'.', %al
	je 3f
	mov %al, (%rdi)
	inc %rdi
	inc %edx
	inc %ecx
	jmp 2b
3:	mov %dl, (%r15)
	cmp %r13d, %ecx
	jae 4f
	inc %ecx
	jmp 1b
4:	movb $0, (%rdi)
	movl $0x01000100, 1(%rdi)       # type A, class IN (both 0x0001 big-endian)
	add $5, %rdi
	sub %rbx, %rdi
	mov %edi, %r15d                 # packet length
	# udp socket with a receive timeout
	mov $2, %edi
	mov $2, %esi
	xor %edx, %edx
	call sys_socket
	test %eax, %eax
	js 8f
	mov %eax, %r12d
	movq $5, (%rsp)                 # timeval {5, 0}
	movq $0, 8(%rsp)
	mov %r12d, %edi
	mov $1, %esi                    # SOL_SOCKET
	mov $20, %edx                   # SO_RCVTIMEO
	mov %rsp, %r10
	mov $16, %r8d
	mov $54, %eax                   # setsockopt
	syscall
	# sendto
	movw $2, 16(%rsp)
	movw $0x3500, 18(%rsp)          # port 53
	mov %r14d, 20(%rsp)
	movq $0, 24(%rsp)
	mov %r12d, %edi
	mov %rbx, %rsi
	mov %r15d, %edx
	xor %r10d, %r10d
	lea 16(%rsp), %r8
	mov $16, %r9d
	mov $44, %eax                   # sendto
	syscall
	test %rax, %rax
	js 8f
	mov %r12d, %edi
	mov %rbx, %rsi
	mov $1024, %edx
	call sys_read
	cmp $12, %rax
	jl 8f
	mov %eax, %r13d                 # response length
	movzwl 6(%rbx), %eax
	xchg %al, %ah
	mov %eax, %r14d                 # ancount
	# skip the question
	lea 12(%rbx), %rdi
	call skip_name
	add $4, %rdi
5:	test %r14d, %r14d
	jz 8f
	call skip_name                  # answer name
	movzwl (%rdi), %eax
	xchg %al, %ah                   # type
	movzwl 8(%rdi), %ecx
	xchg %cl, %ch                   # rdlength
	add $10, %rdi
	cmp $1, %eax
	jne 6f
	cmp $4, %ecx
	jne 6f
	mov (%rdi), %eax
	jmp 9f
6:	add %rcx, %rdi
	dec %r14d
	jmp 5b
8:	xor %eax, %eax
9:	add $32, %rsp
	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# skip_name: rdi past a DNS name (labels or a compression pointer)
skip_name:
1:	movzbl (%rdi), %eax
	test %al, %al
	jz 2f
	test $0xc0, %al
	jnz 3f
	lea 1(%rdi,%rax), %rdi
	jmp 1b
2:	inc %rdi
	ret
3:	add $2, %rdi
	ret

# resolve_host(name, len) -> eax address in network order, or 0
resolve_host:
	push %rbx
	push %r12
	mov %rdi, %rbx
	mov %esi, %r12d
	call parse_ipv4
	test %eax, %eax
	jnz 9f
	cmp $9, %r12d
	jne 1f
	mov %rbx, %rdi
	lea s_localhost(%rip), %rsi
	mov $9, %edx
	call memeq
	test %eax, %eax
	jz 1f
	mov $0x0100007f, %eax
	jmp 9f
1:	mov %rbx, %rdi
	mov %r12d, %esi
	call hosts_lookup
	test %eax, %eax
	jnz 9f
	call nameserver
	test %eax, %eax
	jz 8f
	mov %eax, %edx
	mov %rbx, %rdi
	mov %r12d, %esi
	call dns_query
	jmp 9f
8:	xor %eax, %eax
9:	pop %r12
	pop %rbx
	ret

	.section .rodata
s_hosts: .asciz "/etc/hosts"
s_resolv: .asciz "/etc/resolv.conf"
s_nameserver: .ascii "nameserver "
s_localhost: .ascii "localhost"
