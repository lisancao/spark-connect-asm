# HTTP/2 client, enough for gRPC: one request stream at a time. Port of the wasm h2 module.
	.include "src/layout.inc"
	.text
	.globl h2_connect, h2_request, on_bytes, h2_phase, done_code, done_msg, done_len

# send_frame(type, flags, stream, payload, len): 9-byte header then payload; dropped on replay
send_frame:
	push %rbx
	push %r12
	push %r13
	mov %rcx, %r12
	mov %r8d, %r13d
	lea mem+FRAME_HDR(%rip), %rbx
	mov %r8d, %eax
	shr $16, %eax
	mov %al, (%rbx)
	mov %r8d, %eax
	shr $8, %eax
	mov %al, 1(%rbx)
	mov %r8b, 2(%rbx)
	mov %dil, 3(%rbx)
	mov %sil, 4(%rbx)
	mov %edx, %eax
	bswap %eax
	mov %eax, 5(%rbx)
	cmpl $0, sock_fd(%rip)
	js 9f
	mov sock_fd(%rip), %edi
	mov %rbx, %rsi
	mov $9, %edx
	call sys_write
	test %r13d, %r13d
	jz 9f
	mov sock_fd(%rip), %edi
	mov %r12, %rsi
	mov %r13d, %edx
	call sys_write
9:	pop %r13
	pop %r12
	pop %rbx
	ret

# h2_connect(authority ptr, len, tls): reset state, preface, SETTINGS, WINDOW_UPDATE
h2_connect:
	push %rbx
	movl $1, h2_next(%rip)
	movl $0, h2_stream(%rip)
	movl $0, h2_phase(%rip)
	mov %edx, h2_tls(%rip)
	movl $0, rb_len(%rip)
	movl $0, hb_len(%rip)
	call hpack_reset
	call huff_build
	cmp $255, %esi
	jbe 1f
	mov $255, %esi
1:	mov %esi, auth_len(%rip)
	mov %esi, %ecx
	mov %rdi, %rsi
	lea mem+AUTHORITY(%rip), %rdi
	rep movsb
	cmpl $0, sock_fd(%rip)
	js 2f
	mov sock_fd(%rip), %edi
	lea s_preface(%rip), %rsi
	mov $24, %edx
	call sys_write
2:	mov $4, %edi
	xor %esi, %esi
	xor %edx, %edx
	lea s_settings(%rip), %rcx
	mov $18, %r8d
	call send_frame
	mov $8, %edi
	xor %esi, %esi
	xor %edx, %edx
	lea s_winupd(%rip), %rcx
	mov $4, %r8d
	call send_frame
	pop %rbx
	ret

wr_byte2:                               # byte in dil at wp2
	mov wp2(%rip), %rax
	mov %dil, (%rax)
	incq wp2(%rip)
	ret

# h2_request(path, plen, payload, len, mode): payload has 5 spare bytes in front
h2_request:
	push %rbx
	push %r12
	push %r13
	push %r14
	push %r15
	mov %rdi, %r12
	mov %esi, %r13d
	mov %rdx, %r14
	mov %ecx, %r15d
	mov %r8d, h2_mode(%rip)
	mov h2_next(%rip), %eax
	mov %eax, h2_stream(%rip)
	addl $2, h2_next(%rip)
	movl $1, h2_phase(%rip)
	movl $-1, grpc_status(%rip)
	movl $0, http_status(%rip)
	movq $0, gmsg_ptr(%rip)
	movl $0, gmsg_len(%rip)
	movl $0, hb_len(%rip)
	lea mem+HDRBLK(%rip), %rax
	mov %rax, wp2(%rip)
	mov $0x83, %edi                 # :method POST
	call wr_byte2
	mov $0x86, %edi                 # :scheme http
	cmpl $0, h2_tls(%rip)
	je 1f
	mov $0x87, %edi
1:	call wr_byte2
	mov $0x04, %edi                 # :path (name index 4)
	call wr_byte2
	mov %r12, %rdi
	mov %r13d, %esi
	call hp_wstr
	mov $0x01, %edi                 # :authority (name index 1)
	call wr_byte2
	lea mem+AUTHORITY(%rip), %rdi
	mov auth_len(%rip), %esi
	call hp_wstr
	mov $4, %edi                    # content-type (name index 31)
	xor %esi, %esi
	mov $31, %edx
	call hp_wint
	lea s_ct(%rip), %rdi
	mov $16, %esi
	call hp_wstr
	xor %edi, %edi                  # te: trailers (new name)
	call wr_byte2
	lea s_te(%rip), %rdi
	mov $2, %esi
	call hp_wstr
	lea s_trailers(%rip), %rdi
	mov $8, %esi
	call hp_wstr
	mov $4, %edi                    # user-agent (name index 58)
	xor %esi, %esi
	mov $58, %edx
	call hp_wint
	lea s_ua(%rip), %rdi
	mov $21, %esi
	call hp_wstr
	mov $1, %edi                    # HEADERS, END_HEADERS
	mov $4, %esi
	mov h2_stream(%rip), %edx
	lea mem+HDRBLK(%rip), %rcx
	mov wp2(%rip), %r8
	sub %rcx, %r8
	call send_frame
	# gRPC prefix, then DATA frames of at most 16384 bytes
	lea -5(%r14), %rbx
	movb $0, (%rbx)
	mov %r15d, %eax
	bswap %eax
	mov %eax, 1(%rbx)
	lea 5(%r15), %r12d              # total
2:	mov $16384, %r13d
	cmp %r12d, %r13d
	cmovae %r12d, %r13d             # chunk
	xor %esi, %esi
	cmp %r12d, %r13d
	jne 3f
	mov $1, %esi                    # END_STREAM
3:	xor %edi, %edi
	mov h2_stream(%rip), %edx
	mov %rbx, %rcx
	mov %r13d, %r8d
	call send_frame
	add %r13, %rbx
	sub %r13d, %r12d
	jnz 2b
	pop %r15
	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# fail(code, msg, len)
fail:
	cmpl $3, h2_phase(%rip)
	je 1f
	movl $3, h2_phase(%rip)
	mov %edi, done_code(%rip)
	mov %rsi, done_msg(%rip)
	mov %edx, done_len(%rip)
1:	ret

finish:
	cmpl $3, h2_phase(%rip)
	je 9f
	movl $3, h2_phase(%rip)
	mov http_status(%rip), %eax
	test %eax, %eax
	jz 1f
	cmp $200, %eax
	je 1f
	movl $14, done_code(%rip)
	lea s_http(%rip), %rax
	mov %rax, done_msg(%rip)
	movl $22, done_len(%rip)
	ret
1:	mov grpc_status(%rip), %eax
	test %eax, %eax
	jns 2f
	movl $2, done_code(%rip)
	lea s_nostatus(%rip), %rax
	mov %rax, done_msg(%rip)
	movl $19, done_len(%rip)
	ret
2:	mov %eax, done_code(%rip)
	mov gmsg_ptr(%rip), %rax
	mov %rax, done_msg(%rip)
	mov gmsg_len(%rip), %eax
	mov %eax, done_len(%rip)
9:	ret

# hb_append(p, n)
hb_append:
	mov hb_len(%rip), %eax
	lea (%rax,%rsi), %ecx
	cmp $0x10000, %ecx
	jbe 1f
	mov $2, %edi
	lea s_hbig(%rip), %rsi
	mov $22, %edx
	jmp fail
1:	mov %ecx, hb_len(%rip)
	lea mem+HDRBLK(%rip), %rdx
	add %rax, %rdx
	mov %rsi, %rax
	mov %rdi, %rsi
	mov %rdx, %rdi
	mov %eax, %ecx
	rep movsb
	ret

headers_done:
	lea mem+HDRBLK(%rip), %rdi
	mov hb_len(%rip), %eax
	lea (%rdi,%rax), %rsi
	call hp_decode
	movl $0, hb_len(%rip)
	cmpl $0, hp_err(%rip)
	je 1f
	mov $2, %edi
	lea s_hpack(%rip), %rsi
	mov $20, %edx
	jmp fail
1:	cmpl $0, hb_end_stream(%rip)
	je 2f
	jmp finish
2:	ret

# process_frame: one complete frame sits at mem+FRAME_BUF
process_frame:
	push %rbx
	push %r12
	push %r13
	push %r14
	lea mem+FRAME_BUF(%rip), %rax
	movzbl 3(%rax), %ebx            # type
	movzbl 4(%rax), %r12d           # flags
	mov 5(%rax), %r13d
	bswap %r13d
	and $0x7fffffff, %r13d          # stream
	lea 9(%rax), %r14               # payload
	mov rb_need(%rip), %ecx
	sub $9, %ecx                    # plen -> keep in r8d via stack
	mov %ecx, %r8d
	cmp $1, %ebx
	ja 1f
	test $8, %r12d                  # PADDED (DATA, HEADERS)
	jz 1f
	movzbl (%r14), %eax
	inc %eax
	sub %eax, %r8d
	inc %r14
1:	test %ebx, %ebx
	jnz 10f
	# DATA
	cmp h2_stream(%rip), %r13d
	jne 99f
	mov %r14, %rdi
	mov %r8d, %esi
	call grpc_feed
	test $1, %r12d
	jz 99f
	call finish
	jmp 99f
10:	cmp $1, %ebx
	jne 20f
	# HEADERS
	cmp h2_stream(%rip), %r13d
	jne 99f
	test $0x20, %r12d               # PRIORITY
	jz 11f
	add $5, %r14
	sub $5, %r8d
11:	mov %r12d, %eax
	and $1, %eax
	mov %eax, hb_end_stream(%rip)
	mov %r14, %rdi
	mov %r8d, %esi
	call hb_append
	test $4, %r12d
	jz 99f
	call headers_done
	jmp 99f
20:	cmp $9, %ebx
	jne 30f
	# CONTINUATION
	cmp h2_stream(%rip), %r13d
	jne 99f
	mov %r14, %rdi
	mov %r8d, %esi
	call hb_append
	test $4, %r12d
	jz 99f
	call headers_done
	jmp 99f
30:	cmp $4, %ebx
	jne 40f
	# SETTINGS -> ack
	test $1, %r12d
	jnz 99f
	mov $4, %edi
	mov $1, %esi
	xor %edx, %edx
	xor %ecx, %ecx
	xor %r8d, %r8d
	call send_frame
	jmp 99f
40:	cmp $6, %ebx
	jne 50f
	# PING -> ack
	test $1, %r12d
	jnz 99f
	mov $6, %edi
	mov $1, %esi
	xor %edx, %edx
	mov %r14, %rcx
	mov $8, %r8d
	call send_frame
	jmp 99f
50:	cmp $3, %ebx
	jne 60f
	cmp h2_stream(%rip), %r13d
	jne 99f
	mov $13, %edi
	lea s_rst(%rip), %rsi
	mov $22, %edx
	call fail
	jmp 99f
60:	cmp $7, %ebx
	jne 99f
	mov $14, %edi
	lea s_goaway(%rip), %rsi
	mov $18, %edx
	call fail
99:	pop %r14
	pop %r13
	pop %r12
	pop %rbx
	ret

# on_bytes(p, n): socket bytes in any chunking
on_bytes:
	push %rbx
	push %r12
	push %r13
	mov %rdi, %rbx
	mov %esi, %r12d
1:	test %r12d, %r12d
	jz 9f
	mov rb_len(%rip), %eax
	cmp $9, %eax
	jae 3f
	mov $9, %r13d
	sub %eax, %r13d                 # take = 9 - rb_len
	cmp %r12d, %r13d
	cmova %r12d, %r13d
	lea mem+FRAME_BUF(%rip), %rdi
	add %rax, %rdi
	mov %rbx, %rsi
	mov %r13d, %ecx
	rep movsb
	add %r13d, rb_len(%rip)
	add %r13, %rbx
	sub %r13d, %r12d
	cmpl $9, rb_len(%rip)
	jne 1b
	lea mem+FRAME_BUF(%rip), %rax
	movzbl (%rax), %ecx
	shl $16, %ecx
	movzbl 1(%rax), %edx
	shl $8, %edx
	or %edx, %ecx
	movzbl 2(%rax), %edx
	or %edx, %ecx                   # payload length
	cmp $16384, %ecx
	jbe 2f
	mov $2, %edi
	lea s_fbig(%rip), %rsi
	mov $23, %edx
	call fail
	jmp 9f
2:	add $9, %ecx
	mov %ecx, rb_need(%rip)
	jmp 1b
3:	mov rb_need(%rip), %r13d
	sub %eax, %r13d                 # take = need - len
	cmp %r12d, %r13d
	cmova %r12d, %r13d
	lea mem+FRAME_BUF(%rip), %rdi
	add %rax, %rdi
	mov %rbx, %rsi
	mov %r13d, %ecx
	rep movsb
	add %r13d, rb_len(%rip)
	add %r13, %rbx
	sub %r13d, %r12d
	mov rb_len(%rip), %eax
	cmp rb_need(%rip), %eax
	jne 1b
	call process_frame
	movl $0, rb_len(%rip)
	jmp 1b
9:	pop %r13
	pop %r12
	pop %rbx
	ret

	.section .rodata
s_preface: .ascii "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
s_settings: .byte 0,2, 0,0,0,0, 0,4, 0x7f,0xff,0xff,0xff, 0,5, 0,0,0x40,0
s_winupd: .byte 0x7f,0xff,0,0
s_ct:	.ascii "application/grpc"
s_te:	.ascii "te"
s_trailers: .ascii "trailers"
s_ua:	.ascii "spark-connect-asm/0.1"
s_http:	.ascii "HTTP status is not 200"
s_nostatus: .ascii "missing grpc-status"
s_goaway: .ascii "GOAWAY from server"
s_rst:	.ascii "RST_STREAM from server"
s_fbig:	.ascii "frame larger than 16384"
s_hpack: .ascii "HPACK decoding error"
s_hbig:	.ascii "header block too large"

	.bss
	.balign 8
done_msg: .quad 0
h2_stream: .long 0
h2_next: .long 0
h2_phase: .long 0
h2_tls:	.long 0
auth_len: .long 0
rb_len:	.long 0
rb_need: .long 0
hb_len:	.long 0
hb_end_stream: .long 0
done_code: .long 0
done_len: .long 0
